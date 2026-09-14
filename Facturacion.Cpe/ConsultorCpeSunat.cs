using System.Net.Http.Headers;
using System.Text;
using System.Xml.Linq;

namespace Facturacion.Cpe;

/// <summary>
/// Estado de un comprobante según SUNAT.
/// </summary>
/// <param name="Codigo">Código que devolvió el servicio de consulta.</param>
/// <param name="Mensaje">Descripción legible.</param>
/// <param name="Existe">Si SUNAT tiene registro del comprobante.</param>
/// <param name="Aceptado">Si además está aceptado.</param>
/// <param name="CdrZip">El CDR recuperado, si el servicio lo devolvió.</param>
public record EstadoComprobante(
    string Codigo,
    string Mensaje,
    bool Existe,
    bool Aceptado,
    byte[]? CdrZip,
    byte[]? CdrXml)
{
    public static EstadoComprobante Fallo(string mensaje) =>
        new("", mensaje, false, false, null, null);
}

/// <summary>
/// Consulta el estado de comprobantes ya enviados.
///
/// EL PROBLEMA QUE RESUELVE, Y QUE VAS A TENER:
///
/// Envías una factura, SUNAT la recibe y la procesa, pero la respuesta se
/// pierde por un corte de red o un timeout. Tu sistema no sabe si el
/// comprobante existe. Si lo reenvías y sí existía, generas un duplicado;
/// si no lo reenvías y no existía, la factura nunca se emitió.
///
/// Con esta consulta preguntas directamente: ¿tienes esto o no?
///
/// OJO: vive en un ENDPOINT DISTINTO al de envío. No es billService, es el
/// servicio de consultas. Es un error común apuntar al endpoint equivocado
/// y recibir un fallo de autenticación confuso.
/// </summary>
public class ConsultorCpeSunat : IDisposable
{
    private static readonly XNamespace Soap =
        "http://schemas.xmlsoap.org/soap/envelope/";

    private static readonly XNamespace Wsse =
        "http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd";

    private static readonly XNamespace Servicio = "http://service.sunat.gob.pe";

    private readonly ConfiguracionSunat _config;
    private readonly HttpClient _http;
    private readonly bool _propietarioDelHttpClient;

    public ConsultorCpeSunat(ConfiguracionSunat config, HttpClient? http = null)
    {
        _config = config ?? throw new ArgumentNullException(nameof(config));

        _propietarioDelHttpClient = http is null;
        _http = http ?? new HttpClient();
        _http.Timeout = config.Timeout;
    }

    /// <summary>
    /// Pregunta por un comprobante concreto y recupera su CDR si existe.
    /// </summary>
    /// <param name="ruc">RUC del emisor.</param>
    /// <param name="tipoComprobante">Catálogo 01. "01" factura, "03" boleta.</param>
    /// <param name="serie">Serie. Ej: F001</param>
    /// <param name="numero">Correlativo, sin ceros a la izquierda.</param>
    public async Task<EstadoComprobante> ConsultarAsync(
        string ruc,
        string tipoComprobante,
        string serie,
        int numero,
        CancellationToken ct = default)
    {
        if (!_config.PermiteConsulta)
            return EstadoComprobante.Fallo(
                "Este ambiente no permite consultar comprobantes. " +
                "SUNAT solo publica el servicio de consulta en producción, " +
                "no en beta. Usa ConfiguracionSunat.Produccion con un RUC y " +
                "credenciales SOL reales.");

        var cuerpo = new XElement(Servicio + "getStatusCdr",
            new XElement("rucComprobante", ruc),
            new XElement("tipoComprobante", tipoComprobante),
            new XElement("serieComprobante", serie),
            new XElement("numeroComprobante", numero));

        var sobre = ConstruirSobre(cuerpo);

        string respuesta;
        int codigoHttp;

        try
        {
            using var contenido = new StringContent(sobre, Encoding.UTF8);
            contenido.Headers.ContentType =
                new MediaTypeHeaderValue("text/xml") { CharSet = "UTF-8" };

            using var peticion = new HttpRequestMessage(
                HttpMethod.Post, _config.EndpointConsulta) { Content = contenido };

            peticion.Headers.TryAddWithoutValidation("SOAPAction", "\"\"");

            var http = await _http.SendAsync(peticion, ct);

            codigoHttp = (int)http.StatusCode;
            respuesta = await http.Content.ReadAsStringAsync(ct);
        }
        catch (TaskCanceledException) when (!ct.IsCancellationRequested)
        {
            return EstadoComprobante.Fallo(
                "Tiempo de espera agotado consultando a SUNAT.");
        }
        catch (HttpRequestException ex)
        {
            return EstadoComprobante.Fallo($"Error de red: {ex.Message}");
        }

        return Interpretar(respuesta, codigoHttp, _config.EndpointConsulta);
    }

    // ------------------------------------------------------------------ interno

