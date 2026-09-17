using Facturacion.Cpe;
using Facturacion.Persistencia;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;

namespace Facturacion.Worker;

/// <summary>
/// Procesa las guías de remisión: las firma, las envía y consulta el ticket.
///
/// POR QUÉ ES UN SERVICIO APARTE Y NO PARTE DEL WORKER DE COMPROBANTES:
///
/// El ritmo es incompatible. Las facturas se envían y se olvidan; las guías
/// tienen un vehículo esperando la constancia para salir, así que se
/// consultan cada pocos segundos.
///
/// Si compartieran bucle, o las facturas irían demasiado rápido o las guías
/// demasiado lento. Es la misma razón por la que los resúmenes y los webhooks
/// también tienen el suyo.
/// </summary>
public sealed class ProcesadorGuias
{
    private readonly RepositorioGuias _guias;
    private readonly AlmacenCertificados _certificados;
    private readonly ProveedorCredenciales _credenciales;
    private readonly IAlmacenArchivos _archivos;
    private readonly ILogger<ProcesadorGuias> _log;

    public ProcesadorGuias(
        RepositorioGuias guias,
        AlmacenCertificados certificados,
        ProveedorCredenciales credenciales,
        IAlmacenArchivos archivos,
        ILogger<ProcesadorGuias> log)
    {
        _guias = guias;
        _certificados = certificados;
        _credenciales = credenciales;
        _archivos = archivos;
        _log = log;
    }

    /// <summary>Procesa un lote: envía las nuevas y consulta las enviadas.</summary>
    public async Task<int> ProcesarLoteAsync(int limite, CancellationToken ct)
    {
        var trabajos = await _guias.ReclamarAsync(limite, ct);

        if (trabajos.Count == 0) return 0;

        foreach (var trabajo in trabajos)
        {
            try
            {
                if (trabajo.Estado == "ENVIADO" && trabajo.Ticket is not null)
                    await ConsultarAsync(trabajo, ct);
                else
                    await EnviarAsync(trabajo, ct);
            }
            catch (Exception ex)
            {
                // Un fallo en una guía no debe frenar el lote: las demás
                // pueden tener su propio vehículo esperando.
                _log.LogError(ex,
                    "Fallo inesperado procesando la guía {Numero}.", trabajo.Numero);

                await _guias.AnotarFalloAsync(
                    trabajo.TenantId, trabajo.Id,
                    $"Error interno: {ex.Message}", reintentable: true, ct);
            }
        }

        return trabajos.Count;
    }

    // ------------------------------------------------------------- envío

    private async Task EnviarAsync(TrabajoGuia trabajo, CancellationToken ct)
    {
        var guia = RepositorioGuias.Deserializar(trabajo.GreJson);

        // Se revisa otra vez antes de enviar.
        //
        // Ya se revisó al crearla, pero entre una cosa y otra pudo cambiar
        // algo: una serie cerrada, una fecha que ya pasó. Cuesta microsegundos
        // y evita un rechazo con el camión esperando.
        var problemas = guia.Revisar();

        if (problemas.Count > 0)
        {
            await _guias.AnotarFalloAsync(
                trabajo.TenantId, trabajo.Id,
                "La guía no pasa la revisión: " + string.Join(" ", problemas),
                reintentable: false, ct);

            return;
        }

        var certificado = await _certificados.ObtenerActivoAsync(trabajo.TenantId, ct);

        if (certificado is null)
        {
            await _guias.AnotarFalloAsync(
                trabajo.TenantId, trabajo.Id,
                "La empresa no tiene certificado digital activo.",
                reintentable: false, ct);

            return;
        }

        ConfiguracionGre configuracion;

        try
        {
            configuracion = await ResolverConfiguracionAsync(trabajo.TenantId, ct);
        }
        catch (Exception ex)
        {
            await _guias.AnotarFalloAsync(
                trabajo.TenantId, trabajo.Id, ex.Message,
                reintentable: false, ct);

            return;
        }

        // --- Generar, firmar y comprimir ---

        var xml = GeneradorGuiaXml.Generar(guia);
        var firmado = FirmadorXml.Firmar(xml, certificado);

        // UTF-8 SIN BOM: los tres bytes de marca invalidan la firma, porque
        // no formaban parte de lo que se firmó.
        var sinBom = new System.Text.UTF8Encoding(false);

        using var memoria = new MemoryStream();

        using (var escritor = new System.Xml.XmlTextWriter(memoria, sinBom))
            firmado.Save(escritor);

        var bytesXml = memoria.ToArray();
        var zip = EmpaquetadorZip.Comprimir(guia.NombreArchivo, bytesXml);

        // Se guarda el XML ANTES de enviarlo.
        //
        // Si el envío falla a mitad, el documento firmado ya existe y se
        // puede inspeccionar. Guardarlo después dejaría sin rastro justo el
        // caso que hay que investigar.
        var rutaXml = await _archivos.GuardarAsync(
            guia.Remitente.Ruc, guia.FechaEmision,
            $"{guia.NombreArchivo}.xml", bytesXml, ct);

        // --- Enviar ---

        using var cliente = new ClienteGre(configuracion);

        var envio = await cliente.EnviarAsync($"{guia.NombreArchivo}.zip", zip, ct);

        if (!envio.Exitoso)
        {
            _log.LogWarning(
                "Guía {Numero} no enviada: {Mensaje}", trabajo.Numero, envio.Mensaje);

            await _guias.AnotarFalloAsync(
                trabajo.TenantId, trabajo.Id, envio.Mensaje,
                envio.EsReintentable, ct);

            return;
        }

        _log.LogInformation(
            "Guía {Numero} enviada. Ticket {Ticket}.", trabajo.Numero, envio.Ticket);

        await _guias.GuardarTicketAsync(
            trabajo.TenantId, trabajo.Id, envio.Ticket!, rutaXml, ct);
    }

