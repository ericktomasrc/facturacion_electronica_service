# =============================================================================
# Entrega 2026-10-10 — Alta de una empresa, PARTE A (servicio): el webhook de la API
#
# Se ejecuta desde la raíz del servicio:
#   cd "D:\Reyban Consulting\facturacion electronica\facturacion_electronica_service"
#   .\entrega-2026-10-10-parteA-webhook-api.ps1
#
#   migraciones\023_webhook_api.sql   NUEVO. webhooks.origen ('panel'|'api'),
#                                     secreto_cambiado_en, uno de la API activo
#                                     por empresa, webhook_cambios, y fuera
#                                     DELETE/TRUNCATE. No se aplica sola
#   Persistencia\DestinoWebhook.cs     NUEVO. A dónde se puede mandar un aviso:
#                                     https y direcciones públicas. Al registrar
#                                     y al conectar desde el worker
#   Persistencia\RepositorioWebhookApi NUEVO. El webhook de la API, con RLS
#   Persistencia\RepositorioWebhooks   Sin DELETE. Desactivar anota el cambio.
#                                     Lista con origen. Historial de cambios
#   Api\EndpointsWebhookApi.cs         NUEVO. POST y GET /v1/webhook, y
#                                     POST /v1/webhook/reintentar
#   Api\EndpointsWebhooks.cs           Panel: sin «Eliminar», URL revisada,
#                                     /webhook-cambios, permiso en reintentar
#   Api\Autenticacion.cs               El prefijo de la clave, para el rastro
#   Api\Program.cs                     Registra lo nuevo
#   Api\wwwroot\admin.html             Pestaña Webhooks: «registrado por la
#                                     API», sin Eliminar, tabla de Cambios
#   Worker\DespachadorWebhooks.cs      Revisa la URL al despachar; bloqueo = agotado
#   Worker\Program.cs                  El cliente HTTP seguro de los webhooks
#
# PROTECCIÓN: los 7 que ya existen solo se reemplazan si siguen IGUAL a los
# que me pasaste el 10 de octubre por la noche. Si alguno cambió, NO TOCA
# NADA. Todo o nada. UTF-8 sin BOM, .bak. La migración NO se aplica.
# =============================================================================

$ErrorActionPreference = 'Stop'
$raiz = (Get-Location).Path

if (-not (Test-Path (Join-Path $raiz 'Facturacion.Api')) -or -not (Test-Path (Join-Path $raiz 'migraciones'))) {
    Write-Host "No encuentro 'Facturacion.Api' y 'migraciones' aquí ($raiz)." -ForegroundColor Red
    Write-Host "Ejecuta el script desde la raíz del servicio (facturacion_electronica_service). No se tocó nada." -ForegroundColor Red
    exit 1
}

$utf8SinBom = New-Object System.Text.UTF8Encoding $false

function Normalizar([string]$t) { return $t.TrimStart([char]0xFEFF).Replace("`r", '').TrimEnd() }

function Huella([string]$t) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $bytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes((Normalizar $t)))
    return ([System.BitConverter]::ToString($bytes)).Replace('-', '')
}

function Respaldar([string]$completa) {
    $bak = "$completa.bak"
    if (Test-Path $bak) { $bak = "$completa.$(Get-Date -Format 'yyyyMMdd-HHmmss').bak" }
    Copy-Item $completa $bak -Force
    return (Split-Path $bak -Leaf)
}

$plan = New-Object System.Collections.Generic.List[object]

# Una ruta que empieza por '*' se busca por nombre dentro de reyban_plataforma_web\src.
function Planear([string]$ruta, [string]$esperada, [string]$texto) {
    $texto = $texto.Replace("`r", '')
    if ($ruta.StartsWith('*')) {
        $nombre = $ruta.Substring(1)
        $hallados = @(Get-ChildItem -Path (Join-Path $raiz 'reyban_plataforma_web\src') -Recurse -Filter $nombre -File |
            Where-Object { $_.FullName -notmatch '\\node_modules\\' })
        if ($hallados.Count -ne 1) {
            $plan.Add([pscustomobject]@{ Ruta = $nombre; Accion = 'conflicto'; Motivo = "lo encuentro $($hallados.Count) veces dentro de reyban_plataforma_web\src. Dime cuál es." })
            return
        }
        $completa = $hallados[0].FullName
        $ruta = $completa.Substring($raiz.Length).TrimStart('\')
    }
    else { $completa = Join-Path $raiz $ruta }

    $accion = ''; $motivo = ''; $crlf = $false
    if (-not (Test-Path $completa)) {
        if ($esperada -eq '') { $accion = 'nuevo' }
        else { $accion = 'conflicto'; $motivo = 'no existe. ¿Está en otra carpeta?' }
    }
    else {
        $actual = [System.IO.File]::ReadAllText($completa)
        $crlf = $actual.Contains("`r`n")
        if ((Normalizar $actual) -eq (Normalizar $texto)) { $accion = 'igual' }
        elseif ((Huella $actual) -ne $esperada) { $accion = 'conflicto'; $motivo = 'cambió desde que me lo pasaste. Pásamelo de nuevo.' }
        else { $accion = 'reemplazar' }
    }
    $plan.Add([pscustomobject]@{ Ruta = $ruta; Completa = $completa; Accion = $accion; Motivo = $motivo; Texto = $texto; Crlf = $crlf })
}

# --- migraciones\023_webhook_api.sql
Planear 'migraciones\023_webhook_api.sql' '' @'
-- ===========================================================================
-- 023 — El webhook de la API: la clave fac_ registra el suyo
--
-- POR QUE HACE FALTA (alta-empresa-diseno.md, parte A):
--
-- Hasta hoy un webhook solo se registraba desde el panel, y el secreto whsec_
-- se copiaba a mano a la plataforma. Desde ahora la plataforma lo registra
-- sola con POST /v1/webhook, usando la clave de la empresa.
--
-- UNO POR EMPRESA, Y SE ACTUALIZA EN LA MISMA FILA. El disparador
-- encolar_evento_comprobante crea una entrega por cada webhook activo: si
-- cada rotacion creara uno nuevo, cada factura se avisaria dos, tres, cuatro
-- veces. Por eso:
--
--   origen               'panel' (los de siempre) o 'api' (los de /v1/webhook)
--   ux_webhooks_api_...  como mucho UN webhook 'api' activo por empresa
--   secreto_cambiado_en  cuando se genero el secreto vigente
--
-- webhook_cambios: quien cambio que y cuando. URL de antes y de despues,
-- y el prefijo de la clave que lo hizo (el mismo que ensena el panel).
-- NUNCA el secreto.
--
-- NADA SE BORRA (punto 18): se quita DELETE y TRUNCATE sobre webhooks,
-- webhook_entregas y webhook_cambios a todos los roles de la aplicacion. El
-- boton "Eliminar" del panel desaparece; queda "Desactivar".
--
-- Idempotente: se puede aplicar dos veces sin error.
-- ===========================================================================

BEGIN;

-- --- webhooks: origen y fecha del secreto ---------------------------------

ALTER TABLE webhooks
    ADD COLUMN IF NOT EXISTS origen text NOT NULL DEFAULT 'panel';

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'ck_webhooks_origen'
                      AND conrelid = 'webhooks'::regclass) THEN
        ALTER TABLE webhooks
            ADD CONSTRAINT ck_webhooks_origen CHECK (origen IN ('panel', 'api'));
    END IF;
END
$$;

ALTER TABLE webhooks
    ADD COLUMN IF NOT EXISTS secreto_cambiado_en timestamptz;

-- Los que ya existen: su secreto es el de su creacion.
UPDATE webhooks SET secreto_cambiado_en = creado_en
 WHERE secreto_cambiado_en IS NULL;

ALTER TABLE webhooks ALTER COLUMN secreto_cambiado_en SET DEFAULT now();
ALTER TABLE webhooks ALTER COLUMN secreto_cambiado_en SET NOT NULL;

-- Uno solo de la API, activo, por empresa. Los desactivados no cuentan:
-- quedan como historial.
CREATE UNIQUE INDEX IF NOT EXISTS ux_webhooks_api_por_tenant
    ON webhooks (tenant_id)
    WHERE origen = 'api' AND activo;


-- --- webhook_cambios -------------------------------------------------------

CREATE TABLE IF NOT EXISTS webhook_cambios (
    id              bigserial   PRIMARY KEY,
    webhook_id      uuid        NOT NULL REFERENCES webhooks(id) ON DELETE RESTRICT,
    tenant_id       uuid        NOT NULL REFERENCES tenants(id)  ON DELETE RESTRICT,

    -- alta:        la API lo creo
    -- rotacion:    la API le cambio el secreto (y quiza la URL)
    -- activado / desactivado: desde el panel
    accion          text        NOT NULL,

    url_antes       text,
    url_despues     text        NOT NULL,

    -- 'api' o 'panel'
    hecho_desde     text        NOT NULL,

    -- Prefijo de la clave fac_ que hizo el cambio: sus primeros 20
    -- caracteres, los mismos de api_keys.prefijo, que el panel ya ensena en
    -- la pestana Claves de acceso. Sirve para encontrarla y revocarla.
    prefijo_clave   text,

    -- Los cambios hechos desde el panel no llevan prefijo: quien los hizo esta
    -- en la bitacora del panel (auditoria), con su correo, ruta y hora.

    creado_en       timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT ck_webhook_cambios_accion
        CHECK (accion IN ('alta', 'rotacion', 'activado', 'desactivado')),
    CONSTRAINT ck_webhook_cambios_desde
        CHECK (hecho_desde IN ('api', 'panel')),
    CONSTRAINT ck_webhook_cambios_prefijo
        CHECK (prefijo_clave IS NULL OR length(prefijo_clave) <= 20)
);

CREATE INDEX IF NOT EXISTS ix_webhook_cambios_tenant
    ON webhook_cambios (tenant_id, creado_en DESC);

ALTER TABLE webhook_cambios ENABLE ROW LEVEL SECURITY;
ALTER TABLE webhook_cambios FORCE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS aislamiento_tenant ON webhook_cambios;

CREATE POLICY aislamiento_tenant ON webhook_cambios
    USING (tenant_id = app_tenant_actual())
    WITH CHECK (tenant_id = app_tenant_actual());

-- Solo se escribe y se lee: ni UPDATE ni DELETE. Es una bitacora.
GRANT SELECT, INSERT ON webhook_cambios TO facturacion_app;
GRANT SELECT, INSERT ON webhook_cambios TO facturacion_operador;
GRANT USAGE, SELECT ON SEQUENCE webhook_cambios_id_seq TO facturacion_app;
GRANT USAGE, SELECT ON SEQUENCE webhook_cambios_id_seq TO facturacion_operador;


-- --- Nada se borra --------------------------------------------------------
--
-- La 005 dio ALL al operador, que incluye DELETE y TRUNCATE. El unico que
-- los usaba era "Eliminar webhook", que desaparece en esta misma entrega.

REVOKE DELETE, TRUNCATE ON webhooks, webhook_entregas, webhook_cambios
    FROM facturacion_operador, facturacion_app;


-- Sin tildes: PowerShell 5.1 manda este archivo a psql en ASCII.
COMMENT ON COLUMN webhooks.origen IS
    'panel: registrado a mano en el panel. api: registrado con POST /v1/webhook por la clave de la empresa; uno activo como mucho.';

COMMENT ON TABLE webhook_cambios IS
    'Quien cambio cada webhook y cuando: URL antes y despues, prefijo de la clave. Nunca el secreto.';

COMMIT;
'@

# --- Facturacion.Persistencia\DestinoWebhook.cs
Planear 'Facturacion.Persistencia\DestinoWebhook.cs' '' @'
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
'@

# --- Facturacion.Persistencia\RepositorioWebhookApi.cs
Planear 'Facturacion.Persistencia\RepositorioWebhookApi.cs' '' @'
using Dapper;

namespace Facturacion.Persistencia;

/// <summary>Lo que devuelve registrar el webhook de la API.</summary>
public record RegistroWebhookApi(
    Guid Id,
    string Url,
    string Secreto,
    bool Creado,
    string? UrlAnterior);

/// <summary>Cómo está el webhook de la API de una empresa. Nunca el secreto.</summary>
public record EstadoWebhookApi(
    Guid Id,
    string Url,
    DateTime CreadoEn,
    DateTime SecretoCambiadoEn,
    int Pendientes,
    int Agotados);

/// <summary>La última entrega del webhook de la API.</summary>
public record UltimaEntregaApi(
    string Tipo,
    string Estado,
    short Intentos,
    int? UltimoCodigo,
    string? UltimoError,
    DateTime CreadoEn,
    DateTime? EntregadoEn);

/// <summary>El último cambio del webhook de la API (webhook_cambios).</summary>
public record UltimoCambioApi(
    string Accion,
    string HechoDesde,
    string? PrefijoClave,
    DateTime CreadoEn);

/// <summary>
/// El webhook de la API: el que registra la propia empresa con su clave fac_
/// (POST /v1/webhook). Diseño: alta-empresa-diseno.md, parte A.
///
/// A DIFERENCIA DE RepositorioWebhooks, ESTE NO USA EL ROL DE OPERADOR. Todo
/// va por FabricaSesiones, con el rol facturacion_app y la empresa de la
/// clave declarada para Row Level Security. La empresa sale de la clave
/// (ContextoEmisor), nunca de la petición; y aunque un WHERE de aquí se
/// equivocara, la base no dejaría ver ni tocar el webhook de otra empresa.
/// Son dos barreras, a propósito.
///
/// UNO POR EMPRESA, Y SE ACTUALIZA EN LA MISMA FILA (diseño §2.2). Las
/// entregas en cola leen la URL y el secreto al despacharse: actualizando la
/// fila, salen firmadas con el secreto nuevo, que es el que la plataforma ya
/// tiene. Si se creara otro, cada factura se avisaría dos veces.
///
/// Los webhooks del panel (origen 'panel') no se ven ni se tocan desde aquí.
/// </summary>
public sealed class RepositorioWebhookApi
{
    public const string NombreWebhook = "Webhook de la empresa";

    private readonly FabricaSesiones _sesiones;

    public RepositorioWebhookApi(FabricaSesiones sesiones)
    {
        _sesiones = sesiones ?? throw new ArgumentNullException(nameof(sesiones));
    }

    /// <summary>
    /// Crea el webhook de la API de la empresa o, si ya tiene uno activo, le
    /// cambia la URL y el secreto. Siempre devuelve un secreto NUEVO: el
    /// anterior deja de valer en ese instante.
    ///
    /// La URL tiene que venir ya revisada por DestinoWebhook.
    /// </summary>
    public async Task<RegistroWebhookApi> RegistrarAsync(
        Guid tenantId, string url, string? prefijoClave, CancellationToken ct = default)
    {
        var secreto = RepositorioWebhooks.GenerarSecreto();

        await using var sesion = await _sesiones.AbrirAsync(tenantId, ct);

        // DOS PETICIONES A LA VEZ de la misma empresa (dos pestañas pulsando
        // «Conectar») no pueden crear dos. El índice único ya lo impediría
        // con un error; el candado hace que la segunda espere y actualice.
        await sesion.Conexion.ExecuteAsync(new CommandDefinition(
            "SELECT pg_advisory_xact_lock(hashtextextended('webhook_api:' || @tenantId::text, 0))",
            new { tenantId }, sesion.Transaccion, cancellationToken: ct));

        var actual = await sesion.Conexion.QuerySingleOrDefaultAsync<IdYUrl>(
            new CommandDefinition(
                """
                SELECT id AS "Id", url AS "Url"
                  FROM webhooks
                 WHERE tenant_id = @tenantId
                   AND origen = 'api'
                   AND activo
                 FOR UPDATE
                """,
                new { tenantId }, sesion.Transaccion, cancellationToken: ct));

        Guid id;

        if (actual is null)
        {
            // Eventos vacío = todos (decisión del 10 de octubre): el día que
            // aparezca uno nuevo, llega solo, sin tocar cada empresa.
            id = await sesion.Conexion.ExecuteScalarAsync<Guid>(new CommandDefinition(
                """
                INSERT INTO webhooks
                       (tenant_id, nombre, url, secreto, eventos, origen, secreto_cambiado_en)
                VALUES (@tenantId, @nombre, @url, @secreto, '{}', 'api', now())
                RETURNING id
                """,
                new { tenantId, nombre = NombreWebhook, url, secreto },
                sesion.Transaccion, cancellationToken: ct));
        }
        else
        {
            id = actual.Id;

            await sesion.Conexion.ExecuteAsync(new CommandDefinition(
                """
                UPDATE webhooks
                   SET url = @url,
                       secreto = @secreto,
                       secreto_cambiado_en = now()
                 WHERE id = @id
                   AND tenant_id = @tenantId
                """,
                new { id, tenantId, url, secreto },
                sesion.Transaccion, cancellationToken: ct));
        }

        // La bitácora del cambio: URL de antes y de después, y quién (el
        // prefijo de la clave, el mismo que enseña el panel). EL SECRETO NO VA AQUÍ, ni en ningún registro.
        await sesion.Conexion.ExecuteAsync(new CommandDefinition(
            """
            INSERT INTO webhook_cambios
                   (webhook_id, tenant_id, accion, url_antes, url_despues,
                    hecho_desde, prefijo_clave)
            VALUES (@id, @tenantId, @accion, @urlAntes, @url, 'api', @prefijoClave)
            """,
            new
            {
                id, tenantId, url, prefijoClave,
                accion = actual is null ? "alta" : "rotacion",
                urlAntes = actual?.Url
            },
            sesion.Transaccion, cancellationToken: ct));

        await sesion.ConfirmarAsync(ct);

        return new RegistroWebhookApi(id, url, secreto, actual is null, actual?.Url);
    }

    /// <summary>El webhook de la API activo, o null si la empresa no tiene.</summary>
    public async Task<(EstadoWebhookApi? Webhook, UltimaEntregaApi? UltimaEntrega,
        UltimoCambioApi? UltimoCambio, int OtrosActivos)> ObtenerAsync(
        Guid tenantId, CancellationToken ct = default)
    {
        await using var sesion = await _sesiones.AbrirAsync(tenantId, ct);

        var webhook = await sesion.Conexion.QuerySingleOrDefaultAsync<EstadoWebhookApi>(
            new CommandDefinition(
                """
                SELECT w.id                  AS "Id",
                       w.url                 AS "Url",
                       w.creado_en           AS "CreadoEn",
                       w.secreto_cambiado_en AS "SecretoCambiadoEn",
                       (SELECT count(*)::int FROM webhook_entregas e
                         WHERE e.webhook_id = w.id AND e.estado = 'PENDIENTE') AS "Pendientes",
                       (SELECT count(*)::int FROM webhook_entregas e
                         WHERE e.webhook_id = w.id AND e.estado = 'AGOTADO')   AS "Agotados"
                  FROM webhooks w
                 WHERE w.tenant_id = @tenantId
                   AND w.origen = 'api'
                   AND w.activo
                """,
                new { tenantId }, sesion.Transaccion, cancellationToken: ct));

        // Los del panel no se enseñan, solo se cuentan: si hay alguno activo,
        // los avisos de esta empresa también van a otro sitio (el ERP de un
        // cliente, por ejemplo). La plataforma lo sabrá; la URL, no.
        var otros = await sesion.Conexion.ExecuteScalarAsync<int>(new CommandDefinition(
            """
            SELECT count(*)::int FROM webhooks
             WHERE tenant_id = @tenantId AND origen = 'panel' AND activo
            """,
            new { tenantId }, sesion.Transaccion, cancellationToken: ct));

        if (webhook is null) return (null, null, null, otros);

        var ultima = await sesion.Conexion.QuerySingleOrDefaultAsync<UltimaEntregaApi>(
            new CommandDefinition(
                """
                SELECT tipo          AS "Tipo",
                       estado        AS "Estado",
                       intentos      AS "Intentos",
                       ultimo_codigo AS "UltimoCodigo",
                       ultimo_error  AS "UltimoError",
                       creado_en     AS "CreadoEn",
                       entregado_en  AS "EntregadoEn"
                  FROM webhook_entregas
                 WHERE webhook_id = @id AND tenant_id = @tenantId
                 ORDER BY creado_en DESC, id DESC
                 LIMIT 1
                """,
                new { id = webhook.Id, tenantId }, sesion.Transaccion, cancellationToken: ct));

        var cambio = await sesion.Conexion.QuerySingleOrDefaultAsync<UltimoCambioApi>(
            new CommandDefinition(
                """
                SELECT accion      AS "Accion",
                       hecho_desde AS "HechoDesde",
                       prefijo_clave AS "PrefijoClave",
                       creado_en   AS "CreadoEn"
                  FROM webhook_cambios
                 WHERE webhook_id = @id AND tenant_id = @tenantId
                 ORDER BY creado_en DESC, id DESC
                 LIMIT 1
                """,
                new { id = webhook.Id, tenantId }, sesion.Transaccion, cancellationToken: ct));

        return (webhook, ultima, cambio, otros);
    }

    /// <summary>
    /// Devuelve a la cola las entregas AGOTADAS del webhook de la API de esta
    /// empresa, de los últimos <paramref name="dias"/> días. Devuelve cuántas.
    ///
    /// Para después de «Conectar» (diseño §10.5): mientras el servicio tenía
    /// un secreto que la plataforma no había guardado, los avisos se
    /// rechazaron con 401, y un 4xx no se reintenta: quedan agotados al primer
    /// intento. Reenviarlos es seguro: llevan el mismo evento_id y la
    /// plataforma descarta lo que ya tenía.
    ///
    /// Solo el webhook de la API de la propia empresa; nunca las del panel.
    /// </summary>
    public async Task<int> ReintentarAgotadasAsync(
        Guid tenantId, int dias, CancellationToken ct = default)
    {
        await using var sesion = await _sesiones.AbrirAsync(tenantId, ct);

        var filas = await sesion.Conexion.ExecuteAsync(new CommandDefinition(
            """
            UPDATE webhook_entregas e
               SET estado = 'PENDIENTE',
                   intentos = 0,
                   proximo_intento_en = NULL
              FROM webhooks w
             WHERE w.id = e.webhook_id
               AND w.tenant_id = @tenantId
               AND w.origen = 'api'
               AND w.activo
               AND e.tenant_id = @tenantId
               AND e.estado = 'AGOTADO'
               AND e.creado_en >= now() - make_interval(days => @dias)
            """,
            new { tenantId, dias }, sesion.Transaccion, cancellationToken: ct));

        await sesion.ConfirmarAsync(ct);

        return filas;
    }

    private sealed record IdYUrl(Guid Id, string Url);
}
'@

# --- Facturacion.Persistencia\RepositorioWebhooks.cs
Planear 'Facturacion.Persistencia\RepositorioWebhooks.cs' 'DCC1D3A29977227F6FDA6ED96819C7C3C013979266941CA501733FDB9173BDB3' @'
using System.Security.Cryptography;
using Dapper;
using Npgsql;

namespace Facturacion.Persistencia;

/// <summary>Un webhook configurado por una empresa.</summary>
///
/// LOS EVENTOS SE LEEN COMO TEXTO, NO COMO ARREGLO.
///
/// La columna es un text[] de PostgreSQL, y Dapper la entrega como
/// System.Array sin convertirla a string[]. El error que produce habla de
/// constructores, igual que pasó con count(*) devolviendo bigint y con las
/// columnas date.
///
/// Leerlo como una cadena separada por comas y dividirla aquí evita el
/// problema por completo, y cuesta menos que configurar un conversor.
public record WebhookAdmin(
    Guid Id,
    string Nombre,
    string Url,
    string? EventosTexto,
    bool Activo,
    DateTime CreadoEn,
    int Pendientes,
    int Agotados,
    string Origen,
    DateTime SecretoCambiadoEn)
{
    /// <summary>
    /// Registrado con POST /v1/webhook por la clave de la empresa (la
    /// plataforma), no a mano. Lo mantiene la plataforma al conectar.
    /// </summary>
    public bool EsDeLaApi => Origen == "api";

    /// <summary>Vacío significa que está suscrito a todos los eventos.</summary>
    public string[] Eventos =>
        string.IsNullOrWhiteSpace(EventosTexto)
            ? []
            : EventosTexto.Split(',', StringSplitOptions.RemoveEmptyEntries);
}

/// <summary>Una entrega pendiente de despachar.</summary>
public record EntregaPendiente(
    long Id,
    Guid WebhookId,
    Guid TenantId,
    Guid EventoId,
    string Tipo,
    string Cuerpo,
    string Url,
    string Secreto,
    short Intentos);

/// <summary>Una fila de webhook_cambios, para el panel.</summary>
public record CambioWebhook(
    long Id,
    Guid WebhookId,
    string Accion,
    string? UrlAntes,
    string UrlDespues,
    string HechoDesde,
    string? PrefijoClave,
    DateTime CreadoEn);

public enum ResultadoCambioEstado { Hecho, SinCambio, Conflicto }

/// <summary>Historial de entregas, para el panel.</summary>
public record EntregaHistorial(
    long Id,
    Guid EventoId,
    string Tipo,
    string Estado,
    short Intentos,
    int? UltimoCodigo,
    string? UltimoError,
    DateTime CreadoEn,
    DateTime? EntregadoEn);

/// <summary>
/// Gestiona los webhooks y su bandeja de salida.
///
/// Usa el rol de operador porque el despachador trabaja sobre todas las
/// empresas. La administración desde el panel también, que es donde se
/// configuran.
/// </summary>
public sealed class RepositorioWebhooks
{
    private readonly string _cadenaOperador;

    public RepositorioWebhooks(string cadenaConexionOperador)
    {
        _cadenaOperador = cadenaConexionOperador
            ?? throw new ArgumentNullException(nameof(cadenaConexionOperador));
    }

    private async Task<NpgsqlConnection> AbrirAsync(CancellationToken ct)
    {
        var conexion = new NpgsqlConnection(_cadenaOperador);
        await conexion.OpenAsync(ct);
        return conexion;
    }

    /// <summary>
    /// Genera el secreto con el que se firman los envíos a este webhook.
    ///
    /// El cliente lo usa para comprobar que el aviso viene de nosotros. Sin
    /// firma, cualquiera que descubriera su URL podría enviarle mensajes
    /// falsos diciendo que una factura fue aceptada.
    /// </summary>
    public static string GenerarSecreto() =>
        "whsec_" + Convert.ToBase64String(RandomNumberGenerator.GetBytes(32))
            .Replace("+", "").Replace("/", "").Replace("=", "");

    // ------------------------------------------------------- configuración

    public async Task<IReadOnlyList<WebhookAdmin>> ListarAsync(
        Guid tenantId, CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);

