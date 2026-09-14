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
    /// <param name="nombreArchivo">Con extensión .zip. Ej: 20601234567-01-F001-00000001.zip</param>
    /// <param name="contenidoZip">El ZIP con el XML firmado dentro.</param>
    Task<ResultadoEnvio> EnviarAsync(
        string nombreArchivo,
        byte[] contenidoZip,
        CancellationToken ct = default);
}

/// <summary>Credenciales y endpoint del emisor.</summary>
public class ConfiguracionSunat
{
    /// <summary>URL del servicio. Beta y producción son distintas.</summary>
    public string Endpoint { get; set; } =
        "https://e-beta.sunat.gob.pe/ol-ti-itcpfegem-beta/billService";

    /// <summary>Usuario SOL con el formato RUC + usuario. Ej: 20601234567MODDATOS</summary>
    public string Usuario { get; set; } = "";

    public string Clave { get; set; } = "";

    public TimeSpan Timeout { get; set; } = TimeSpan.FromSeconds(60);

    /// <summary>Credenciales del ambiente de pruebas de SUNAT.</summary>
    public static ConfiguracionSunat Beta(string ruc) => new()
    {
        Endpoint = "https://e-beta.sunat.gob.pe/ol-ti-itcpfegem-beta/billService",
        Usuario = $"{ruc}MODDATOS",
        Clave = "MODDATOS"
    };
}