    // ---------------------------------------------------------- consulta

    private async Task ConsultarAsync(TrabajoGuia trabajo, CancellationToken ct)
    {
        ConfiguracionGre configuracion;

        try
        {
            configuracion = await ResolverConfiguracionAsync(trabajo.TenantId, ct);
        }
        catch (Exception ex)
        {
            await _guias.AnotarFalloAsync(
                trabajo.TenantId, trabajo.Id, ex.Message, reintentable: false, ct);

            return;
        }

        using var cliente = new ClienteGre(configuracion);

        var estado = await cliente.ConsultarAsync(trabajo.Ticket!, ct);

        if (!estado.Terminado)
        {
            // Sigue en proceso. Se anota como fallo reintentable para que el
            // backoff programe la siguiente consulta, no porque haya fallado
            // nada.
            await _guias.AnotarFalloAsync(
                trabajo.TenantId, trabajo.Id,
                estado.Descripcion, reintentable: true, ct);

            return;
        }

        var guia = RepositorioGuias.Deserializar(trabajo.GreJson);

        string? rutaCdr = null;

        if (estado.CdrZip is not null)
        {
            rutaCdr = await _archivos.GuardarAsync(
                guia.Remitente.Ruc, guia.FechaEmision,
                $"R-{guia.NombreArchivo}.zip", estado.CdrZip, ct);
        }

        // El mensaje guardado incluye las observaciones.
        //
        // Una guía aceptada con observaciones es válida, pero esas
        // observaciones pueden sancionarse en una fiscalización. Perderlas
        // sería quitarle al cliente la única pista de que algo no está bien.
        var mensaje = estado.Descripcion;

        if (estado.Observaciones.Count > 0)
            mensaje += " | Observaciones: " + string.Join("; ", estado.Observaciones);

        await _guias.ResolverAsync(
            trabajo.TenantId, trabajo.Id, estado.Aceptado,
            estado.CodigoRespuesta, mensaje, rutaCdr, ct);

        if (estado.Aceptado)
        {
            _log.LogInformation(
                "Guía {Numero} ACEPTADA. El traslado puede iniciarse.",
                trabajo.Numero);
        }
        else
        {
            // Se registra como aviso, no como error: el sistema hizo su
            // trabajo. El problema está en los datos de la guía.
            _log.LogWarning(
                "Guía {Numero} RECHAZADA ({Codigo}): {Mensaje}",
                trabajo.Numero, estado.CodigoRespuesta, mensaje);
        }
    }

    // ------------------------------------------------------------- apoyo

    /// <summary>
    /// Arma la configuración de la GRE para una empresa.
    ///
    /// Necesita cuatro credenciales: el client_id y el client_secret que el
    /// contribuyente generó en su menú SOL, más el usuario y la clave SOL.
    /// Las dos primeras son solo para guías; las dos últimas se comparten
    /// con las facturas.
    /// </summary>
    private async Task<ConfiguracionGre> ResolverConfiguracionAsync(
        Guid tenantId, CancellationToken ct)
    {
        var gre = await _credenciales.ObtenerGreAsync(tenantId, ct);

        return gre;
    }
}

/// <summary>
/// El bucle que procesa las guías.
///
/// CADA 10 SEGUNDOS, mucho más seguido que el de resúmenes, que va cada
/// minuto. La razón es siempre la misma: hay un vehículo esperando la
/// constancia para poder salir.
/// </summary>
public sealed class ServicioGuias : BackgroundService
{
    private readonly ProcesadorGuias _procesador;
    private readonly ILogger<ServicioGuias> _log;
    private readonly TimeSpan _intervalo;
    private readonly int _lote;

    public ServicioGuias(
        ProcesadorGuias procesador,
        Microsoft.Extensions.Configuration.IConfiguration configuracion,
        ILogger<ServicioGuias> log)
    {
        _procesador = procesador;
        _log = log;

        _intervalo = TimeSpan.FromSeconds(
            configuracion.GetValue("Guias:IntervaloSegundos", 10));

        _lote = configuracion.GetValue("Guias:TamanoLote", 20);
    }

    protected override async Task ExecuteAsync(CancellationToken ct)
    {
        _log.LogInformation(
            "Servicio de guías iniciado. Ciclo cada {Intervalo}, lote {Lote}.",
            _intervalo, _lote);

        while (!ct.IsCancellationRequested)
        {
            try
            {
                var procesadas = await _procesador.ProcesarLoteAsync(_lote, ct);

                // Si había trabajo, se vuelve enseguida en vez de esperar el
                // ciclo completo: puede haber más guías en cola.
                if (procesadas > 0) continue;
            }
            catch (OperationCanceledException) when (ct.IsCancellationRequested)
            {
                break;
            }
            catch (Exception ex)
            {
                _log.LogError(ex, "Error en el ciclo de guías. Se reintenta.");
            }

            try
            {
                await Task.Delay(_intervalo, ct);
            }
            catch (OperationCanceledException) { break; }
        }

        _log.LogInformation("Servicio de guías detenido.");
    }
}