        var filas = await conexion.QueryAsync<WebhookAdmin>(
            new CommandDefinition(
                """
                SELECT w.id        AS "Id",
                       w.nombre    AS "Nombre",
                       w.url       AS "Url",

                       -- El arreglo se aplana a texto para que Dapper lo
                       -- pueda materializar sin conversores.
                       array_to_string(w.eventos, ',') AS "EventosTexto",

                       w.activo    AS "Activo",
                       w.creado_en AS "CreadoEn",

                       (SELECT count(*)::int FROM webhook_entregas e
                         WHERE e.webhook_id = w.id AND e.estado = 'PENDIENTE')
                                   AS "Pendientes",

                       (SELECT count(*)::int FROM webhook_entregas e
                         WHERE e.webhook_id = w.id AND e.estado = 'AGOTADO')
                                   AS "Agotados",

                       w.origen              AS "Origen",
                       w.secreto_cambiado_en AS "SecretoCambiadoEn"

                  FROM webhooks w
                 WHERE w.tenant_id = @tenantId
                 ORDER BY w.activo DESC, w.creado_en DESC
                """,
                new { tenantId }, cancellationToken: ct));

        return filas.ToList();
    }

    /// <summary>
    /// Registra un webhook desde el panel (origen 'panel').
    ///
    /// La URL ya viene revisada por DestinoWebhook. Los de la API no se crean
    /// aquí: los mantiene POST /v1/webhook (RepositorioWebhookApi).
    /// </summary>
    public async Task<(Guid Id, string Secreto)> CrearAsync(
        Guid tenantId, string nombre, string url, string[] eventos,
        CancellationToken ct = default)
    {
        var secreto = GenerarSecreto();

        await using var conexion = await AbrirAsync(ct);

        var id = await conexion.ExecuteScalarAsync<Guid>(new CommandDefinition(
            """
            INSERT INTO webhooks (tenant_id, nombre, url, secreto, eventos)
            VALUES (@tenantId, @nombre, @url, @secreto, @eventos)
            RETURNING id
            """,
            new { tenantId, nombre, url, secreto, eventos },
            cancellationToken: ct));

        return (id, secreto);
    }

    /// <summary>
    /// Activa o desactiva un webhook desde el panel, y lo anota en
    /// webhook_cambios. Quién lo hizo queda en la bitácora del panel.
    ///
    /// Devuelve null si no existe, o el resultado. Activar un webhook de la
    /// API cuando la empresa ya tiene otro de la API activo choca con
    /// ux_webhooks_api_por_tenant: se responde Conflicto en vez de dejar dos
    /// (cada factura se avisaría dos veces).
    /// </summary>
    public async Task<ResultadoCambioEstado?> CambiarEstadoAsync(
        Guid tenantId, Guid webhookId, bool activo, CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);
        await using var transaccion = await conexion.BeginTransactionAsync(ct);

        var actual = await conexion.QuerySingleOrDefaultAsync<UrlYEstado>(
            new CommandDefinition(
                """
                SELECT url AS "Url", activo AS "Activo" FROM webhooks
                 WHERE id = @webhookId AND tenant_id = @tenantId
                 FOR UPDATE
                """,
                new { tenantId, webhookId }, transaccion, cancellationToken: ct));

        if (actual is null) return null;

        if (actual.Activo == activo) return ResultadoCambioEstado.SinCambio;

        try
        {
            await conexion.ExecuteAsync(new CommandDefinition(
                "UPDATE webhooks SET activo = @activo WHERE id = @webhookId AND tenant_id = @tenantId",
                new { tenantId, webhookId, activo }, transaccion, cancellationToken: ct));
        }
        catch (PostgresException ex) when (ex.SqlState == PostgresErrorCodes.UniqueViolation)
        {
            return ResultadoCambioEstado.Conflicto;
        }

        await conexion.ExecuteAsync(new CommandDefinition(
            """
            INSERT INTO webhook_cambios
                   (webhook_id, tenant_id, accion, url_antes, url_despues, hecho_desde)
            VALUES (@webhookId, @tenantId, @accion, @url, @url, 'panel')
            """,
            new
            {
                webhookId, tenantId,
                accion = activo ? "activado" : "desactivado",
                url = actual.Url
            },
            transaccion, cancellationToken: ct));

        await transaccion.CommitAsync(ct);

        return ResultadoCambioEstado.Hecho;
    }

    private sealed record UrlYEstado(string Url, bool Activo);

    /// <summary>Quién cambió qué en los webhooks de una empresa. Nunca el secreto.</summary>
    public async Task<IReadOnlyList<CambioWebhook>> CambiosAsync(
        Guid tenantId, int limite = 50, CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);

        var filas = await conexion.QueryAsync<CambioWebhook>(
            new CommandDefinition(
                """
                SELECT id          AS "Id",
                       webhook_id  AS "WebhookId",
                       accion      AS "Accion",
                       url_antes   AS "UrlAntes",
                       url_despues AS "UrlDespues",
                       hecho_desde AS "HechoDesde",
                       prefijo_clave AS "PrefijoClave",
                       creado_en   AS "CreadoEn"
                  FROM webhook_cambios
                 WHERE tenant_id = @tenantId
                 ORDER BY creado_en DESC, id DESC
                 LIMIT @limite
                """,
                new { tenantId, limite }, cancellationToken: ct));

        return filas.ToList();
    }

    public async Task<IReadOnlyList<EntregaHistorial>> HistorialAsync(
        Guid tenantId, int limite = 50, CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);

        var filas = await conexion.QueryAsync<EntregaHistorial>(
            new CommandDefinition(
                """
                SELECT id            AS "Id",
                       evento_id     AS "EventoId",
                       tipo          AS "Tipo",
                       estado        AS "Estado",
                       intentos      AS "Intentos",
                       ultimo_codigo AS "UltimoCodigo",
                       ultimo_error  AS "UltimoError",
                       creado_en     AS "CreadoEn",
                       entregado_en  AS "EntregadoEn"
                  FROM webhook_entregas
                 WHERE tenant_id = @tenantId
                 ORDER BY creado_en DESC
                 LIMIT @limite
                """,
                new { tenantId, limite }, cancellationToken: ct));

        return filas.ToList();
    }

    // ------------------------------------------------------------ despacho

    /// <summary>
    /// Toma entregas pendientes cuyo momento ya llegó.
    ///
    /// Igual que en la cola de comprobantes, FOR UPDATE SKIP LOCKED permite
    /// que varios despachadores trabajen sin pisarse.
    /// </summary>
    public async Task<IReadOnlyList<EntregaPendiente>> ReclamarAsync(
        int limite = 20, CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);
        await using var transaccion = await conexion.BeginTransactionAsync(ct);

        var entregas = await conexion.QueryAsync<EntregaPendiente>(
            new CommandDefinition(
                """
                WITH candidatas AS (
                    SELECT e.id
                      FROM webhook_entregas e
                      JOIN webhooks w ON w.id = e.webhook_id
                     WHERE e.estado = 'PENDIENTE'
                       AND w.activo
                       AND (e.proximo_intento_en IS NULL
                            OR e.proximo_intento_en <= now())
                     ORDER BY e.proximo_intento_en NULLS FIRST, e.creado_en
                     FOR UPDATE OF e SKIP LOCKED
                     LIMIT @limite
                ),
                tomadas AS (
                    UPDATE webhook_entregas e
                       SET intentos = e.intentos + 1
                      FROM candidatas c
                     WHERE e.id = c.id
                    RETURNING e.id, e.webhook_id, e.tenant_id, e.evento_id,
                              e.tipo, e.cuerpo, e.intentos
                )
                SELECT t.id           AS "Id",
                       t.webhook_id   AS "WebhookId",
                       t.tenant_id    AS "TenantId",
                       t.evento_id    AS "EventoId",
                       t.tipo         AS "Tipo",
                       t.cuerpo::text AS "Cuerpo",
                       w.url          AS "Url",
                       w.secreto      AS "Secreto",
                       t.intentos     AS "Intentos"
                  FROM tomadas t
                  JOIN webhooks w ON w.id = t.webhook_id
                """,
                new { limite },
                transaccion, cancellationToken: ct));

        await transaccion.CommitAsync(ct);

        return entregas.ToList();
    }

    public async Task MarcarEntregadaAsync(
        long entregaId, int codigo, CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);

        await conexion.ExecuteAsync(new CommandDefinition(
            """
            UPDATE webhook_entregas
               SET estado = 'ENTREGADO',
                   entregado_en = now(),
                   ultimo_codigo = @codigo,
                   ultimo_error = NULL,
                   proximo_intento_en = NULL
             WHERE id = @entregaId
            """,
            new { entregaId, codigo }, cancellationToken: ct));
    }

    /// <summary>
    /// Registra un fallo y programa el siguiente intento.
    ///
    /// Si se agotaron los intentos, la entrega se marca como AGOTADA y deja
    /// de reintentarse. Seguir insistiendo indefinidamente contra un servidor
    /// que no responde solo consume recursos y esconde el problema: una
    /// entrega agotada es algo que alguien tiene que mirar.
    /// </summary>
    public async Task RegistrarFalloAsync(
        long entregaId, int intentos, int maximoIntentos,
        int? codigo, string error, TimeSpan espera,
        CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);

        var agotada = intentos >= maximoIntentos;

        await conexion.ExecuteAsync(new CommandDefinition(
            """
            UPDATE webhook_entregas
               SET estado = @estado,
                   ultimo_codigo = @codigo,
                   ultimo_error = @error,
                   proximo_intento_en = CASE WHEN @agotada
                       THEN NULL
                       ELSE now() + @espera::interval END
             WHERE id = @entregaId
            """,
            new
            {
                entregaId,
                estado = agotada ? "AGOTADO" : "PENDIENTE",
                codigo,
                error = error.Length > 500 ? error[..500] : error,
                agotada,
                espera = $"{(int)espera.TotalSeconds} seconds"
            },
            cancellationToken: ct));
    }

    /// <summary>Devuelve a la cola una entrega agotada, tras corregir la causa.</summary>
    public async Task<bool> ReintentarAsync(
        long entregaId, CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);

        var filas = await conexion.ExecuteAsync(new CommandDefinition(
            """
            UPDATE webhook_entregas
               SET estado = 'PENDIENTE', intentos = 0, proximo_intento_en = NULL
             WHERE id = @entregaId AND estado = 'AGOTADO'
            """,
            new { entregaId }, cancellationToken: ct));

        return filas > 0;
    }

    /// <summary>Encola un evento de prueba, para verificar la configuración.</summary>
    public async Task<bool> EnviarPruebaAsync(
        Guid tenantId, Guid webhookId, CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);

        var filas = await conexion.ExecuteAsync(new CommandDefinition(
            """
            INSERT INTO webhook_entregas (webhook_id, tenant_id, tipo, cuerpo)
            SELECT id, tenant_id, 'prueba',
                   jsonb_build_object(
                       'tipo', 'prueba',
                       'mensaje', 'Si recibes esto, el webhook está bien configurado.',
                       'ocurridoEn', now())
              FROM webhooks
             WHERE id = @webhookId AND tenant_id = @tenantId AND activo
            """,
            new { tenantId, webhookId }, cancellationToken: ct));

        return filas > 0;
    }
}
'@

# --- Facturacion.Api\EndpointsWebhookApi.cs
Planear 'Facturacion.Api\EndpointsWebhookApi.cs' '' @'
using Facturacion.Persistencia;

namespace Facturacion.Api;

/// <summary>
/// El webhook de la propia empresa, gestionado con su clave fac_.
///
/// Diseño: alta-empresa-diseno.md, parte A. Lo usa la plataforma al
/// «Conectar» una empresa: registra su propio webhook y se queda el secreto
/// sin que nadie lo copie a mano.
///
///   POST /v1/webhook             lo crea, o le cambia la URL y el secreto
///   GET  /v1/webhook             cómo está (nunca el secreto)
///   POST /v1/webhook/reintentar  devuelve a la cola sus entregas agotadas
///
/// LA EMPRESA SALE DE LA CLAVE, NUNCA DE LA PETICIÓN. Ninguna de estas rutas
/// lleva un id de empresa ni de webhook: solo existe «el webhook de la API de
/// quien llama». Y todo va con el rol facturacion_app y RLS
/// (RepositorioWebhookApi), no con el de operador.
///
/// LO QUE ESTO ABRE, Y CÓMO SE CIERRA (diseño §2.4): desde ahora una clave
/// decide a dónde manda el servicio sus avisos. Por eso la URL pasa por
/// DestinoWebhook aquí, y otra vez en el worker al despachar: solo https y
/// solo direcciones públicas. Y cada cambio queda en webhook_cambios con el
/// prefijo de la clave que lo hizo.
/// </summary>
public static class EndpointsWebhookApi
{
    private const string DescripcionFirma =
        "Cada aviso llega por POST con las cabeceras X-Facturacion-Timestamp, " +
        "X-Facturacion-Firma, X-Facturacion-Evento y X-Facturacion-Tipo. La firma " +
        "es el HMAC-SHA256 de 'timestamp.cuerpo' con el secreto, en hexadecimal " +
        "minúsculo. Suscrito a todos los eventos.";

    public static void MapearWebhookApi(this WebApplication app)
    {
        var grupo = app.MapGroup("/v1/webhook").WithTags("Webhook de la empresa");

        grupo.MapPost("", async (
            PeticionWebhookApi peticion,
            ContextoEmisor emisor,
            RepositorioWebhookApi repositorio,
            ReglasDestinoWebhook reglas,
            ILoggerFactory registro,
            CancellationToken ct) =>
        {
            var tenant = emisor.Exigir();
            var url = peticion.Url?.Trim();

            var problema = await DestinoWebhook.RevisarAsync(url, reglas.PermitirLocales, ct);

            if (problema is not null)
                return Results.BadRequest(new RespuestaError("La URL no es válida.", problema));

            var r = await repositorio.RegistrarAsync(tenant.Id, url!, emisor.PrefijoClave, ct);

            // Al registro va QUÉ pasó, nunca el secreto.
            registro.CreateLogger("Facturacion.Api.WebhookApi").LogInformation(
                "Webhook de la API {Accion} para la empresa {Ruc} con la clave {Prefijo}…: {Url}",
                r.Creado ? "creado" : "rotado", tenant.Ruc, emisor.PrefijoClave, r.Url);

            return Results.Ok(new
            {
                id = r.Id,
                url = r.Url,
                secreto = r.Secreto,
                creado = r.Creado,
                urlAnterior = r.UrlAnterior,
                aviso = r.Creado
                    ? "Guarda el secreto ahora: no se vuelve a mostrar."
                    : "El secreto anterior dejó de valer ahora mismo. Las entregas en " +
                      "cola saldrán firmadas con este."
            });
        })
        .WithSummary("Registra el webhook de la empresa, o le cambia la URL y el secreto")
        .WithDescription(
            "La empresa es la de la clave. Si ya tiene webhook de la API, se " +
            "actualiza en la misma fila y se genera un secreto NUEVO: el anterior " +
            "deja de valer en ese momento. El secreto se devuelve solo aquí. " +
            "La URL tiene que ser https:// y pública. " + DescripcionFirma);

        grupo.MapGet("", async (
            ContextoEmisor emisor, RepositorioWebhookApi repositorio, CancellationToken ct) =>
        {
            var tenant = emisor.Exigir();

            var (w, ultima, cambio, otros) = await repositorio.ObtenerAsync(tenant.Id, ct);

            if (w is null)
                return Results.Ok(new { registrado = false, otrosWebhooksActivos = otros });

            return Results.Ok(new
            {
                registrado = true,
                id = w.Id,
                url = w.Url,
                eventos = "todos",
                creadoEn = w.CreadoEn,
                secretoCambiadoEn = w.SecretoCambiadoEn,
                pendientes = w.Pendientes,
                agotados = w.Agotados,
                ultimaEntrega = ultima is null ? null : new
                {
                    tipo = ultima.Tipo,
                    estado = ultima.Estado,
                    intentos = ultima.Intentos,
                    codigo = ultima.UltimoCodigo,
                    error = ultima.UltimoError,
                    creadoEn = ultima.CreadoEn,
                    entregadoEn = ultima.EntregadoEn
                },
                ultimoCambio = cambio is null ? null : new
                {
                    accion = cambio.Accion,
                    hechoDesde = cambio.HechoDesde,
                    prefijoClave = cambio.PrefijoClave,
                    en = cambio.CreadoEn
                },
                otrosWebhooksActivos = otros
            });
        })
        .WithSummary("Cómo está el webhook de la empresa")
        .WithDescription(
            "URL, entregas pendientes y agotadas, la última entrega y el último " +
            "cambio. Nunca el secreto. otrosWebhooksActivos cuenta los registrados " +
            "a mano en el panel del servicio, que no se ven desde aquí.");

        grupo.MapPost("/reintentar", async (
            int? dias,
            ContextoEmisor emisor, RepositorioWebhookApi repositorio, CancellationToken ct) =>
        {
            var tenant = emisor.Exigir();
            var plazo = Math.Clamp(dias ?? 7, 1, 30);

            var reencoladas = await repositorio.ReintentarAgotadasAsync(tenant.Id, plazo, ct);

            return Results.Ok(new
            {
                reencoladas,
                dias = plazo,
                mensaje = reencoladas == 0
                    ? "No había entregas agotadas."
                    : $"{reencoladas} entregas devueltas a la cola. Saldrán en los próximos segundos."
            });
        })
        .WithSummary("Devuelve a la cola las entregas agotadas del webhook de la empresa")
        .WithDescription(
            "Solo las del webhook de la API de la empresa de la clave, de los " +
            "últimos 'dias' días (7 si no se dice; de 1 a 30). Para después de " +
            "rotar el secreto: los avisos que se rechazaron mientras tanto vuelven " +
            "a salir con el mismo evento.");
    }
}

/// <summary>Cuerpo de POST /v1/webhook. Ni empresa ni secreto: salen de la clave.</summary>
public record PeticionWebhookApi(string? Url);
'@

# --- Facturacion.Api\EndpointsWebhooks.cs
Planear 'Facturacion.Api\EndpointsWebhooks.cs' 'F765F3D1CCB6A865E538E1A5D52F5F196BD8FC1AB443FBD6BFDFB3E2CD16DF3B' @'
using Facturacion.Persistencia;

namespace Facturacion.Api;

/// <summary>
/// Configuración de webhooks por empresa.
///
/// El secreto de firma se muestra UNA sola vez al crearlos, igual que las
/// claves de acceso. Sin él, el cliente no puede verificar que los avisos
/// vienen de nosotros.
///
/// DESDE LA 023 HAY DOS ORÍGENES. Los de aquí son 'panel'. Los 'api' los
/// registra la propia empresa con su clave (EndpointsWebhookApi): aquí se
/// ven, se pueden desactivar y probar, pero su URL y su secreto los mantiene
/// la plataforma al conectar.
///
/// NADA SE BORRA (punto 18): ya no hay DELETE. Se desactiva, y el webhook
/// conserva su historial de entregas y de cambios.
/// </summary>
public static class EndpointsWebhooks
{
    public static void MapearWebhooks(this WebApplication app)
    {
        var grupo = app.MapGroup("/admin/tenants/{id:guid}/webhooks")
            .AddEndpointFilter<AutenticacionPanel>()
            .AddEndpointFilter(new ExigirPermiso(Permiso.WebhooksGestionar))
            .WithTags("Webhooks");

        grupo.MapGet("", async (
            Guid id, RepositorioWebhooks webhooks, CancellationToken ct) =>
            Results.Ok(await webhooks.ListarAsync(id, ct)))
            .WithSummary("Lista los webhooks de una empresa");

        grupo.MapPost("", async (
            Guid id, NuevoWebhook nuevo,
            RepositorioWebhooks webhooks, ReglasDestinoWebhook reglas,
            CancellationToken ct) =>
        {
            // Las mismas reglas que /v1/webhook y que el worker al despachar:
            // https y dirección pública, salvo en desarrollo con
            // FACTURACION_WEBHOOKS_LOCALES. Un webhook del panel que el worker
            // luego no pudiera entregar solo serviría para confundir.
            var problema = await DestinoWebhook.RevisarAsync(
                nuevo.Url, reglas.PermitirLocales, ct);

            if (problema is not null)
                return Results.BadRequest(new RespuestaError("La URL no es válida.", problema));

            var (webhookId, secreto) = await webhooks.CrearAsync(
                id, nuevo.Nombre, nuevo.Url.Trim(), nuevo.Eventos ?? [], ct);

            return Results.Ok(new
            {
                id = webhookId,
                secreto,
                aviso =
                    "Este secreto se muestra una sola vez. El cliente lo necesita " +
                    "para verificar que los avisos vienen de nosotros: con él " +
                    "recalcula la firma de cada mensaje y descarta los que no " +
                    "coincidan."
            });
        })
        .WithSummary("Registra un webhook")
        .WithDescription(
            "Devuelve el secreto de firma UNA sola vez. " +
            "Cada aviso llega con las cabeceras X-Facturacion-Timestamp y " +
            "X-Facturacion-Firma. La firma es el HMAC-SHA256 de " +
            "'timestamp.cuerpo' usando el secreto, en hexadecimal minúsculo.");

        grupo.MapPatch("/{webhookId:guid}", async (
            Guid id, Guid webhookId, CambioEstadoWebhook cambio,
            RepositorioWebhooks webhooks, CancellationToken ct) =>
        {
            var resultado = await webhooks.CambiarEstadoAsync(
                id, webhookId, cambio.Activo, ct);

            return resultado switch
            {
                null => Results.NotFound(new RespuestaError("No se encontró el webhook.")),

                ResultadoCambioEstado.Conflicto => Results.Conflict(new RespuestaError(
                    "La empresa ya tiene otro webhook de la API activo.",
                    "Solo puede haber uno: con dos, cada factura se avisaría dos " +
                    "veces. Desactiva el otro primero.")),

                _ => Results.Ok(new { mensaje = cambio.Activo
                    ? "Webhook activado." : "Webhook desactivado." })
            };
        })
        .WithSummary("Activa o desactiva un webhook")
        .WithDescription(
            "Sustituye a «Eliminar»: nada se borra. El webhook desactivado deja " +
            "de recibir avisos y conserva su historial.");

        app.MapGet("/admin/tenants/{id:guid}/webhook-cambios", async (
            Guid id, RepositorioWebhooks webhooks, int? limite,
            CancellationToken ct) =>
            Results.Ok(await webhooks.CambiosAsync(
                id, Math.Clamp(limite ?? 30, 1, 200), ct)))
            .AddEndpointFilter<AutenticacionPanel>()
            .AddEndpointFilter(new ExigirPermiso(Permiso.WebhooksGestionar))
            .WithTags("Webhooks")
            .WithSummary("Quién cambió los webhooks de la empresa")
            .WithDescription(
                "Altas y rotaciones hechas por la API (con el prefijo de la " +
                "clave) y activaciones desde el panel. Nunca el secreto.");

        grupo.MapPost("/{webhookId:guid}/prueba", async (
            Guid id, Guid webhookId,
            RepositorioWebhooks webhooks, CancellationToken ct) =>
        {
            var encolado = await webhooks.EnviarPruebaAsync(id, webhookId, ct);

            return encolado
                ? Results.Ok(new { mensaje =
                    "Aviso de prueba encolado. Llegará en los próximos segundos." })
                : Results.NotFound(new RespuestaError(
                    "No se encontró el webhook, o está desactivado."));
        })
        .WithSummary("Envía un aviso de prueba")
        .WithDescription(
            "Sirve para comprobar la configuración sin esperar a que haya " +
            "un comprobante real.");

        // El historial no cuelga de un webhook concreto: interesa ver todas
        // las entregas del emisor juntas.
        app.MapGet("/admin/tenants/{id:guid}/webhook-entregas", async (
            Guid id, RepositorioWebhooks webhooks, int? limite,
            CancellationToken ct) =>
            Results.Ok(await webhooks.HistorialAsync(
                id, Math.Clamp(limite ?? 50, 1, 200), ct)))
            .AddEndpointFilter<AutenticacionPanel>()
            .AddEndpointFilter(new ExigirPermiso(Permiso.WebhooksGestionar))
            .WithTags("Webhooks")
            .WithSummary("Historial de entregas");

        app.MapPost("/admin/webhook-entregas/{entregaId:long}/reintentar", async (
            long entregaId, RepositorioWebhooks webhooks, CancellationToken ct) =>
        {
            var reintentada = await webhooks.ReintentarAsync(entregaId, ct);

            return reintentada
                ? Results.Ok(new { mensaje = "Devuelta a la cola." })
                : Results.NotFound(new RespuestaError(
                    "No se pudo reintentar.",
                    "O no existe, o no está agotada. Solo se reintentan las " +
                    "entregas que agotaron sus intentos."));
        })
        .AddEndpointFilter<AutenticacionPanel>()
        .AddEndpointFilter(new ExigirPermiso(Permiso.WebhooksGestionar))
        .WithTags("Webhooks")
        .WithSummary("Reintenta una entrega agotada")
        .WithDescription(
            "Para después de corregir la causa: la URL estaba mal, el " +
            "servidor del cliente estaba caído.");
    }
}

public record NuevoWebhook(string Nombre, string Url, string[]? Eventos);

public record CambioEstadoWebhook(bool Activo);
'@

# --- Facturacion.Api\Autenticacion.cs
Planear 'Facturacion.Api\Autenticacion.cs' 'BA5A07EBF1F848C183441A984DF6E6733E630C46498CE36EA77F0637807F7ED2' @'
using Facturacion.Persistencia;

namespace Facturacion.Api;

/// <summary>
/// El emisor de la petición en curso.
///
/// Se registra como servicio con ámbito de petición, así que cualquier
/// endpoint puede pedirlo y siempre corresponde a quien está llamando.
/// </summary>
public sealed class ContextoEmisor
{
    public TenantResuelto? Tenant { get; private set; }

    public bool Autenticado => Tenant is not null;

    /// <summary>
    /// El prefijo de la clave con la que se llamó: sus primeros 20
    /// caracteres, los mismos que guarda api_keys.prefijo y que enseña la
    /// pestaña Claves de acceso del panel.
    ///
    /// Solo para dejar rastro de QUÉ clave hizo un cambio (POST /v1/webhook
    /// lo guarda en webhook_cambios) y poder encontrarla en esa pestaña para
    /// revocarla. No es secreto: ya está a la vista en el panel, y con él
    /// no se reconstruye la clave.
    /// </summary>
    public string? PrefijoClave { get; private set; }

    public TenantResuelto Exigir() =>
        Tenant ?? throw new InvalidOperationException(
            "No hay emisor en el contexto. El endpoint debería estar protegido.");

    internal void Establecer(TenantResuelto tenant, string clave)
    {
        Tenant = tenant;
        PrefijoClave = clave[..Math.Min(20, clave.Length)];
    }
}

/// <summary>
/// Middleware que resuelve el emisor a partir de la clave de acceso.
///
/// ESTE ES EL PUNTO DONDE EL AISLAMIENTO SE VUELVE REAL. Row Level Security
/// da la capacidad, pero solo sirve si el tenant_id que se declara viene de
/// algo que el cliente no controla. Esa es la clave de acceso.
///
/// Si el tenant viniera en el cuerpo de la petición o en un parámetro,
/// cualquiera podría poner el de otra empresa.
///
/// La clave se envía así:
///
///     Authorization: Bearer fac_test_xxxxx
///
/// o bien:
///
///     X-Api-Key: fac_test_xxxxx
/// </summary>
public sealed class AutenticacionApiKey
{
    private readonly RequestDelegate _siguiente;

