using System.Net.Http.Json;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Facturacion.Cpe;

/// <summary>Credenciales y direcciones de la API de guías.</summary>
public sealed class ConfiguracionGre
{
    public string Ruc { get; init; } = "";
    public string ClientId { get; init; } = "";
    public string ClientSecret { get; init; } = "";

    /// <summary>Usuario SOL secundario, con el RUC delante.</summary>
    public string UsuarioSol { get; init; } = "";
    public string ClaveSol { get; init; } = "";

    public string UrlToken { get; init; } = "";
    public string UrlEnvio { get; init; } = "";

    /// <summary>
    /// Ambiente de pruebas.
    ///
    /// ESTO NO ES SUNAT. Es un simulador mantenido por la comunidad que imita
    /// el comportamiento de la API de guías.
    ///
    /// A diferencia de las facturas, que tienen un beta oficial con
    /// credenciales MODDATOS, SUNAT no publica un ambiente de pruebas de GRE
    /// igual de accesible. El simulador permite desarrollar y comprobar que
    /// el XML, la firma y el flujo de ticket funcionan, pero NO garantiza que
    /// SUNAT vaya a aceptar el documento.
    ///
    /// Es la misma situación que el certificado autofirmado: sirve para
    /// construir, y la verificación real llega con el primer cliente que
    /// tenga credenciales de producción.
    ///
    /// NOTA SOBRE EL RUC: el simulador exige que el último dígito sea 5.
    /// Es una regla suya, no de SUNAT.
    /// </summary>
    public static ConfiguracionGre Beta(string ruc) => new()
    {
        Ruc = ruc,
        ClientId = "test-85e5b0ae-255c-4891-a595-0b98c65c9854",
        ClientSecret = "test-Hty/M6QshYvPgItX2P0+Kw==",
        UsuarioSol = ruc + "MODDATOS",
        ClaveSol = "MODDATOS",
        UrlToken = "https://gre-test.nubefact.com/v1/clientessol/{clientId}/oauth2/token/",
        UrlEnvio = "https://gre-test.nubefact.com/v1"
    };

    /// <summary>
    /// Producción.
    ///
    /// El client_id y el client_secret los genera cada contribuyente en su
    /// menú SOL, opción "Credenciales de API SUNAT". Es un paso que hace una
    /// sola vez y que hay que pedirle al darlo de alta.
    /// </summary>
    public static ConfiguracionGre Produccion(
        string ruc, string clientId, string clientSecret,
        string usuarioSol, string claveSol) => new()
    {
        Ruc = ruc,
        ClientId = clientId,
        ClientSecret = clientSecret,
        UsuarioSol = ruc + usuarioSol,
        ClaveSol = claveSol,
        UrlToken = "https://api-seguridad.sunat.gob.pe/v1/clientessol/{clientId}/oauth2/token/",
        UrlEnvio = "https://api-cpe.sunat.gob.pe/v1"
    };
}

/// <summary>Resultado de enviar una guía.</summary>
public record EnvioGre(
    bool Exitoso,
    string? Ticket,
    string Mensaje,
    bool EsReintentable = false,
    int CodigoHttp = 0);

/// <summary>Resultado de consultar un ticket de guía.</summary>
/// <param name="RespuestaCruda">
/// El JSON tal como llegó.
///
/// SE CONSERVA A PROPÓSITO. Cuando SUNAT rechaza con un código genérico como
/// el 99 y no adjunta CDR, el motivo real está aquí y en ningún otro sitio.
/// Descartarlo obliga a volver a enviar solo para ver qué pasó.
/// </param>
public record EstadoGre(
    bool Terminado,
    bool Aceptado,
    string? CodigoRespuesta,
    string Descripcion,
    byte[]? CdrZip,
    IReadOnlyList<string> Observaciones,
    bool EsReintentable = false,
    string? RespuestaCruda = null);

/// <summary>
/// Cliente de la API REST de guías de remisión.
///
/// ES UN CANAL COMPLETAMENTE DISTINTO al de las facturas:
///
///   Facturas    SOAP con WS-Security, respuesta inmediata con el CDR
///   Guías       REST con OAuth2, respuesta con ticket que hay que consultar
///
/// No se pueden compartir ni las credenciales, ni el cliente HTTP, ni el
/// manejo de errores. Por eso vive en su propia clase.
/// </summary>
public sealed class ClienteGre : IDisposable
{
    private readonly ConfiguracionGre _config;
    private readonly HttpClient _http;

    /// <summary>
    /// El token en memoria, con su caducidad.
    ///
    /// POR QUÉ SE GUARDA: dura una hora y pedir uno nuevo en cada envío
    /// añadiría una petición extra a cada guía, y SUNAT limita la tasa. Se
    /// renueva un minuto antes de que expire, para no quedarse justo.
    /// </summary>
    private string? _token;
    private DateTime _tokenExpira = DateTime.MinValue;