    private string ConstruirSobre(XElement cuerpo)
    {
        var sobre = new XElement(Soap + "Envelope",
            new XAttribute(XNamespace.Xmlns + "soapenv", Soap.NamespaceName),
            new XAttribute(XNamespace.Xmlns + "ser", Servicio.NamespaceName),
            new XAttribute(XNamespace.Xmlns + "wsse", Wsse.NamespaceName),

            new XElement(Soap + "Header",
                new XElement(Wsse + "Security",
                    new XElement(Wsse + "UsernameToken",
                        new XElement(Wsse + "Username", _config.Usuario),
                        new XElement(Wsse + "Password", _config.Clave)))),

            new XElement(Soap + "Body", cuerpo));

        return new XDocument(new XDeclaration("1.0", "UTF-8", null), sobre).ToString();
    }

    private static EstadoComprobante Interpretar(
        string cuerpo, int codigoHttp, string endpoint)
    {
        XDocument doc;

        try
        {
            doc = XDocument.Parse(cuerpo);
        }
        catch (Exception)
        {
            // NO ocultar la respuesta real detrás de un mensaje genérico.
            // Si SUNAT devolvió HTML, casi siempre significa que el endpoint
            // está mal o el servicio no existe en ese ambiente. Sin ver el
            // cuerpo ni el código HTTP, ese diagnóstico es imposible.
            var recorte = cuerpo.Length > 400 ? cuerpo[..400] + "..." : cuerpo;

            return EstadoComprobante.Fallo(
                $"Respuesta no interpretable. HTTP {codigoHttp}. " +
                $"Endpoint: {endpoint}. Respuesta: {recorte}");
        }

        var fault = doc.Descendants().FirstOrDefault(e => e.Name.LocalName == "Fault");

        if (fault is not null)
        {
            var mensaje = fault.Descendants()
                .FirstOrDefault(e => e.Name.LocalName == "faultstring")?.Value
                ?? "SUNAT rechazó la consulta.";

            return EstadoComprobante.Fallo(mensaje);
        }

        var codigo = Buscar(doc, "statusCode") ?? "";
        var mensajeSunat = Buscar(doc, "statusMessage")
            ?? EstadoCdr.Descripcion(codigo);

        var contenido = Buscar(doc, "content");

        byte[]? cdrZip = null;
        byte[]? cdrXml = null;

        // El CDR solo viene cuando el comprobante existe y fue procesado.
        if (!string.IsNullOrWhiteSpace(contenido) && EsBase64(contenido))
        {
            try
            {
                cdrZip = Convert.FromBase64String(contenido);
                (_, cdrXml) = EmpaquetadorZip.ExtraerPrimerXml(cdrZip);
            }
            catch (Exception)
            {
                // Si el contenido no es un ZIP válido se ignora: el código y
                // el mensaje siguen siendo información útil.
                cdrZip = null;
                cdrXml = null;
            }
        }

        return new EstadoComprobante(
            Codigo: codigo,
            Mensaje: mensajeSunat,
            Existe: EstadoCdr.Existe(codigo),
            Aceptado: EstadoCdr.EstaAceptado(codigo),
            CdrZip: cdrZip,
            CdrXml: cdrXml);
    }

    private static string? Buscar(XDocument doc, string nombreLocal) =>
        doc.Descendants()
           .FirstOrDefault(e => e.Name.LocalName == nombreLocal)
           ?.Value;

    private static bool EsBase64(string valor)
    {
        var limpio = valor.Trim();
        if (limpio.Length < 100) return false;

        var buffer = new byte[limpio.Length];
        return Convert.TryFromBase64String(limpio, buffer, out _);
    }

    public void Dispose()
    {
        if (_propietarioDelHttpClient)
            _http.Dispose();

        GC.SuppressFinalize(this);
    }
}

/// <summary>
/// Códigos que devuelve el servicio de consulta de comprobantes.
///
/// Verifica estos valores contra la documentación vigente de SUNAT antes de
/// tomar decisiones automáticas con ellos: los códigos se han ampliado varias
/// veces y esta lista puede quedar corta.
/// </summary>
public static class EstadoCdr
{
    public const string NoExiste            = "0001";
    public const string AceptadoConCdr      = "0004";
    public const string AceptadoSinCdr      = "0005";
    public const string Rechazado           = "0003";
    public const string Anulado             = "0002";

    public static bool Existe(string codigo) => codigo is not ("" or NoExiste);

    public static bool EstaAceptado(string codigo) =>
        codigo is AceptadoConCdr or AceptadoSinCdr;

    public static string Descripcion(string codigo) => codigo switch
    {
        NoExiste       => "El comprobante no existe en SUNAT.",
        Anulado        => "El comprobante existe pero fue dado de baja.",
        Rechazado      => "El comprobante existe y fue rechazado.",
        AceptadoConCdr => "El comprobante existe y está aceptado.",
        AceptadoSinCdr => "El comprobante está aceptado, sin CDR disponible.",
        ""             => "SUNAT no devolvió código de estado.",
        _              => $"Código no reconocido: {codigo}"
    };
}