    public AutenticacionApiKey(RequestDelegate siguiente)
    {
        _siguiente = siguiente;
    }

    public async Task InvokeAsync(
        HttpContext contexto,
        RepositorioTenants tenants,
        ContextoEmisor emisor)
    {
        // Las rutas públicas no exigen clave.
        if (EsRutaPublica(contexto.Request.Path))
        {
            await _siguiente(contexto);
            return;
        }

        var clave = LeerClave(contexto.Request);

        if (string.IsNullOrWhiteSpace(clave))
        {
            await Responder(contexto, StatusCodes.Status401Unauthorized,
                "Falta la clave de acceso.",
                "Envíala en la cabecera Authorization: Bearer <clave> o X-Api-Key: <clave>.");
            return;
        }

        var tenant = await tenants.ResolverPorClaveAsync(
            clave, contexto.RequestAborted);

        if (tenant is null)
        {
            // Un solo mensaje para clave inexistente, revocada o emisor
            // desactivado. Distinguirlos le diría a quien prueba claves
            // cuáles existen.
            await Responder(contexto, StatusCodes.Status401Unauthorized,
                "Clave de acceso no válida.");
            return;
        }

        emisor.Establecer(tenant, clave);

        await _siguiente(contexto);
    }

    private static bool EsRutaPublica(PathString ruta) =>
        ruta.StartsWithSegments("/health") ||
        ruta.StartsWithSegments("/openapi") ||
        ruta.StartsWithSegments("/swagger") ||
        ruta.StartsWithSegments("/docs") ||

        // Los endpoints de operación NO son públicos: tienen su propia
        // autenticación, con una clave distinta a la de los emisores.
        // Una clave de emisor jamás debe abrirlos, porque muestran datos
        // de todas las empresas.
        ruta.StartsWithSegments("/admin") ||

        // El portal del receptor es público POR DISEÑO: lo abre el cliente
        // de cada emisor, que no tiene clave ni cuenta. No muestra nada sin
        // los cinco datos del comprobante o un acceso válido, y la empresa
        // sale siempre de la dirección (EndpointsPortal).
        ruta.StartsWithSegments("/portal") ||

        EsArchivoEstatico(ruta.Value) ||

        ruta == "/";

    /// <summary>
    /// Los archivos del panel se sirven sin clave de emisor.
    ///
    /// No exponen nada: el HTML pide la clave de operador por su cuenta antes
    /// de consultar cualquier dato. Lo que está protegido son los endpoints
    /// que devuelven información, no la página que los llama.
    ///
    /// PathString no es una cadena: es un tipo propio de ASP.NET. Su
    /// propiedad Value sí lo es, y puede ser nula.
    /// </summary>
    private static bool EsArchivoEstatico(string? ruta)
    {
        if (string.IsNullOrEmpty(ruta)) return false;

        return ruta.EndsWith(".html", StringComparison.OrdinalIgnoreCase)
            || ruta.EndsWith(".css", StringComparison.OrdinalIgnoreCase)
            || ruta.EndsWith(".js", StringComparison.OrdinalIgnoreCase)
            || ruta.EndsWith(".ico", StringComparison.OrdinalIgnoreCase);
    }

    private static string? LeerClave(HttpRequest peticion)
    {
        var autorizacion = peticion.Headers.Authorization.ToString();

        if (autorizacion.StartsWith("Bearer ", StringComparison.OrdinalIgnoreCase))
            return autorizacion["Bearer ".Length..].Trim();

        var cabecera = peticion.Headers["X-Api-Key"].ToString();

        return string.IsNullOrWhiteSpace(cabecera) ? null : cabecera.Trim();
    }

    private static async Task Responder(
        HttpContext contexto, int codigo, string error, string? detalle = null)
    {
        contexto.Response.StatusCode = codigo;
        await contexto.Response.WriteAsJsonAsync(new RespuestaError(error, detalle));
    }
}
'@

# --- Facturacion.Api\Program.cs
Planear 'Facturacion.Api\Program.cs' 'E34A7E33ACA82F847A1565239ADD6CB0161F8A5423C211713FFE4D314E4257DA' @'
using System.ComponentModel.DataAnnotations;
using System.Text.Json;
using Facturacion.Api;
using Facturacion.Cpe;
using Facturacion.Persistencia;
using Microsoft.OpenApi.Models;

// Los secretos se leen del entorno, no de appsettings.json.
//
// En desarrollo vienen de un archivo .env en la raíz de la solución, que
// está en el .gitignore. En producción los pone el contenedor o el gestor
// de secretos, y este código no cambia.
ConfiguracionSecretos.CargarArchivoEnv();

var builder = WebApplication.CreateBuilder(args);

// --- Servicios -------------------------------------------------------------

var cadenaConexion = ConfiguracionSecretos.CadenaPostgres(
    "facturacion_app", "FACTURACION_APP_PASSWORD",
    "la conexión de la aplicación, sujeta a Row Level Security");

// El diagnóstico mira TODAS las empresas, así que usa el rol de operador.
// Es una vista de infraestructura, no de cliente, y por eso su endpoint
// está protegido con una clave distinta.
var cadenaOperador = ConfiguracionSecretos.CadenaPostgres(
    "facturacion_operador", "FACTURACION_OPERADOR_PASSWORD",
    "las consultas del panel, que ven todas las empresas");

builder.Services.AddSingleton(new FabricaSesiones(cadenaConexion));
builder.Services.AddSingleton(new RepositorioDiagnostico(cadenaOperador));
builder.Services.AddSingleton<RepositorioTenants>();
builder.Services.AddSingleton<RepositorioComprobantes>();
builder.Services.AddSingleton<RepositorioPortal>();

// ALMACÉN COMPARTIDO CON EL WORKER.
//
// Los dos procesos leen y escriben en el mismo sitio. Con carpetas locales
// eso era frágil: bastaba que cada uno apuntara a una ruta distinta para que
// el worker generara archivos y la API respondiera que no existen.
//
// Con S3 el problema desaparece: ambos apuntan al mismo servidor, y da igual
// desde qué máquina corran.
var opcionesAlmacen = new OpcionesAlmacen();
builder.Configuration.GetSection("Almacen").Bind(opcionesAlmacen);

// Las credenciales del almacén también son secretos.
if (opcionesAlmacen.Tipo.Equals("s3", StringComparison.OrdinalIgnoreCase))
{
    opcionesAlmacen.Usuario = ConfiguracionSecretos.Exigir(
        "ALMACEN_USUARIO", "el acceso al almacén de comprobantes");

    opcionesAlmacen.Clave = ConfiguracionSecretos.Exigir(
        "ALMACEN_CLAVE", "el acceso al almacén de comprobantes");
}

builder.Services.AddSingleton(opcionesAlmacen);
builder.Services.AddSingleton(FabricaAlmacen.Crear(opcionesAlmacen));

// Administración de empresas, series y claves.
builder.Services.AddSingleton(new RepositorioAdmin(cadenaOperador));
builder.Services.AddSingleton(new RepositorioWebhooks(cadenaOperador));

// El webhook de la propia empresa (POST/GET /v1/webhook). Este NO usa el rol
// de operador: va con facturacion_app y RLS, con la empresa de la clave.
builder.Services.AddSingleton<RepositorioWebhookApi>();

// A dónde se pueden registrar webhooks: https y direcciones públicas, salvo
// en Development con FACTURACION_WEBHOOKS_LOCALES=true. El worker aplica la
// misma regla al despachar.
builder.Services.AddSingleton(
    ReglasDestinoWebhook.Resolver(builder.Environment.IsDevelopment()));
builder.Services.AddSingleton(new RepositorioConsultas(cadenaOperador));
builder.Services.AddSingleton(new RepositorioRoles(cadenaOperador));

// Las guías tienen su propio repositorio: otra tabla, otro canal y otro
// ritmo de reintentos.
builder.Services.AddSingleton(proveedor =>
    new RepositorioGuias(
        proveedor.GetRequiredService<FabricaSesiones>(),
        cadenaOperador));

// La baja escribe en la misma tabla que los resúmenes, con tipo 'RA'.
builder.Services.AddSingleton(proveedor =>
    new RepositorioBajas(
        proveedor.GetRequiredService<FabricaSesiones>(),
        cadenaOperador));

// --- Correo ----------------------------------------------------------------
//
// Las credenciales son secretos y salen del .env, como todo lo demás. Si no
// están configuradas, el sistema funciona igual: los correos simplemente no
// se envían y queda constancia en el log.
var opcionesCorreo = new OpcionesCorreo
{
    Host = ConfiguracionSecretos.Opcional("MAIL_HOST", ""),
    Puerto = int.TryParse(
        ConfiguracionSecretos.Opcional("MAIL_PORT", "587"), out var puertoCorreo)
        ? puertoCorreo : 587,
    Usuario = ConfiguracionSecretos.Opcional("MAIL_USUARIO", ""),
    Clave = ConfiguracionSecretos.Opcional("MAIL_CLAVE", ""),
    Desde = ConfiguracionSecretos.Opcional("MAIL_DESDE", ""),
    Nombre = ConfiguracionSecretos.Opcional("MAIL_NOMBRE", "Facturación electrónica"),
    UrlPanel = ConfiguracionSecretos.Opcional("PANEL_URL", "https://localhost:7295"),

    // La dirección pública del portal del receptor, para el enlace del
    // correo de entrega. En producción: https://comprobantes.reyban.pe.
    // Vacía: la del panel con /portal, que es lo que sirve en desarrollo.
    UrlPortal = ConfiguracionSecretos.Opcional("PORTAL_URL", "")
};

builder.Services.AddSingleton(opcionesCorreo);
builder.Services.AddSingleton<ServicioCorreo>();

// El correo de entrega del portal: la cola (rol de operador, recorre todas
// las empresas) y el proceso que la vacía cada 30 segundos.
builder.Services.AddSingleton(new RepositorioCorreosPortal(cadenaOperador));
builder.Services.AddHostedService<ServicioCorreosEntrega>();

// El repositorio de usuarios necesita el protector para cifrar el secreto
// del segundo factor, igual que los certificados.
builder.Services.AddSingleton(proveedor =>
    new RepositorioUsuarios(
        cadenaOperador,
        proveedor.GetRequiredService<IProtectorDeSecretos>()));

// El operador de cada petición. Con ámbito de petición, como el emisor.
builder.Services.AddScoped<ContextoOperador>();

// La API necesita la llave maestra porque cifra los certificados al cargarlos.
// Si falta la variable de entorno, el proceso no arranca: es preferible a
// descubrirlo cuando alguien intente subir un certificado.
builder.Services.AddSingleton<IProtectorDeSecretos>(_ => ProtectorAesGcm.DesdeEntorno());
builder.Services.AddSingleton<AlmacenCertificados>();

// El panel necesita comprobar si una empresa está lista para producción.
builder.Services.AddSingleton(proveedor =>
    new ProveedorCredenciales(
        cadenaOperador,
        proveedor.GetRequiredService<IProtectorDeSecretos>()));

// Con ámbito de petición: cada llamada tiene su propio emisor.
builder.Services.AddScoped<ContextoEmisor>();

builder.Services.ConfigureHttpJsonOptions(opciones =>
{
    opciones.SerializerOptions.PropertyNamingPolicy = JsonNamingPolicy.CamelCase;
    opciones.SerializerOptions.DefaultIgnoreCondition =
        System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull;
});

// --- Documentación interactiva ---------------------------------------------
//
// Swagger sirve para dos cosas distintas, y la segunda importa más:
//
//   1. Probar la API sin escribir un cliente.
//   2. Ser el contrato que le entregas a quien integra. Cuando un cliente
//      pregunte "¿qué campos acepta?", la respuesta es una URL, no un correo
//      con un ejemplo que quedará desactualizado.
//
// En producción conviene protegerlo o desactivarlo: expone la forma completa
// de la API a cualquiera que la alcance.

builder.Services.AddEndpointsApiExplorer();

builder.Services.AddSwaggerGen(opciones =>
{
    opciones.SwaggerDoc("v1", new OpenApiInfo
    {
        Title = "Servicio de facturación electrónica",
        Version = "v1",
        Description =
            "Emisión de comprobantes electrónicos para SUNAT.\n\n" +
            "Toda petición requiere una clave de acceso.\n\n" +
            "**Emisión y consulta** (`/v1/*`): la clave determina qué empresa " +
            "emite, así que el RUC del emisor NO se envía en el cuerpo. " +
            "En Authorize, campo `ApiKey`, escribe `Bearer` seguido de la " +
            "clave que se le entregó a esa empresa.\n\n" +
            "**Administración** (`/admin/*`): se entra con usuario y " +
            "contraseña desde el panel, y la sesión viaja en una cookie.\n\n" +
            "Ninguna clave aparece en esta documentación a propósito: si " +
            "estuviera aquí, estaría también en el repositorio."
    });

    // DOS ESQUEMAS DE AUTENTICACIÓN, Y ES A PROPÓSITO.
    //
    // Los emisores usan su clave en Authorization: Bearer. El panel usa
    // sesión con cookie, que el navegador envía sola.
    //
    // Declarar el primero en Swagger no es un detalle cosmético: sin él,
    // probar la API obligaría a escribir comandos a mano, y eso hace que se
    // pruebe menos.

    opciones.AddSecurityDefinition("ApiKey", new OpenApiSecurityScheme
    {
        Name = "Authorization",
        Type = SecuritySchemeType.ApiKey,
        In = ParameterLocation.Header,
        Description =
            "Clave del EMISOR. Escribe: Bearer {tu clave}\n\n" +
            "Sirve para /v1/*: emitir comprobantes, guías y consultarlos.",
        Scheme = "Bearer"
    });

    opciones.AddSecurityRequirement(new OpenApiSecurityRequirement
    {
        {
            new OpenApiSecurityScheme
            {
                Reference = new OpenApiReference
                {
                    Type = ReferenceType.SecurityScheme,
                    Id = "ApiKey"
                }
            },
            Array.Empty<string>()
        }
    });
});

var app = builder.Build();

// Comprobar el almacén AL ARRANCAR, no al primer uso.
//
// Descubrir que la configuración está mal cuando un cliente emite su primera
// factura es mucho peor que descubrirlo al encender el servicio.
if (app.Services.GetRequiredService<IAlmacenArchivos>() is AlmacenArchivosS3 almacenS3)
{
    var mensaje = await almacenS3.ComprobarAsync();
    app.Logger.LogInformation("{Mensaje}", mensaje);
}

// --- Middleware ------------------------------------------------------------

if (app.Environment.IsDevelopment())
{
    app.UseSwagger();

    app.UseSwaggerUI(opciones =>
    {
        opciones.SwaggerEndpoint("/swagger/v1/swagger.json", "Facturación v1");

        opciones.RoutePrefix = "docs";
        opciones.DocumentTitle = "Facturación electrónica";
    });
}

// Aviso si el correo no está configurado.
//
// No impide arrancar: el sistema funciona sin correo. Pero conviene saberlo
// antes de que alguien pida recuperar su contraseña y no le llegue nada.
if (!opcionesCorreo.Configurado)
{
    app.Logger.LogWarning(
        "El correo NO está configurado. La recuperación de contraseña y los " +
        "avisos no se enviarán. Rellena MAIL_HOST, MAIL_DESDE y las demás " +
        "variables en el .env.");
}

// Primer administrador, si todavía no hay ninguno.
//
// Sin usuarios no se puede entrar al panel, y sin entrar no se pueden crear
// usuarios. Alguien tiene que romper ese círculo, y es este arranque.
{
    var usuarios = app.Services.GetRequiredService<RepositorioUsuarios>();

    var correo = ConfiguracionSecretos.Opcional(
        "ADMIN_CORREO", "admin@localhost");

    var provisional = await usuarios.AsegurarPrimerAdministradorAsync(
        correo,
        Environment.GetEnvironmentVariable("ADMIN_CONTRASENA"));

    if (provisional is not null)
    {
        app.Logger.LogWarning(
            "PRIMER ADMINISTRADOR CREADO.\n" +
            "  Correo:     {Correo}\n" +
            "  Contraseña: {Clave}\n" +
            "Se pedirá cambiarla al entrar. Este mensaje NO se repite: " +
            "anótala ahora.",
            correo, provisional);
    }
}

// Se dice al arrancar qué destinos de webhook se aceptan. El modo de fallo
// sería el silencio: rechazar el localhost de la plataforma sin saber por qué.
app.Logger.LogInformation("{Diagnostico}",
    ReglasDestinoWebhook.Diagnostico(app.Environment.IsDevelopment()));

// Sirve el panel desde wwwroot.
app.UseDefaultFiles();
app.UseStaticFiles();

// Registra en la bitácora toda acción que modifique algo.
app.UseMiddleware<AuditoriaPanel>();

app.UseMiddleware<AutenticacionApiKey>();

// --- Endpoints -------------------------------------------------------------

app.MapearSesion();
app.MapearRoles();
app.MapearDiagnostico();
app.MapearAdministracion();
app.MapearWebhooks();
app.MapearWebhookApi();
app.MapearConsultas();
app.MapearNotas();
app.MapearDescargas();
app.MapearGuias();
app.MapearLiquidaciones();
app.MapearRetencionPercepcion();
app.MapearBajas();
app.MapearAnulacionBoletas();
app.MapearEstadoSunat();
app.MapearPortal();
app.MapearPortalAdmin();

app.MapGet("/health", () => Results.Ok(new { estado = "vivo" }))
   .WithName("Salud")
   .WithTags("Servicio")
   .WithSummary("Comprueba que el servicio responde. No requiere clave.");

// La raíz lleva al panel.
//
// Devolver un JSON informativo era cómodo para desarrollar y confuso para
// quien llega desde un correo: ve un texto técnico y no sabe qué hacer.
app.MapGet("/", () => Results.Redirect("/login.html"))
   .ExcludeFromDescription();


/// Emite un comprobante.
///
/// Responde 202 Accepted: el comprobante quedó registrado, pero TODAVÍA NO
/// fue a SUNAT. Eso lo hará el worker. Esperar aquí a SUNAT dejaría la
/// petición colgada varios segundos y el sistema caería cuando SUNAT caiga.
app.MapPost("/v1/comprobantes", async (
    PeticionComprobante peticion,
    HttpContext contexto,
    ContextoEmisor emisor,
    RepositorioComprobantes repositorio,
    ILogger<Program> registro,
    CancellationToken ct) =>
{
    var tenant = emisor.Exigir();

    // --- Validación del contrato ---
    var errores = new List<ValidationResult>();

    if (!Validator.TryValidateObject(
            peticion, new ValidationContext(peticion), errores, validateAllProperties: true))
    {
        return Results.BadRequest(new RespuestaError(
            "La petición no es válida.",
            string.Join(" ", errores.Select(e => e.ErrorMessage))));
    }

    if (peticion.Lineas.Count == 0)
        return Results.BadRequest(new RespuestaError(
            "El comprobante necesita al menos una línea."));

    // El correo del receptor es opcional, pero si viene tiene que tener forma
    // de correo: un comprobante aceptado cuyo correo rebota es un cliente que
    // cree que no le facturaron.
    if (peticion.Receptor.ProblemaCorreo() is { } problemaCorreo)
        return Results.BadRequest(new RespuestaError(
            "El correo del receptor no es válido.", problemaCorreo));

    if (peticion.Moneda != "PEN" && peticion.TipoCambio is null)
        return Results.BadRequest(new RespuestaError(
            "Falta el tipo de cambio.",
            "Los comprobantes en moneda distinta de PEN deben declararlo."));

    // La detracción solo existe en facturas.
    //
    // SUNAT no la admite en boletas porque no dan crédito fiscal, y el
    // sistema de detracciones está pensado para operaciones que sí lo dan.
    if (peticion.Detraccion is not null && peticion.Tipo != TipoComprobante.Factura)
    {
        return Results.BadRequest(new RespuestaError(
            "La detracción solo aplica a facturas.",
            "SUNAT no admite detracción en comprobantes que no dan crédito " +
            "fiscal, como las boletas."));
    }

    // Los anticipos, de momento, solo en facturas.
    //
    // SUNAT sí los admite en boletas, pero las boletas viajan por resumen
    // diario, que es otro formato con sus propias reglas y que no hemos
    // probado con anticipos. Rechazarlo es más honesto que aceptarlo y
    // emitir un comprobante donde el anticipo no aparece por ningún lado.
    if (peticion.Anticipos.Count > 0 && peticion.Tipo != TipoComprobante.Factura)
    {
        return Results.BadRequest(new RespuestaError(
            "Los anticipos solo están implementados en facturas.",
            "Las boletas viajan por resumen diario, y ese camino todavía no " +
            "declara anticipos."));
    }

    // La percepción, por lo mismo que los anticipos.
    if (peticion.Percepcion is not null && peticion.Tipo != TipoComprobante.Factura)
    {
        return Results.BadRequest(new RespuestaError(
            "La percepción solo está implementada en facturas.",
            "Las boletas viajan por resumen diario, y ese camino todavía no " +
            "declara percepción."));
    }

    // Las cuotas de crédito, lo mismo.
    //
    // SUNAT solo las exige cuando el receptor tiene RUC, y una boleta nunca
    // lo tiene, así que en rigor no harían falta. Pero el resumen diario no
    // las declara, y aceptarlas para después perderlas es peor que decir
    // que no están.
    if (peticion.Cuotas.Count > 0 && peticion.Tipo != TipoComprobante.Factura)
    {
        return Results.BadRequest(new RespuestaError(
            "Las cuotas de crédito solo están implementadas en facturas.",
            "Las boletas viajan por resumen diario, y ese formato no declara " +
            "cuotas."));
    }

    // --- Construcción del comprobante ---
    // El emisor sale del tenant, NUNCA de la petición.

    ComprobanteBase comprobante;

    try
    {
        comprobante = ConstruirComprobante(peticion, tenant);
    }
    catch (ArgumentException ex)
    {
        return Results.BadRequest(new RespuestaError("Datos inválidos.", ex.Message));
    }

    // LOS AVISOS DE PLAZO NO BLOQUEAN, PERO TIENEN QUE VERSE.
    //
    // Facturar el lunes una venta del sábado es legítimo y frecuente. Lo que
    // no puede pasar es que nadie sepa que ese comprobante vence hoy, porque
    // si el envío falla no hay segunda oportunidad: SUNAT lo rechaza con el
    // 2108 y queda emitido sin declarar.
    foreach (var aviso in ReglasFechaEmision.Avisos(comprobante)
                 .Concat(ReglasIsc.Avisos(comprobante))
                 .Concat(comprobante is Factura fx
                     ? ReglasHidrobiologicos.Revisar(fx)
                         .Where(p => p.StartsWith("Aviso:"))
                     : []))
        registro.LogWarning("{Serie}: {Aviso}", peticion.Serie, aviso);


    // --- Los anticipos tienen que existir de verdad ---
    //
    // SUNAT valida esto con las reglas 3218 y 3219, pero solo en producción:
    // en beta su listado de comprobantes está vacío y acepta cualquier
    // número inventado. Lo comprobamos aquí mientras el anticipo lo haya
    // emitido este mismo contribuyente, que es el caso normal.
    //
    // Si lo emitió otro RUC, SUNAT admite el caso y nosotros no tenemos
    // forma de verificarlo: se deja pasar y que decida SUNAT.

    foreach (var anticipo in peticion.Anticipos)
    {
        if (anticipo.RucEmisor != tenant.Ruc) continue;

        var partes = (anticipo.Numero ?? "").Split('-');

        if (partes.Length != 2 || !int.TryParse(partes[1], out var correlativoPrevio))
        {
            return Results.BadRequest(new RespuestaError(
                "El número del comprobante de anticipo no es válido.",
                $"'{anticipo.Numero}' debería tener la forma SERIE-CORRELATIVO."));
        }

        // CATÁLOGO 12 → CATÁLOGO 01, Y NO SON EL MISMO NÚMERO.
        //
        // En el bloque de anticipos, "02" significa factura. En nuestra base
        // la factura es "01". Buscar por "02" no encontraría nada, y el
        // error acusaría al usuario de algo que hizo bien.
        var tipoEnLaBase = anticipo.TipoComprobante == TipoComprobanteAnticipo.Factura
            ? TipoComprobante.Factura
            : TipoComprobante.Boleta;

        var previo = await repositorio.BuscarPorNumeroAsync(
            tenant.Id, tipoEnLaBase, partes[0], correlativoPrevio, ct);

        if (previo is null)
        {
            return Results.BadRequest(new RespuestaError(
                "El comprobante del anticipo no existe.",
                $"No se encontró {anticipo.Numero} entre los comprobantes de " +
                "este emisor. SUNAT lo rechazaría con el error 3218."));
        }

        if (previo.Estado is not ("ACEPTADO" or "ACEPTADO_CON_OBSERVACIONES"))
        {
            return Results.BadRequest(new RespuestaError(
                "El comprobante del anticipo todavía no fue aceptado.",
                $"{anticipo.Numero} está en estado {previo.Estado}. Solo se " +
                "puede descontar un anticipo que SUNAT ya aceptó (error 3219)."));
        }

        if (previo.Moneda != peticion.Moneda)
        {
            return Results.BadRequest(new RespuestaError(
                "El anticipo está en otra moneda.",
                $"{anticipo.Numero} se emitió en {previo.Moneda} y esta factura " +
                $"está en {peticion.Moneda}. SUNAT exige la misma moneda en " +
                "todo el documento."));
        }

        // SE PUEDE DESCONTAR MENOS, NUNCA MÁS.
        //
        // Aplicar solo una parte del anticipo es legítimo: un adelanto grande
        // puede repartirse entre dos entregas. Declarar más de lo que aquella
        // factura cobró no lo es nunca.
        //
        // Esta comprobación atrapa de paso el error más común del módulo:
        // mandar el monto SIN IGV. Como sale un 18% por debajo, no salta
        // aquí — pero si alguien manda el valor con IGV de una factura que
        // no lo llevaba, sí.
        if (anticipo.MontoTotal > previo.ImporteTotal)
        {
            return Results.BadRequest(new RespuestaError(
                "El anticipo declara más de lo que su factura cobró.",
                $"{anticipo.Numero} se emitió por {previo.ImporteTotal:0.00} y " +
                $"aquí se declaran {anticipo.MontoTotal:0.00}."));
        }
    }

    // --- Persistencia ---

    var idempotencyKey = contexto.Request.Headers["Idempotency-Key"].ToString();

    try
    {
        var guardado = await repositorio.CrearAsync(
            tenant.Id,
            comprobante,
            extraJson: peticion.Extra is null
                ? null
                : JsonSerializer.Serialize(peticion.Extra),
            idempotencyKey: string.IsNullOrWhiteSpace(idempotencyKey) ? null : idempotencyKey,
            correoReceptor: peticion.Receptor.CorreoLimpio(),
            ct: ct);

        var respuesta = RespuestaComprobante.Desde(guardado, peticion.Moneda);

        // Si la clave de idempotencia ya se había usado, no se creó nada:
        // se devuelve el comprobante original con 200, no con 202.
        return guardado.YaExistia
            ? Results.Ok(respuesta)
            : Results.Accepted($"/v1/comprobantes/{guardado.Id}", respuesta);
    }
    catch (InvalidOperationException ex)
    {
        // Serie inexistente o inactiva.
        return Results.BadRequest(new RespuestaError("No se pudo emitir.", ex.Message));
    }
})
.WithName("EmitirComprobante")
.WithTags("Comprobantes")
.WithSummary("Emite una factura o boleta")
.WithDescription(
    "Responde 202: el comprobante queda registrado, pero todavía NO fue a SUNAT. " +
    "Eso lo hace el worker.\n\n" +
    "Envía la cabecera Idempotency-Key para que un reintento no produzca un duplicado: " +
    "si la clave ya se usó, responde 200 con el comprobante original.\n\n" +
    "**Detracción:** si la operación está sujeta al SPOT, incluye el objeto " +
    "`detraccion`. El monto se calcula solo si no lo envías.\n\n" +
    "**Percepción:** solo si el emisor es agente de percepción designado, y " +
    "solo al contado. El importe total del comprobante sale SIN percepción: " +
    "el total con percepción viaja en un bloque aparte del XML.\n\n" +
    "**Crédito:** si la forma de pago es `Credito` y el receptor tiene RUC, " +
    "hay que enviar al menos una cuota en `cuotas`, con su monto y su fecha " +
    "de vencimiento. SUNAT lo exige desde 2022.\n\n" +
    "**Operaciones gratuitas:** lo que se entrega sin cobrar va en su propia " +
    "línea, con su valor referencial en `valorUnitario` y el código que " +
    "corresponda en `tipoAfectacionIgv` — el más habitual es `15`, " +
    "bonificaciones. No suman al importe total: el cliente paga lo mismo. " +
    "El IGV de esas líneas sí se declara, y lo asume el emisor.\n\n" +
    "**Cargos y descuentos globales:** en `cargosGlobales`, con el código " +
    "del catálogo 53 — `50` cargo, `03` descuento, `45` FISE, `46` recargo " +
    "al consumo. Esos cuatro no generan IGV ni entran en el valor de venta: " +
    "solo mueven el importe a pagar.\n\n" +
    "El `49` es la excepción: SÍ se suma a la base imponible y genera su " +
    "propio IGV. Para un descuento que reduzca el IGV, usa " +
    "`descuentoGlobalPorcentaje`.\n\n" +
    "**Detracción de pesca:** con `tipoOperacion` `1002` y código de bien " +
    "`004`, hay que enviar el bloque `hidrobiologicos` con los seis datos " +
    "del desembarque. SUNAT los cruza contra el parte de descarga.\n\n" +
    "**Retenciones:** `62` retención del IGV, que es informativa y no mueve " +
    "el importe total; `63` retención de renta de segunda categoría, que sí " +
    "resta. La `62` necesita `baseImponible` y `porcentaje`.\n\n" +
    "**ICBPER:** las bolsas de plástico van en su propia línea con " +
    "`afectoIcbper: true`. La cantidad de esa línea es el número de bolsas. " +
    "La tasa sale sola de la fecha de emisión —0.50 soles por bolsa desde " +
    "2023— y este impuesto SÍ sube el importe total.\n\n" +
    "**IVAP (arroz pilado):** afectación `17` en las líneas. Sustituye al " +
    "IGV con una tasa del 4%, y es excluyente: si una línea lo lleva, todas " +
    "tienen que llevarlo. No hace falta enviar `porcentajeIgv`.\n\n" +
    "**Plazo:** SUNAT da 3 días calendario para que una factura le llegue, " +
    "y 7 para una boleta. Pasado el plazo la rechaza con el error 2108 y el " +
    "correlativo se pierde, así que una petición con `fechaEmision` vencida " +
    "se rechaza aquí mismo.\n\n" +
    "**ISC:** en la línea, con `sistemaIsc` (catálogo 08) y `tasaIsc`. " +
    "A diferencia de los demás impuestos, el ISC **entra en la base del " +
    "IGV**: con 1000 de valor y 10% de ISC, el IGV sale sobre 1100.")
