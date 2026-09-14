using System.Net.Http.Headers;
using System.Text;
using System.Xml.Linq;

namespace Facturacion.Cpe;

/// <summary>
/// Envía comprobantes al servicio SOAP de SUNAT (billService).
///
/// Soporta los dos flujos:
///
///   SÍNCRONO  (facturas, notas)
///     sendBill → CDR inmediato
///
///   ASÍNCRONO (resúmenes diarios, comunicaciones de baja)
///     sendSummary → ticket
///     getStatus   → CDR, cuando SUNAT termine de procesar
///
/// POR QUÉ EL SOBRE SOAP SE ARMA A MANO: el cliente generado desde el WSDL
/// arrastra configuración de WCF difícil de ajustar, sobre todo para la
/// cabecera WS-Security. Así son 30 líneas y se ve exactamente qué se envía.
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

    // ------------------------------------------------------------ flujo síncrono

    public async Task<ResultadoEnvio> EnviarAsync(
        string nombreArchivo,
        byte[] contenidoZip,
        CancellationToken ct = default)
    {
        var cuerpo = new XElement(Servicio + "sendBill",
            new XElement("fileName", nombreArchivo),
            new XElement("contentFile", Convert.ToBase64String(contenidoZip)));

        var (exito, respuesta, error, codigoHttp) = await PostAsync(cuerpo, ct);

        if (!exito)
            return ResultadoEnvio.FalloDeRed(error!);

        return InterpretarSendBill(respuesta!, codigoHttp);
    }

    // ----------------------------------------------------------- flujo asíncrono

    /// <summary>
    /// Envía un resumen diario o una comunicación de baja.
    /// SUNAT NO devuelve un CDR aquí, sino un ticket para consultar después.
    /// </summary>
    public async Task<ResultadoTicket> EnviarResumenAsync(
        string nombreArchivo,
        byte[] contenidoZip,
        CancellationToken ct = default)
    {
        var cuerpo = new XElement(Servicio + "sendSummary",
            new XElement("fileName", nombreArchivo),
            new XElement("contentFile", Convert.ToBase64String(contenidoZip)));

        var (exito, respuesta, error, codigoHttp) = await PostAsync(cuerpo, ct);

        if (!exito)
            return ResultadoTicket.Fallo(error!, reintentable: true);

        return InterpretarSendSummary(respuesta!, codigoHttp);
    }

    /// <summary>
    /// Consulta el resultado de un ticket.
    ///
    /// SUNAT puede responder que todavía está procesando (código 98). En ese
    /// caso hay que volver a consultar más tarde, no reintentar el envío.
    /// </summary>
    public async Task<ResultadoEnvio> ConsultarTicketAsync(
        string ticket,
        CancellationToken ct = default)
    {
        var cuerpo = new XElement(Servicio + "getStatus",
            new XElement("ticket", ticket));

        var (exito, respuesta, error, codigoHttp) = await PostAsync(cuerpo, ct);

        if (!exito)
            return ResultadoEnvio.FalloDeRed(error!);

        return InterpretarGetStatus(respuesta!, codigoHttp);
    }

    /// <summary>
    /// Consulta el ticket repetidamente hasta que SUNAT termine de procesar.
    ///
    /// Útil para pruebas. En producción NO se hace así: el worker encola una
    /// consulta diferida y libera el hilo, en vez de quedarse esperando.
    /// </summary>
    public async Task<ResultadoEnvio> EsperarTicketAsync(
        string ticket,
        int intentosMaximos = 10,
        TimeSpan? esperaEntreIntentos = null,
        CancellationToken ct = default)
    {
        var espera = esperaEntreIntentos ?? TimeSpan.FromSeconds(3);

        // SUNAT necesita unos segundos antes de reconocer un ticket recién
        // emitido. Consultar de inmediato puede devolver "el ticket no existe".
        await Task.Delay(espera, ct);

        ResultadoEnvio ultimo = ResultadoEnvio.FalloDeRed("Sin intentos.");

        for (var intento = 1; intento <= intentosMaximos; intento++)
        {
            ultimo = await ConsultarTicketAsync(ticket, ct);

            // 98 significa "todavía en proceso": solo en ese caso se reintenta.
            if (ultimo.CodigoRespuesta != "98")
                return ultimo;

            await Task.Delay(espera, ct);
        }

        return ultimo;
    }

    // ------------------------------------------------------------------ interno

    private async Task<(bool Exito, string? Respuesta, string? Error, int CodigoHttp)> PostAsync(
        XElement cuerpoSoap,
        CancellationToken ct)
    {
        var sobre = ConstruirSobre(cuerpoSoap);

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

            peticion.Headers.TryAddWithoutValidation("SOAPAction", "\"\"");

            var respuesta = await _http.SendAsync(peticion, ct);
            var texto = await respuesta.Content.ReadAsStringAsync(ct);

            return (true, texto, null, (int)respuesta.StatusCode);
        }
        catch (TaskCanceledException) when (!ct.IsCancellationRequested)
        {
            return (false, null,
                "Tiempo de espera agotado. SUNAT no respondió dentro del plazo.", 0);
        }
        catch (HttpRequestException ex)
        {
            return (false, null, $"Error de red: {ex.Message}", 0);
        }
    }

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

    private static ResultadoEnvio InterpretarSendBill(string cuerpo, int codigoHttp)
    {
        if (!TryParsear(cuerpo, codigoHttp, out var doc, out var errorParseo))
            return ResultadoEnvio.FalloDeRed(errorParseo);

        var fault = LeerFault(doc!);
        if (fault is not null)
            return fault;

        var applicationResponse = Buscar(doc!, "applicationResponse");

        if (applicationResponse is null)
            return ResultadoEnvio.FalloDeRed(
                "SUNAT respondió sin CDR y sin error. Respuesta inesperada.");

        var cdrZip = Convert.FromBase64String(applicationResponse.Value);
        var (_, cdrXml) = EmpaquetadorZip.ExtraerPrimerXml(cdrZip);

        return LectorCdr.Interpretar(cdrZip, cdrXml);
    }

    private static ResultadoTicket InterpretarSendSummary(string cuerpo, int codigoHttp)
    {
        if (!TryParsear(cuerpo, codigoHttp, out var doc, out var errorParseo))
            return ResultadoTicket.Fallo(errorParseo, reintentable: true);

        var fault = LeerFault(doc!);
        if (fault is not null)
            return ResultadoTicket.Fallo(
                $"[{fault.CodigoRespuesta}] {fault.Descripcion}");

        var ticket = Buscar(doc!, "ticket");

        return ticket is null
            ? ResultadoTicket.Fallo("SUNAT no devolvió ticket.", reintentable: true)
            : new ResultadoTicket(true, ticket.Value, "Resumen recibido por SUNAT.");
    }

    private static ResultadoEnvio InterpretarGetStatus(string cuerpo, int codigoHttp)
    {
        if (!TryParsear(cuerpo, codigoHttp, out var doc, out var errorParseo))
            return ResultadoEnvio.FalloDeRed(errorParseo);

        var fault = LeerFault(doc!);
        if (fault is not null)
            return fault;

        var statusCode = Buscar(doc!, "statusCode")?.Value ?? "";
        var content = Buscar(doc!, "content")?.Value;

        // 98 = todavía en proceso. Volver a consultar, no reintentar el envío.
        if (statusCode == "98")
            return new ResultadoEnvio(
                false, "98", "En proceso. Vuelve a consultar el ticket.",
                [], null, null);

        if (string.IsNullOrWhiteSpace(content))
            return new ResultadoEnvio(
                false, statusCode,
                $"SUNAT respondió sin contenido. Código {statusCode}.",
                [], null, null);

        // CUIDADO CON ESTO: el elemento 'content' no siempre trae un ZIP en
        // base64. Cuando hay un problema con el propio ticket, SUNAT pone ahí
        // un mensaje en TEXTO PLANO. Por ejemplo:
        //
        //   <content>El ticket no existe</content>
        //   <statusCode>0127</statusCode>
        //
        // Decodificarlo a ciegas lanza una excepción, y si el catch de arriba
        // es demasiado amplio, termina reportando un error falso de red en vez
        // del problema real. Por eso se verifica antes.
        if (!EsBase64(content))
            return new ResultadoEnvio(
                false, statusCode, content, [], null, null);

        var cdrZip = Convert.FromBase64String(content);
        var (_, cdrXml) = EmpaquetadorZip.ExtraerPrimerXml(cdrZip);

        return LectorCdr.Interpretar(cdrZip, cdrXml);
    }

    /// <summary>
    /// Comprueba si el texto es realmente un ZIP codificado en base64.
    /// Un mensaje corto de SUNAT nunca lo es.
    /// </summary>
    private static bool EsBase64(string valor)
    {
        var limpio = valor.Trim();

        // Un ZIP con un CDR dentro siempre supera holgadamente este tamaño.
        if (limpio.Length < 100) return false;

        var buffer = new byte[limpio.Length];
        return Convert.TryFromBase64String(limpio, buffer, out _);
    }

    /// <summary>
    /// Intenta interpretar la respuesta como XML.
    ///
    /// EL MENSAJE DESCRIBE EL HECHO, NO UNA SUPOSICIÓN.
    ///
    /// La versión anterior decía "el servicio está caído o en mantenimiento"
    /// cada vez que la respuesta no era XML. Sonaba útil y mandaba a buscar en
    /// la dirección equivocada: la causa real solía ser saturación por enviar
    /// demasiadas peticiones seguidas, o una URL mal escrita.
    ///
    /// Incluir el código HTTP y un recorte de lo que de verdad llegó convierte
    /// un misterio en algo que se diagnostica de un vistazo.
    /// </summary>
    private static bool TryParsear(
        string cuerpo, int codigoHttp, out XDocument? doc, out string error)
    {
        try
        {
            doc = XDocument.Parse(cuerpo);
            error = "";
            return true;
        }
        catch (Exception)
        {
            doc = null;

            var recorte = cuerpo.Length > 300
                ? cuerpo[..300].ReplaceLineEndings(" ") + "..."
                : cuerpo.ReplaceLineEndings(" ");

            var pista = codigoHttp switch
            {
                429        => "SUNAT está limitando las peticiones: llegan demasiadas seguidas.",
                >= 500     => "SUNAT devolvió un error de servidor.",
                404        => "La URL del servicio no existe. Revisa el endpoint.",
                401 or 403 => "Credenciales rechazadas.",
                _          => "Respuesta inesperada."
            };

            error = $"{pista} HTTP {codigoHttp}. Recibido: {recorte}";
            return false;
        }
    }

    private static XElement? Buscar(XDocument doc, string nombreLocal) =>
        doc.Descendants().FirstOrDefault(e => e.Name.LocalName == nombreLocal);

    private static ResultadoEnvio? LeerFault(XDocument doc)
    {
        var fault = Buscar(doc, "Fault");
        if (fault is null) return null;

        var codigo = fault.Descendants()
            .FirstOrDefault(e => e.Name.LocalName == "faultcode")?.Value ?? "";

        var mensaje = fault.Descendants()
            .FirstOrDefault(e => e.Name.LocalName == "faultstring")?.Value
            ?? "SUNAT rechazó el envío sin dar detalle.";

        // El código viene como "soap-env:Client.2335"; interesa el número final.
        var numero = codigo.Contains('.')
            ? codigo[(codigo.LastIndexOf('.') + 1)..]
            : codigo;

        return new ResultadoEnvio(false, numero, mensaje, [], null, null)
        {
            EsReintentable = false
        };
    }

    public void Dispose()
    {
        if (_propietarioDelHttpClient)
            _http.Dispose();

        GC.SuppressFinalize(this);
    }
}
