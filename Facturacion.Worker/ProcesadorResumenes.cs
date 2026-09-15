using System.Text.Json;
using Facturacion.Cpe;
using Facturacion.Persistencia;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;

namespace Facturacion.Worker;

/// <summary>
/// Arma, envía y cierra los resúmenes diarios de boletas.
///
/// EL FLUJO COMPLETO, QUE ES DE TRES TIEMPOS:
///
///   1. Agrupar: se juntan las boletas de un emisor y una fecha ya cerrada,
///      y se crea el resumen que las informa.
///
///   2. Enviar: se genera el XML, se firma y se manda con sendSummary.
///      SUNAT devuelve un TICKET, no un CDR: solo acusa recibo.
///
///   3. Consultar: más tarde se pregunta por ese ticket. Recién ahí SUNAT
///      dice si acepta el resumen, y ese desenlace se aplica a todas las
///      boletas que informaba.
///
/// Los tres pasos están separados a propósito. Encadenarlos en una sola
/// operación obligaría a esperar a SUNAT con todo en la mano, y si el proceso
/// muriera en medio, las boletas quedarían en un limbo del que nadie las
/// rescataría.
/// </summary>
public sealed class ProcesadorResumenes
{
    private static readonly JsonSerializerOptions OpcionesJson = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        PropertyNameCaseInsensitive = true
    };

    private readonly RepositorioResumenes _resumenes;
    private readonly ColaTrabajos _cola;
    private readonly AlmacenCertificados _certificados;
    private readonly ProveedorCredenciales _credenciales;
    private readonly IAlmacenArchivos _archivos;
    private readonly ILogger<ProcesadorResumenes> _log;

    public ProcesadorResumenes(
        RepositorioResumenes resumenes,
        ColaTrabajos cola,
        AlmacenCertificados certificados,
        ProveedorCredenciales credenciales,
        IAlmacenArchivos archivos,
        ILogger<ProcesadorResumenes> log)
    {
        _resumenes = resumenes;
        _cola = cola;
        _certificados = certificados;
        _credenciales = credenciales;
        _archivos = archivos;
        _log = log;
    }

    // ------------------------------------------------------- 1. agrupar

    public async Task AgruparAsync(CancellationToken ct)
    {
        var lotes = await _resumenes.BuscarLotesAsync(ct);

        foreach (var lote in lotes)
        {
            try
            {
                var armado = await _resumenes.ArmarResumenAsync(
                    lote.TenantId, lote.FechaEmision, ct);

                if (armado is null) continue;

                _log.LogInformation(
                    "Resumen {Identificador} armado con {Cantidad} boleta(s) del {Fecha}.",
                    armado.Value.Resumen.Identificador,
                    armado.Value.Boletas.Count,
                    lote.FechaEmision);
            }
            catch (Exception ex)
            {
                _log.LogError(ex,
                    "No se pudo armar el resumen de {Fecha} para el emisor {Tenant}.",
                    lote.FechaEmision, lote.TenantId);
            }
        }
    }

    // -------------------------------------------------------- 2. enviar

    public async Task EnviarPendientesAsync(CancellationToken ct)
    {
        foreach (var resumen in await _resumenes.BuscarPorEnviarAsync(ct: ct))
        {
            try { await EnviarAsync(resumen, ct); }
            catch (Exception ex)
            {
                _log.LogError(ex, "Falló el envío de {Id}", resumen.Identificador);

                await _resumenes.ProgramarReintentoAsync(
                    resumen.Id,
                    EsperaReintento.Calcular(resumen.IntentosFallidos),
                    ex.Message, ct);
            }
        }
    }

    private async Task EnviarAsync(ResumenGuardado resumen, CancellationToken ct)
    {
        var tenant = await _cola.ObtenerTenantAsync(resumen.TenantId, ct)
            ?? throw new InvalidOperationException("El emisor ya no existe.");

        var boletas = await _resumenes.BoletasDeAsync(resumen.Id, ct);

        if (boletas.Count == 0)
            throw new InvalidOperationException(
                "El resumen no tiene boletas asignadas.");

        using var certificado = await _certificados.ObtenerActivoAsync(
                resumen.TenantId, ct)
            ?? throw new InvalidOperationException(
                "El emisor no tiene certificado activo.");

        // --- Reconstruir el documento ---

        var documento = new ResumenDiario
        {
            Emisor = ArmarEmisor(tenant),
            FechaReferencia = resumen.FechaReferencia,
            FechaGeneracion = resumen.FechaGeneracion,
            Correlativo = resumen.Correlativo,
            Lineas = boletas.Select((b, indice) =>
            {
                var boleta = JsonSerializer.Deserialize<Boleta>(b.CpeJson, OpcionesJson)
                    ?? throw new InvalidOperationException(
                        $"No se pudo leer la boleta {b.NumeroCompleto}.");

                // Los totales se recalculan desde la boleta original, no se
                // copian de la base: así el resumen nunca puede declarar un
                // monto distinto al del comprobante que informa.
                return LineaResumen.DesdeBoleta(boleta, indice + 1);
            }).ToList()
        };

        // --- Firmar y guardar ---

        var xml = GeneradorResumenXml.Generar(documento);
        var firmado = FirmadorXml.Firmar(xml, certificado);
        var bytes = SerializarSinBom(firmado);

        var rutaXml = await _archivos.GuardarAsync(
            tenant.Ruc, documento.FechaGeneracion,
            $"{documento.NombreArchivo}.xml", bytes, ct);

        // --- Enviar ---

        var zip = EmpaquetadorZip.Comprimir(documento.NombreArchivo, bytes);

        var configuracion = await _credenciales.ObtenerAsync(resumen.TenantId, ct);

        using var enviador = new EnviadorSunatSoap(configuracion);

        var envio = await enviador.EnviarResumenAsync(
            $"{documento.NombreArchivo}.zip", zip, ct);

        if (!envio.Exitoso)
        {
            // Sin ticket no hay nada que consultar después. Se reintenta.
            await _resumenes.ProgramarReintentoAsync(
                resumen.Id,
                EsperaReintento.Calcular(resumen.IntentosFallidos),
                envio.Mensaje, ct);

            _log.LogWarning("{Id} no se pudo enviar: {Mensaje}",
                resumen.Identificador, envio.Mensaje);

            return;
        }

        await _resumenes.RegistrarTicketAsync(resumen.Id, envio.Ticket, rutaXml, ct);

        _log.LogInformation(
            "{Id} enviado con {Cantidad} boleta(s). Ticket {Ticket}.",
            resumen.Identificador, boletas.Count, envio.Ticket);
    }

    // ----------------------------------------------------- 3. consultar

    public async Task ConsultarTicketsAsync(CancellationToken ct)
    {
        foreach (var resumen in await _resumenes.BuscarTicketsPendientesAsync(ct: ct))
        {
            try { await ConsultarAsync(resumen, ct); }
            catch (Exception ex)
            {
                _log.LogError(ex, "Falló la consulta de {Id}", resumen.Identificador);

                await _resumenes.ProgramarReintentoAsync(
                    resumen.Id,
                    EsperaReintento.Calcular(resumen.IntentosFallidos),
                    ex.Message, ct);
            }
        }
    }

    private async Task ConsultarAsync(ResumenGuardado resumen, CancellationToken ct)
    {
        var tenant = await _cola.ObtenerTenantAsync(resumen.TenantId, ct)
            ?? throw new InvalidOperationException("El emisor ya no existe.");

        var configuracion = await _credenciales.ObtenerAsync(resumen.TenantId, ct);

        using var enviador = new EnviadorSunatSoap(configuracion);

        var resultado = await enviador.ConsultarTicketAsync(resumen.Ticket!, ct);

        // 98 significa que SUNAT sigue procesando. No es un fallo: hay que
        // volver a preguntar más tarde, sin gastar un intento.
        if (resultado.CodigoRespuesta == "98")
        {
            await _resumenes.ProgramarReintentoAsync(
                resumen.Id, TimeSpan.FromMinutes(2),
                "SUNAT sigue procesando el resumen.", ct);

            return;
        }

        if (resultado.EsReintentable)
        {
            await _resumenes.ProgramarReintentoAsync(
                resumen.Id,
                EsperaReintento.Calcular(resumen.IntentosFallidos),
                resultado.Descripcion, ct);

            return;
        }

        // --- Desenlace ---

        string? rutaCdr = null;

        if (resultado.CdrZip is not null)
        {
            rutaCdr = await _archivos.GuardarAsync(
                tenant.Ruc,
                resumen.FechaGeneracion,
                $"R-{tenant.Ruc}-{resumen.Identificador}.zip",
                resultado.CdrZip, ct);
        }

        var estado = resultado.Aceptado
            ? (resultado.Observaciones.Count > 0
                ? EstadoResumenCpe.ConObservaciones
                : EstadoResumenCpe.Aceptado)
            : EstadoResumenCpe.Rechazado;

        var observaciones = resultado.Observaciones.Count == 0
            ? ""
            : " Observaciones: " + string.Join(" | ", resultado.Observaciones);

        // El desenlace del resumen se aplica también a todas sus boletas:
        // una boleta cuyo resumen fue aceptado está comunicada, y una cuyo
        // resumen fue rechazado no lo está.
        await _resumenes.CerrarAsync(
            resumen.Id, estado, resultado.CodigoRespuesta,
            resultado.Descripcion + observaciones, rutaCdr, ct);

        if (resultado.Aceptado)
        {
            _log.LogInformation(
                "{Id} aceptado. {Cantidad} boleta(s) comunicadas.",
                resumen.Identificador, resumen.Comprobantes);
        }
        else
        {
            _log.LogWarning(
                "{Id} RECHAZADO. Código {Codigo}: {Mensaje}. " +
                "Sus {Cantidad} boleta(s) NO están comunicadas.",
                resumen.Identificador, resultado.CodigoRespuesta,
                resultado.Descripcion, resumen.Comprobantes);
        }
    }

    // ------------------------------------------------------------ apoyo

    private static Emisor ArmarEmisor(TenantResuelto t) => new()
    {
        Ruc = t.Ruc,
        RazonSocial = t.RazonSocial,
        NombreComercial = t.NombreComercial,
        Ubigeo = t.Ubigeo,
        Direccion = t.Direccion,
        Distrito = t.Distrito,
        Provincia = t.Provincia,
        Departamento = t.Departamento
    };

    private static byte[] SerializarSinBom(System.Xml.XmlDocument doc)
    {
        using var memoria = new MemoryStream();

        var configuracion = new System.Xml.XmlWriterSettings
        {
            Encoding = new System.Text.UTF8Encoding(false),
            Indent = false,
            OmitXmlDeclaration = false,
            NewLineHandling = System.Xml.NewLineHandling.None
        };

        using (var writer = System.Xml.XmlWriter.Create(memoria, configuracion))
            doc.Save(writer);

        return memoria.ToArray();
    }
}