.Produces<RespuestaComprobante>(StatusCodes.Status202Accepted)
.Produces<RespuestaComprobante>(StatusCodes.Status200OK)
.Produces<RespuestaError>(StatusCodes.Status400BadRequest)
.Produces<RespuestaError>(StatusCodes.Status401Unauthorized);


/// Estado de un comprobante.
app.MapGet("/v1/comprobantes/{id:guid}", async (
    Guid id,
    ContextoEmisor emisor,
    RepositorioComprobantes repositorio,
    CancellationToken ct) =>
{
    var tenant = emisor.Exigir();

    var comprobante = await repositorio.ObtenerAsync(tenant.Id, id, ct);

    // Si el comprobante es de otra empresa, Row Level Security hace que
    // simplemente no exista para esta consulta. El 404 es correcto y además
    // no revela que el identificador pertenece a alguien más.
    return comprobante is null
        ? Results.NotFound(new RespuestaError("No se encontró el comprobante."))
        : Results.Ok(RespuestaEstado.Desde(comprobante));
})
.WithName("ConsultarComprobante")
.WithTags("Comprobantes")
.WithSummary("Estado de un comprobante")
.Produces<RespuestaEstado>()
.Produces<RespuestaError>(StatusCodes.Status404NotFound);


/// Lista los comprobantes del emisor.
app.MapGet("/v1/comprobantes", async (
    ContextoEmisor emisor,
    RepositorioComprobantes repositorio,
    int? limite,
    CancellationToken ct) =>
{
    var tenant = emisor.Exigir();

    var comprobantes = await repositorio.ListarAsync(
        tenant.Id, Math.Clamp(limite ?? 50, 1, 200), ct);

    return Results.Ok(comprobantes.Select(RespuestaEstado.Desde));
})
.WithName("ListarComprobantes")
.WithTags("Comprobantes")
.WithSummary("Lista los comprobantes del emisor")
.Produces<IEnumerable<RespuestaEstado>>();


/// Historial de intentos de un comprobante.
app.MapGet("/v1/comprobantes/{id:guid}/historial", async (
    Guid id,
    ContextoEmisor emisor,
    RepositorioComprobantes repositorio,
    CancellationToken ct) =>
{
    var tenant = emisor.Exigir();

    var historial = await repositorio.HistorialAsync(tenant.Id, id, ct);

    return Results.Ok(historial.Select(i => new
    {
        intento = i.IntentoNro,
        desde = i.EstadoAnterior,
        hasta = i.EstadoNuevo,
        codigoSunat = i.CodigoSunat,
        mensaje = i.Mensaje,
        duracionMs = i.DuracionMs,
        fecha = i.CreadoEn
    }));
})
.WithName("HistorialComprobante")
.WithTags("Comprobantes")
.WithSummary("Bitácora de un comprobante")
.WithDescription(
    "Cada cambio de estado, con su código de SUNAT y su duración. " +
    "La bitácora es append-only: nunca se modifica ni se borra.");


/// Datos del emisor autenticado. Útil para verificar que la clave funciona.
app.MapGet("/v1/emisor", async (
    ContextoEmisor emisor, AlmacenCertificados certificados, CancellationToken ct) =>
{
    var tenant = emisor.Exigir();

    // EL VENCIMIENTO DEL CERTIFICADO, para que quien integra avise antes.
    //
    // El dato existía, pero solo en `/admin/tenants/{id}/certificados`, que va
    // con la sesión del panel y cruza empresas: nadie de fuera puede ni debe
    // usar esa ruta. Aquí sale solo la fecha del activo de ESTA empresa.
    // Null si no tiene certificado cargado.
    var validoHasta = await certificados.VencimientoActivoAsync(tenant.Id, ct);

    return Results.Ok(new
    {
        ruc = tenant.Ruc,
        razonSocial = tenant.RazonSocial,
        ambiente = tenant.Ambiente,
        certificadoValidoHasta = validoHasta,
        certificadoDiasParaVencer = validoHasta is { } h
            ? (int?)Math.Ceiling((h - DateTime.UtcNow).TotalDays)
            : null
    });
})
.WithName("Emisor")
.WithTags("Servicio")
.WithSummary("Datos del emisor autenticado")
.WithDescription("Sirve para verificar que una clave de acceso funciona.");

app.Run();


// ---------------------------------------------------------------------------

static ComprobanteBase ConstruirComprobante(
    PeticionComprobante peticion, TenantResuelto tenant)
{
    var emisor = new Emisor
    {
        Ruc = tenant.Ruc,
        RazonSocial = tenant.RazonSocial,
        NombreComercial = tenant.NombreComercial,
        Ubigeo = tenant.Ubigeo,
        Direccion = tenant.Direccion,
        Distrito = tenant.Distrito,
        Provincia = tenant.Provincia,
        Departamento = tenant.Departamento
    };

    var receptor = new Receptor
    {
        TipoDocumento = peticion.Receptor.TipoDocumento,
        NumeroDocumento = peticion.Receptor.NumeroDocumento,
        RazonSocial = peticion.Receptor.RazonSocial,
        Direccion = peticion.Receptor.Direccion
    };

    // EL RECEPTOR SE REVISA LO PRIMERO, y antes de gastar un correlativo.
    //
    // Un RUC con el digito verificador cambiado no existe, y la factura
    // emitida a ese numero hay que anularla con una nota de credito. Eso
    // cuesta mas que este if.
    var problemasReceptor = ReglasReceptor.Errores(receptor);

    if (problemasReceptor.Count > 0)
        throw new ArgumentException(string.Join(" ", problemasReceptor));

    if (peticion.Tipo == TipoComprobante.Factura &&
    !TipoOperacion.EsExportacion(peticion.TipoOperacion ?? "") &&
    receptor.TipoDocumento != TipoDocIdentidad.Ruc)
    {
        throw new ArgumentException(
            $"Una factura solo se puede emitir a un RUC, y el receptor llego " +
            $"con documento de tipo '{receptor.TipoDocumento}'. Si el cliente " +
            $"no tiene RUC, el documento que le corresponde es una boleta de " +
            $"venta (tipo 03). La unica factura que admite otro documento es " +
            $"la de exportacion, y esa se declara con tipo de operacion " +
            $"0200-0208.");
    }

    var lineas = peticion.Lineas.Select((l, indice) => new LineaComprobante
    {
        Numero = indice + 1,
        CodigoProducto = l.CodigoProducto,
        Descripcion = l.Descripcion,
        UnidadMedida = l.UnidadMedida,
        Cantidad = l.Cantidad,
        ValorUnitario = l.ValorUnitario,
        DescuentoPorcentaje = l.DescuentoPorcentaje,
        TipoAfectacionIgv = l.TipoAfectacionIgv,
        PorcentajeIgv = l.PorcentajeIgv
            ?? AfectacionIgv.TasaPorDefecto(l.TipoAfectacionIgv),
        AfectoIcbper = l.AfectoIcbper,
        IcbperUnitario = l.IcbperUnitario,
        SistemaIsc = l.SistemaIsc,
        TasaIsc = l.TasaIsc
    }).ToList();

    // --- Que un dedazo en la afectación dé 400 y no 500 ---------------------
    //
    // Un "1O" con la letra O en vez del cero llegaba hasta el cálculo de
    // totales y reventaba allí con una excepción interna: el cliente de la
    // API recibía "error del servidor" y no tenía forma de saber qué había
    // puesto mal.
    //
    // Con quince códigos válidos en el catálogo 07 —los cuatro de siempre
    // más las once gratuitas— el dedazo ya no es raro.

    var afectacionesRaras = lineas
        .Where(l => !AfectacionIgv.Existe(l.TipoAfectacionIgv))
        .Select(l => $"la linea {l.Numero} llego con '{l.TipoAfectacionIgv}'")
        .ToList();

    if (afectacionesRaras.Count > 0)
    {
        throw new ArgumentException(
            "Hay afectaciones de IGV que no existen en el catalogo 07: " +
            $"{string.Join(", ", afectacionesRaras)}.");
    }

    var tipoCambio = peticion.TipoCambio is null ? null : new TipoCambio
    {
        MonedaOrigen = peticion.TipoCambio.MonedaOrigen,
        MonedaDestino = peticion.TipoCambio.MonedaDestino,
        Tasa = peticion.TipoCambio.Tasa,
        Fecha = peticion.TipoCambio.Fecha ?? RelojPeru.Hoy
    };

    var fecha = peticion.FechaEmision ?? RelojPeru.Ahora;

    // LA FACTURA SE CONSTRUYE APARTE porque puede llevar detracción, y eso
    // no cabe en un inicializador: el monto depende de los totales, y los
    // totales dependen de la factura ya completa.
    if (peticion.Tipo == TipoComprobante.Factura)
    {
        var factura = new Factura
        {
            Serie = peticion.Serie,
            FechaEmision = fecha,
            Moneda = peticion.Moneda,
            FormaPago = peticion.FormaPago,
            TipoOperacion = peticion.TipoOperacion,
            PaisDeUso = peticion.PaisDeUso,
            Drawback = peticion.Drawback,
            DescuentoGlobalPorcentaje = peticion.DescuentoGlobalPorcentaje,
            TipoCambio = tipoCambio,
            Emisor = emisor,
            Receptor = receptor,
            Lineas = lineas
        };

        // LOS CARGOS GLOBALES VAN LOS PRIMEROS, y el orden no es casual:
        // cambian el importe total, y la detracción, la percepción y las
        // cuotas se comprueban todas contra ese importe. Copiarlos después
        // haría que esas tres miraran un total que ya no es el final.
        factura.CargosGlobales = MapearCargosGlobales(peticion);

        // Las cuotas se copian antes que nada: la revisión de crédito mira
        // los totales, y los totales no cambian por las cuotas, pero sí las
        // demás revisiones miran la factura entera.
        factura.Cuotas = peticion.Cuotas.Select(c => new CuotaCredito
        {
            Numero = c.Numero,
            Monto = c.Monto,
            FechaVencimiento = c.FechaVencimiento
        }).ToList();

        if (peticion.Detraccion is not null)
            AplicarDetraccion(factura, peticion.Detraccion);

        // Los anticipos se copian ANTES de revisar nada, porque cambian
        // los totales y las dos revisiones miran totales.
        factura.Anticipos = peticion.Anticipos.Select(a => new Anticipo
        {
            IdentificadorPago = a.IdentificadorPago,
            TipoComprobante = a.TipoComprobante,
            Numero = a.Numero,
            RucEmisor = a.RucEmisor,
            MontoTotal = a.MontoTotal,
            FechaPago = a.FechaPago,
            TipoAfectacion = a.TipoAfectacion,
            PorcentajeIgv = a.PorcentajeIgv
        }).ToList();

        if (peticion.Percepcion is not null)
            AplicarPercepcion(factura, peticion.Percepcion);

        var problemasExportacion = Exportacion.Errores(factura);

        if (problemasExportacion.Count > 0)
            throw new ArgumentException(string.Join(" ", problemasExportacion));

        var problemasAnticipos = ReglasAnticipos.Errores(factura);

        if (problemasAnticipos.Count > 0)
            throw new ArgumentException(string.Join(" ", problemasAnticipos));

        var problemasPercepcion = ReglasPercepcion.Errores(factura);

        if (problemasPercepcion.Count > 0)
            throw new ArgumentException(string.Join(" ", problemasPercepcion));

        var problemasCredito = ReglasCredito.Errores(factura);

        if (problemasCredito.Count > 0)
            throw new ArgumentException(string.Join(" ", problemasCredito));

        // Las líneas gratuitas y los cargos globales se revisan lo mismo que
        // en la boleta de más abajo, y por eso están escritos dos veces en
        // vez de una: la factura sale por su propio return, unas líneas
        // antes de que exista el comprobante genérico.
        var problemasGratuitas = Gratuitas.Errores(factura);

        if (problemasGratuitas.Count > 0)
            throw new ArgumentException(string.Join(" ", problemasGratuitas));

        var problemasCargos = ReglasCargosGlobales.Errores(factura);

        if (problemasCargos.Count > 0)
            throw new ArgumentException(string.Join(" ", problemasCargos));

        var problemasIcbper = ReglasIcbper.Errores(factura);

        if (problemasIcbper.Count > 0)
            throw new ArgumentException(string.Join(" ", problemasIcbper));

        var problemasIvap = ReglasIvap.Errores(factura);

        if (problemasIvap.Count > 0)
            throw new ArgumentException(string.Join(" ", problemasIvap));

        // Los datos del desembarque se copian ANTES de revisar, porque la
        // revision los mira, y se vuelcan en la primera linea: SUNAT solo
        // comprueba que cada codigo exista en el comprobante.
        if (peticion.Hidrobiologicos is { } h)
        {
            factura.Hidrobiologicos = new RecursosHidrobiologicos(
                h.Matricula,
                h.NombreEmbarcacion,
                h.TipoEspecie,
                h.LugarDescarga,
                h.FechaDescarga,
                h.CantidadEspecie);

            if (factura.Lineas.Count > 0)
            {
                factura.Lineas[0].Propiedades =
                    factura.Hidrobiologicos.ComoPropiedades().ToList();
            }
        }

        var problemasHidro = ReglasHidrobiologicos.Errores(factura);

        if (problemasHidro.Count > 0)
            throw new ArgumentException(string.Join(" ", problemasHidro));

        var problemasIsc = ReglasIsc.Errores(factura);

        if (problemasIsc.Count > 0)
            throw new ArgumentException(string.Join(" ", problemasIsc));

        // La fecha, al final: necesita saber el tipo de comprobante, porque
        // el plazo de una factura no es el de una boleta.
        var problemasFecha = ReglasFechaEmision.Errores(factura);

        if (problemasFecha.Count > 0)
            throw new ArgumentException(string.Join(" ", problemasFecha));

        return factura;
    }

    var comprobante = peticion.Tipo switch
    {
        TipoComprobante.Boleta => new Boleta
        {
            Serie = peticion.Serie,
            FechaEmision = fecha,
            Moneda = peticion.Moneda,
            FormaPago = peticion.FormaPago,
            DescuentoGlobalPorcentaje = peticion.DescuentoGlobalPorcentaje,
            TipoCambio = tipoCambio,
            Emisor = emisor,
            Receptor = receptor,
            Lineas = lineas,
            CargosGlobales = MapearCargosGlobales(peticion)
        },

        _ => throw new ArgumentException(
            $"Tipo de comprobante no soportado por este endpoint: {peticion.Tipo}. " +
            "Las notas de crédito y débito tienen su propia ruta.")
    };

    // Una bonificación en una boleta es tan común como en una factura: el
    // "llévate 3 y paga 2" de mostrador va casi siempre a consumidor final.
    //
    // OJO: esto rechaza lo que está mal, pero las boletas todavía viajan por
    // resumen diario y ese camino no declara el total de gratuitas. Hasta
    // que lo haga, las bonificaciones conviene emitirlas en factura.
    var problemasGratuitasBoleta = Gratuitas.Errores(comprobante);

    if (problemasGratuitasBoleta.Count > 0)
        throw new ArgumentException(string.Join(" ", problemasGratuitasBoleta));

    // El recargo al consumo es el caso típico de boleta: un restaurante que
    // cobra el 10% a un consumidor final.
    var problemasCargosBoleta = ReglasCargosGlobales.Errores(comprobante);

    if (problemasCargosBoleta.Count > 0)
        throw new ArgumentException(string.Join(" ", problemasCargosBoleta));

    // EL ICBPER ES, SOBRE TODO, UN ASUNTO DE BOLETAS: grava las bolsas que
    // se entregan a un consumidor final, y el consumidor final compra con
    // boleta. Que funcione aqui importa mas que en la factura.
    var problemasIcbperBoleta = ReglasIcbper.Errores(comprobante);

    if (problemasIcbperBoleta.Count > 0)
        throw new ArgumentException(string.Join(" ", problemasIcbperBoleta));

    var problemasIvapBoleta = ReglasIvap.Errores(comprobante);

    if (problemasIvapBoleta.Count > 0)
        throw new ArgumentException(string.Join(" ", problemasIvapBoleta));

    var problemasIscBoleta = ReglasIsc.Errores(comprobante);

    if (problemasIscBoleta.Count > 0)
        throw new ArgumentException(string.Join(" ", problemasIscBoleta));

    var problemasFechaBoleta = ReglasFechaEmision.Errores(comprobante);

    if (problemasFechaBoleta.Count > 0)
        throw new ArgumentException(string.Join(" ", problemasFechaBoleta));

    return comprobante;
}

/// <summary>
/// Pasa los cargos y descuentos globales del DTO al modelo.
///
/// Está aparte porque lo usan las dos ramas —factura y boleta— y porque
/// duplicar un mapeo es la forma más silenciosa de que un campo nuevo se
/// copie en un sitio y en el otro no.
/// </summary>
static List<CargoGlobal> MapearCargosGlobales(PeticionComprobante peticion) =>
    peticion.CargosGlobales.Select(cg => new CargoGlobal
    {
        Codigo = cg.Codigo,
        Monto = cg.Monto,
        BaseImponible = cg.BaseImponible,
        Porcentaje = cg.Porcentaje,
        Descripcion = cg.Descripcion
    }).ToList();

/// <summary>
/// Añade los datos de detracción a una factura ya construida.
///
/// SE HACE APARTE Y NO EN EL INICIALIZADOR porque necesita los totales, y los
/// totales necesitan la factura completa. Calcularlo todo de una vez obligaría
/// a duplicar aquí la lógica del IGV y los descuentos, que es justo el tipo de
/// duplicación que termina divergiendo.
///
/// Lanza ArgumentException si los datos no sirven, para que el endpoint
/// responda 400 con el motivo en vez de dejar que SUNAT lo rechace después.
/// </summary>
static void AplicarDetraccion(Factura factura, DetraccionDto datos)
{
    var totales = CalculadoraTotales.Calcular(factura);

    factura.Detraccion = new Detraccion(
        datos.TipoOperacion,
        datos.CodigoBienServicio,
        datos.Porcentaje,

        // Si el cliente no manda el monto, se calcula.
        //
        // Es lo habitual: el porcentaje lo sabe, pero el redondeo al entero
        // que hace el Banco de la Nación no tiene por qué conocerlo.
        datos.Monto ?? Detraccion.CalcularMonto(
            totales.ImporteTotal, datos.Porcentaje),

        datos.CuentaBancoNacion,
        datos.MedioDePago);

    var problemas = factura.Detraccion.Revisar(totales.ImporteTotal, factura.Moneda);

    // Los avisos empiezan por "Aviso:" y NO impiden emitir.
    //
    // El del umbral de 700 soles es uno: hay operaciones que se detraen
    // igualmente por acuerdo o régimen especial. Bloquearlo haría que el
    // sistema decidiera por el contribuyente en un asunto que es suyo.
    var errores = problemas.Where(p => !p.StartsWith("Aviso:")).ToList();

    if (errores.Count > 0)
        throw new ArgumentException(string.Join(" ", errores));
}

/// <summary>
/// Añade la percepción a una factura ya construida.
///
/// SE HACE APARTE, como la detracción, porque necesita el importe total y
/// el importe total necesita la factura completa.
///
/// LA BASE VA SIEMPRE EN SOLES. Si la factura está en otra moneda hay que
/// convertirla: SUNAT exige la percepción en moneda nacional aunque todo lo
/// demás del documento esté en dólares. Es la única excepción que admite a
/// "la moneda debe ser la misma en todo el comprobante".
/// </summary>
static void AplicarPercepcion(Factura factura, PercepcionDto datos)
{
    if (!RegimenPercepcion.Existe(datos.Regimen))
    {
        throw new ArgumentException(
            $"El regimen de percepcion '{datos.Regimen}' no existe en el " +
            $"catalogo 22. Solo 01 (venta interna), 02 (combustible) y " +
            $"03 (agente con tasa especial).");
    }

    var totales = CalculadoraTotales.Calcular(factura);

    // El importe total, convertido a soles si hace falta.
    //
    // La tasa que corresponde es la que YA se declaró en este comprobante,
    // no otra consultada aparte: si se usara una distinta, el XML diría dos
    // cosas diferentes sobre el mismo día y el mismo documento.
    var baseEnSoles = factura.Moneda == "PEN"
        ? totales.ImporteTotal
        : CalculadoraTotales.Redondear(
            totales.ImporteTotal * (factura.TipoCambio?.Tasa ?? 0m));

    var porcentaje = datos.Porcentaje
        ?? RegimenPercepcion.TasaReferencia(datos.Regimen);

    factura.Percepcion = new Percepcion(
        datos.Regimen,
        porcentaje,
        baseEnSoles,

        // Si el cliente no manda el monto, se calcula. Es lo habitual: el
        // régimen lo sabe, el redondeo no tiene por qué conocerlo.
        datos.Monto ?? Percepcion.CalcularMonto(baseEnSoles, porcentaje));
}
'@