    private static readonly TimeSpan MargenRenovacion = TimeSpan.FromMinutes(1);

    public ClienteGre(ConfiguracionGre configuracion, HttpClient? http = null)
    {
        _config = configuracion ?? throw new ArgumentNullException(nameof(configuracion));

        _http = http ?? new HttpClient();
        _http.Timeout = TimeSpan.FromSeconds(60);
    }

    // ------------------------------------------------------------ token

    /// <summary>
    /// Obtiene un token, reutilizando el que haya si sigue vigente.
    /// </summary>
    private async Task<string> ObtenerTokenAsync(CancellationToken ct)
    {
        if (_token is not null && DateTime.UtcNow < _tokenExpira - MargenRenovacion)
            return _token;

        var url = _config.UrlToken.Replace("{clientId}", _config.ClientId);

        // El cuerpo va como formulario, no como JSON. Es lo que espera el
        // servicio de seguridad de SUNAT.
        var campos = new Dictionary<string, string>
        {
            ["grant_type"] = "password",
            ["scope"] = "https://api-cpe.sunat.gob.pe",
            ["client_id"] = _config.ClientId,
            ["client_secret"] = _config.ClientSecret,
            ["username"] = _config.UsuarioSol,
            ["password"] = _config.ClaveSol
        };

        using var contenido = new FormUrlEncodedContent(campos);

        var respuesta = await _http.PostAsync(url, contenido, ct);
        var texto = await respuesta.Content.ReadAsStringAsync(ct);

        if (!respuesta.IsSuccessStatusCode)
        {
            throw new InvalidOperationException(
                $"No se pudo obtener el token de la GRE. " +
                $"HTTP {(int)respuesta.StatusCode}. Recibido: {Recortar(texto)}. " +
                "Revisa que el client_id y el client_secret sean los que el " +
                "contribuyente generó en su menú SOL, y que el usuario SOL " +
                "lleve el RUC delante.");
        }

        // UN 200 NO SIGNIFICA QUE HAYA TOKEN.
        //
        // El servicio responde 200 y mete el error dentro del cuerpo, con un
        // campo "cod" y un "msg". Dar por bueno el código HTTP hacía que el
        // fallo apareciera más tarde, en el envío, con un mensaje que
        // culpaba al token cuando el token nunca había existido.
        //
        // Es el mismo patrón que ya nos costó tiempo con SUNAT devolviendo
        // HTML en vez de XML: hay que mirar el contenido, no solo el estado.
        var error = JsonSerializer.Deserialize<ErrorEnCuerpo>(texto);

        if (error is not null && !string.IsNullOrWhiteSpace(error.Cod))
        {
            throw new InvalidOperationException(
                $"El servicio rechazó las credenciales. " +
                $"Código {error.Cod}: {error.Msg}");
        }

        var datos = JsonSerializer.Deserialize<RespuestaToken>(texto);

        if (datos is null || string.IsNullOrWhiteSpace(datos.AccessToken))
        {
            throw new InvalidOperationException(
                $"La respuesta no contiene un token. Recibido: {Recortar(texto)}");
        }

        _token = datos.AccessToken;

        // expires_in viene en segundos. SUNAT usa 3600 hoy, pero el manual
        // dice que el valor lo indica el propio servicio: se respeta el que
        // llegue en vez de suponerlo.
        _tokenExpira = DateTime.UtcNow.AddSeconds(datos.ExpiresIn);

        return _token;
    }

    // ------------------------------------------------------------ envío