/// <summary>
/// Ejecuta el ciclo de resúmenes en segundo plano.
///
/// Corre mucho más espaciado que el worker de facturas, y es deliberado: los
/// resúmenes se arman una vez al día y SUNAT tarda minutos en procesarlos.
/// Consultar cada pocos segundos no acelera nada y solo gasta peticiones
/// contra un servicio que ya sabemos que limita la tasa.
/// </summary>
public sealed class ServicioResumenes : BackgroundService
{
    private readonly ProcesadorResumenes _procesador;
    private readonly ILogger<ServicioResumenes> _log;
    private readonly TimeSpan _intervalo;

    public ServicioResumenes(
        ProcesadorResumenes procesador,
        ILogger<ServicioResumenes> log,
        TimeSpan? intervalo = null)
    {
        _procesador = procesador;
        _log = log;
        _intervalo = intervalo ?? TimeSpan.FromMinutes(1);
    }

    protected override async Task ExecuteAsync(CancellationToken ct)
    {
        _log.LogInformation(
            "Servicio de resúmenes iniciado. Ciclo cada {Intervalo}.", _intervalo);

        while (!ct.IsCancellationRequested)
        {
            try
            {
                await _procesador.AgruparAsync(ct);
                await _procesador.EnviarPendientesAsync(ct);
                await _procesador.ConsultarTicketsAsync(ct);
            }
            catch (OperationCanceledException) when (ct.IsCancellationRequested)
            {
                break;
            }
            catch (Exception ex)
            {
                // El ciclo nunca muere por un error. Si muriera, las boletas
                // dejarían de comunicarse en silencio y nadie se enteraría
                // hasta que SUNAT reclamara.
                _log.LogError(ex, "Error en el ciclo de resúmenes. Se reintenta.");
            }

            await Task.Delay(_intervalo, ct);
        }

        _log.LogInformation("Servicio de resúmenes detenido.");
    }
}
