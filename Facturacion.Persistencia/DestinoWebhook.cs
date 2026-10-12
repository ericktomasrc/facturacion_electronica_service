using System.Net;
using System.Net.Sockets;

namespace Facturacion.Persistencia;

/// <summary>
/// Si se permiten destinos locales: http:// y ESTA MISMA MÁQUINA (localhost,
/// 127.x, ::1), que es donde corre la plataforma en desarrollo
/// (http://localhost:5255). Las demás IPs internas —10.x, 192.168.x,
/// 169.254.x…— siguen bloqueadas incluso así, y por eso las pruebas
/// negativas se pueden hacer en desarrollo.
///
/// SOLO EN DESARROLLO, y solo si se pide: el entorno tiene que ser
/// Development Y la variable FACTURACION_WEBHOOKS_LOCALES valer "true". Es
/// el mismo patrón que FACTURACION_TLS_INSEGURO en la plataforma: una de
/// las dos condiciones sola no basta, para que un .env copiado a producción
/// no abra la puerta.
///
/// La comparten la API (al registrar) y el worker (al despachar), y cada uno
/// la calcula al arrancar con <see cref="Resolver"/>.
/// </summary>
public sealed record ReglasDestinoWebhook(bool PermitirLocales)
{
    public const string Variable = "FACTURACION_WEBHOOKS_LOCALES";

    public static ReglasDestinoWebhook Resolver(bool esDesarrollo)
    {
        var pedida = ConfiguracionSecretos.Opcional(Variable, "false")
            .Equals("true", StringComparison.OrdinalIgnoreCase);

        return new ReglasDestinoWebhook(esDesarrollo && pedida);
    }

    /// <summary>Lo que se escribe en el registro al arrancar.</summary>
    public static string Diagnostico(bool esDesarrollo)
    {
        var pedida = ConfiguracionSecretos.Opcional(Variable, "false")
            .Equals("true", StringComparison.OrdinalIgnoreCase);

        if (pedida && esDesarrollo)
            return $"Webhooks: destinos LOCALES PERMITIDOS ({Variable}=true en Development). " +
                   "Se aceptan http:// y esta máquina (localhost). Las demás IPs internas, no. " +
                   "NUNCA en producción.";

        if (pedida)
            return $"Webhooks: {Variable}=true SE IGNORA porque el entorno no es Development. " +
                   "Solo https:// y direcciones públicas.";

        if (esDesarrollo)
            return "Webhooks: solo https:// y direcciones públicas. OJO: así la plataforma " +
                   $"en http://localhost NO recibe avisos. Pon {Variable}=true en el .env.";

        return "Webhooks: solo https:// y direcciones públicas.";
    }
}

/// <summary>
/// A dónde puede mandar el servicio sus avisos.
///
/// EL RIESGO QUE CIERRA (diseño §2.4): desde que una clave fac_ puede
/// registrar su webhook, cualquiera con una clave decide a qué dirección le
/// hace el servicio un POST cada vez que hay una factura. Si esa dirección
/// fuera interna —la base, el almacén, el 169.254.169.254 de un proveedor de
/// nube— el servicio sería una puerta hacia dentro.
///
/// Se comprueba DOS veces:
///
///   Al registrar   <see cref="RevisarAsync"/>: forma de la URL y a qué IPs
///                  resuelve. Da un mensaje claro a quien la escribió.
///
///   Al despachar   <see cref="CrearManejador"/>: el worker resuelve el
///                  nombre, comprueba CADA IP y se conecta a esa misma IP
///                  ya comprobada. Un dominio puede cambiar de IP entre el
///                  registro y el envío (o entre la comprobación y la
///                  conexión, si se hicieran por separado); así no hay hueco.
///                  Y no se siguen redirecciones: un 302 hacia dentro sería
///                  la misma puerta por otro lado.
/// </summary>
public static class DestinoWebhook
{
    public const int LargoMaximo = 2000;