    /// <summary>
    /// Envía una guía firmada y comprimida.
    ///
    /// Devuelve un TICKET, no un CDR. La guía no está aceptada hasta que se
    /// consulte ese ticket, y eso importa más aquí que en las facturas: el
    /// traslado no puede empezar sin una constancia aceptada.
    /// </summary>
    public async Task<EnvioGre> EnviarAsync(
        string nombreArchivo, byte[] zip, CancellationToken ct = default)
    {
        string token;

        try
        {
            token = await ObtenerTokenAsync(ct);
        }
        catch (Exception ex)
        {
            return new EnvioGre(false, null, ex.Message, EsReintentable: true);
        }

        // El nombre sin extensión es parte de la dirección. Así lo exige la
        // API: el recurso se identifica por RUC-tipo-serie-número.
        var identificador = Path.GetFileNameWithoutExtension(nombreArchivo);

        var url = $"{_config.UrlEnvio.TrimEnd('/')}" +
                  $"/contribuyente/gem/comprobantes/{identificador}";

        var cuerpo = new
        {
            archivo = new
            {
                nomArchivo = nombreArchivo,
                arcGreZip = Convert.ToBase64String(zip),

                // El hash del ZIP, no del XML. SUNAT lo usa para comprobar
                // que el archivo llegó íntegro.
                hashZip = Convert.ToHexString(SHA256.HashData(zip)).ToLowerInvariant()
            }
        };

        try
        {
            using var peticion = new HttpRequestMessage(HttpMethod.Post, url)
            {
                Content = JsonContent.Create(cuerpo)
            };

            peticion.Headers.TryAddWithoutValidation("Authorization", "Bearer " + token);

            var respuesta = await _http.SendAsync(peticion, ct);
            var texto = await respuesta.Content.ReadAsStringAsync(ct);

            var codigo = (int)respuesta.StatusCode;

            if (respuesta.IsSuccessStatusCode)
            {
                var datos = JsonSerializer.Deserialize<RespuestaEnvio>(texto);

                if (string.IsNullOrWhiteSpace(datos?.NumTicket))
                {
                    return new EnvioGre(false, null,
                        $"SUNAT aceptó el envío pero no devolvió ticket. " +
                        $"Recibido: {Recortar(texto)}",
                        EsReintentable: true, CodigoHttp: codigo);
                }

                return new EnvioGre(true, datos.NumTicket,
                    "Guía enviada. Falta consultar el ticket.",
                    CodigoHttp: codigo);
            }

            // Un 401 significa que el token caducó o fue revocado. Se
            // descarta el que teníamos para que el siguiente intento pida
            // uno nuevo en vez de repetir el mismo error.
            if (codigo == 401)
            {
                _token = null;
                _tokenExpira = DateTime.MinValue;

                return new EnvioGre(false, null,
                    "El token fue rechazado. Se pedirá uno nuevo en el " +
                    "siguiente intento.",
                    EsReintentable: true, CodigoHttp: codigo);
            }

            // Un 4xx que no sea 401 ni 429 es un problema del documento o de
            // la configuración: reintentarlo daría el mismo resultado.
            var reintentable = codigo >= 500 || codigo == 429;

            return new EnvioGre(false, null,
                DescribirError(codigo, texto),
                EsReintentable: reintentable, CodigoHttp: codigo);
        }
        catch (TaskCanceledException) when (!ct.IsCancellationRequested)
        {
            return new EnvioGre(false, null,
                "Tiempo de espera agotado. SUNAT no respondió dentro del plazo.",
                EsReintentable: true);
        }
        catch (HttpRequestException ex)
        {
            return new EnvioGre(false, null,
                $"Error de red: {ex.Message}", EsReintentable: true);
        }
    }

    // --------------------------------------------------------- consulta

    /// <summary>
    /// Consulta el resultado de un envío por su ticket.
    /// </summary>
    public async Task<EstadoGre> ConsultarAsync(
        string ticket, CancellationToken ct = default)
    {
        string token;

        try
        {
            token = await ObtenerTokenAsync(ct);
        }
        catch (Exception ex)
        {
            return new EstadoGre(false, false, null, ex.Message, null, [],
                EsReintentable: true);
        }

        var url = $"{_config.UrlEnvio.TrimEnd('/')}" +
                  $"/contribuyente/gem/comprobantes/envios/{ticket}";

        try
        {
            using var peticion = new HttpRequestMessage(HttpMethod.Get, url);
            peticion.Headers.TryAddWithoutValidation("Authorization", "Bearer " + token);

            var respuesta = await _http.SendAsync(peticion, ct);
            var texto = await respuesta.Content.ReadAsStringAsync(ct);

            var codigo = (int)respuesta.StatusCode;

            if (codigo == 401)
            {
                _token = null;
                _tokenExpira = DateTime.MinValue;

                return new EstadoGre(false, false, null,
                    "El token fue rechazado. Se reintentará.", null, [],
                    EsReintentable: true);
            }

            if (!respuesta.IsSuccessStatusCode)
            {
                return new EstadoGre(false, false, null,
                    DescribirError(codigo, texto), null, [],
                    EsReintentable: codigo >= 500 || codigo == 429);
            }

            var datos = JsonSerializer.Deserialize<RespuestaTicket>(texto);

            if (datos is null)
                return new EstadoGre(false, false, null,
                    $"Respuesta ilegible: {Recortar(texto)}", null, [],
                    EsReintentable: true, RespuestaCruda: texto);

            // SUNAT usa códigos de estado propios para el proceso:
            //   "06" en proceso, "05" procesado, "98"/"99" con error.
            // Mientras esté en proceso hay que volver a preguntar.
            if (datos.CodRespuesta is null or "" or "98")
            {
                return new EstadoGre(false, false, datos.CodRespuesta,
                    "SUNAT sigue procesando la guía.", null, [],
                    RespuestaCruda: texto);
            }

            var aceptado = datos.CodRespuesta == "0";

            byte[]? cdr = null;

            if (!string.IsNullOrWhiteSpace(datos.ArcCdr))
            {
                try { cdr = Convert.FromBase64String(datos.ArcCdr); }
                catch (FormatException) { /* se guarda sin CDR */ }
            }

            var observaciones = datos.Observaciones ?? [];

            // Cuando el rechazo no trae CDR ni mensaje, se arma una
            // descripción con lo que haya llegado. Es preferible un texto
            // feo con la verdad que uno limpio que no dice nada.
            var descripcion = datos.Mensaje ?? datos.DesRespuesta;

            if (string.IsNullOrWhiteSpace(descripcion))
            {
                descripcion = aceptado
                    ? "Aceptada"
                    : $"Rechazada con código {datos.CodRespuesta}. " +
                      $"Respuesta: {Recortar(texto)}";
            }

            return new EstadoGre(
                Terminado: true,
                Aceptado: aceptado,
                CodigoRespuesta: datos.CodRespuesta,
                Descripcion: descripcion,
                CdrZip: cdr,
                Observaciones: observaciones,
                RespuestaCruda: texto);
        }
        catch (TaskCanceledException) when (!ct.IsCancellationRequested)
        {
            return new EstadoGre(false, false, null,
                "Tiempo de espera agotado.", null, [], EsReintentable: true);
        }
        catch (HttpRequestException ex)
        {
            return new EstadoGre(false, false, null,
                $"Error de red: {ex.Message}", null, [], EsReintentable: true);
        }
    }

