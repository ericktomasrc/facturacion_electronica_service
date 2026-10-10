namespace Facturacion.Persistencia;

/// <summary>
/// Estados por los que pasa un comprobante en la base de datos.
///
/// NO CONFUNDIR con EstadoComprobante de Facturacion.Cpe, que es el resultado
/// de consultarle a SUNAT por un comprobante. Son cosas distintas y por eso
/// llevan nombres distintos: uno es el ciclo de vida interno, el otro es lo
/// que SUNAT responde.
///
/// Los valores deben coincidir con el CHECK de la tabla: si el código y el
/// esquema se desincronizan, el INSERT falla en producción y no en las pruebas.
/// </summary>
public static class EstadoCpe
{
    public const string Borrador   = "BORRADOR";
    public const string Firmado    = "FIRMADO";
    public const string Encolado   = "ENCOLADO";
    public const string Enviado    = "ENVIADO";
    public const string Aceptado   = "ACEPTADO";
    public const string ConObservaciones = "ACEPTADO_CON_OBSERVACIONES";
    public const string Rechazado  = "RECHAZADO";
    public const string Anulado    = "ANULADO";

    /// <summary>
    /// Estados desde los que ya no hay vuelta atrás: el comprobante llegó
    /// a SUNAT y su suerte está decidida.
    /// </summary>
    public static bool EsFinal(string estado) =>
        estado is Aceptado or ConObservaciones or Rechazado or Anulado;

    /// <summary>Estados que un worker debe seguir procesando.</summary>
    public static bool EstaPendiente(string estado) =>
        estado is Firmado or Encolado or Enviado;
}

/// <summary>Comprobante tal como quedó guardado.</summary>
/// <param name="YaExistia">
/// true cuando la petición traía una clave de idempotencia que ya se había
/// usado. En ese caso no se creó nada nuevo: se devuelve el comprobante
/// original. Es la diferencia entre un doble clic inofensivo y un duplicado
/// tributario.
/// </param>
public record ComprobanteGuardado(
    Guid Id,
    Guid TenantId,
    string TipoComprobante,
    string Serie,
    int Correlativo,
    string Estado,
    decimal ImporteTotal,
    bool YaExistia)
{
    public string NumeroCompleto => $"{Serie}-{Correlativo:D8}";
}

/// <summary>Resumen de un comprobante para listados y consultas.</summary>
public record ResumenComprobante(
    Guid Id,
    string TipoComprobante,
    string Serie,
    int Correlativo,
    DateTime FechaEmision,
    string Moneda,
    decimal ImporteTotal,
    string Estado,
    string? CodigoSunat,
    string? MensajeSunat,
    string? Ticket,
    DateTime CreadoEn)
{
    public string NumeroCompleto => $"{Serie}-{Correlativo:D8}";
}

/// <summary>Un asiento de la bitácora de envíos.</summary>
public record IntentoEnvio(
    long Id,
    Guid ComprobanteId,
    short IntentoNro,
    string? EstadoAnterior,
    string EstadoNuevo,
    string? CodigoSunat,
    string? Mensaje,
    int? DuracionMs,
    string? Worker,
    DateTime CreadoEn);

/// <summary>
/// Datos de un cambio de estado, para registrar en la bitácora.
/// </summary>
public record CambioEstado(
    string EstadoNuevo,
    string? CodigoSunat = null,
    string? Mensaje = null,
    string? RequestRaw = null,
    string? ResponseRaw = null,
    int? DuracionMs = null,
    string? Worker = null,
    string? Ticket = null);

/// <summary>
/// Dónde están los archivos de un comprobante.
///
/// Las rutas son RELATIVAS al almacén, no absolutas. Guardar rutas absolutas
/// ataría los datos a la máquina que los escribió: al mudar de servidor, o
/// al pasar de disco a S3, todas dejarían de servir.
/// </summary>
public record ArchivosComprobante(
    string Numero,
    string TipoComprobante,
    string Estado,
    string? RutaXml,
    string? RutaCdr,
    string? RutaPdf)
{
    /// <summary>Nombre con el que se ofrece la descarga al usuario.</summary>
    public string NombreDescarga(string extension) =>
        $"{Numero}.{extension}";
}

/// <summary>
/// Lo necesario para reconstruir el PDF de un comprobante.
///
/// El PDF no se guarda en el almacén: se genera cuando alguien lo pide. Es el
/// archivo más pesado de los tres y el único que se puede rehacer a partir de
/// lo que ya está en la base.
/// </summary>
public record DatosParaPdf(
    string Numero,
    string TipoComprobante,
    string Estado,
    string? CodigoSunat,
    string? MensajeSunat,
    string CpeJson,
    string? RutaXml);