# --- Facturacion.Api\wwwroot\admin.html
Planear 'Facturacion.Api\wwwroot\admin.html' 'A41B795F87E687754EDE5581C097CBA5FCB182CD5E8D1938C94E431B6B4EF1C8' @'
<!DOCTYPE html>
<html lang="es">
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Empresas · Facturación electrónica</title>
    <style>
           :root {
               --fondo: #f6f7f9;
               --panel: #ffffff;
               --sutil: #f1f3f5;
               --borde: #e3e6ea;
               --borde-fuerte: #cfd4da;
               --texto: #1b1f24;
               --tenue: #5c6570;
               --apagado: #8a929c;
               --acento: #2563eb;
               --acento-fondo: #eef4ff;
               --ok: #15803d;
               --ok-fondo: #eaf6ee;
               --aviso: #a16207;
               --aviso-fondo: #fdf5e3;
               --mal: #b91c1c;
               --mal-fondo: #fdeded;
               --radio: 8px;
           }

           @media (prefers-color-scheme: dark) {
               :root {
                   --fondo: #0f1115;
                   --panel: #171a21;
                   --sutil: #1c212b;
                   --borde: #262b36;
                   --borde-fuerte: #3a4152;
                   --texto: #e6e8ec;
                   --tenue: #98a1ae;
                   --apagado: #6f7884;
                   --acento: #4493f8;
                   --acento-fondo: #12233c;
                   --ok: #3fb950;
                   --ok-fondo: #122a18;
                   --aviso: #d29922;
                   --aviso-fondo: #2b2311;
                   --mal: #f85149;
                   --mal-fondo: #2d1516;
               }
           }

           * {
               box-sizing: border-box;
           }

           body {
               margin: 0;
               padding: 22px;
               background: var(--fondo);
               color: var(--texto);
               font: 15px/1.55 ui-sans-serif, system-ui, "Segoe UI", sans-serif;
           }

           .contenedor {
               max-width: 1180px;
               margin: 0 auto;
           }

           header {
               display: flex;
               align-items: center;
               justify-content: space-between;
               gap: 16px;
               margin-bottom: 6px;
               flex-wrap: wrap;
           }

           h1 {
               font-size: 19px;
               margin: 0;
               font-weight: 500;
           }

           nav {
               display: flex;
               gap: 18px;
               border-bottom: 1px solid var(--borde);
               margin-bottom: 16px;
           }

               nav a {
                   color: var(--tenue);
                   text-decoration: none;
                   font-size: 14px;
                   padding: 0 2px 9px;
                   border-bottom: 2px solid transparent;
                   margin-bottom: -1px;
               }

                   nav a:hover {
                       color: var(--texto);
                   }

                   nav a.activo {
                       color: var(--texto);
                       border-bottom-color: var(--acento);
                   }

           input, select, button {
               font: inherit;
               font-size: 14px;
               color: var(--texto);
               background: var(--panel);
               border: 1px solid var(--borde);
               border-radius: var(--radio);
               padding: 7px 11px;
           }

               input:focus, select:focus {
                   outline: none;
                   border-color: var(--acento);
               }

           button {
               cursor: pointer;
           }

               button:hover:not(:disabled) {
                   border-color: var(--borde-fuerte);
               }

               button:disabled {
                   opacity: .5;
                   cursor: default;
               }

               button.principal {
                   background: var(--acento);
                   border-color: var(--acento);
                   color: #fff;
                   font-weight: 500;
               }

                   button.principal:hover:not(:disabled) {
                       filter: brightness(1.08);
                   }

               button.peligro {
                   color: var(--mal);
                   border-color: var(--borde);
               }

               button.mini {
                   padding: 4px 10px;
                   font-size: 13px;
               }

           .barra {
               display: flex;
               gap: 10px;
               align-items: center;
               margin-bottom: 12px;
           }

           .buscador {
               flex: 1;
               max-width: 340px;
               position: relative;
           }

               .buscador input {
                   width: 100%;
                   padding-left: 32px;
               }

               .buscador svg {
                   position: absolute;
                   left: 10px;
                   top: 9px;
                   width: 15px;
                   height: 15px;
                   stroke: var(--apagado);
                   fill: none;
                   stroke-width: 2;
               }

           .maestro-detalle {
               display: grid;
               grid-template-columns: 266px minmax(0,1fr);
               gap: 14px;
               align-items: start;
           }

           @media (max-width:880px) {
               .maestro-detalle {
                   grid-template-columns: 1fr;
               }
           }

           .tarjeta {
               background: var(--panel);
               border: 1px solid var(--borde);
               border-radius: 12px;
           }

           .lista {
               max-height: calc(100vh - 210px);
               overflow-y: auto;
           }

           .fila-empresa {
               padding: 10px 13px;
               border-bottom: 1px solid var(--borde);
               cursor: pointer;
           }

               .fila-empresa:last-child {
                   border-bottom: none;
               }

               .fila-empresa:hover {
                   background: var(--sutil);
               }

               .fila-empresa.activa {
                   background: var(--acento-fondo);
               }

                   .fila-empresa.activa .nombre {
                       color: var(--acento);
                   }

               .fila-empresa.inactiva {
                   opacity: .55;
               }

               .fila-empresa .nombre {
                   font-size: 14px;
                   display: flex;
                   align-items: center;
                   gap: 6px;
               }

               .fila-empresa .ruc {
                   font-size: 12px;
                   color: var(--tenue);
                   font-family: ui-monospace, Consolas, monospace;
               }

           .pie-lista {
               padding: 9px 13px;
               font-size: 12px;
               color: var(--apagado);
               border-top: 1px solid var(--borde);
           }

           .detalle {
               padding: 18px 20px;
           }

           .cabecera-detalle {
               display: flex;
               align-items: flex-start;
               justify-content: space-between;
               gap: 14px;
               margin-bottom: 16px;
           }

               .cabecera-detalle h2 {
                   font-size: 17px;
                   margin: 0;
                   font-weight: 500;
               }

               .cabecera-detalle .sub {
                   font-size: 13px;
                   color: var(--tenue);
                   font-family: ui-monospace, Consolas, monospace;
                   margin-top: 2px;
               }

           .insignia {
               font-size: 12px;
               padding: 3px 10px;
               border-radius: var(--radio);
               white-space: nowrap;
           }

           .i-ok {
               background: var(--ok-fondo);
               color: var(--ok);
           }

           .i-aviso {
               background: var(--aviso-fondo);
               color: var(--aviso);
           }

           .i-mal {
               background: var(--mal-fondo);
               color: var(--mal);
           }

           .i-tenue {
               background: var(--sutil);
               color: var(--tenue);
           }

           /* Webhook registrado por la API (la plataforma), no a mano. */
           .i-api {
               background: var(--acento-fondo);
               color: var(--acento);
           }

           .metricas {
               display: grid;
               grid-template-columns: repeat(auto-fit,minmax(130px,1fr));
               gap: 10px;
               margin-bottom: 18px;
           }

           .metrica {
               background: var(--sutil);
               border-radius: var(--radio);
               padding: 11px 13px;
           }

               .metrica .et {
                   font-size: 12px;
                   color: var(--tenue);
               }

               .metrica .va {
                   font-size: 15px;
                   margin-top: 2px;
               }

           .pestanas {
               display: flex;
               gap: 16px;
               border-bottom: 1px solid var(--borde);
               margin-bottom: 14px;
           }

           .pestana {
               font-size: 13px;
               color: var(--tenue);
               cursor: pointer;
               padding: 0 2px 8px;
               border-bottom: 2px solid transparent;
               margin-bottom: -1px;
               background: none;
               border-top: none;
               border-left: none;
               border-right: none;
           }

               .pestana:hover {
                   color: var(--texto);
               }

               .pestana.activa {
                   color: var(--texto);
                   border-bottom-color: var(--acento);
               }

           table {
               width: 100%;
               border-collapse: collapse;
               font-size: 13.5px;
           }

           th {
               text-align: left;
               color: var(--tenue);
               font-weight: 400;
               padding: 6px 8px;
               border-bottom: 1px solid var(--borde);
               font-size: 12.5px;
           }

           td {
               padding: 9px 8px;
               border-bottom: 1px solid var(--borde);
           }

           tr:last-child td {
               border-bottom: none;
           }

           .mono {
               font-family: ui-monospace, Consolas, monospace;
               font-size: 13px;
           }

           .recorte {
               overflow: hidden;
               text-overflow: ellipsis;
               white-space: nowrap;
           }

           td.mal, .mal {
               color: var(--mal);
           }

           /* La fila recién creada. El resaltado se va solo a los pocos segundos:
        sirve para encontrarla, no para quedarse ahí. */
           tr.fila-inactiva td:not(:last-child) {
               opacity: .55;
           }

           tr.recien {
               background: var(--ok-fondo);
           }

               tr.recien td:first-child {
                   box-shadow: inset 3px 0 0 var(--ok);
               }

           .filtro-tabla {
               display: flex;
               align-items: center;
               justify-content: space-between;
               gap: 12px;
               margin-bottom: 8px;
           }

               .filtro-tabla .buscador {
                   max-width: 260px;
                   flex: 1;
               }

                   .filtro-tabla .buscador input {
                       padding: 6px 11px 6px 30px;
                       font-size: 13.5px;
                   }

                   .filtro-tabla .buscador svg {
                       top: 8px;
                       width: 14px;
                       height: 14px;
                   }

               .filtro-tabla .conteo {
                   font-size: 12.5px;
                   color: var(--tenue);
               }

           .tenue {
               color: var(--tenue);
           }

           .vacio {
               color: var(--tenue);
               font-size: 14px;
               padding: 14px 0;
           }


           .usuario {
               display: flex;
               align-items: center;
               gap: 12px;
               font-size: 13.5px;
               color: var(--tenue);
           }

               .usuario .rol {
                   background: var(--sutil);
                   border-radius: var(--radio);
                   padding: 2px 9px;
                   font-size: 12px;
               }

               .usuario a {
                   color: var(--acento);
                   text-decoration: none;
               }

                   .usuario a:hover {
                       text-decoration: underline;
                   }

           .rejilla {
               display: grid;
               grid-template-columns: repeat(auto-fit,minmax(170px,1fr));
               gap: 11px;
               margin: 14px 0;
           }

           label {
               display: block;
               font-size: 12px;
               color: var(--tenue);
               margin-bottom: 4px;
           }

               label input, label select {
                   width: 100%;
               }

           .err {
               color: var(--mal);
               font-size: 12px;
               margin-top: 3px;
               min-height: 14px;
           }

           label.invalido input {
               border-color: var(--mal);
           }

           /* El input de archivo nativo no se puede estilizar: se oculta y se usa
        una etiqueta como botón. El input sigue ahí, así que el teclado y los
        lectores de pantalla lo siguen alcanzando. */
           .archivo {
               position: relative;
           }

               .archivo input[type=file] {
                   position: absolute;
                   inset: 0;
                   opacity: 0;
                   width: 100%;
                   height: 100%;
                   cursor: pointer;
               }

               .archivo .caja {
                   display: flex;
                   align-items: center;
                   gap: 9px;
                   border: 1px dashed var(--borde-fuerte);
                   border-radius: var(--radio);
                   padding: 8px 11px;
                   background: var(--panel);
                   font-size: 13.5px;
                   color: var(--tenue);
               }

               .archivo:hover .caja {
                   border-color: var(--acento);
                   color: var(--texto);
               }

               .archivo.con-archivo .caja {
                   border-style: solid;
                   border-color: var(--ok);
                   color: var(--texto);
               }

               .archivo .caja svg {
                   width: 16px;
                   height: 16px;
                   stroke: currentColor;
                   fill: none;
                   stroke-width: 2;
                   flex: none;
               }

               .archivo .nombre-archivo {
                   overflow: hidden;
                   text-overflow: ellipsis;
                   white-space: nowrap;
               }

           #avisos {
               position: fixed;
               top: 18px;
               right: 18px;
               z-index: 60;
               display: flex;
               flex-direction: column;
               gap: 8px;
               max-width: 370px;
           }

           .flotante {
               background: var(--panel);
               border: 1px solid var(--borde);
               border-left: 3px solid var(--acento);
               border-radius: var(--radio);
               padding: 11px 14px;
               font-size: 14px;
               box-shadow: 0 6px 22px rgba(0,0,0,.14);
               animation: entrar .16s ease-out;
           }

               .flotante.ok {
                   border-left-color: var(--ok);
               }

               .flotante.mal {
                   border-left-color: var(--mal);
               }

               .flotante .t {
                   font-weight: 500;
               }

               .flotante .d {
                   color: var(--tenue);
                   font-size: 13px;
                   margin-top: 2px;
               }

           @keyframes entrar {
               from {
                   opacity: 0;
                   transform: translateX(14px);
               }
           }

           .velo {
               position: fixed;
               inset: 0;
               background: rgba(15,18,23,.5);
               z-index: 70;
               display: none;
               align-items: center;
               justify-content: center;
               padding: 20px;
           }

               .velo.visible {
                   display: flex;
               }

           .modal {
               background: var(--panel);
               border: 1px solid var(--borde);
               border-radius: 14px;
               padding: 22px 24px;
               width: 100%;
               max-width: 560px;
               max-height: 88vh;
               overflow-y: auto;
           }

               .modal h3 {
                   margin: 0 0 4px;
                   font-size: 17px;
                   font-weight: 500;
               }

               .modal .ayuda {
                   margin: 0 0 4px;
                   color: var(--tenue);
                   font-size: 13.5px;
               }

               .modal .botones {
                   display: flex;
                   gap: 8px;
                   justify-content: flex-end;
                   margin-top: 18px;
               }

           /* El logo se enseña sobre blanco en los dos temas: así va a salir
        en el PDF y en el correo, que son blancos. */
           .logo-caja {
               width: 200px;
               height: 76px;
               border: 1px dashed var(--borde-fuerte);
               border-radius: var(--radio);
               background: #fff;
               display: flex;
               align-items: center;
               justify-content: center;
               padding: 8px;
               flex: none;
           }

               .logo-caja img {
                   max-width: 100%;
                   max-height: 100%;
               }

               .logo-caja .tenue {
                   font-size: 13px;
                   color: #8a929c;
               }

           .direccion-portal {
               background: var(--sutil);
               border-radius: var(--radio);
               padding: 11px 13px;
               margin-bottom: 8px;
               font-size: 14px;
           }

           .muestra-color {
               display: flex;
               gap: 8px;
               align-items: center;
           }

               .muestra-color input[type=color] {
                   width: 46px;
                   height: 36px;
                   padding: 2px;
                   flex: none;
                   cursor: pointer;
               }

           .secreto {
               background: var(--ok-fondo);
               border: 1px solid var(--ok);
               border-radius: var(--radio);
               padding: 13px 15px;
               margin-top: 12px;
           }

               .secreto code {
                   display: block;
                   font-family: ui-monospace,Consolas,monospace;
                   font-size: 14px;
                   word-break: break-all;
                   margin: 9px 0;
                   color: var(--ok);
               }
    </style>