    // ------------------------------------------------------------ apoyo

    /// <summary>
    /// Describe un error HTTP con lo que de verdad llegó.
    ///
    /// Igual que en el cliente SOAP: el mensaje dice el hecho y un recorte
    /// de la respuesta, no una suposición sobre la causa.
    /// </summary>
    private static string DescribirError(int codigo, string cuerpo)
    {
        var pista = codigo switch
        {
            400 => "La petición no es válida. Suele ser el nombre del archivo " +
                   "o el hash.",
            403 => "Acceso denegado. Comprueba que la empresa esté habilitada " +
                   "para emitir guías.",
            404 => "La dirección no existe. Revisa el endpoint.",
            422 => "SUNAT rechazó el contenido de la guía.",
            429 => "SUNAT está limitando las peticiones.",
            >= 500 => "Error de servidor en SUNAT.",
            _ => "Respuesta inesperada."
        };

        return $"{pista} HTTP {codigo}. Recibido: {Recortar(cuerpo)}";
    }

    private static string Recortar(string texto) =>
        texto.Length > 300
            ? texto[..300].ReplaceLineEndings(" ") + "..."
            : texto.ReplaceLineEndings(" ");

    public void Dispose() => _http.Dispose();

    // ------------------------------------------------- formas de respuesta

    /// <summary>
    /// Error devuelto dentro de una respuesta con estado 200.
    ///
    /// No es lo habitual en HTTP, pero este servicio lo hace, y descubrirlo
    /// tarde confunde: el fallo aparece dos pasos más adelante.
    /// </summary>
    private sealed record ErrorEnCuerpo(
        [property: JsonPropertyName("cod")] string? Cod,
        [property: JsonPropertyName("msg")] string? Msg);

    private sealed record RespuestaToken(
        [property: JsonPropertyName("access_token")] string AccessToken,
        [property: JsonPropertyName("expires_in")] int ExpiresIn,
        [property: JsonPropertyName("token_type")] string? TokenType);

    private sealed record RespuestaEnvio(
        [property: JsonPropertyName("numTicket")] string? NumTicket);

    /// <summary>
    /// La respuesta del ticket.
    ///
    /// Se declaran más campos de los que la documentación menciona porque el
    /// motivo del rechazo aparece en unos u otros según el caso: a veces en
    /// "mensaje", a veces dentro de "error", a veces solo en el CDR.
    /// </summary>
    private sealed record RespuestaTicket(
        [property: JsonPropertyName("codRespuesta")] string? CodRespuesta,
        [property: JsonPropertyName("arcCdr")] string? ArcCdr,
        [property: JsonPropertyName("indCdrGenerado")] string? IndCdrGenerado,
        [property: JsonPropertyName("mensaje")] string? Mensaje,
        [property: JsonPropertyName("desRespuesta")] string? DesRespuesta,
        [property: JsonPropertyName("error")] JsonElement? Error,
        [property: JsonPropertyName("observaciones")] string[]? Observaciones);
}
