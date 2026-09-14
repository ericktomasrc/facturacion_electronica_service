namespace Facturacion.Cpe;

/// <summary>
/// Resultado de enviar un comprobante.
/// </summary>
/// <param name="Aceptado">true solo si SUNAT devolvió código 0.</param>
/// <param name="CodigoRespuesta">
/// Código del CDR. "0" es aceptado. Del 100 al 1999 son rechazos por datos
/// (NO reintentar, el XML está mal). Del 2000 al 3999, errores que impiden
/// la emisión. Del 4000 en adelante, observaciones: el comprobante se acepta
/// pero con avisos.
/// </param>
/// <param name="Descripcion">Mensaje legible que devolvió SUNAT.</param>
/// <param name="Observaciones">Notas adicionales del CDR, si las hay.</param>
/// <param name="CdrZip">El CDR comprimido, tal como llegó. Hay que conservarlo.</param>
/// <param name="CdrXml">El XML del CDR ya descomprimido.</param>
public record ResultadoEnvio(
    bool Aceptado,
    string CodigoRespuesta,
    string Descripcion,
    IReadOnlyList<string> Observaciones,
    byte[]? CdrZip,
    byte[]? CdrXml)
{
    /// <summary>
    /// Indica si tiene sentido reintentar el envío.
    ///
    /// REGLA QUE EVITA MUCHOS PROBLEMAS: si SUNAT rechazó por error de datos,
    /// no se reintenta nunca. El XML está mal y mañana va a estar igual de mal.
    /// Solo se reintentan fallos de red y timeouts.
    /// </summary>
    public bool EsReintentable { get; init; }

    public static ResultadoEnvio FalloDeRed(string mensaje) =>
        new(false, "RED", mensaje, [], null, null) { EsReintentable = true };
}

/// <summary>
/// Abstracción del transporte hacia SUNAT.
///
/// POR QUÉ EXISTE ESTA INTERFAZ: hoy el envío es directo a SUNAT, pero mañana
/// puede hacer falta pasar por un OSE como contingencia, o simular el envío en
/// las pruebas. Con esta interfaz, cambiar de canal no toca el dominio ni la
/// base de datos: solo se inyecta otra implementación.
/// </summary>
public interface IEnviadorCpe
{
    Task<ResultadoEnvio> EnviarAsync(
        string nombreArchivo,
        byte[] contenidoZip,
        CancellationToken ct = default);
}

/// <summary>
/// Credenciales y endpoints del emisor.
///
/// SON DOS SERVICIOS DISTINTOS, y confundirlos produce errores desconcertantes:
///
///   Endpoint         → envío de comprobantes (billService)
///   EndpointConsulta → consulta de comprobantes ya enviados (billConsultService)
///
/// ADVERTENCIA IMPORTANTE SOBRE EL AMBIENTE DE PRUEBAS:
///
/// SUNAT NO OFRECE SERVICIO DE CONSULTA EN BETA. Solo existe en producción.
/// Cualquier intento de consultar contra un endpoint beta devuelve un 404,
/// porque ese servicio sencillamente no está publicado ahí.
///
/// Consecuencia práctica: la consulta de CDR solo se puede verificar con RUC
/// y credenciales SOL reales. Conviene tenerlo presente al planificar las
/// pruebas, porque es fácil perder horas creyendo que el código está mal.
/// </summary>
public class ConfiguracionSunat
{
    /// <summary>Servicio de envío. Beta y producción son distintos.</summary>
    public string Endpoint { get; set; } =
        "https://e-beta.sunat.gob.pe/ol-ti-itcpfegem-beta/billService";

    /// <summary>
    /// Servicio de consulta de CDR. Solo existe en producción.
    /// Vacío significa que la consulta no está disponible en este ambiente.
    /// </summary>
    public string EndpointConsulta { get; set; } = "";

    /// <summary>
    /// Servicio de consulta de validez de comprobantes. También solo en
    /// producción. Sirve para verificar comprobantes de PROVEEDORES, no
    /// propios: útil cuando hay que validar una factura de compra.
    /// </summary>
    public string EndpointValidez { get; set; } = "";

    /// <summary>Indica si este ambiente permite consultar comprobantes.</summary>
    public bool PermiteConsulta => !string.IsNullOrWhiteSpace(EndpointConsulta);

    /// <summary>Usuario SOL con el formato RUC + usuario. Ej: 20601234567MODDATOS</summary>
    public string Usuario { get; set; } = "";

    public string Clave { get; set; } = "";

    public TimeSpan Timeout { get; set; } = TimeSpan.FromSeconds(60);

    /// <summary>
    /// Ambiente de pruebas. Solo permite ENVIAR comprobantes.
    /// La consulta queda deshabilitada porque SUNAT no la publica en beta.
    /// </summary>
    public static ConfiguracionSunat Beta(string ruc) => new()
    {
        Endpoint = "https://e-beta.sunat.gob.pe/ol-ti-itcpfegem-beta/billService",
        EndpointConsulta = "",
        EndpointValidez = "",
        Usuario = $"{ruc}MODDATOS",
        Clave = "MODDATOS"
    };

    /// <summary>
    /// Producción. Las credenciales son las del usuario SOL SECUNDARIO del
    /// contribuyente, nunca las del principal: ese usuario puede hacer todo
    /// en el portal de SUNAT y no tiene por qué vivir en tu base de datos.
    /// </summary>
    public static ConfiguracionSunat Produccion(
        string ruc, string usuarioSol, string clave) => new()
    {
        Endpoint = "https://e-factura.sunat.gob.pe/ol-ti-itcpfegem/billService",
        EndpointConsulta =
            "https://e-factura.sunat.gob.pe/ol-it-wsconscpegem/billConsultService",
        EndpointValidez =
            "https://e-factura.sunat.gob.pe/ol-it-wsconsvalidcpe/billValidService",
        Usuario = $"{ruc}{usuarioSol}",
        Clave = clave
    };
}