    /// <summary>
    /// Revisa la forma de la URL, sin tocar la red. Null si está bien; si no,
    /// el motivo, escrito para quien la tecleó.
    /// </summary>
    public static string? RevisarForma(string? url, bool permitirLocales)
    {
        if (string.IsNullOrWhiteSpace(url))
            return "Falta la URL.";

        if (url.Length > LargoMaximo)
            return $"La URL es demasiado larga (máximo {LargoMaximo} caracteres).";

        if (!Uri.TryCreate(url.Trim(), UriKind.Absolute, out var uri) ||
            (uri.Scheme != Uri.UriSchemeHttp && uri.Scheme != Uri.UriSchemeHttps))
            return "La URL no es válida. Debe ser una dirección completa que empiece con https://";

        if (!string.IsNullOrEmpty(uri.UserInfo))
            return "La URL no puede llevar usuario ni contraseña delante del dominio.";

        if (uri.Scheme != Uri.UriSchemeHttps && !permitirLocales)
            return "La URL tiene que empezar con https://. Por http:// los avisos " +
                   "viajarían sin cifrar, con datos de facturación del cliente.";

        if (IPAddress.TryParse(uri.IdnHost.Trim('[', ']'), out var ip))
            return Permitida(ip, permitirLocales)
                ? null
                : $"La URL apunta a una IP interna ({ip}). Tiene que ser una dirección pública.";

        var host = uri.IdnHost.TrimEnd('.').ToLowerInvariant();

        if (permitirLocales && (host == "localhost" || host.EndsWith(".localhost")))
            return null;

        if (EsNombreLocal(host))
            return "La URL apunta a un nombre local. Tiene que ser una dirección pública.";

        return null;
    }

    /// <summary>
    /// Forma y a qué IPs resuelve el nombre. Null si está bien.
    /// </summary>
    public static async Task<string?> RevisarAsync(
        string? url, bool permitirLocales, CancellationToken ct = default)
    {
        var forma = RevisarForma(url, permitirLocales);
        if (forma is not null) return forma;

        var uri = new Uri(url!.Trim());

        IPAddress[] direcciones;

        try
        {
            direcciones = await ResolverAsync(uri.IdnHost, ct);
        }
        catch (SocketException)
        {
            return $"No se encuentra el dominio {uri.IdnHost}. Revisa que esté bien escrito.";
        }

        if (direcciones.Length == 0)
            return $"No se encuentra el dominio {uri.IdnHost}. Revisa que esté bien escrito.";

        var interna = direcciones.FirstOrDefault(d => !Permitida(d, permitirLocales));

        return interna is null
            ? null
            : $"El dominio {uri.IdnHost} resuelve a una IP interna ({interna}). " +
              "Tiene que ser una dirección pública.";
    }

    /// <summary>
    /// El manejador HTTP del despachador: no sigue redirecciones, no usa
    /// proxy y solo se conecta a IPs comprobadas.
    /// </summary>
    public static SocketsHttpHandler CrearManejador(bool permitirLocales) => new()
    {
        AllowAutoRedirect = false,
        UseProxy = false,
        UseCookies = false,
        PooledConnectionLifetime = TimeSpan.FromMinutes(2),

        ConnectCallback = async (contexto, ct) =>
        {
            var host = contexto.DnsEndPoint.Host;
            var puerto = contexto.DnsEndPoint.Port;

            var direcciones = await ResolverAsync(host, ct);

            if (direcciones.Length == 0)
                throw new HttpRequestException($"No se encuentra el dominio {host}.");

            // TODAS, no la primera: un nombre con una IP pública y otra
            // privada es justo el truco que esto tiene que parar.
            var interna = direcciones.FirstOrDefault(d => !Permitida(d, permitirLocales));

            if (interna is not null)
                throw new DestinoBloqueadoException(
                    $"Bloqueado: {host} resuelve a una IP interna ({interna}). " +
                    "Los webhooks solo van a direcciones públicas.");

            Exception? ultimo = null;

            foreach (var ip in direcciones)
            {
                var socket = new Socket(ip.AddressFamily, SocketType.Stream, ProtocolType.Tcp)
                {
                    NoDelay = true
                };

                try
                {
                    await socket.ConnectAsync(new IPEndPoint(ip, puerto), ct);
                    return new NetworkStream(socket, ownsSocket: true);
                }
                catch (Exception ex) when (ex is not OperationCanceledException)
                {
                    socket.Dispose();
                    ultimo = ex;
                }
            }

            throw new HttpRequestException(
                $"No se pudo conectar con {host}:{puerto}.", ultimo);
        }
    };