</head>
<body>

    <div id="avisos"></div>

    <div class="velo" id="velo-confirmar">
        <div class="modal" style="max-width:430px">
            <h3 id="cf-titulo"></h3>
            <p class="ayuda" id="cf-texto"></p>
            <div class="botones">
                <button id="cf-cancelar">Cancelar</button>
                <button id="cf-aceptar" class="principal">Confirmar</button>
            </div>
        </div>
    </div>

    <div class="velo" id="velo-nueva">
        <div class="modal">
            <h3>Nueva empresa</h3>
            <p class="ayuda">
                Después habrá que cargarle un certificado, dar de alta al
                menos una serie y emitirle una clave de acceso.
            </p>

            <div class="rejilla">
                <label>
                    RUC<input id="n-ruc" maxlength="11" placeholder="20601234567">
                    <div class="err" id="e-ruc"></div>
                </label>
                <label>
                    Razón social<input id="n-razon" placeholder="Comercial Andina EIRL">
                    <div class="err" id="e-razon"></div>
                </label>
                <label>Nombre comercial<input id="n-comercial" placeholder="opcional"></label>
                <label>
                    Identificador del portal<input id="n-identificador" maxlength="40" placeholder="opcional · ferreteria-lopez">
                    <div class="err" id="e-identificador"></div>
                </label>
                <label>Dirección<input id="n-direccion"></label>
                <label>Distrito<input id="n-distrito" value="LIMA"></label>
                <label>Provincia<input id="n-provincia" value="LIMA"></label>
                <label>Departamento<input id="n-departamento" value="LIMA"></label>
                <label>Ubigeo<input id="n-ubigeo" value="150101"></label>
                <label>
                    Ambiente
                    <select id="n-ambiente">
                        <option value="beta">beta (pruebas)</option>
                        <option value="produccion">producción</option>
                    </select>
                </label>
                <label>Usuario SOL<input id="n-sol" value="MODDATOS"></label>
            </div>

            <div class="botones">
                <button id="nv-cancelar">Cancelar</button>
                <button id="nv-crear" class="principal">Crear empresa</button>
            </div>
        </div>
    </div>

    <div class="contenedor">
        <header>
            <h1>Facturación electrónica</h1>
            <div id="usuario-actual" class="usuario"></div>
        </header>

        <nav>
            <a href="/diagnostico.html">Estado del servicio</a>
            <a href="/admin.html" class="activo">Empresas</a>
            <a href="/comprobantes.html">Comprobantes</a>
            <a href="/cuenta.html">Mi cuenta</a>
        </nav>

        <div id="raiz">
            <div class="tarjeta" style="padding:18px 20px">
                <span class="vacio">Cargando…</span>
            </div>
        </div>
    </div>

    <script src="/fechas.js"></script>
    <script>
        // NO SE USA "$" COMO NOMBRE DE FUNCIÓN. Browser Link, la herramienta de
        // Visual Studio que recarga la página al guardar, inyecta jQuery y espera
        // encontrarlo ahí. Definir otra cosa rompe su script con un error que parece
        // del panel y no lo es.
        const elem = id => document.getElementById(id);
        const esc = t => String(t ?? "").replace(/[&<>"']/g,
            c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));

        const estado = {
            empresas: [],
            seleccionada: null,

            // Buscador de la lista de empresas. Tiene nombre propio a propósito:
            // "filtro" a secas se confundía con los filtros de las pestañas, que son
            // otra cosa, y esa colisión rompía la página al arrancar.
            filtroEmpresas: "",

            pestana: "series",
            series: [],
            claves: [],
            certificados: [],
            webhooks: [],
            entregas: [],
            cambiosWebhook: [],
            revision: null,

            // Identificador de lo recién creado en cada pestaña, para resaltarlo.
            recien: { series: null, claves: null, certificado: null, webhooks: null },

            // Filtro de texto de cada pestaña. Son independientes: buscar en claves
            // no debe alterar lo que ves al volver a series.
            filtro: { series: "", claves: "", certificado: "", webhooks: "" }
        };


        // ---------------------------------------------------------------- sesión
        //
        // La autenticación va por cookie, no por una clave escrita en la página.
        //
        // La cookie es HttpOnly, así que este JavaScript NO puede leerla: el
        // navegador la envía sola en cada petición. Si algún día se cuela un script
        // malicioso, no podrá robar la sesión.

        let usuarioActual = null;


        // ------------------------------------------------------------------- menú
        //
        // El menú se arma según los permisos del usuario: cada quien ve solo las
        // pantallas que puede usar.
        //
        // OCULTAR NO ES PROTEGER. El servidor comprueba el permiso en cada petición;
        // esto solo evita mostrar opciones que darían un error al pulsarlas.

        const PANTALLAS = [
            { url: "/diagnostico.html", texto: "Estado del servicio", permiso: "diagnostico.ver" },
            { url: "/admin.html", texto: "Empresas", permiso: "empresas.ver" },
            { url: "/comprobantes.html", texto: "Comprobantes", permiso: "comprobantes.ver" },
            { url: "/usuarios.html", texto: "Usuarios", permiso: "usuarios.gestionar" },
            { url: "/cuenta.html", texto: "Mi cuenta", permiso: null }
        ];

        const puede = permiso => usuarioActual?.permisos?.includes(permiso) === true;

        function pintarMenu() {
            const menu = document.querySelector("nav");
            if (!menu) return;

            const actual = location.pathname;

            menu.innerHTML = PANTALLAS
                .filter(p => p.permiso === null || puede(p.permiso))
                .map(p => `<a href="${p.url}" class="${actual === p.url ? "activo" : ""}">
                     ${esc(p.texto)}</a>`)
                .join("");
        }

        async function cargarUsuario() {
            const r = await fetch("/admin/yo");

            if (r.status === 401) {
                location.href = "/login.html";
                return false;
            }

            usuarioActual = await r.json();

            const caja = elem("usuario-actual");

            if (caja) {
                caja.innerHTML =
                    `<span>${esc(usuarioActual.nombre || usuarioActual.correo)}</span>` +
                    `<span class="rol">${esc(usuarioActual.rol)}</span>` +
                    `<a href="#" id="salir">Salir</a>`;

                elem("salir").onclick = async e => {
                    e.preventDefault();
                    await fetch("/admin/sesion", { method: "DELETE" });
                    location.href = "/login.html";
                };
            }

            pintarMenu();

            return true;
        }

        const esAdministrador = () => usuarioActual?.esAdministrador === true;


        // ------------------------------------------------------------------ avisos

        function avisar(titulo, detalle = "", tipo = "") {
            const caja = document.createElement("div");
            caja.className = "flotante " + tipo;

            caja.innerHTML = `<div class="t">${esc(titulo)}</div>` +
                (detalle ? `<div class="d">${esc(detalle)}</div>` : "");

            elem("avisos").appendChild(caja);

            // Los errores duran más: hay que poder leerlos con calma.
            setTimeout(() => caja.remove(), tipo === "mal" ? 8000 : 4000);
        }

        function confirmar(titulo, texto, textoBoton = "Confirmar") {
            return new Promise(resolver => {
                elem("cf-titulo").textContent = titulo;
                elem("cf-texto").textContent = texto;
                elem("cf-aceptar").textContent = textoBoton;
                elem("velo-confirmar").classList.add("visible");

                const cerrar = r => {
                    elem("velo-confirmar").classList.remove("visible");
                    resolver(r);
                };

                elem("cf-aceptar").onclick = () => cerrar(true);
                elem("cf-cancelar").onclick = () => cerrar(false);
            });
        }

        // --------------------------------------------------------------------- api

        async function api(ruta, opciones = {}) {
            const r = await fetch(ruta, opciones);

            if (r.status === 401) {
                location.href = "/login.html";
                throw new Error("Sesión caducada.");
            }

            const cuerpo = await r.json().catch(() => ({}));

            if (!r.ok) {
                const error = new Error(cuerpo.error || `Error ${r.status}`);
                error.detalle = cuerpo.detalle || "";
                throw error;
            }

            return cuerpo;
        }

        async function iniciar() {
            try {
                estado.empresas = await api("/admin/tenants");
                pintar();
            } catch (e) {
                elem("raiz").innerHTML =
                    `<div class="tarjeta" style="padding:18px 20px;color:var(--mal)">
             ${esc(e.message)}</div>`;
            }
        }

        // ----------------------------------------------------------------- pintado

        function empresasVisibles() {
            const f = estado.filtroEmpresas.trim().toLowerCase();

            if (!f) return estado.empresas;

            return estado.empresas.filter(e =>
                e.razonSocial.toLowerCase().includes(f) || e.ruc.includes(f));
        }

        function pintar() {
            const visibles = empresasVisibles();

            elem("raiz").innerHTML = `
        <div class="barra">
          <div class="buscador">
            <svg viewBox="0 0 24 24"><circle cx="11" cy="11" r="7"/><path d="M20 20l-3.5-3.5"/></svg>
            <input id="buscar" placeholder="Buscar por RUC o nombre" value="${esc(estado.filtroEmpresas)}">
          </div>
          ${puede("empresas.editar")
                    ? `<button class="principal" id="btn-nueva">Nueva empresa</button>` : ""}
        </div>

        <div class="maestro-detalle">
          <div class="tarjeta">
            <div class="lista" id="lista">
              ${visibles.length === 0
                    ? `<div class="vacio" style="padding:16px 13px">
                     ${estado.empresas.length === 0
                        ? "Todavía no hay empresas."
                        : "Ninguna empresa coincide con la búsqueda."}</div>`
                    : visibles.map(filaEmpresa).join("")}
            </div>
            <div class="pie-lista">
              ${visibles.length === estado.empresas.length
                    ? `${estado.empresas.length} ${estado.empresas.length === 1 ? "empresa" : "empresas"}`
                    : `${visibles.length} de ${estado.empresas.length}`}
            </div>
          </div>

          <div class="tarjeta detalle" id="detalle">
            ${estado.seleccionada ? "" : `<div class="vacio">Elige una empresa de la lista.</div>`}
          </div>
        </div>`;

            const buscar = elem("buscar");

            buscar.oninput = () => {
                estado.filtroEmpresas = buscar.value;

                // Se repinta solo la lista para no perder el foco del buscador.
                const posicion = buscar.selectionStart;
                pintar();
                const nuevo = elem("buscar");
                nuevo.focus();
                nuevo.setSelectionRange(posicion, posicion);
            };

            if (elem("btn-nueva")) elem("btn-nueva").onclick = abrirNueva;

            document.querySelectorAll("[data-empresa]").forEach(fila =>
                fila.onclick = () => seleccionar(fila.dataset.empresa));

            if (estado.seleccionada) pintarDetalle();
        }

        function filaEmpresa(e) {
            const activa = estado.seleccionada?.id === e.id;
            const alerta = problemaDe(e);

            return `
        <div class="fila-empresa ${activa ? "activa" : ""} ${e.activo ? "" : "inactiva"}"
             data-empresa="${e.id}" title="${alerta ? esc(alerta) : ""}">
          <div class="nombre">
            ${esc(e.razonSocial)}
            ${alerta ? `<span style="color:var(--aviso);font-size:13px">&#9679;</span>` : ""}
          </div>
          <div class="ruc">${esc(e.ruc)}${e.ambiente === "produccion" ? " · producción" : ""}</div>
        </div>`;
        }

        /// Lo que hace falta mirar en esta empresa. Aparece como punto en la lista
        /// para que los problemas se vean sin abrir una por una.
        function problemaDe(e) {
            if (!e.activo) return null;
            if (!e.tieneCertificado) return "Sin certificado: no puede emitir.";

            const dias = Math.ceil((new Date(e.certificadoVence) - new Date()) / 86400000);

            if (dias < 0) return "Certificado vencido: no puede emitir.";
            if (dias <= 30) return `El certificado vence en ${dias} días.`;
            if (e.series === 0) return "Sin series: no puede emitir.";
            if (e.claves === 0) return "Sin claves: el cliente no puede conectarse.";

            return null;
        }

        function pintarDetalle() {
            const t = estado.seleccionada;

            elem("detalle").innerHTML = `
        <div class="cabecera-detalle">
          <div>
            <h2>${esc(t.razonSocial)}</h2>
            <div class="sub">${esc(t.ruc)} · ${t.ambiente}</div>
          </div>
          <div style="display:flex;gap:8px;align-items:center">
            <span class="insignia ${t.activo ? "i-ok" : "i-tenue"}">
              ${t.activo ? "Activa" : "Inactiva"}</span>
            ${puede("empresas.editar")
                    ? `<button class="mini" id="btn-alternar">
                   ${t.activo ? "Desactivar" : "Activar"}</button>` : ""}
          </div>
        </div>

        <div class="metricas">
          <div class="metrica">
            <div class="et">Certificado</div>
            <div class="va">${estadoCertificado(t)}</div>
          </div>
          <div class="metrica">
            <div class="et">Comprobantes</div>
            <div class="va">${t.comprobantes.toLocaleString("es-PE")}</div>
          </div>
          <div class="metrica">
            <div class="et">Series activas</div>
            <div class="va">${t.series}</div>
          </div>
          <div class="metrica">
            <div class="et">Claves activas</div>
            <div class="va">${t.claves}</div>
          </div>
        </div>

        <div class="pestanas">
          ${pestanasVisibles().map(p => `
            <button class="pestana ${estado.pestana === p ? "activa" : ""}"
                    data-pestana="${p}">${nombrePestana(p)}</button>`).join("")}
        </div>

        <div id="cuerpo-pestana"><div class="vacio">Cargando…</div></div>`;

            if (elem("btn-alternar")) elem("btn-alternar").onclick = alternarActiva;

            document.querySelectorAll("[data-pestana]").forEach(boton =>
                boton.onclick = () => {
                    estado.pestana = boton.dataset.pestana;
                    pintarDetalle();
                });

            cargarPestana();
        }

        /// Las pestañas del detalle también dependen de los permisos.
        ///
        /// Sin esto, alguien de soporte vería la pestaña de certificados y al pulsar
        /// recibiría un 403. Es mejor no mostrar lo que no se puede usar.
        function pestanasVisibles() {
            const todas = [
                { clave: "series", permiso: "empresas.ver" },
                { clave: "marca", permiso: "empresas.ver" },
                { clave: "claves", permiso: "claves.gestionar" },
                { clave: "certificado", permiso: "certificados.gestionar" },
                { clave: "webhooks", permiso: "webhooks.gestionar" },
                { clave: "produccion", permiso: "produccion.cambiar" }
            ];

            return todas.filter(p => puede(p.permiso)).map(p => p.clave);
        }

        const nombrePestana = p => ({
            series: "Series",
            marca: "Marca",
            claves: "Claves de acceso",
            certificado: "Certificado",
            webhooks: "Webhooks",
            produccion: "Producción"
        }[p]);

        function estadoCertificado(t) {
            if (!t.tieneCertificado)
                return `<span style="color:var(--mal)">Falta</span>`;

            const dias = Math.ceil((new Date(t.certificadoVence) - new Date()) / 86400000);

            if (dias < 0) return `<span style="color:var(--mal)">Vencido</span>`;
            if (dias <= 30) return `<span style="color:var(--aviso)">Vence en ${dias} d</span>`;

            return `<span style="color:var(--ok)">Vence en ${dias} d</span>`;
        }

        // -------------------------------------------------------------- pestañas

        async function cargarPestana() {
            const id = estado.seleccionada.id;
            const cuerpo = elem("cuerpo-pestana");

            try {
                if (estado.pestana === "series") {
                    estado.series = await api(`/admin/tenants/${id}/series`);
                    cuerpo.innerHTML = vistaSeries();
                    elem("btn-serie").onclick = crearSerie;

                    // El ejemplo del recuadro sigue al tipo elegido: así se ve la inicial
                    // que toca antes de escribir, no después del rechazo.
                    const tipo = elem("s-tipo");

                    if (tipo) tipo.onchange = () => {
                        const campo = elem("s-serie");
                        if (campo) campo.placeholder = serieSugerida(tipo.value);
                    };

                    enlazarAccionesSerie();

                    enlazarFiltro("series", () => {
                        elem("tabla-series").innerHTML = tablaSeries();
                        enlazarAccionesSerie();
                    });

                } else if (estado.pestana === "claves") {
                    estado.claves = await api(`/admin/tenants/${id}/claves`);
                    cuerpo.innerHTML = vistaClaves();
                    elem("btn-clave").onclick = crearClave;

                    enlazarRevocar();

                    enlazarFiltro("claves", () => {
                        elem("tabla-claves").innerHTML = tablaClaves();
                        enlazarRevocar();
                    });

                } else if (estado.pestana === "marca") {
                    // No hace falta pedir nada: la marca viene con la lista de
                    // empresas, que ya está cargada.
                    cuerpo.innerHTML = vistaMarca();
                    enlazarMarca();

                } else if (estado.pestana === "produccion") {
                    estado.revision = await api(`/admin/tenants/${id}/revision-produccion`);

                    cuerpo.innerHTML = vistaProduccion();

                    elem("btn-sol").onclick = guardarCredenciales;
                    elem("btn-ambiente").onclick = cambiarAmbiente;
                    elem("btn-gre").onclick = guardarCredencialesGre;

                } else if (estado.pestana === "webhooks") {
                    estado.webhooks = await api(`/admin/tenants/${id}/webhooks`);
                    estado.entregas = await api(`/admin/tenants/${id}/webhook-entregas?limite=20`);
                    estado.cambiosWebhook = await api(`/admin/tenants/${id}/webhook-cambios?limite=20`);

                    cuerpo.innerHTML = vistaWebhooks();
                    elem("btn-webhook").onclick = crearWebhook;

                    enlazarAccionesWebhook();

                    enlazarFiltro("webhooks", () => {
                        elem("tabla-webhooks").innerHTML = tablaWebhooks();
                        enlazarAccionesWebhook();
                    });

                } else {
                    estado.certificados = await api(`/admin/tenants/${id}/certificados`);
                    cuerpo.innerHTML = vistaCertificado();
                    elem("btn-certificado").onclick = subirCertificado;

                    enlazarAccionesCertificado();

                    enlazarFiltro("certificado", () => {
                        elem("tabla-certificado").innerHTML = tablaCertificados();
                        enlazarAccionesCertificado();
                    });

                    // El input de archivo está oculto: hay que reflejar el nombre elegido
                    // en la caja visible, o el usuario no sabe si seleccionó algo.
                    elem("c-archivo").onchange = e => {
                        const archivo = e.target.files[0];

                        elem("nombre-archivo").textContent =
                            archivo ? archivo.name : "Elegir archivo .pfx o .p12";

                        elem("envoltura-archivo").classList.toggle("con-archivo", !!archivo);
                    };
                }
            } catch (e) {
                cuerpo.innerHTML = `<div class="vacio" style="color:var(--mal)">${esc(e.message)}</div>`;
            }
        }

        function vistaSeries() {
            return `
        <div class="rejilla" style="margin-top:0">
          <label>Tipo
            <select id="s-tipo">
              <option value="01">Factura</option>
              <option value="03">Boleta</option>
              <option value="04">Liquidación de compra</option>
              <option value="07">Nota de crédito</option>
              <option value="08">Nota de débito</option>
              <option value="09">Guía de remisión remitente</option>
              <option value="20">Comprobante de retención</option>
              <option value="31">Guía de remisión transportista</option>
              <option value="40">Comprobante de percepción</option>
            </select></label>
          <label>Serie<input id="s-serie" maxlength="4" placeholder="F001">
            <div class="err" id="e-serie"></div></label>
          <label>Último correlativo ya emitido<input id="s-corr" type="number" value="0"></label>
        </div>

        <div style="display:flex;align-items:center;gap:12px;margin-bottom:16px">
          <button id="btn-serie">Agregar serie</button>
          <span class="tenue" style="font-size:12.5px">
            Si la empresa viene de otro sistema, pon el último número que ya emitió.
          </span>
        </div>

        ${estado.series.length === 0
                    ? `<div class="vacio" style="border-top:1px solid var(--borde)">
               Sin series. Hace falta al menos una para poder emitir.</div>`
                    : barraFiltro("series", estado.series.length, filtrar("series").length) +
                    `<div id="tabla-series">${tablaSeries()}</div>`}`;
        }

        function tablaSeries() {
            const filas = filtrar("series");

            if (filas.length === 0)
                return `<div class="vacio">Ninguna serie coincide con la búsqueda.</div>`;

            return `<table>
          <tr><th>Tipo</th><th>Serie</th><th>Emitidos</th><th>Siguiente</th>
              <th>Estado</th><th style="text-align:right">Acciones</th></tr>
          ${filas.map(s => `<tr class="${s.id === estado.recien.series ? "recien" : ""}
                                        ${s.activo ? "" : "fila-inactiva"}">
            <td>${nombreTipo(s.tipoComprobante)}</td>
            <td class="mono">${esc(s.serie)}</td>
            <td>${s.comprobantes}</td>
            <td class="tenue">${s.ultimoCorrelativo + 1}</td>
            <td>${s.activo
                    ? `<span class="insignia i-ok">activa</span>`
                    : `<span class="insignia i-tenue">cerrada</span>`}</td>
            <td style="text-align:right;white-space:nowrap">
              ${accionesSerie(s)}
            </td>
          </tr>`).join("")}
        </table>`;
        }

        /// Qué se puede hacer con una serie depende de si ya se usó.
        ///
        /// Sin comprobantes se puede borrar sin consecuencias. Con comprobantes
        /// solo se puede cerrar: borrarla dejaría huérfano el rastro de esa
        /// numeración, y eso es un problema tributario, no de datos.
        function accionesSerie(s) {
            if (s.sePuedeEliminar)
                return `<button class="mini peligro" data-borrar-serie="${s.id}"
                  data-serie-nombre="${esc(s.serie)}">Eliminar</button>`;

            return s.activo
                ? `<button class="mini" data-cerrar-serie="${s.id}"
             data-serie-nombre="${esc(s.serie)}"
             title="Deja de poder emitir. El histórico no se toca.">Cerrar</button>`
                : `<button class="mini" data-abrir-serie="${s.id}"
             data-serie-nombre="${esc(s.serie)}">Reactivar</button>`;
        }

        function vistaClaves() {
            return `
        <div class="rejilla" style="margin-top:0">
          <label>Nombre de la clave<input id="k-nombre" placeholder="ERP producción"></label>
        </div>

        <div style="display:flex;align-items:center;gap:12px;margin-bottom:16px">
          <button id="btn-clave">Emitir clave</button>
          <span class="tenue" style="font-size:12.5px">
            El secreto se muestra una sola vez.
          </span>
        </div>

        <div id="k-resultado"></div>

        ${estado.claves.length === 0
                    ? `<div class="vacio" style="border-top:1px solid var(--borde)">
               Sin claves. El cliente todavía no puede conectarse.</div>`
                    : barraFiltro("claves", estado.claves.length, filtrar("claves").length) +
                    `<div id="tabla-claves">${tablaClaves()}</div>`}`;
        }

        function tablaClaves() {
            const filas = filtrar("claves");

            if (filas.length === 0)
                return `<div class="vacio">Ninguna clave coincide con la búsqueda.</div>`;

            return `<table>
          <tr><th>Nombre</th><th>Prefijo</th><th>Creada</th><th>Último uso</th>
              <th>Estado</th><th></th></tr>
          ${filas.map(k => `<tr class="${k.id === estado.recien.claves ? "recien" : ""}">
            <td>${esc(k.nombre)}</td>
            <td class="mono">${esc(k.prefijo)}…</td>
            <td class="tenue">${diaDe(k.creadoEn)}</td>
            <td class="tenue">${k.ultimoUso ? diaDe(k.ultimoUso) : "nunca"}</td>
            <td>${k.activo
                    ? `<span class="insignia i-ok">activa</span>`
                    : `<span class="insignia i-tenue">revocada</span>`}</td>
            <td>${k.activo
                    ? `<button class="mini peligro" data-revocar="${k.id}">Revocar</button>`
                    : ""}</td>
          </tr>`).join("")}
        </table>`;
        }

        function vistaCertificado() {
            return `
        <div class="rejilla" style="margin-top:0">
          <label>Archivo del certificado
            <span class="archivo" id="envoltura-archivo">
              <input id="c-archivo" type="file" accept=".pfx,.p12">
              <span class="caja">
                <svg viewBox="0 0 24 24"><path d="M12 16V4m0 0L8 8m4-4l4 4"/><path d="M4 16v3a1 1 0 001 1h14a1 1 0 001-1v-3"/></svg>
                <span class="nombre-archivo" id="nombre-archivo">Elegir archivo .pfx o .p12</span>
              </span>
            </span>
          </label>
          <label>Contraseña del certificado
            <input id="c-clave" type="password" placeholder="la que entregó el cliente"></label>
        </div>

        <div style="display:flex;align-items:center;gap:12px;margin-bottom:16px">
          <button id="btn-certificado">Cargar certificado</button>
          <span class="tenue" style="font-size:12.5px">
            Se cifra antes de guardarse y reemplaza al activo anterior.
          </span>
        </div>

        <div id="c-resultado"></div>

        ${estado.certificados.length === 0
                    ? `<div class="vacio" style="border-top:1px solid var(--borde)">
               Sin certificado. Esta empresa no puede firmar ni emitir.</div>`
                    : barraFiltro("certificado", estado.certificados.length,
                        filtrar("certificado").length) +
                    `<div id="tabla-certificado">${tablaCertificados()}</div>`}`;
        }

        function tablaCertificados() {
            const filas = filtrar("certificado");

            if (filas.length === 0)
                return `<div class="vacio">Ningún certificado coincide con la búsqueda.</div>`;

            return `<table>
          <tr><th>Titular</th><th>Vence</th><th>Firmó</th><th>Estado</th>
              <th style="text-align:right">Acciones</th></tr>
          ${filas.map(c => `<tr class="${c.id === estado.recien.certificado ? "recien" : ""}
                                        ${c.activo ? "" : "fila-inactiva"}">
            <td style="font-size:13px">${esc(c.subject)}</td>
            <td class="mono">${dia(c.validoHasta)}</td>
            <td>${c.comprobantesFirmados}</td>
            <td>${c.activo
                    ? `<span class="insignia ${c.diasParaVencer <= 30 ? "i-aviso" : "i-ok"}">
                     activo · ${c.diasParaVencer} d</span>`
                    : `<span class="insignia i-tenue">reemplazado</span>`}</td>
            <td style="text-align:right;white-space:nowrap">
              ${c.sePuedeEliminar
                    ? `<button class="mini peligro" data-borrar-cert="${c.id}">Eliminar</button>`
                    : `<span class="tenue" style="font-size:12px"
                     title="${c.activo
                        ? "Es el certificado en uso."
                        : "Firmó comprobantes: hay que conservarlo para poder verificar esas firmas."}">
                     ${c.activo ? "en uso" : "se conserva"}</span>`}
            </td>
          </tr>`).join("")}
        </table>`;
        }

        /// Busca el texto en cualquier campo de la fila.
        ///
        /// Se concatenan todos los valores en vez de comparar campo por campo:
        /// así el buscador sirve para lo que el usuario tenga en la cabeza, sea el
        /// número de serie, el tipo, una fecha o el nombre de una clave, sin que
        /// haya que anticipar por cuál va a buscar.
        function coincide(fila, filtro, extras = []) {
            const f = filtro.trim().toLowerCase();
            if (!f) return true;

            const texto = [...Object.values(fila), ...extras]
                .filter(v => v !== null && v !== undefined && typeof v !== "object")
                .join(" ")
                .toLowerCase();

            return texto.includes(f);
        }

        /// Cabecera con buscador y conteo, común a las tres pestañas.
        function barraFiltro(clave, total, visibles) {
            return `
        <div class="filtro-tabla">
          <div class="buscador">
            <svg viewBox="0 0 24 24"><circle cx="11" cy="11" r="7"/><path d="M20 20l-3.5-3.5"/></svg>
            <input id="f-${clave}" placeholder="Buscar" value="${esc(estado.filtro[clave])}">
          </div>
          <span class="conteo">${visibles === total
                    ? `${total} ${total === 1 ? "registro" : "registros"}`
                    : `${visibles} de ${total}`}</span>
        </div>`;
        }

        /// Reengancha el buscador sin repintar la pestaña entera, para no perder
        /// el foco ni el cursor mientras se escribe.
        function enlazarFiltro(clave, repintarTabla) {
            const campo = elem("f-" + clave);
            if (!campo) return;

            campo.oninput = () => {
                estado.filtro[clave] = campo.value;
                repintarTabla();

                const conteo = document.querySelector(".filtro-tabla .conteo");
                if (conteo) conteo.textContent = textoConteo(clave);
            };
        }

        function enlazarRevocar() {
            document.querySelectorAll("[data-revocar]").forEach(b =>
                b.onclick = () => revocar(b.dataset.revocar));
        }

        function enlazarAccionesSerie() {
            document.querySelectorAll("[data-borrar-serie]").forEach(b =>
                b.onclick = () => eliminarSerie(b.dataset.borrarSerie, b.dataset.serieNombre));

            document.querySelectorAll("[data-cerrar-serie]").forEach(b =>
                b.onclick = () => cambiarSerie(b.dataset.cerrarSerie, false, b.dataset.serieNombre));

            document.querySelectorAll("[data-abrir-serie]").forEach(b =>
                b.onclick = () => cambiarSerie(b.dataset.abrirSerie, true, b.dataset.serieNombre));
        }

        function enlazarAccionesCertificado() {
            document.querySelectorAll("[data-borrar-cert]").forEach(b =>
                b.onclick = () => eliminarCertificado(b.dataset.borrarCert));
        }

        function textoConteo(clave) {
            const total = estado[clave === "certificado" ? "certificados" : clave].length;
            const visibles = filtrar(clave).length;

            return visibles === total
                ? `${total} ${total === 1 ? "registro" : "registros"}`
                : `${visibles} de ${total}`;
        }

        function filtrar(clave) {
            const f = estado.filtro[clave];

            if (clave === "series")
                return estado.series.filter(x =>
                    coincide(x, f, [nombreTipo(x.tipoComprobante)]));

            if (clave === "claves")
                return estado.claves.filter(x => coincide(x, f));

            if (clave === "webhooks")
                return estado.webhooks.filter(x => coincide(x, f, x.eventos ?? []));

            return estado.certificados.filter(x => coincide(x, f));
        }

        // ------------------------------------------------------------------ marca
        //
        // Cómo ve a la empresa su cliente: el portal donde descarga sus
        // comprobantes, el correo que recibe y el PDF.
        //
        // LAS MISMAS REGLAS QUE Marca.cs Y QUE LA MIGRACIÓN 020. Las de aquí
        // solo sirven para avisar mientras se escribe; las que mandan son las
        // del servidor.

        const DOMINIO_PORTAL = "comprobantes.reyban.pe";

        const RESERVADOS = ["api", "e", "portal", "admin", "www", "static",
            "assets", "health", "docs"];

        function problemaIdentificador(v) {
            if (!v) return "";
            if (v.length < 3 || v.length > 40) return "Entre 3 y 40 caracteres.";
            if (!/^[a-z0-9][a-z0-9-]{1,38}[a-z0-9]$/.test(v))
                return "Solo minúsculas sin tilde, números y guiones, sin guion al principio ni al final.";
            if (v.includes("--")) return "Sin dos guiones seguidos.";
            if (RESERVADOS.includes(v)) return `«${v}» está reservado. Elige otro.`;
            return "";
        }

        /// Una sugerencia sacada del nombre. SOLO SE SUGIERE: el
        /// identificador no se puede cambiar después, así que lo decide una
        /// persona, no el nombre comercial, que sí puede cambiar.
        function sugerirIdentificador(t) {
            const base = (t.nombreComercial || t.razonSocial || "")
                .normalize("NFD").replace(/[\u0300-\u036f]/g, "")
                .toLowerCase()
                .replace(/\b(s\.?a\.?c\.?|e\.?i\.?r\.?l\.?|s\.?r\.?l\.?|s\.?a\.?a\.?|s\.?a\.?)$/, "")
                .replace(/[^a-z0-9]+/g, "-")
                .replace(/^-+|-+$/g, "")
                .slice(0, 40)
                .replace(/-+$/g, "");

            return problemaIdentificador(base) ? "" : base;
        }

        function vistaMarca() {
            const t = estado.seleccionada;
            const editar = puede("empresas.editar");
            const dis = editar ? "" : "disabled";
            const sugerido = sugerirIdentificador(t);

            return `
        <p class="ayuda" style="margin-top:0">
          Cómo ve a esta empresa su cliente: en el portal donde descarga sus
          comprobantes, en el correo que recibe y en el PDF.
        </p>

        <h2>Dirección del portal</h2>
        ${t.identificador
                    ? `<div class="direccion-portal">
               ${DOMINIO_PORTAL}/<strong class="mono" style="font-size:14px">${esc(t.identificador)}</strong>
             </div>
             <div class="tenue" style="font-size:12.5px;margin-bottom:22px">
               Ya no se puede cambiar: es la dirección que va en los correos enviados.
             </div>`
                    : `<div class="rejilla" style="margin-top:0">
               <label>Identificador
                 <input id="m-identificador" maxlength="40" ${dis}
                        placeholder="${esc(sugerido || "ferreteria-lopez")}">
                 <div class="err" id="e-identificador"></div></label>
             </div>
             <div class="direccion-portal tenue" id="m-direccion">
               ${DOMINIO_PORTAL}/<span class="mono">…</span>
             </div>
             <div class="tenue" style="font-size:12.5px;margin-bottom:22px;
                                      border-left:2px solid var(--aviso);padding-left:11px">
               <strong>Se pone una sola vez.</strong> Va en la dirección de cada
               correo que se mande a los clientes de esta empresa, y cambiarlo
               rompería esos enlaces. Minúsculas, números y guiones.
               ${sugerido && editar
                        ? `<a href="#" id="m-sugerencia" style="color:var(--acento)">Usar «${esc(sugerido)}»</a>`
                        : ""}
             </div>`}

        <h2>Correo y color</h2>
        <div class="rejilla" style="margin-top:0">
          <label>Correo de respuesta
            <input id="m-correo" type="email" maxlength="254" ${dis}
                   value="${esc(t.correoRespuesta ?? "")}" placeholder="ventas@empresa.pe">
            <div class="err" id="e-correo"></div></label>
          <label>Color de la marca
            <span class="muestra-color">
              <input id="m-color-elegir" type="color" ${dis}
                     value="${esc(t.colorMarca ?? "#2563eb")}" title="Elegir color">
              <input id="m-color" maxlength="7" ${dis}
                     value="${esc(t.colorMarca ?? "")}" placeholder="vacío: sin color">
            </span>
            <div class="err" id="e-color"></div></label>
        </div>

        <div class="tenue" style="font-size:12.5px;margin-bottom:14px">
          Las respuestas de sus clientes al correo del comprobante llegan a ese
          correo. <strong>Sin él, no se les manda correo.</strong>
        </div>

        ${editar ? `<button class="principal" id="btn-marca">Guardar</button>` : ""}

        <h2 style="margin-top:26px">Logo</h2>
        <div style="display:flex;gap:16px;align-items:center;flex-wrap:wrap;margin-bottom:10px">
          <div class="logo-caja">
            ${t.tieneLogo
                    ? `<img src="/admin/tenants/${t.id}/logo?v=${encodeURIComponent(t.logoVersion)}"
                      alt="Logo de ${esc(t.razonSocial)}">`
                    : `<span class="tenue">Sin logo</span>`}
          </div>

          ${editar ? `
            <div style="display:flex;gap:10px;align-items:center;flex-wrap:wrap">
              <span class="archivo" id="envoltura-logo" style="min-width:220px">
                <input id="l-archivo" type="file" accept=".png,.jpg,.jpeg,image/png,image/jpeg">
                <span class="caja">
                  <svg viewBox="0 0 24 24"><path d="M12 16V4m0 0L8 8m4-4l4 4"/><path d="M4 16v3a1 1 0 001 1h14a1 1 0 001-1v-3"/></svg>
                  <span class="nombre-archivo" id="nombre-logo">Elegir PNG o JPG</span>
                </span>
              </span>
              <button id="btn-logo">${t.tieneLogo ? "Cambiar logo" : "Subir logo"}</button>
            </div>` : ""}
        </div>

        <div class="tenue" style="font-size:12.5px">
          PNG o JPG, máximo 300 KB. En el PDF sale a la izquierda del recuadro del
          RUC, a 50 puntos de alto. Mejor con fondo transparente o blanco.
        </div>
        <div id="l-resultado"></div>`;
        }

        function enlazarMarca() {
            const campo = elem("m-identificador");

            if (campo) {
                const reflejar = () => {
                    const v = campo.value.trim().toLowerCase();
                    const problema = problemaIdentificador(v);

                    elem("e-identificador").textContent = problema;
                    campo.parentElement.classList.toggle("invalido", !!problema);

                    elem("m-direccion").innerHTML =
                        `${DOMINIO_PORTAL}/<span class="mono">${esc(v || "…")}</span>`;
                };

                campo.oninput = reflejar;

                const sugerencia = elem("m-sugerencia");
                if (sugerencia) sugerencia.onclick = ev => {
                    ev.preventDefault();
                    campo.value = sugerirIdentificador(estado.seleccionada);
                    reflejar();
                    campo.focus();
                };
            }

            // El selector de color y el texto se siguen el uno al otro. El
            // texto manda: vacío significa "sin color".
            const elegir = elem("m-color-elegir");
            const texto = elem("m-color");

            if (elegir && texto) {
                elegir.oninput = () => { texto.value = elegir.value; };
                texto.oninput = () => {
                    if (/^#[0-9a-fA-F]{6}$/.test(texto.value.trim()))
                        elegir.value = texto.value.trim().toLowerCase();
                };
            }

            if (elem("btn-marca")) elem("btn-marca").onclick = guardarMarca;
            if (elem("btn-logo")) elem("btn-logo").onclick = subirLogo;

            const archivo = elem("l-archivo");
            if (archivo) archivo.onchange = ev => {
                const f = ev.target.files[0];
                elem("nombre-logo").textContent = f ? f.name : "Elegir PNG o JPG";
                elem("envoltura-logo").classList.toggle("con-archivo", !!f);
            };
        }

        async function guardarMarca() {
            const t = estado.seleccionada;
            const campo = elem("m-identificador");
            const identificador = campo ? campo.value.trim().toLowerCase() : null;
            const correo = elem("m-correo").value.trim();
            const color = elem("m-color").value.trim().toLowerCase();

            let valido = true;

            const marcar = (id, mensaje) => {
                elem("e-" + id).textContent = mensaje;
                elem("m-" + id).parentElement.classList.toggle("invalido", !!mensaje);
                if (mensaje) valido = false;
            };

            if (campo) marcar("identificador", problemaIdentificador(identificador));

            marcar("correo", !correo || /^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(correo)
                ? "" : "No tiene forma de correo.");

            elem("e-color").textContent =
                !color || /^#[0-9a-f]{6}$/.test(color) ? "" : "Tiene que ir como #rrggbb.";
            if (elem("e-color").textContent) valido = false;

            if (!valido) return;

            // FIJAR EL IDENTIFICADOR SE CONFIRMA APARTE, porque no tiene vuelta.
            if (identificador) {
                const seguro = await confirmar(
                    "Fijar la dirección del portal",
                    `La dirección de ${t.razonSocial} será ${DOMINIO_PORTAL}/${identificador}. ` +
                    "No se podrá cambiar nunca: va en cada correo que se mande a sus clientes.",
                    "Sí, fijarla");

                if (!seguro) return;
            }

            const boton = elem("btn-marca");
            boton.disabled = true;

            try {
                await api(`/admin/tenants/${t.id}/marca`, {
                    method: "PUT",
                    headers: { "Content-Type": "application/json" },
                    body: JSON.stringify({
                        identificador: identificador || null,
                        colorMarca: color || null,
                        correoRespuesta: correo || null
                    })
                });

                avisar("Marca guardada", "", "ok");
                await recargar();

            } catch (ex) {
                avisar(ex.message, ex.detalle, "mal");
                boton.disabled = false;
            }
        }

        async function subirLogo() {
            const archivo = elem("l-archivo").files[0];
            const resultado = elem("l-resultado");

            if (!archivo) {
                resultado.innerHTML =
                    `<div style="color:var(--mal);margin-top:10px">Elige el archivo del logo.</div>`;
                return;
            }

            // Se avisa antes de subir para no gastar el viaje. El servidor lo
            // vuelve a comprobar, y además mira que de verdad sea PNG o JPG.
            if (archivo.size > 300 * 1024) {
                resultado.innerHTML =
                    `<div style="color:var(--mal);margin-top:10px">Pesa
                 ${Math.ceil(archivo.size / 1024)} KB y el máximo es 300 KB.</div>`;
                return;
            }

            const datos = new FormData();
            datos.append("archivo", archivo);

            const boton = elem("btn-logo");
            boton.disabled = true;
            resultado.innerHTML = `<div class="tenue" style="margin-top:10px">Comprobando y guardando…</div>`;

            try {
                const r = await api(`/admin/tenants/${estado.seleccionada.id}/logo`,
                    { method: "POST", body: datos });

                avisar("Logo guardado", r.mensaje, "ok");
                await recargar();

            } catch (ex) {
                resultado.innerHTML =
                    `<div style="color:var(--mal);margin-top:10px">${esc(ex.message)}<br>
             <span class="tenue">${esc(ex.detalle || "")}</span></div>`;
                boton.disabled = false;
            }
        }

        function vistaProduccion() {
            const t = estado.seleccionada;
            const r = estado.revision;

            return `
        <div style="background:var(--sutil);border-radius:var(--radio);
                    padding:13px 15px;margin-bottom:18px">
          <div style="display:flex;align-items:center;justify-content:space-between;
                      gap:12px;flex-wrap:wrap">
            <div>
              <div style="font-size:14px">Ambiente actual:
                <strong>${t.ambiente === "produccion" ? "Producción" : "Beta (pruebas)"}</strong>
              </div>
              <div class="tenue" style="font-size:12.5px;margin-top:2px">
                ${t.ambiente === "produccion"
                    ? "Los comprobantes van a SUNAT de verdad y tienen valor legal."
                    : "Los comprobantes van al ambiente de pruebas y no tienen validez."}
              </div>
            </div>
            <button id="btn-ambiente" class="${t.ambiente === "produccion" ? "" : "principal"}">
              ${t.ambiente === "produccion" ? "Volver a pruebas" : "Pasar a producción"}
            </button>
          </div>
        </div>

        <h2>Credenciales SOL</h2>
        <div class="rejilla" style="margin-top:0">
          <label>Usuario SOL secundario
            <input id="s-usuario" placeholder="FACTURA01"
                   value="${esc(t.usuarioSol && t.usuarioSol !== "MODDATOS" ? t.usuarioSol : "")}">
            <div class="err" id="e-usuario"></div></label>
          <label>Clave SOL
            <input id="s-clave" type="password"
                   placeholder="${t.tieneClaveSol ? "•••••• (guardada)" : "la del usuario secundario"}">
          </label>
        </div>

        <div style="display:flex;align-items:center;gap:12px;margin-bottom:18px">
          <button id="btn-sol">Guardar credenciales</button>
          <span class="tenue" style="font-size:12.5px">
            La clave se cifra igual que el certificado.
          </span>
        </div>

        <div class="tenue" style="font-size:12.5px;margin-bottom:22px;
                                  border-left:2px solid var(--borde);padding-left:11px">
          Debe ser el usuario SOL <strong>secundario</strong> del contribuyente,
          nunca el principal. El principal puede declarar, pagar y modificar datos
          en el portal de SUNAT, y ese nivel de acceso no tiene por qué vivir aquí.
        </div>

        <h2>Guías de remisión</h2>
        <p class="ayuda" style="margin-top:0">
          Las guías usan un canal distinto al de las facturas: no es SOAP con
          clave SOL, sino una API REST con credenciales propias. El contribuyente
          las genera en su menú SOL, opción &laquo;Credenciales de API SUNAT&raquo;.
        </p>

        <div style="display:flex;align-items:center;gap:12px;margin-bottom:14px">
          ${t.greListo
                    ? `<span class="insignia i-ok">habilitadas</span>`
                    : `<span class="insignia i-tenue">sin configurar</span>`}
          ${t.greClientId
                    ? `<span class="tenue mono" style="font-size:12.5px">
                 ${esc(t.greClientId)}</span>` : ""}
        </div>

        <div class="rejilla" style="margin-top:0">
          <label>client_id
            <input id="g-client" placeholder="el que generó en su menú SOL"
                   value="${esc(t.greClientId ?? "")}"></label>
          <label>client_secret
            <input id="g-secret" type="password"
                   placeholder="${t.tieneGreSecret ? "•••••• (guardado)" : "el secreto"}">
          </label>
        </div>

        <div style="display:flex;align-items:center;gap:12px;margin-bottom:22px">
          <button id="btn-gre">Guardar credenciales de guías</button>
          <span class="tenue" style="font-size:12.5px">
            El secreto se cifra igual que el certificado.
          </span>
        </div>

        <h2>Revisión previa</h2>
        ${r.listo
                    ? `<div class="secreto">Todo listo. Esta empresa puede emitir en producción.</div>`
                    : `<div style="background:var(--mal-fondo);border:1px solid var(--mal);
                         border-radius:var(--radio);padding:13px 15px">
               <strong style="color:var(--mal)">Falta lo siguiente:</strong>
               <ul style="margin:8px 0 0;padding-left:20px;font-size:13.5px">
                 ${r.faltantes.map(f => `<li>${esc(f)}</li>`).join("")}
               </ul>
             </div>`}

        ${r.advertencias.length === 0 ? "" : `
          <div style="background:var(--aviso-fondo);border:1px solid var(--aviso);
                      border-radius:var(--radio);padding:13px 15px;margin-top:12px">
            <strong style="color:var(--aviso)">Conviene revisar:</strong>
            <ul style="margin:8px 0 0;padding-left:20px;font-size:13.5px">
              ${r.advertencias.map(a => `<li>${esc(a)}</li>`).join("")}
            </ul>
          </div>`}`;
        }

        async function guardarCredenciales() {
            const usuario = elem("s-usuario").value.trim();
            const clave = elem("s-clave").value;

            elem("e-usuario").textContent = "";

            if (!usuario) {
                elem("e-usuario").textContent = "Escribe el usuario SOL.";
                return;
            }

            if (!clave) {
                avisar("Falta la clave SOL",
                    "Escríbela aunque ya hubiera una guardada: no se puede leer.", "mal");
                return;
            }

            const boton = elem("btn-sol");
            boton.disabled = true;

            try {
                await api(`/admin/tenants/${estado.seleccionada.id}/credenciales-sol`, {
                    method: "POST",
                    headers: { "Content-Type": "application/json" },
                    body: JSON.stringify({ usuario, clave })
                });

                avisar("Credenciales guardadas y cifradas", "", "ok");

                elem("s-clave").value = "";
                await recargar();

            } catch (e) {
                avisar(e.message, e.detalle, "mal");
            } finally {
                boton.disabled = false;
            }
        }

        async function guardarCredencialesGre() {
            const clientId = elem("g-client").value.trim();
            const secret = elem("g-secret").value;

            if (!clientId) {
                avisar("Falta el client_id", "", "mal");
                return;
            }

            if (!secret) {
                avisar("Falta el client_secret",
                    "Escríbelo aunque ya hubiera uno guardado: no se puede leer.", "mal");
                return;
            }

            const boton = elem("btn-gre");
            boton.disabled = true;

            try {
                const r = await api(`/admin/tenants/${estado.seleccionada.id}/credenciales-gre`, {
                    method: "POST",
                    headers: { "Content-Type": "application/json" },
                    body: JSON.stringify({ clientId, clientSecret: secret })
                });

                avisar("Credenciales de guías guardadas", r.mensaje, "ok");

                elem("g-secret").value = "";
                await recargar();

            } catch (e) {
                avisar(e.message, e.detalle, "mal");
            } finally {
                boton.disabled = false;
            }
        }

        async function cambiarAmbiente() {
            const t = estado.seleccionada;
            const aProduccion = t.ambiente !== "produccion";

            const seguro = await confirmar(
                aProduccion ? "Pasar a producción" : "Volver al ambiente de pruebas",

                aProduccion
                    ? `${t.razonSocial} empezará a emitir comprobantes REALES ante SUNAT, ` +
                    "con valor legal. Los correlativos que consuma no se pueden recuperar."
                    : `${t.razonSocial} volverá a emitir contra el ambiente de pruebas. ` +
                    "Los comprobantes que emita dejarán de tener validez legal.",

                aProduccion ? "Pasar a producción" : "Volver a pruebas");

            if (!seguro) return;

            try {
                const r = await api(`/admin/tenants/${t.id}/ambiente`, {
                    method: "POST",
                    headers: { "Content-Type": "application/json" },
                    body: JSON.stringify({ ambiente: aProduccion ? "produccion" : "beta" })
                });

                avisar(r.mensaje,
                    r.advertencias?.length ? r.advertencias.join(" ") : "", "ok");

                await recargar();

            } catch (e) {
                avisar(e.message, e.detalle, "mal");
            }
        }

        function vistaWebhooks() {
            return `
        <div class="rejilla" style="margin-top:0">
          <label>Nombre<input id="w-nombre" placeholder="ERP del cliente"></label>
          <label>URL de destino
            <input id="w-url" placeholder="https://sistema-del-cliente.com/avisos">
            <div class="err" id="e-url"></div></label>
        </div>

        <div style="display:flex;align-items:center;gap:12px;margin-bottom:16px">
          <button id="btn-webhook">Registrar webhook</button>
          <span class="tenue" style="font-size:12.5px">
            El secreto de firma se muestra una sola vez.
          </span>
        </div>

        <div id="w-resultado"></div>

        ${estado.webhooks.length === 0
                    ? `<div class="vacio" style="border-top:1px solid var(--borde)">
               Sin webhooks. El cliente tendrá que consultar el estado por su cuenta.
               Si usa la plataforma, se registra solo al pulsar «Conectar» allí.</div>`
                    : barraFiltro("webhooks", estado.webhooks.length,
                        filtrar("webhooks").length) +
                    `<div id="tabla-webhooks">${tablaWebhooks()}</div>`}

        ${estado.entregas.length === 0 ? "" : `
          <h2 style="margin-top:26px">Últimas entregas</h2>
          ${tablaEntregas()}`}

        ${estado.cambiosWebhook.length === 0 ? "" : `
          <h2 style="margin-top:26px">Cambios</h2>
          <p class="tenue" style="font-size:12.5px;margin:-4px 0 10px">
            Altas y rotaciones hechas con una clave de acceso, y activaciones desde
            aquí. Si ves un cambio que no esperabas, busca ese prefijo en
            <strong>Claves de acceso</strong> y revócala.</p>
          ${tablaCambiosWebhook()}`}`;
        }

        const nombreAccionWebhook = a => ({
            alta: "Registrado",
            rotacion: "Secreto rotado",
            activado: "Activado",
            desactivado: "Desactivado"
        }[a] || a);

        function tablaCambiosWebhook() {
            return `<table>
          <tr><th>Cuándo</th><th>Qué</th><th>URL</th><th>Quién</th></tr>
          ${estado.cambiosWebhook.map(c => `<tr>
            <td class="tenue" style="white-space:nowrap">${fechaHora(c.creadoEn)}</td>
            <td>${esc(nombreAccionWebhook(c.accion))}</td>
            <td class="mono recorte" style="max-width:300px;font-size:12.5px"
                title="${esc(c.urlAntes && c.urlAntes !== c.urlDespues
                    ? `${c.urlAntes} → ${c.urlDespues}` : c.urlDespues)}">
              ${c.urlAntes && c.urlAntes !== c.urlDespues
                    ? `<span class="tenue">${esc(c.urlAntes)}</span> → ` : ""}${esc(c.urlDespues)}</td>
            <td>${c.hechoDesde === "api"
                    ? `<span class="mono" style="font-size:12.5px">${esc(c.prefijoClave ?? "")}…</span>`
                    : `<span class="tenue">panel</span>`}</td>
          </tr>`).join("")}
        </table>`;
        }

        function tablaWebhooks() {
            const filas = filtrar("webhooks");

            if (filas.length === 0)
                return `<div class="vacio">Ningún webhook coincide con la búsqueda.</div>`;

            return `<table>
          <tr><th>Nombre</th><th>URL</th><th>Pendientes</th><th>Agotadas</th>
              <th>Estado</th><th style="text-align:right">Acciones</th></tr>
          ${filas.map(w => `<tr class="${w.id === estado.recien.webhooks ? "recien" : ""}
                                        ${w.activo ? "" : "fila-inactiva"}">
            <td>${esc(w.nombre)}
              ${w.origen === "api"
                    ? `<div style="margin-top:4px"><span class="insignia i-api"
                         title="Lo registró la plataforma con la clave de la empresa. La URL y el secreto los mantiene ella al conectar; aquí solo se prueba o se desactiva.">registrado por la API</span></div>`
                    : ""}</td>
            <td class="mono recorte" title="${esc(w.url)}"
                style="max-width:230px">${esc(w.url)}</td>
            <td>${w.pendientes}</td>
            <td class="${w.agotados > 0 ? "mal" : ""}">${w.agotados}</td>
            <td title="Secreto vigente desde ${esc(fechaHora(w.secretoCambiadoEn))}">${w.activo
                    ? `<span class="insignia i-ok">activo</span>`
                    : `<span class="insignia i-tenue">inactivo</span>`}</td>
            <td style="text-align:right;white-space:nowrap">
              <button class="mini" data-probar-wh="${w.id}">Probar</button>
              <button class="mini" data-alternar-wh="${w.id}"
                      data-activo="${w.activo}">${w.activo ? "Desactivar" : "Activar"}</button>
            </td>
          </tr>`).join("")}
        </table>`;
        }

        function tablaEntregas() {
            return `<table>
          <tr><th>Evento</th><th>Estado</th><th>Intentos</th><th>Detalle</th>
              <th>Cuándo</th><th></th></tr>
          ${estado.entregas.map(e => `<tr>
            <td class="mono" style="font-size:12.5px">${esc(e.tipo)}</td>
            <td>${insigniaEntrega(e.estado)}</td>
            <td>${e.intentos}</td>
            <td class="recorte tenue" style="max-width:260px"
                title="${esc(e.ultimoError ?? "")}">
              ${e.ultimoCodigo ? `HTTP ${e.ultimoCodigo}` : ""}
              ${esc(e.ultimoError ?? "")}</td>
            <td class="tenue">${fechaHora(e.creadoEn)}</td>
            <td>${e.estado === "AGOTADO"
                    ? `<button class="mini" data-reintentar-entrega="${e.id}">Reintentar</button>`
                    : ""}</td>
          </tr>`).join("")}
        </table>`;
        }

        const insigniaEntrega = estado => ({
            ENTREGADO: `<span class="insignia i-ok">entregado</span>`,
            PENDIENTE: `<span class="insignia i-aviso">pendiente</span>`,
            AGOTADO: `<span class="insignia i-mal">agotado</span>`
        }[estado] || esc(estado));

        function enlazarAccionesWebhook() {
            document.querySelectorAll("[data-probar-wh]").forEach(b =>
                b.onclick = () => probarWebhook(b.dataset.probarWh));

            document.querySelectorAll("[data-alternar-wh]").forEach(b =>
                b.onclick = () => alternarWebhook(
                    b.dataset.alternarWh, b.dataset.activo !== "true"));

            document.querySelectorAll("[data-reintentar-entrega]").forEach(b =>
                b.onclick = () => reintentarEntrega(b.dataset.reintentarEntrega));
        }

        async function crearWebhook() {
            const url = elem("w-url").value.trim();
            const caja = elem("e-url");

            if (!/^https?:\/\/.+/i.test(url)) {
                caja.textContent = "Debe ser una dirección completa, con https:// delante.";
                elem("w-url").parentElement.classList.add("invalido");
                return;
            }

            caja.textContent = "";
            elem("w-url").parentElement.classList.remove("invalido");

            const boton = elem("btn-webhook");
            boton.disabled = true;

            try {
                const r = await api(`/admin/tenants/${estado.seleccionada.id}/webhooks`, {
                    method: "POST",
                    headers: { "Content-Type": "application/json" },
                    body: JSON.stringify({
                        nombre: elem("w-nombre").value.trim() || "Sin nombre",
                        url,
                        eventos: []
                    })
                });

                // Igual que con las claves: el secreto se muestra fijo, no como aviso
                // flotante. Es la única vez que existe fuera del cliente.
                elem("w-resultado").innerHTML = `
          <div class="secreto">
            <strong>Entrega este secreto al cliente ahora.</strong>
            <code>${esc(r.secreto)}</code>
            <button class="mini" id="btn-copiar-secreto">Copiar</button>
            <div class="tenue" style="font-size:12.5px;margin-top:8px">${esc(r.aviso)}</div>
          </div>`;

                elem("btn-copiar-secreto").onclick = async () => {
                    await navigator.clipboard.writeText(r.secreto);
                    avisar("Secreto copiado", "", "ok");
                };

                elem("w-nombre").value = "";
                elem("w-url").value = "";

                marcarRecien("webhooks", r.id);

                estado.webhooks = await api(`/admin/tenants/${estado.seleccionada.id}/webhooks`);

                const tabla = elem("tabla-webhooks");
                if (tabla) { tabla.innerHTML = tablaWebhooks(); enlazarAccionesWebhook(); }
                else cargarPestana();

            } catch (e) {
                avisar(e.message, e.detalle, "mal");
            } finally {
                boton.disabled = false;
            }
        }

        async function probarWebhook(id) {
            try {
                const r = await api(
                    `/admin/tenants/${estado.seleccionada.id}/webhooks/${id}/prueba`,
                    { method: "POST" });

                avisar("Aviso de prueba encolado", r.mensaje, "ok");

                // Se espera al ciclo del despachador antes de refrescar, o la entrega
                // aparecería siempre como pendiente y parecería que no funciona.
                setTimeout(() => {
                    if (estado.pestana === "webhooks") cargarPestana();
                }, 12000);

            } catch (e) { avisar(e.message, e.detalle, "mal"); }
        }

        async function alternarWebhook(id, activar) {
            // Desactivar el de la API deja a la plataforma sin avisos de SUNAT
            // hasta que alguien pulse «Conectar» otra vez. Se pregunta antes.
            const w = estado.webhooks.find(x => x.id === id);

            if (!activar && w && w.origen === "api") {
                const seguro = await confirmar(
                    "Desactivar el webhook de la API",
                    "La plataforma dejará de enterarse de lo que responde SUNAT para " +
                    "esta empresa, y sus comprobantes se quedarán «en camino». Volverá " +
                    "a funcionar cuando se pulse «Conectar» en la plataforma.",
                    "Desactivar");

                if (!seguro) return;
            }

            try {
                await api(`/admin/tenants/${estado.seleccionada.id}/webhooks/${id}`, {
                    method: "PATCH",
                    headers: { "Content-Type": "application/json" },
                    body: JSON.stringify({ activo: activar })
                });

                avisar(activar ? "Webhook activado" : "Webhook desactivado", "", "ok");
                await cargarPestana();

            } catch (e) { avisar(e.message, e.detalle, "mal"); }
        }

        async function reintentarEntrega(id) {
            try {
                await api(`/admin/webhook-entregas/${id}/reintentar`, { method: "POST" });

                avisar("Entrega devuelta a la cola",
                    "Se enviará en el siguiente ciclo.", "ok");

                setTimeout(() => {
                    if (estado.pestana === "webhooks") cargarPestana();
                }, 12000);

            } catch (e) { avisar(e.message, e.detalle, "mal"); }
        }

        // LOS NUEVE TIPOS QUE EL SISTEMA EMITE.
        //
        // Faltaban seis, y el panel los enseñaba como el número crudo. Peor aún: el
        // desplegable de "agregar serie" solo ofrecía cuatro, así que una empresa
        // nueva no podía recibir su L001, su R001 ni su V001 desde aquí.
        const nombreTipo = t => ({
            "01": "Factura",
            "03": "Boleta",
            "04": "Liquidación de compra",
            "07": "Nota de crédito",
            "08": "Nota de débito",
            "09": "Guía de remisión remitente",
            "20": "Comprobante de retención",
            "31": "Guía de remisión transportista",
            "40": "Comprobante de percepción"
        }[t] || t);

        // LA INICIAL DE LA SERIE LA FIJA SUNAT y no es negociable. Se usa para
        // sugerir el ejemplo correcto al cambiar de tipo, porque teclear "F001" en
        // una liquidación es el error más fácil de cometer aquí.
        const serieSugerida = t =>
        ({
            "01": "F001", "03": "B001", "04": "L001", "07": "F001", "08": "F001",
            "09": "T001", "20": "R001", "31": "V001", "40": "P001"
        }[t] || "F001");

        // ----------------------------------------------------------------- acciones

        function seleccionar(id) {
            estado.seleccionada = estado.empresas.find(e => e.id === id);

            // La primera pestaña que el usuario pueda ver, no siempre "series":
            // alguien sin empresas.ver no debería aterrizar en una pantalla vacía.
            const visibles = pestanasVisibles();
            estado.pestana = visibles[0] ?? "series";

            pintar();
        }

        async function recargar() {
            const id = estado.seleccionada?.id;
            estado.empresas = await api("/admin/tenants");
            estado.seleccionada = id ? estado.empresas.find(e => e.id === id) : null;
            pintar();
        }

        function abrirNueva() {
            ["ruc", "razon", "identificador"].forEach(c => {
                elem("e-" + c).textContent = "";
                elem("n-" + c).parentElement.classList.remove("invalido");
            });

            elem("velo-nueva").classList.add("visible");
            elem("n-ruc").focus();
        }

        elem("nv-cancelar").onclick = () =>
            elem("velo-nueva").classList.remove("visible");

        elem("nv-crear").onclick = crearEmpresa;

        async function crearEmpresa() {
            const ruc = elem("n-ruc").value.trim();
            const razon = elem("n-razon").value.trim();

            let valido = true;

            const marcar = (campo, mensaje) => {
                elem("e-" + campo).textContent = mensaje;
                elem("n-" + campo).parentElement.classList.toggle("invalido", !!mensaje);
                if (mensaje) valido = false;
            };

            // Validar antes de llamar no sustituye la validación del servidor, que es
            // la que de verdad protege. Solo evita un viaje y señala el campo exacto.
            marcar("ruc", /^\d{11}$/.test(ruc) ? "" : "Debe tener 11 dígitos.");
            marcar("razon", razon.length >= 3 ? "" : "Escribe la razón social.");

            const identificador = elem("n-identificador").value.trim().toLowerCase();
            marcar("identificador", problemaIdentificador(identificador));

            if (!valido) return;

            const boton = elem("nv-crear");
            boton.disabled = true;

            try {
                await api("/admin/tenants", {
                    method: "POST",
                    headers: { "Content-Type": "application/json" },
                    body: JSON.stringify({
                        ruc, razonSocial: razon,
                        nombreComercial: elem("n-comercial").value.trim(),
                        direccion: elem("n-direccion").value.trim(),
                        distrito: elem("n-distrito").value.trim(),
                        provincia: elem("n-provincia").value.trim(),
                        departamento: elem("n-departamento").value.trim(),
                        ubigeo: elem("n-ubigeo").value.trim(),
                        ambiente: elem("n-ambiente").value,
                        usuarioSol: elem("n-sol").value.trim(),
                        identificador: identificador || null,
                        maxConcurrencia: 1
                    })
                });

                elem("velo-nueva").classList.remove("visible");
                elem("n-ruc").value = "";
                elem("n-razon").value = "";
                elem("n-comercial").value = "";
                elem("n-direccion").value = "";
                elem("n-identificador").value = "";

                avisar("Empresa creada",
                    "Ahora hace falta el certificado, una serie y una clave.", "ok");

                await recargar();

            } catch (e) {
                avisar(e.message, e.detalle, "mal");
            } finally {
                boton.disabled = false;
            }
        }

        async function alternarActiva() {
            const t = estado.seleccionada;

            if (t.activo) {
                const seguro = await confirmar(
                    "Desactivar empresa",
                    `${t.razonSocial} dejará de poder emitir de inmediato y sus claves ` +
                    `dejarán de funcionar. Los comprobantes ya emitidos no se ven afectados.`,
                    "Desactivar");

                if (!seguro) return;
            }

            try {
                await api(`/admin/tenants/${t.id}`, {
                    method: "PATCH",
                    headers: { "Content-Type": "application/json" },
                    body: JSON.stringify({ activo: !t.activo })
                });

                avisar(t.activo ? "Empresa desactivada" : "Empresa activada", "", "ok");
                await recargar();

            } catch (e) { avisar(e.message, e.detalle, "mal"); }
        }

        /// Resalta lo recién creado y quita la marca a los pocos segundos.
        ///
        /// Dejarla fija haría que, tras varias altas, media tabla quedara marcada
        /// y la marca dejaría de significar nada.
        function marcarRecien(pestana, id) {
            estado.recien[pestana] = id;

            setTimeout(() => {
                if (estado.recien[pestana] !== id) return;

                estado.recien[pestana] = null;

                const tabla = elem("tabla-" + pestana);
                if (!tabla) return;

                if (pestana === "series") {
                    tabla.innerHTML = tablaSeries();
                    enlazarAccionesSerie();
                } else if (pestana === "claves") {
                    tabla.innerHTML = tablaClaves();
                    enlazarRevocar();
                } else {
                    tabla.innerHTML = tablaCertificados();
                    enlazarAccionesCertificado();
                }
            }, 6000);
        }

        async function crearSerie() {
            const serie = elem("s-serie").value.trim().toUpperCase();

            if (serie.length !== 4) {
                elem("e-serie").textContent = "Debe tener 4 caracteres. Ej: F001, B001.";
                elem("s-serie").parentElement.classList.add("invalido");
                return;
            }

            elem("e-serie").textContent = "";
            elem("s-serie").parentElement.classList.remove("invalido");

            const boton = elem("btn-serie");
            boton.disabled = true;

            try {
                const creada = await api(`/admin/tenants/${estado.seleccionada.id}/series`, {
                    method: "POST",
                    headers: { "Content-Type": "application/json" },
                    body: JSON.stringify({
                        tipoComprobante: elem("s-tipo").value,
                        serie,
                        correlativoInicial: parseInt(elem("s-corr").value || "0", 10)
                    })
                });

                marcarRecien("series", creada.id);

                avisar(`Serie ${serie} lista`,
                    "Si ya existía, solo se reactivó: el correlativo no cambió.", "ok");

                elem("s-serie").value = "";
                elem("s-corr").value = "0";

                await recargar();



            } catch (e) {
                avisar(e.message, e.detalle, "mal");
                boton.disabled = false;
            }
        }

        async function crearClave() {
            const boton = elem("btn-clave");
            boton.disabled = true;

            try {
                const r = await api(`/admin/tenants/${estado.seleccionada.id}/claves`, {
                    method: "POST",
                    headers: { "Content-Type": "application/json" },
                    body: JSON.stringify({
                        nombre: elem("k-nombre").value.trim() || "Sin nombre",
                        produccion: estado.seleccionada.ambiente === "produccion"
                    })
                });

                // Se muestra fija, no como aviso flotante: es la única vez que este valor
                // existe fuera del cliente. Un aviso que desaparece solo sería un error.
                elem("k-resultado").innerHTML = `
          <div class="secreto">
            <strong>Copia esta clave ahora y entrégasela al cliente.</strong>
            <code>${esc(r.clave)}</code>
            <button class="mini" id="btn-copiar">Copiar</button>
            <div class="tenue" style="font-size:12.5px;margin-top:8px">${esc(r.aviso)}</div>
          </div>`;

                elem("btn-copiar").onclick = async () => {
                    await navigator.clipboard.writeText(r.clave);
                    avisar("Clave copiada", "", "ok");
                };

                marcarRecien("claves", r.id);

                // Se actualiza la lista sin repintar el detalle, para no borrar la clave
                // que el operador todavía no ha copiado.
                estado.claves = await api(`/admin/tenants/${estado.seleccionada.id}/claves`);
                estado.empresas = await api("/admin/tenants");

                const tabla = elem("tabla-claves");
                if (tabla) { tabla.innerHTML = tablaClaves(); enlazarRevocar(); }

            } catch (e) {
                avisar(e.message, e.detalle, "mal");
            } finally {
                boton.disabled = false;
            }
        }

        async function eliminarSerie(id, nombre) {
            const seguro = await confirmar(
                `Eliminar la serie ${nombre}`,
                "Esta serie nunca emitió comprobantes, así que se puede borrar sin " +
                "consecuencias. Si después la necesitas, hay que volver a darla de alta.",
                "Eliminar");

            if (!seguro) return;

            try {
                await api(`/admin/tenants/${estado.seleccionada.id}/series/${id}`,
                    { method: "DELETE" });

                avisar(`Serie ${nombre} eliminada`, "", "ok");
                await recargar();

            } catch (e) { avisar(e.message, e.detalle, "mal"); }
        }

        async function cambiarSerie(id, activar, nombre) {
            if (!activar) {
                const seguro = await confirmar(
                    `Cerrar la serie ${nombre}`,
                    "Dejará de poder emitir comprobantes. Los que ya emitió NO se tocan: " +
                    "siguen consultándose y descargándose igual. Puedes reactivarla después.",
                    "Cerrar serie");

                if (!seguro) return;
            }

            try {
                await api(`/admin/tenants/${estado.seleccionada.id}/series/${id}`, {
                    method: "PATCH",
                    headers: { "Content-Type": "application/json" },
                    body: JSON.stringify({ activo: activar })
                });

                avisar(activar ? `Serie ${nombre} reactivada` : `Serie ${nombre} cerrada`,
                    "", "ok");

                await recargar();

            } catch (e) { avisar(e.message, e.detalle, "mal"); }
        }

        async function eliminarCertificado(id) {
            const seguro = await confirmar(
                "Eliminar certificado",
                "Este certificado nunca firmó comprobantes y no está en uso, así que se " +
                "puede borrar. Es lo que se hace cuando se cargó el archivo equivocado.",
                "Eliminar");

            if (!seguro) return;

            try {
                await api(`/admin/tenants/${estado.seleccionada.id}/certificados/${id}`,
                    { method: "DELETE" });

                avisar("Certificado eliminado", "", "ok");
                await recargar();

            } catch (e) { avisar(e.message, e.detalle, "mal"); }
        }

        async function revocar(id) {
            const seguro = await confirmar(
                "Revocar clave",
                "El sistema que la use dejará de poder emitir de inmediato. No se puede " +
                "deshacer: habría que emitir una clave nueva.",
                "Revocar");

            if (!seguro) return;

            try {
                await api(`/admin/claves/${id}`, { method: "DELETE" });
                avisar("Clave revocada", "", "ok");
                await recargar();
            } catch (e) { avisar(e.message, e.detalle, "mal"); }
        }

        async function subirCertificado() {
            const archivo = elem("c-archivo").files[0];
            const resultado = elem("c-resultado");

            if (!archivo) {
                resultado.innerHTML =
                    `<div style="color:var(--mal);margin-top:10px">Elige el archivo .pfx.</div>`;
                return;
            }

            // LA CONTRASEÑA VA EN EL CUERPO, NO EN LA DIRECCIÓN. Una dirección
            // queda escrita en los registros del proxy y de cualquier
            // intermediario; el cuerpo no.
            const datos = new FormData();
            datos.append("archivo", archivo);
            datos.append("clave", elem("c-clave").value);

            const boton = elem("btn-certificado");
            boton.disabled = true;
            resultado.innerHTML = `<div class="tenue" style="margin-top:10px">Cifrando y guardando…</div>`;

            try {
                const cargado = await api(
                    `/admin/tenants/${estado.seleccionada.id}/certificado`,
                    { method: "POST", body: datos });

                avisar("Certificado cargado y cifrado", "", "ok");

                elem("c-clave").value = "";

                await recargar();
                marcarRecien("certificado", cargado.id);

            } catch (e) {
                resultado.innerHTML =
                    `<div style="color:var(--mal);margin-top:10px">${esc(e.message)}<br>
             <span class="tenue">${esc(e.detalle || "")}</span></div>`;

                boton.disabled = false;
            }
        }

        cargarUsuario().then(ok => { if (ok) iniciar(); });
    </script>
</body>
</html>
'@

# --- Facturacion.Worker\DespachadorWebhooks.cs
Planear 'Facturacion.Worker\DespachadorWebhooks.cs' '89A812B4005CD15647CDF33A1AB29E4667BA20CBF779C17ADCDAE12AC4FBF261' @'
using System.Diagnostics;
using System.Security.Cryptography;
using System.Text;
using Facturacion.Persistencia;

namespace Facturacion.Worker;

/// <summary>
/// Entrega los avisos a los sistemas de los clientes.
///
/// CÓMO SE FIRMA CADA ENVÍO, Y POR QUÉ IMPORTA:
///
/// La URL de un webhook es pública: está abierta a internet esperando
/// peticiones. Si no se firmara nada, cualquiera que la descubriera podría
/// enviarle al cliente un aviso falso diciendo que una factura de diez mil
/// soles fue aceptada.
///
/// Por eso cada envío lleva dos cabeceras:
///
///   X-Facturacion-Timestamp   momento del envío
///   X-Facturacion-Firma       HMAC-SHA256 de "timestamp.cuerpo"
///
/// El cliente recalcula ese HMAC con el secreto que le dimos y compara. Si
/// no coincide, descarta el mensaje.
///
/// El timestamp entra en la firma a propósito: sin él, alguien que capturara
/// un aviso legítimo podría reenviarlo tal cual más tarde y el cliente lo
/// daría por bueno. Con él, basta rechazar los mensajes demasiado viejos.
/// </summary>
public sealed class DespachadorWebhooks
{
    /// <summary>
    /// Tras estos intentos la entrega se da por perdida.
    ///
    /// Con la escalera de espera, ocho intentos cubren varias horas. Si el
    /// servidor del cliente sigue caído después de eso, insistir no ayuda:
    /// el problema es suyo y alguien tiene que avisarle.
    /// </summary>
    public const int MaximoIntentos = 8;

    private readonly RepositorioWebhooks _webhooks;
    private readonly HttpClient _http;
    private readonly ReglasDestinoWebhook _reglas;
    private readonly ILogger<DespachadorWebhooks> _log;

    public DespachadorWebhooks(
        RepositorioWebhooks webhooks,
        IHttpClientFactory fabricaHttp,
        ReglasDestinoWebhook reglas,
        ILogger<DespachadorWebhooks> log)
    {
        _webhooks = webhooks;
        _reglas = reglas;
        _log = log;

        _http = fabricaHttp.CreateClient("webhooks");

        // Un cliente lento no debe retener el despachador. Diez segundos es
        // generoso para recibir un aviso y responder.
        _http.Timeout = TimeSpan.FromSeconds(10);
    }

    public async Task DespacharAsync(CancellationToken ct)
    {
        var entregas = await _webhooks.ReclamarAsync(ct: ct);

        if (entregas.Count == 0) return;

        // Se despachan en paralelo con un tope: un cliente lento no debe
        // retrasar los avisos de los demás.
        using var semaforo = new SemaphoreSlim(5);

        await Task.WhenAll(entregas.Select(async entrega =>
        {
            await semaforo.WaitAsync(ct);

            try { await EntregarAsync(entrega, ct); }
            finally { semaforo.Release(); }
        }));
    }

    private async Task EntregarAsync(EntregaPendiente entrega, CancellationToken ct)
    {
        var cronometro = Stopwatch.StartNew();

        // LA URL SE REVISA OTRA VEZ AL DESPACHAR, no solo al registrarla: los
        // webhooks de antes de la 023 se registraron sin estas reglas (http,
        // IPs privadas), y las reglas pueden cambiar de un entorno a otro.
        // La IP la comprueba además el manejador HTTP al conectar
        // (DestinoWebhook.CrearManejador).
        var problema = DestinoWebhook.RevisarForma(entrega.Url, _reglas.PermitirLocales);

        if (problema is not null)
        {
            _log.LogWarning(
                "Webhook {Tipo} bloqueado, no se envía: {Problema}", entrega.Tipo, problema);

            // Como un 4xx: reintentar no lo arregla. Queda AGOTADO, a la
            // vista en el panel, hasta que alguien corrija la URL.
            await _webhooks.RegistrarFalloAsync(
                entrega.Id, MaximoIntentos, MaximoIntentos, null,
                "Bloqueado: " + problema, TimeSpan.Zero, ct);

            return;
        }

        try
        {
            var marca = DateTimeOffset.UtcNow.ToUnixTimeSeconds().ToString();
            var firma = Firmar(marca, entrega.Cuerpo, entrega.Secreto);

            using var peticion = new HttpRequestMessage(HttpMethod.Post, entrega.Url)
            {
                Content = new StringContent(
                    entrega.Cuerpo, Encoding.UTF8, "application/json")
            };

            peticion.Headers.TryAddWithoutValidation("X-Facturacion-Timestamp", marca);
            peticion.Headers.TryAddWithoutValidation("X-Facturacion-Firma", firma);
            peticion.Headers.TryAddWithoutValidation("X-Facturacion-Evento", entrega.EventoId.ToString());
            peticion.Headers.TryAddWithoutValidation("X-Facturacion-Tipo", entrega.Tipo);

            var respuesta = await _http.SendAsync(peticion, ct);

            cronometro.Stop();

            if (respuesta.IsSuccessStatusCode)
            {
                await _webhooks.MarcarEntregadaAsync(
                    entrega.Id, (int)respuesta.StatusCode, ct);

                _log.LogInformation(
                    "Webhook {Tipo} entregado en {Ms} ms ({Codigo}).",
                    entrega.Tipo, cronometro.ElapsedMilliseconds,
                    (int)respuesta.StatusCode);

                return;
            }

            // UN 3xx TAMPOCO: el cliente HTTP no sigue redirecciones (una
            // redirección hacia una IP interna sería la misma puerta por otro
            // lado). Se registra con su código y se corrige la URL.
            //
            // UN 4xx NO SE REINTENTA, salvo el 429.
            //
            // Un 404 o un 401 significan que la URL está mal o que el cliente
            // cambió su autenticación. Reintentar ocho veces lo mismo no lo
            // va a arreglar: hace falta que alguien corrija la configuración.
            var codigo = (int)respuesta.StatusCode;

            var reintentable = codigo >= 500 || codigo == 429;

            await _webhooks.RegistrarFalloAsync(
                entrega.Id,
                reintentable ? entrega.Intentos : MaximoIntentos,
                MaximoIntentos,
                codigo,
                $"El servidor respondió {codigo} {respuesta.ReasonPhrase}." +
                (reintentable ? "" : " No se reintenta: revisa la URL."),
                EsperaReintento.Calcular(entrega.Intentos),
                ct);

            _log.LogWarning(
                "Webhook {Tipo} rechazado con {Codigo}. {Accion}",
                entrega.Tipo, codigo,
                reintentable ? "Se reintentará." : "No se reintenta.");
        }
        catch (TaskCanceledException) when (!ct.IsCancellationRequested)
        {
            await RegistrarFalloAsync(entrega,
                "El servidor del cliente no respondió dentro del plazo.", ct);
        }
        catch (HttpRequestException ex) when (DestinoBloqueadoException.Buscar(ex) is { } bloqueado)
        {
            // La URL resolvió a una IP interna. Como un 4xx: no se reintenta.
            _log.LogWarning(
                "Webhook {Tipo} bloqueado, no se envía: {Motivo}", entrega.Tipo, bloqueado.Message);

            await _webhooks.RegistrarFalloAsync(
                entrega.Id, MaximoIntentos, MaximoIntentos, null,
                bloqueado.Message, TimeSpan.Zero, ct);
        }
        catch (HttpRequestException ex)
        {
            await RegistrarFalloAsync(entrega,
                $"No se pudo contactar el servidor: {ex.Message}", ct);
        }
        catch (Exception ex)
        {
            await RegistrarFalloAsync(entrega, ex.Message, ct);
        }
    }

    private Task RegistrarFalloAsync(
        EntregaPendiente entrega, string error, CancellationToken ct)
    {
        _log.LogWarning(
            "Webhook {Tipo} falló (intento {Intento}): {Error}",
            entrega.Tipo, entrega.Intentos, error);

        return _webhooks.RegistrarFalloAsync(
            entrega.Id, entrega.Intentos, MaximoIntentos,
            null, error, EsperaReintento.Calcular(entrega.Intentos), ct);
    }

    /// <summary>
    /// Calcula la firma que el cliente debe recalcular por su cuenta.
    ///
    /// El formato es deliberadamente simple para que sea fácil de reproducir
    /// en cualquier lenguaje: HMAC-SHA256 de "timestamp.cuerpo", en
    /// hexadecimal minúsculo.
    /// </summary>
    public static string Firmar(string marcaTiempo, string cuerpo, string secreto)
    {
        var contenido = Encoding.UTF8.GetBytes($"{marcaTiempo}.{cuerpo}");
        var llave = Encoding.UTF8.GetBytes(secreto);

        using var hmac = new HMACSHA256(llave);

        return Convert.ToHexString(hmac.ComputeHash(contenido)).ToLowerInvariant();
    }
}

/// <summary>
/// Despacha webhooks en segundo plano.
///
/// Corre aparte del worker de comprobantes porque su fallo no debe afectar a
/// la facturación: que el servidor de un cliente esté caído no puede impedir
/// que las facturas de los demás lleguen a SUNAT.
/// </summary>
public sealed class ServicioWebhooks : BackgroundService
{
    private readonly DespachadorWebhooks _despachador;
    private readonly ILogger<ServicioWebhooks> _log;
    private readonly TimeSpan _intervalo;

    public ServicioWebhooks(
        DespachadorWebhooks despachador,
        ILogger<ServicioWebhooks> log,
        TimeSpan? intervalo = null)
    {
        _despachador = despachador;
        _log = log;
        _intervalo = intervalo ?? TimeSpan.FromSeconds(10);
    }

    protected override async Task ExecuteAsync(CancellationToken ct)
    {
        _log.LogInformation(
            "Despachador de webhooks iniciado. Ciclo cada {Intervalo}.", _intervalo);

        while (!ct.IsCancellationRequested)
        {
            try
            {
                await _despachador.DespacharAsync(ct);
            }
            catch (OperationCanceledException) when (ct.IsCancellationRequested)
            {
                break;
            }
            catch (Exception ex)
            {
                _log.LogError(ex, "Error en el ciclo de webhooks. Se reintenta.");
            }

            await Task.Delay(_intervalo, ct);
        }

        _log.LogInformation("Despachador de webhooks detenido.");
    }
}
'@

# --- Facturacion.Worker\Program.cs
Planear 'Facturacion.Worker\Program.cs' '8CFB4B6CBAE7CD61583DF59C559895EA30949571499794E56CDD751338D8DD77' @'
using Facturacion.Cpe;
using Facturacion.Persistencia;
using Facturacion.Worker;
using Microsoft.Extensions.Logging;

// Los secretos se leen del entorno, no de appsettings.json.
ConfiguracionSecretos.CargarArchivoEnv();

var builder = Host.CreateApplicationBuilder(args);

// --- Configuración ---------------------------------------------------------

var cadenaApp = ConfiguracionSecretos.CadenaPostgres(
    "facturacion_app", "FACTURACION_APP_PASSWORD",
    "procesar cada comprobante dentro de la sesión de su empresa");

// El worker necesita DOS conexiones con roles distintos:
//
//   Operador: para reclamar trabajos de todas las empresas. No está sujeto
//             a Row Level Security, porque el worker no es un tenant.
//
//   App:      para procesar cada comprobante dentro de la sesión de SU
//             empresa, con las políticas activas.
//
// Reclamar y procesar con el mismo rol privilegiado sería más simple y
// mucho peor: un error de código podría escribir en la empresa equivocada
// sin que nada lo impida.
var cadenaOperador = ConfiguracionSecretos.CadenaPostgres(
    "facturacion_operador", "FACTURACION_OPERADOR_PASSWORD",
    "reclamar trabajo de todas las empresas");

// El almacén se construye desde la configuración: disco en desarrollo,
// S3 en cuanto se apunte a MinIO o a una nube. El código es el mismo.
var opcionesAlmacen = new OpcionesAlmacen();
builder.Configuration.GetSection("Almacen").Bind(opcionesAlmacen);

if (opcionesAlmacen.Tipo.Equals("s3", StringComparison.OrdinalIgnoreCase))
{
    opcionesAlmacen.Usuario = ConfiguracionSecretos.Exigir(
        "ALMACEN_USUARIO", "el acceso al almacén de comprobantes");

    opcionesAlmacen.Clave = ConfiguracionSecretos.Exigir(
        "ALMACEN_CLAVE", "el acceso al almacén de comprobantes");
}

// --- Servicios -------------------------------------------------------------

builder.Services.AddSingleton(new FabricaSesiones(cadenaApp));
builder.Services.AddSingleton(new ColaTrabajos(cadenaOperador));
builder.Services.AddSingleton<RepositorioComprobantes>();
builder.Services.AddSingleton<IProtectorDeSecretos>(_ => ProtectorAesGcm.DesdeEntorno());
builder.Services.AddSingleton<AlmacenCertificados>();

// Resuelve las credenciales de SUNAT según el ambiente de cada empresa.
// En beta, las de pruebas; en producción, las del contribuyente descifradas.
builder.Services.AddSingleton(proveedor =>
    new ProveedorCredenciales(
        cadenaOperador,
        proveedor.GetRequiredService<IProtectorDeSecretos>()));
builder.Services.AddSingleton(FabricaAlmacen.Crear(opcionesAlmacen));

builder.Services.AddSingleton(new OpcionesWorker
{
    TamanoLote = builder.Configuration.GetValue("Worker:TamanoLote", 10),
    Concurrencia = builder.Configuration.GetValue("Worker:Concurrencia", 4),
    EsperaSinTrabajo = TimeSpan.FromSeconds(
        builder.Configuration.GetValue("Worker:EsperaSegundos", 5))
});

// El semáforo por empresa es singleton a propósito: su estado debe
// compartirse entre todos los lotes, no reiniciarse en cada vuelta.
builder.Services.AddSingleton(new SemaforoPorTenant(limitePorDefecto: 1));

builder.Services.AddSingleton<ProcesadorComprobantes>();
builder.Services.AddHostedService<ServicioWorker>();

// --- Resúmenes diarios de boletas -----------------------------------------
//
// Corre como un servicio aparte del worker de facturas porque su ritmo es
// completamente distinto: las facturas se procesan en segundos y los
// resúmenes una vez al día. Mezclarlos obligaría a que el más lento marcara
// el ritmo del más rápido.
builder.Services.AddSingleton(new RepositorioResumenes(cadenaOperador));
builder.Services.AddSingleton<ProcesadorResumenes>();

builder.Services.AddSingleton(proveedor =>
    new RepositorioBajas(
        proveedor.GetRequiredService<FabricaSesiones>(),
        cadenaOperador));

builder.Services.AddSingleton<ProcesadorBajas>();
builder.Services.AddHostedService<ServicioBajas>();

// --- Webhooks --------------------------------------------------------------
//
// Van en su propio servicio porque su fallo NO debe afectar a la facturación:
// que el servidor de un cliente esté caído no puede impedir que las facturas
// de los demás lleguen a SUNAT.
//
// El cliente HTTP de los webhooks NO es uno cualquiera (DestinoWebhook): no
// sigue redirecciones, no usa proxy y solo se conecta a IPs públicas que
// comprueba él mismo al conectar. Desde que una clave fac_ puede registrar su
// webhook, esto es lo que impide que el servicio haga peticiones hacia dentro.
var reglasWebhook = ReglasDestinoWebhook.Resolver(builder.Environment.IsDevelopment());

builder.Services.AddSingleton(reglasWebhook);

builder.Services.AddHttpClient("webhooks")
    .ConfigurePrimaryHttpMessageHandler(() =>
        DestinoWebhook.CrearManejador(reglasWebhook.PermitirLocales));

builder.Services.AddSingleton(new RepositorioWebhooks(cadenaOperador));
builder.Services.AddSingleton<DespachadorWebhooks>();

builder.Services.AddSingleton<IHostedService>(proveedor =>
    new ServicioWebhooks(
        proveedor.GetRequiredService<DespachadorWebhooks>(),
        proveedor.GetRequiredService<ILogger<ServicioWebhooks>>(),
        TimeSpan.FromSeconds(
            builder.Configuration.GetValue("Webhooks:IntervaloSegundos", 10))));

builder.Services.AddSingleton<IHostedService>(proveedor =>
    new ServicioResumenes(
        proveedor.GetRequiredService<ProcesadorResumenes>(),
        proveedor.GetRequiredService<ILogger<ServicioResumenes>>(),
        TimeSpan.FromSeconds(
            builder.Configuration.GetValue("Resumenes:IntervaloSegundos", 60))));

builder.Services.AddSingleton(proveedor =>
    new RepositorioGuias(
        proveedor.GetRequiredService<FabricaSesiones>(),
        cadenaOperador));

builder.Services.AddSingleton<ProcesadorGuias>();
builder.Services.AddHostedService<ServicioGuias>();

// LA RUTA POR DEFECTO ES LA CARPETA DEL PROPIO EJECUTABLE, y así no hay que
// configurarla en ningún ambiente: los esquemas se copian al compilar y
// están donde corre el proceso, sea tu máquina o un contenedor.
//
// La variable de entorno queda solo por si algún día hace falta apuntar a
// otro sitio.
ValidacionPrevia.Ruta = ConfiguracionSecretos.Opcional(
    "FACTURACION_XSD_RUTA",
    Path.Combine(AppContext.BaseDirectory, "xsd"));

ValidacionPrevia.Bloquea = ConfiguracionSecretos
    .Opcional("FACTURACION_XSD_BLOQUEA", "false")
    .Equals("true", StringComparison.OrdinalIgnoreCase);

var host = builder.Build();

// SE DICE AL ARRANCAR QUÉ SE VA A COMPROBAR Y QUÉ NO. El modo de fallo de
// esto es el silencio: si la ruta está mal, no valida nada y nadie se entera.
host.Services.GetRequiredService<ILoggerFactory>()
    .CreateLogger("ValidacionPrevia")
    .LogInformation("{Diagnostico}", ValidacionPrevia.Diagnostico());

// Lo mismo con los destinos de webhook: si el worker no está en Development,
// el webhook de la plataforma en http://localhost se bloquea, y conviene
// verlo aquí y no adivinarlo en las entregas agotadas.
host.Services.GetRequiredService<ILoggerFactory>()
    .CreateLogger("Webhooks")
    .LogInformation("{Diagnostico} Entorno: {Entorno}.",
        ReglasDestinoWebhook.Diagnostico(builder.Environment.IsDevelopment()),
        builder.Environment.EnvironmentName);

host.Run();
'@

# --- Todo o nada -------------------------------------------------------------
$conflictos = @($plan | Where-Object { $_.Accion -eq 'conflicto' })
if ($conflictos.Count -gt 0) {
    Write-Host ''
    Write-Host 'NO SE TOCÓ NINGÚN ARCHIVO. Esto no cuadra:' -ForegroundColor Red
    foreach ($c in $conflictos) { Write-Host "  $($c.Ruta)`n      $($c.Motivo)" -ForegroundColor Red }
    Write-Host ''
    exit 2
}

