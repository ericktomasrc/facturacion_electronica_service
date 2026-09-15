using System.Diagnostics;
using System.Text.Json;
using Facturacion.Cpe;
using Facturacion.Persistencia;
using Microsoft.Extensions.Logging;

namespace Facturacion.Worker;

/// <summary>
/// Calcula cuánto esperar antes de reintentar, según cuántas veces ha fallado.
///
/// POR QUÉ LA ESPERA CRECE:
///
/// Cuando un envío falla por saturación o por caída de SUNAT, reintentarlo de
/// inmediato empeora las cosas: le pedimos otra vez a un servicio que ya nos
/// dijo que no puede. Con espera creciente, si SUNAT vuelve en dos minutos el
/// comprobante sale casi enseguida; si está caído medio día, la cola no se
/// convierte en una ametralladora.
///
/// La escalera está pensada para que el primer reintento sea rápido —la
/// mayoría de los fallos son momentáneos— y los siguientes den tregua de
/// verdad.
/// </summary>
public static class EsperaReintento
{
    private static readonly TimeSpan[] Escalera =
    [
        TimeSpan.FromMinutes(1),
        TimeSpan.FromMinutes(5),
        TimeSpan.FromMinutes(15),
        TimeSpan.FromHours(1),
        TimeSpan.FromHours(6)
    ];

    /// <summary>
    /// A partir de este número de fallos, el comprobante deja de reintentarse
    /// solo y necesita intervención. Seguir insistiendo indefinidamente esconde
    /// un problema que alguien tiene que mirar.
    /// </summary>
    public const int MaximoIntentos = 8;

    public static TimeSpan Calcular(int intentosFallidos)
    {
        var indice = Math.Clamp(intentosFallidos, 0, Escalera.Length - 1);

        var baseEspera = Escalera[indice];

        // Se añade una variación aleatoria de hasta el 20%.
        //
        // POR QUÉ: si veinte comprobantes fallan a la vez porque SUNAT se cayó,
        // sin esta variación los veinte reintentarían exactamente en el mismo
        // instante, provocando otra avalancha. Repartirlos evita ese efecto.
        var variacion = Random.Shared.NextDouble() * 0.2;

        return baseEspera * (1 + variacion);
    }

    public static bool AgotoIntentos(int intentosFallidos) =>
        intentosFallidos >= MaximoIntentos;
}

