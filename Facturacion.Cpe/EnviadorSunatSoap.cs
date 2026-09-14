using System.Net.Http.Headers;
using System.Text;
using System.Xml.Linq;

namespace Facturacion.Cpe;

/// <summary>
/// Envía comprobantes al servicio SOAP de SUNAT (billService).
///
/// POR QUÉ SE ARMA EL SOBRE SOAP A MANO Y NO CON UN CLIENTE GENERADO:
/// el WSDL de SUNAT genera un cliente que arrastra configuración de WCF difícil
/// de ajustar, sobre todo para la cabecera WS-Security. Armar el sobre a mano son
/// 30 líneas, se ve exactamente qué se envía, y depurar es leer un string.
///
/// La autenticación es WS-Security UsernameToken en texto plano. Va sobre HTTPS,
/// así que la credencial viaja cifrada por el canal.
/// </summary>
public class EnviadorSunatSoap : IEnviadorCpe, IDisposable
{
    private static readonly XNamespace Soap =
        "http://schemas.xmlsoap.org/soap/envelope/";

    private static readonly XNamespace Wsse =
        "http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd";

    private static readonly XNamespace Servicio = "http://service.sunat.gob.pe";

    private readonly ConfiguracionSunat _config;
    private readonly HttpClient _http;
    private readonly bool _propietarioDelHttpClient;

    public EnviadorSunatSoap(ConfiguracionSunat config, HttpClient? http = null)
    {
        _config = config ?? throw new ArgumentNullException(nameof(config));

        _propietarioDelHttpClient = http is null;
        _http = http ?? new HttpClient();
        _http.Timeout = config.Timeout;
    }

    public async Task<ResultadoEnvio> EnviarAsync(
        string nombreArchivo,
        byte[] contenidoZip,
        CancellationToken ct = default)
    {
        var sobre = ConstruirSobre(nombreArchivo, contenidoZip);

        HttpResponseMessage respuesta;
        string cuerpo;

        try
        {
            using var contenido = new StringContent(sobre, Encoding.UTF8);
            contenido.Headers.ContentType = new MediaTypeHeaderValue("text/xml")
            {
                CharSet = "UTF-8"
            };

            using var peticion = new HttpRequestMessage(HttpMethod.Post, _config.Endpoint)
            {
                Content = contenido
            };

            // SUNAT espera la cabecera SOAPAction aunque vaya vacía.
            peticion.Headers.TryAddWithoutValidation("SOAPAction", "\"\"");

            respuesta = await _http.SendAsync(peticion, ct);
            cuerpo = await respuesta.Content.ReadAsStringAsync(ct);
        }
        catch (TaskCanceledException) when (!ct.IsCancellationRequested)
        {
            // Timeout. SUNAT se cae con frecuencia: esto SÍ se reintenta.
            return ResultadoEnvio.FalloDeRed(
                "Tiempo de espera agotado. El servicio de SUNAT no respondió.");
        }
        catch (HttpRequestException ex)
        {
            return ResultadoEnvio.FalloDeRed($"Error de red: {ex.Message}");
        }

        return InterpretarRespuesta(respuesta.IsSuccessStatusCode, cuerpo);
    }

    // ------------------------------------------------------------------ interno

    private string ConstruirSobre(string nombreArchivo, byte[] contenidoZip)
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

            new XElement(Soap + "Body",
                new XElement(Servicio + "sendBill",
                    new XElement("fileName", nombreArchivo),
                    new XElement("contentFile", Convert.ToBase64String(contenidoZip)))));

        return new XDocument(new XDeclaration("1.0", "UTF-8", null), sobre).ToString();
    }

    private static ResultadoEnvio InterpretarRespuesta(bool exitoHttp, string cuerpo)
    {
        XDocument doc;

        try
        {
            doc = XDocument.Parse(cuerpo);
        }
        catch (Exception)
        {
            return ResultadoEnvio.FalloDeRed(
                "SUNAT devolvió una respuesta que no es XML válido. " +
                "Suele indicar que el servicio está caído o en mantenimiento.");
        }

        // Caso 1: SUNAT devolvió un Fault con el motivo del rechazo.
        var fault = doc.Descendants().FirstOrDefault(e => e.Name.LocalName == "Fault");

        if (fault is not null)
        {
            var codigo = fault.Descendants()
                .FirstOrDefault(e => e.Name.LocalName == "faultcode")?.Value ?? "";

            var mensaje = fault.Descendants()
                .FirstOrDefault(e => e.Name.LocalName == "faultstring")?.Value
                ?? "SUNAT rechazó el envío sin dar detalle.";

            // El código viene como "soap-env:Client.2335"; interesa el número final.
            var numero = codigo.Contains('.')
                ? codigo[(codigo.LastIndexOf('.') + 1)..]
                : codigo;

            return new ResultadoEnvio(
                Aceptado: false,
                CodigoRespuesta: numero,
                Descripcion: mensaje,
                Observaciones: [],
                CdrZip: null,
                CdrXml: null)
            {
                // Los códigos del 100 al 1999 son errores de datos: NO reintentar.
                // Los del 0100 al 0999 suelen ser de autenticación o formato del envío.
                EsReintentable = false
            };
        }

        // Caso 2: respuesta correcta, con el CDR en base64.
        var applicationResponse = doc.Descendants()
            .FirstOrDefault(e => e.Name.LocalName == "applicationResponse");

        if (applicationResponse is null)
        {
            return exitoHttp
                ? ResultadoEnvio.FalloDeRed(
                    "SUNAT respondió sin CDR y sin error. Respuesta inesperada.")
                : ResultadoEnvio.FalloDeRed(
                    "SUNAT devolvió un error HTTP sin cuerpo interpretable.");
        }

        var cdrZip = Convert.FromBase64String(applicationResponse.Value);
        var (_, cdrXml) = EmpaquetadorZip.ExtraerPrimerXml(cdrZip);

        return LectorCdr.Interpretar(cdrZip, cdrXml);
    }

    public void Dispose()
    {
        if (_propietarioDelHttpClient)
            _http.Dispose();

        GC.SuppressFinalize(this);
    }
}