Write-Host ''
foreach ($p in $plan) {
    if ($p.Accion -eq 'reemplazar') {
        $copia = Respaldar $p.Completa
        $salida = if ($p.Crlf) { $p.Texto.Replace("`n", "`r`n") } else { $p.Texto }
        [System.IO.File]::WriteAllText($p.Completa, $salida, $utf8SinBom)
        Write-Host "  REEMPLAZADO  $($p.Ruta)  (copia: $copia)" -ForegroundColor Green
    }
    elseif ($p.Accion -eq 'nuevo') {
        New-Item -ItemType Directory -Path (Split-Path $p.Completa) -Force | Out-Null
        [System.IO.File]::WriteAllText($p.Completa, $p.Texto.Replace("`n", "`r`n"), $utf8SinBom)
        Write-Host "  NUEVO        $($p.Ruta)" -ForegroundColor Green
    }
    else {
        Write-Host "  IGUAL        $($p.Ruta)  (sin cambios)" -ForegroundColor DarkGray
    }
}

Write-Host ''
Write-Host 'Comprobaciones (solo leen):' -ForegroundColor Cyan

$envRuta = Join-Path $raiz '.env'
if ((Test-Path $envRuta) -and (Select-String -Path $envRuta -Pattern '^\s*FACTURACION_WEBHOOKS_LOCALES\s*=\s*true\s*$' -Quiet)) {
    Write-Host '  .env: FACTURACION_WEBHOOKS_LOCALES=true ya está.' -ForegroundColor Green
}
else {
    Write-Host '  .env: FALTA la línea FACTURACION_WEBHOOKS_LOCALES=true (paso 2 de la guía).' -ForegroundColor Yellow
}

$lanzador = Join-Path $raiz 'Facturacion.Worker\Properties\launchSettings.json'
if ((Test-Path $lanzador) -and (Select-String -Path $lanzador -Pattern '"DOTNET_ENVIRONMENT"\s*:\s*"Development"' -Quiet)) {
    Write-Host '  Worker: arranca en Development (launchSettings.json).' -ForegroundColor Green
}
else {
    Write-Host '  Worker: NO veo DOTNET_ENVIRONMENT=Development en su launchSettings.json.' -ForegroundColor Yellow
    Write-Host '          Mira la línea "Webhooks:" de su registro al arrancar (paso 3).' -ForegroundColor Yellow
}

Write-Host ''
Write-Host 'FALTA APLICAR LA MIGRACIÓN 023 (este script NO la aplica). Desde esta carpeta:' -ForegroundColor Cyan
Write-Host ''
Write-Host '  Get-Content migraciones\023_webhook_api.sql -Raw | docker compose exec -T postgres psql -U facturacion_owner -d facturacion -v ON_ERROR_STOP=1' -ForegroundColor White
Write-Host ''
Write-Host 'Tiene que terminar en COMMIT. Después, reinicia la API y el worker del servicio.' -ForegroundColor Cyan
Write-Host ''