/// <summary>
/// Procesa un comprobante de principio a fin:
/// lo reconstruye, lo firma, lo envía a SUNAT y guarda el resultado.
///
/// Cada paso deja rastro en la bitácora. Cuando algo falla a las tres de la
/// mañana, la diferencia entre resolverlo en cinco minutos o en dos horas es
/// tener ese rastro.
/// </summary>
public sealed class ProcesadorComprobantes
{
    private static readonly JsonSerializerOptions OpcionesJson = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        PropertyNameCaseInsensitive = true
    };

    private readonly ColaTrabajos _cola;
    private readonly RepositorioComprobantes _comprobantes;
    private readonly AlmacenCertificados _certificados;
    private readonly IAlmacenArchivos _archivos;
    private readonly ILogger<ProcesadorComprobantes> _log;

    public ProcesadorComprobantes(
        ColaTrabajos cola,
        RepositorioComprobantes comprobantes,
        AlmacenCertificados certificados,
        IAlmacenArchivos archivos,
        ILogger<ProcesadorComprobantes> log)
    {
        _cola = cola;
        _comprobantes = comprobantes;
        _certificados = certificados;
        _archivos = archivos;
        _log = log;
    }

    public async Task ProcesarAsync(TrabajoComprobante trabajo, CancellationToken ct)
    {
        var cronometro = Stopwatch.StartNew();

        try
        {
            var tenant = await _cola.ObtenerTenantAsync(trabajo.TenantId, ct)
                ?? throw new InvalidOperationException(
                    "El emisor ya no existe o fue desactivado.");

            // --- 1. Reconstruir el comprobante desde el JSON guardado --------

            var comprobante = Deserializar(trabajo);

            // --- 2. Firmar ---------------------------------------------------

            using var certificado = await _certificados.ObtenerActivoAsync(
                    trabajo.TenantId, ct)
                ?? throw new InvalidOperationException(
                    "El emisor no tiene certificado activo. Sin certificado no " +
                    "se puede firmar, y sin firma SUNAT rechaza todo.");

            var xml = GenerarXml(comprobante);
            var firmado = FirmadorXml.Firmar(xml, certificado);

            var bytesXml = ObtenerBytes(firmado);

            var rutaXml = await _archivos.GuardarAsync(
                tenant.Ruc, comprobante.FechaEmision,
                $"{comprobante.NombreArchivo}.xml", bytesXml, ct);

            await _comprobantes.GuardarRutasAsync(
                trabajo.TenantId, trabajo.Id, rutaXml: rutaXml, ct: ct);

            await _comprobantes.RegistrarCambioAsync(trabajo.TenantId, trabajo.Id,
                new CambioEstado(EstadoCpe.Firmado,
                    Mensaje: "XML generado y firmado.",
                    Worker: Environment.MachineName), ct);

            // --- 3. Enviar a SUNAT -------------------------------------------

            var configuracion = ResolverConfiguracion(tenant);

            var zip = EmpaquetadorZip.Comprimir(comprobante.NombreArchivo, bytesXml);

            var relojEnvio = Stopwatch.StartNew();

            using var enviador = new EnviadorSunatSoap(configuracion);

            var envio = await enviador.EnviarAsync(
                $"{comprobante.NombreArchivo}.zip", zip, ct);

            relojEnvio.Stop();

            // --- 4. Guardar el CDR -------------------------------------------
            // Es la prueba legal de recepción. Se conserva tal cual llegó,
            // incluso cuando el comprobante fue rechazado: ahí está escrito
            // el motivo.

            string? rutaCdr = null;

            if (envio.CdrZip is not null)
            {
                rutaCdr = await _archivos.GuardarAsync(
                    tenant.Ruc, comprobante.FechaEmision,
                    $"{LectorCdr.NombreArchivoCdr(comprobante.NombreArchivo)}.zip",
                    envio.CdrZip, ct);

                await _comprobantes.GuardarRutasAsync(
                    trabajo.TenantId, trabajo.Id, rutaCdr: rutaCdr, ct: ct);
            }

            // --- 5. Registrar el desenlace -----------------------------------

            var observaciones = envio.Observaciones.Count == 0
                ? ""
                : " Observaciones: " + string.Join(" | ", envio.Observaciones);

            // CASO A: fallo reintentable (red, timeout, SUNAT saturado).
            // El comprobante vuelve a la cola, pero con espera creciente.
            if (!envio.Aceptado && envio.EsReintentable)
            {
                await ManejarFalloReintentableAsync(
                    trabajo, comprobante.NombreArchivo, envio,
                    (int)relojEnvio.ElapsedMilliseconds, ct);

                return;
            }

            // CASO B: desenlace definitivo. Aceptado, observado o rechazado.
            var estadoFinal = envio.Aceptado
                ? (envio.Observaciones.Count > 0
                    ? EstadoCpe.ConObservaciones
                    : EstadoCpe.Aceptado)
                : EstadoCpe.Rechazado;

            await _comprobantes.RegistrarCambioAsync(trabajo.TenantId, trabajo.Id,
                new CambioEstado(
                    estadoFinal,
                    CodigoSunat: envio.CodigoRespuesta,
                    Mensaje: envio.Descripcion + observaciones,
                    DuracionMs: (int)relojEnvio.ElapsedMilliseconds,
                    Worker: Environment.MachineName), ct);

            // Ya se resolvió: se limpia el contador de reintentos.
            await _cola.LimpiarReintentosAsync(trabajo.Id, ct);

            // EL PDF NO SE GENERA AQUÍ.
            //
            // Antes se creaba y se guardaba junto al XML y al CDR. Se quitó
            // por dos razones:
            //
            //   Espacio. Es el 80% del peso del almacén, y con cien mil
            //   comprobantes diarios son más de dos terabytes al año.
            //
            //   Coherencia. Un PDF guardado refleja el estado que tenía el
            //   comprobante cuando se generó. Si después cambia —una baja,
            //   por ejemplo— el archivo guardado miente.
            //
            // Ahora lo genera la API cuando alguien lo pide, a partir del cpe
            // que está en la base. Cuesta décimas de segundo y siempre
            // refleja el estado actual.

            if (envio.Aceptado)
            {
                _log.LogInformation(
                    "{Numero} aceptado en {Ms} ms",
                    comprobante.NombreArchivo, relojEnvio.ElapsedMilliseconds);
            }
            else
            {
                // Un rechazo por datos NO se reintenta: el XML está mal y
                // mañana estará igual de mal. Necesita corrección humana.
                _log.LogWarning(
                    "{Numero} RECHAZADO por SUNAT. Código {Codigo}: {Mensaje}",
                    comprobante.NombreArchivo, envio.CodigoRespuesta, envio.Descripcion);
            }
        }
        catch (Exception ex)
        {
            await RegistrarFalloAsync(trabajo, ex, cronometro, ct);
        }
    }

    // ------------------------------------------------------------------ interno

    /// <summary>
    /// Gestiona un fallo que sí vale la pena reintentar: red, timeout,
    /// o SUNAT saturado.
    ///
    /// LA DISTINCIÓN QUE IMPORTA, y que este método encarna: un rechazo por
    /// datos NO se reintenta nunca, porque el XML está mal y mañana estará
    /// igual de mal. Solo llegan aquí los fallos que podrían resolverse solos
    /// con el tiempo.
    /// </summary>
    private async Task ManejarFalloReintentableAsync(
        TrabajoComprobante trabajo,
        string numero,
        ResultadoEnvio envio,
        int duracionMs,
        CancellationToken ct)
    {
        var fallosPrevios = trabajo.IntentosFallidos;

        // Tras demasiados intentos, dejar de insistir. Un comprobante que
        // lleva horas fallando esconde un problema que alguien tiene que
        // mirar, y seguir reintentando solo lo oculta.
        if (EsperaReintento.AgotoIntentos(fallosPrevios + 1))
        {
            await _comprobantes.RegistrarCambioAsync(trabajo.TenantId, trabajo.Id,
                new CambioEstado(
                    EstadoCpe.Rechazado,
                    CodigoSunat: envio.CodigoRespuesta,
                    Mensaje:
                        $"Se agotaron los {EsperaReintento.MaximoIntentos} intentos. " +
                        $"Último error: {envio.Descripcion}",
                    DuracionMs: duracionMs,
                    Worker: Environment.MachineName), ct);

            _log.LogError(
                "{Numero} agotó los reintentos tras {Intentos} fallos. " +
                "Requiere revisión manual. Último error: {Mensaje}",
                numero, fallosPrevios + 1, envio.Descripcion);

            return;
        }

        var espera = EsperaReintento.Calcular(fallosPrevios);

        await _comprobantes.RegistrarCambioAsync(trabajo.TenantId, trabajo.Id,
            new CambioEstado(
                EstadoCpe.Borrador,
                CodigoSunat: envio.CodigoRespuesta,
                Mensaje:
                    $"Intento {fallosPrevios + 1} fallido. " +
                    $"Se reintenta en {Describir(espera)}. {envio.Descripcion}",
                ResponseRaw: envio.Descripcion,
                DuracionMs: duracionMs,
                Worker: Environment.MachineName), ct);

        await _cola.ProgramarReintentoAsync(trabajo.Id, espera, ct);

        _log.LogWarning(
            "{Numero} falló (intento {Intento}). Reintento en {Espera}. {Mensaje}",
            numero, fallosPrevios + 1, Describir(espera), envio.Descripcion);
    }

    private static string Describir(TimeSpan espera) =>
        espera.TotalMinutes < 1 ? $"{espera.TotalSeconds:N0} s"
        : espera.TotalHours < 1 ? $"{espera.TotalMinutes:N0} min"
        : $"{espera.TotalHours:N1} h";

    private async Task RegistrarFalloAsync(
        TrabajoComprobante trabajo, Exception ex, Stopwatch cronometro,
        CancellationToken ct)
    {
        _log.LogError(ex, "Falló el procesamiento de {Numero}", trabajo.NumeroCompleto);

        try
        {
            // Los errores de configuración (sin certificado, emisor inactivo)
            // vuelven a BORRADOR: se arreglan desde el panel y el comprobante
            // se procesa solo en el siguiente ciclo. Marcarlos como rechazados
            // obligaría a reemitir algo que nunca llegó a SUNAT.
            await _comprobantes.RegistrarCambioAsync(trabajo.TenantId, trabajo.Id,
                new CambioEstado(
                    EstadoCpe.Borrador,
                    Mensaje: $"Error al procesar: {ex.Message}",
                    ResponseRaw: ex.ToString(),
                    DuracionMs: (int)cronometro.ElapsedMilliseconds,
                    Worker: Environment.MachineName), ct);
        }
        catch (Exception errorAlRegistrar)
        {
            // Si ni siquiera se puede escribir la bitácora, al menos que
            // quede en el log del proceso.
            _log.LogCritical(errorAlRegistrar,
                "No se pudo registrar el fallo de {Id}", trabajo.Id);
        }
    }

    private static ComprobanteBase Deserializar(TrabajoComprobante trabajo) =>
        trabajo.TipoComprobante switch
        {
            TipoComprobante.Factura =>
                JsonSerializer.Deserialize<Factura>(trabajo.CpeJson, OpcionesJson)
                    ?? throw new InvalidOperationException("El JSON del comprobante está vacío."),

            TipoComprobante.Boleta =>
                JsonSerializer.Deserialize<Boleta>(trabajo.CpeJson, OpcionesJson)
                    ?? throw new InvalidOperationException("El JSON del comprobante está vacío."),

            TipoComprobante.NotaCredito =>
                JsonSerializer.Deserialize<NotaCredito>(trabajo.CpeJson, OpcionesJson)
                    ?? throw new InvalidOperationException("El JSON del comprobante está vacío."),

            TipoComprobante.NotaDebito =>
                JsonSerializer.Deserialize<NotaDebito>(trabajo.CpeJson, OpcionesJson)
                    ?? throw new InvalidOperationException("El JSON del comprobante está vacío."),

            _ => throw new InvalidOperationException(
                $"Tipo de comprobante no soportado: {trabajo.TipoComprobante}")
        };

    private static System.Xml.Linq.XDocument GenerarXml(ComprobanteBase comprobante) =>
        comprobante switch
        {
            Factura f => GeneradorFacturaXml.Generar(f),
            NotaCredito n => GeneradorNotaXml.Generar(n),
            NotaDebito n => GeneradorNotaXml.Generar(n),

            // Las boletas no se envían de una en una: van en el resumen
            // diario. Ese flujo es otro y lo maneja un proceso distinto.
            Boleta => throw new InvalidOperationException(
                "Las boletas se comunican en el resumen diario, no individualmente."),

            _ => throw new InvalidOperationException(
                $"No hay generador para {comprobante.GetType().Name}")
        };

    private static ConfiguracionSunat ResolverConfiguracion(TenantResuelto tenant)
    {
        if (!tenant.EsProduccion)
            return ConfiguracionSunat.Beta(tenant.Ruc);

        // En producción hacen falta las credenciales SOL reales del
        // contribuyente, descifradas desde tenants.clave_sol_cifrada.
        // Todavía no está implementado, y es mejor fallar claro que enviar
        // a producción con credenciales de prueba.
        throw new NotImplementedException(
            "El envío a producción requiere descifrar las credenciales SOL " +
            "del emisor. Falta implementarlo.");
    }

    private static byte[] ObtenerBytes(System.Xml.XmlDocument doc)
    {
        // Se serializa exactamente igual que al guardar en disco: UTF-8 sin
        // BOM y sin indentación. Cualquier diferencia invalidaría la firma.
        using var memoria = new MemoryStream();

        var configuracion = new System.Xml.XmlWriterSettings
        {
            Encoding = new System.Text.UTF8Encoding(encoderShouldEmitUTF8Identifier: false),
            Indent = false,
            OmitXmlDeclaration = false,
            NewLineHandling = System.Xml.NewLineHandling.None
        };

        using (var writer = System.Xml.XmlWriter.Create(memoria, configuracion))
            doc.Save(writer);

        return memoria.ToArray();
    }
}