    private static async Task<IPAddress[]> ResolverAsync(string host, CancellationToken ct)
    {
        if (IPAddress.TryParse(host.Trim('[', ']'), out var literal))
            return [literal];

        return await Dns.GetHostAddressesAsync(host, ct);
    }

    /// <summary>
    /// Pública, o esta misma máquina cuando se permiten locales. Nunca el
    /// resto de la red interna.
    /// </summary>
    private static bool Permitida(IPAddress ip, bool permitirLocales)
    {
        if (!EsInterna(ip)) return true;

        if (ip.IsIPv4MappedToIPv6) ip = ip.MapToIPv4();

        return permitirLocales && IPAddress.IsLoopback(ip);
    }

    private static bool EsNombreLocal(string host)
    {
        var h = host.TrimEnd('.').ToLowerInvariant();

        return h == "localhost"
            || h.EndsWith(".localhost")
            || h.EndsWith(".local")
            || h.EndsWith(".internal")
            || h.EndsWith(".lan")
            || !h.Contains('.');   // "postgres", "minio": nombres de la red interna
    }

    /// <summary>
    /// Si una IP es de las que no se pueden alcanzar desde fuera: privada, de
    /// bucle local, de enlace local, compartida (CGNAT), multidifusión o
    /// reservada.
    /// </summary>
    public static bool EsInterna(IPAddress ip)
    {
        if (ip.IsIPv4MappedToIPv6) ip = ip.MapToIPv4();

        if (IPAddress.IsLoopback(ip)) return true;

        if (ip.AddressFamily == AddressFamily.InterNetwork)
        {
            var b = ip.GetAddressBytes();

            return b[0] switch
            {
                0 => true,                                   // 0.0.0.0/8
                10 => true,                                  // 10/8
                100 => b[1] >= 64 && b[1] <= 127,            // 100.64/10 (CGNAT)
                127 => true,                                 // 127/8
                169 => b[1] == 254,                          // 169.254/16
                172 => b[1] >= 16 && b[1] <= 31,             // 172.16/12
                192 => (b[1] == 168)                         // 192.168/16
                    || (b[1] == 0 && b[2] == 0),             // 192.0.0/24
                198 => b[1] == 18 || b[1] == 19,             // 198.18/15
                >= 224 => true,                              // multidifusión y reservadas
                _ => false
            };
        }

        if (ip.AddressFamily == AddressFamily.InterNetworkV6)
        {
            if (ip.Equals(IPAddress.IPv6Any) || ip.Equals(IPAddress.IPv6None)) return true;
            if (ip.IsIPv6LinkLocal || ip.IsIPv6SiteLocal || ip.IsIPv6Multicast) return true;

            var b = ip.GetAddressBytes();

            if ((b[0] & 0xFE) == 0xFC) return true;          // fc00::/7 (privadas)

            // 64:ff9b::/96 lleva una IPv4 dentro (NAT64): se mira esa.
            if (b[0] == 0x00 && b[1] == 0x64 && b[2] == 0xFF && b[3] == 0x9B &&
                b.Skip(4).Take(8).All(x => x == 0))
                return EsInterna(new IPAddress(b.Skip(12).ToArray()));

            return false;
        }

        return true;   // otra familia: no se conoce, no se usa
    }
}

/// <summary>
/// El destino de un webhook resolvió a una IP interna y no se conectó.
///
/// Tipo propio para que el despachador lo distinga de un servidor caído:
/// esto no se arregla reintentando, así que la entrega queda agotada al
/// primer intento, como un 4xx.
/// </summary>
public sealed class DestinoBloqueadoException : Exception
{
    public DestinoBloqueadoException(string mensaje) : base(mensaje) { }

    /// <summary>Busca esta excepción en la cadena de InnerException.</summary>
    public static DestinoBloqueadoException? Buscar(Exception? ex)
    {
        for (var actual = ex; actual is not null; actual = actual.InnerException)
            if (actual is DestinoBloqueadoException bloqueado) return bloqueado;

        return null;
    }
}