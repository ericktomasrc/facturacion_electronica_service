# =============================================================================
# Entrega 2026-10-11 — Alta de una empresa, PARTE C1 (servicio): la clave de alta
#
# Se ejecuta desde la raíz del servicio:
#   cd "D:\Reyban Consulting\facturacion electronica\facturacion_electronica_service"
#   .\entrega-2026-10-11-parteC1-alta.ps1
#
#   migraciones\024_alta_emisores.sql      NUEVO. claves_alta; tenants.estado_alta
#        (las que existen quedan «confirmada»), direccion_revisada_en, RUC único
#        entre las no abandonadas, permiso altas.gestionar. No se aplica sola
#   Persistencia\RepositorioAltas.cs       NUEVO. El alta en UNA transacción,
#        el tope del día, abandonar, confirmar, y lo que refleja /v1/emisor
#   Api\EndpointsAlta.cs                   NUEVO. POST /alta/emisores (alt_),
#        POST /v1/alta/confirmar, /admin/claves-alta, PUT .../direccion
#   Api\Direccion.cs                       NUEVO. Dirección completa, ubigeo
#        contra departamento (normalizado), dígito verificador del RUC
#   Persistencia\RepositorioAdmin.cs       La lista trae alta y dirección;
#        el alta del panel marca la dirección como revisada; guardar dirección
#   Persistencia\RepositorioRoles.cs       Permiso.AltasGestionar
#   Persistencia\RepositorioTenants.cs     Buscar por RUC ignora las abandonadas
#   Api\Autenticacion.cs                   /alta no pide fac_ (tiene su filtro)
#   Api\EndpointsAdmin.cs                  El alta del panel exige la dirección;
#        una abandonada no se reactiva (409)
#   Api\Program.cs                         Registra lo nuevo; /v1/emisor gana
#        alta, portal, dirección y «listo»
#   Api\wwwroot\admin.html                 Bloque «Claves de alta», estados del
#        alta, dirección fiscal en la pestaña Marca, formulario sin LIMA
#
# PROTECCIÓN: los 7 que ya existen solo se reemplazan si siguen IGUAL a los
# que me pasaste el 11 de octubre a la 01:10. Si alguno cambió, NO TOCA NADA.
# Todo o nada. UTF-8 sin BOM, .bak. La migración NO se aplica.
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

# --- migraciones\024_alta_emisores.sql
Planear 'migraciones\024_alta_emisores.sql' '' @'
-- ===========================================================================
-- 024 — El alta de un emisor desde la plataforma
--
-- Diseño: alta-empresa-diseno.md §13 (aprobado el 11 de octubre).
--
-- QUÉ CAMBIA: hasta hoy un emisor solo nacía en el panel del servicio. Desde
-- ahora la plataforma también puede crearlo, con una credencial que SOLO
-- crea: la clave de alta (alt_). No lee, no lista y no modifica ninguna
-- empresa existente.
--
--
-- LO QUE AÑADE:
--
--   claves_alta              Las claves de alta. Como api_keys: solo el hash.
--                            Cada una con su tope de altas por día (20).
--
--   tenants.estado_alta      sin_confirmar · confirmada · abandonada
--                            Dos bases sin transacción común: el servicio crea
--                            el emisor «sin confirmar», la plataforma guarda lo
--                            suyo y después confirma. Si la plataforma no llega
--                            a guardar, el emisor se queda sin confirmar y el
--                            siguiente intento lo da por abandonado. Las que ya
--                            existen pasan a «confirmada» (las creaste tú).
--
--   tenants.direccion_revisada_en
--                            Cuándo escribió alguien la dirección a propósito.
--                            Una dirección por defecto (LIMA) no se distingue
--                            de una revisada: esta columna es la diferencia.
--                            NULA en las que ya existen, porque es la verdad:
--                            nadie la revisó.
--
--   El RUC                   Era único PARA SIEMPRE (tenants_ruc_key). Un emisor
--                            abandonado bloquearía ese RUC sin remedio. Ahora es
--                            único entre los que no están abandonados.
--
--   altas.gestionar          Permiso nuevo: emitir y revocar claves de alta.
--
--
-- NADA SE BORRA: un emisor abandonado se desactiva, su clave se revoca y su
-- webhook se apaga. La fila queda, con la fecha.
--
-- Los mensajes de error van sin tildes: PowerShell 5.1 manda este archivo a
-- psql en ASCII.
-- ===========================================================================

BEGIN;

-- --- claves_alta -----------------------------------------------------------

CREATE TABLE IF NOT EXISTS claves_alta (
    id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    nombre          text        NOT NULL,

    -- Los 20 primeros caracteres, como api_keys.prefijo: para reconocerla en
    -- el panel y en la bitacora sin poder usarla.
    prefijo         varchar(20) NOT NULL,
    hash            varchar(64) NOT NULL,

    -- Altas por dia de Lima. Si se filtra, el dano queda acotado a esto.
    tope_diario     smallint    NOT NULL DEFAULT 20,

    activo          boolean     NOT NULL DEFAULT true,
    creado_en       timestamptz NOT NULL DEFAULT now(),
    creado_por      uuid        REFERENCES usuarios(id) ON DELETE RESTRICT,
    ultimo_uso      timestamptz,
    revocado_en     timestamptz,
    revocado_por    uuid        REFERENCES usuarios(id) ON DELETE RESTRICT,

    -- El ultimo dia en que se mando el correo de «tope alcanzado». Uno al dia.
    tope_avisado_en timestamptz,

    CONSTRAINT ux_claves_alta_hash UNIQUE (hash),
    CONSTRAINT ck_claves_alta_nombre CHECK (length(btrim(nombre)) BETWEEN 1 AND 100),
    CONSTRAINT ck_claves_alta_prefijo CHECK (prefijo LIKE 'alt\_%'),
    CONSTRAINT ck_claves_alta_tope CHECK (tope_diario BETWEEN 1 AND 100),
    CONSTRAINT ck_claves_alta_revocada CHECK (activo OR revocado_en IS NOT NULL)
);

COMMENT ON TABLE claves_alta IS
    'Claves con las que la plataforma crea emisores (POST /alta/emisores). Solo crean: '
    'no leen ni cambian empresas existentes. Solo el hash. Nada se borra.';

-- Solo el operador (el panel y la ruta de alta). La aplicacion no las ve.
GRANT SELECT, INSERT, UPDATE ON claves_alta TO facturacion_operador;
REVOKE DELETE, TRUNCATE ON claves_alta FROM facturacion_operador;


-- --- tenants: el estado del alta -------------------------------------------

ALTER TABLE tenants ADD COLUMN IF NOT EXISTS estado_alta           text;
ALTER TABLE tenants ADD COLUMN IF NOT EXISTS alta_confirmada_en    timestamptz;
ALTER TABLE tenants ADD COLUMN IF NOT EXISTS abandonada_en         timestamptz;
ALTER TABLE tenants ADD COLUMN IF NOT EXISTS creado_por_clave_alta uuid
    REFERENCES claves_alta(id) ON DELETE RESTRICT;
ALTER TABLE tenants ADD COLUMN IF NOT EXISTS direccion_revisada_en timestamptz;

-- LAS QUE YA EXISTEN, CONFIRMADAS. Las creaste tu en el panel: no hay nada
-- que confirmar, y en «sin confirmar» quedarian a tiro de darse por
-- abandonadas. creado_por_clave_alta queda nulo: no las creo ninguna clave.
UPDATE tenants SET estado_alta = 'confirmada' WHERE estado_alta IS NULL;

-- Por defecto «confirmada»: es lo que debe ser un alta del panel. La ruta de
-- alta pone «sin_confirmar» a proposito, nunca por omision.
ALTER TABLE tenants ALTER COLUMN estado_alta SET DEFAULT 'confirmada';
ALTER TABLE tenants ALTER COLUMN estado_alta SET NOT NULL;

ALTER TABLE tenants DROP CONSTRAINT IF EXISTS ck_tenants_estado_alta;
ALTER TABLE tenants ADD CONSTRAINT ck_tenants_estado_alta
    CHECK (estado_alta IN ('sin_confirmar', 'confirmada', 'abandonada'));

-- Abandonada = desactivada y con fecha. Sin las dos cosas no es abandonada.
ALTER TABLE tenants DROP CONSTRAINT IF EXISTS ck_tenants_abandonada;
ALTER TABLE tenants ADD CONSTRAINT ck_tenants_abandonada
    CHECK (estado_alta <> 'abandonada' OR (NOT activo AND abandonada_en IS NOT NULL));

-- Solo una clave de alta crea emisores sin confirmar.
ALTER TABLE tenants DROP CONSTRAINT IF EXISTS ck_tenants_sin_confirmar;
ALTER TABLE tenants ADD CONSTRAINT ck_tenants_sin_confirmar
    CHECK (estado_alta <> 'sin_confirmar' OR creado_por_clave_alta IS NOT NULL);

-- Las vueltas que se permiten, y ninguna mas:
--   sin_confirmar -> confirmada   la plataforma confirmo
--   sin_confirmar -> abandonada   un alta posterior del mismo RUC
-- Y una abandonada no se reactiva nunca: su RUC ya puede tenerlo otra.
CREATE OR REPLACE FUNCTION tenants_estado_alta_transicion()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF OLD.estado_alta = 'abandonada' AND NEW.activo THEN
        RAISE EXCEPTION
            'La empresa % es un alta abandonada y no se puede reactivar.', OLD.ruc
            USING ERRCODE = 'P0001',
                  HINT = 'Su RUC puede estar ya en otra empresa. Da de alta una nueva.';
    END IF;

    IF NEW.estado_alta IS NOT DISTINCT FROM OLD.estado_alta THEN
        RETURN NEW;
    END IF;

    IF OLD.estado_alta = 'sin_confirmar'
       AND NEW.estado_alta IN ('confirmada', 'abandonada') THEN
        RETURN NEW;
    END IF;

    RAISE EXCEPTION
        'La empresa % no puede pasar de % a %.', OLD.ruc, OLD.estado_alta, NEW.estado_alta
        USING ERRCODE = 'P0001';
END;
$$;

DROP TRIGGER IF EXISTS tr_tenants_estado_alta ON tenants;

CREATE TRIGGER tr_tenants_estado_alta
    BEFORE UPDATE OF estado_alta, activo ON tenants
    FOR EACH ROW
    EXECUTE FUNCTION tenants_estado_alta_transicion();


-- --- El RUC: unico entre los que no estan abandonados ----------------------

CREATE UNIQUE INDEX IF NOT EXISTS ux_tenants_ruc_vigente
    ON tenants (ruc)
    WHERE estado_alta <> 'abandonada';

ALTER TABLE tenants DROP CONSTRAINT IF EXISTS tenants_ruc_key;

-- Para contar las altas del dia de cada clave (el tope).
CREATE INDEX IF NOT EXISTS ix_tenants_clave_alta
    ON tenants (creado_por_clave_alta, creado_en)
    WHERE creado_por_clave_alta IS NOT NULL;


-- --- webhook_cambios: los que nacen con el alta ----------------------------

ALTER TABLE webhook_cambios DROP CONSTRAINT IF EXISTS ck_webhook_cambios_desde;
ALTER TABLE webhook_cambios ADD CONSTRAINT ck_webhook_cambios_desde
    CHECK (hecho_desde IN ('api', 'panel', 'alta'));


-- --- El permiso ------------------------------------------------------------

INSERT INTO permisos (clave, area, nombre, descripcion, orden) VALUES
-- Con U&'...' y escapes: el area tiene que ser EXACTAMENTE 'Crítico', la de
-- certificados y produccion, y las tildes no sobreviven al viaje en ASCII.
('altas.gestionar', U&'Cr\00EDtico', 'Emitir y revocar claves de alta',
 'La clave con la que la plataforma crea emisores nuevos. Solo crea: no lee ' ||
 U&'ni cambia los existentes. Si se filtra, alguien podr\00EDa ocupar el RUC ' ||
 'de un cliente.', 42)
ON CONFLICT (clave) DO NOTHING;

INSERT INTO rol_permisos (rol_id, permiso)
SELECT r.id, 'altas.gestionar' FROM roles r WHERE r.clave = 'administrador'
ON CONFLICT DO NOTHING;


COMMENT ON COLUMN tenants.estado_alta IS
    'sin_confirmar (la creo una clave de alta y la plataforma todavia no confirmo) · '
    'confirmada · abandonada (desactivada para siempre; su RUC queda libre).';
COMMENT ON COLUMN tenants.direccion_revisada_en IS
    'Cuando escribio alguien la direccion a proposito. Nula = nadie la reviso.';
COMMENT ON COLUMN tenants.creado_por_clave_alta IS
    'La clave de alta que la creo. Nula = creada en el panel.';


-- --- Comprobaciones: si algo no quedo como debe, no se confirma nada --------

DO $$
DECLARE
    n integer;
BEGIN
    SELECT count(*) INTO n FROM tenants WHERE estado_alta <> 'confirmada';
    IF n > 0 THEN
        RAISE EXCEPTION 'Hay % empresas que no quedaron confirmadas.', n;
    END IF;

    SELECT count(*) INTO n FROM tenants WHERE creado_por_clave_alta IS NOT NULL;
    IF n > 0 THEN
        RAISE EXCEPTION 'Hay % empresas con clave de alta y no deberia haber ninguna.', n;
    END IF;

    IF EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'tenants_ruc_key') THEN
        RAISE EXCEPTION 'tenants_ruc_key sigue existiendo.';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'ux_tenants_ruc_vigente') THEN
        RAISE EXCEPTION 'Falta ux_tenants_ruc_vigente.';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM rol_permisos rp JOIN roles r ON r.id = rp.rol_id
         WHERE r.clave = 'administrador' AND rp.permiso = 'altas.gestionar') THEN
        RAISE EXCEPTION 'El administrador no tiene altas.gestionar.';
    END IF;

    RAISE NOTICE '024: % empresas confirmadas, RUC unico entre las vigentes, permiso listo.',
        (SELECT count(*) FROM tenants);
END;
$$;

COMMIT;
'@

# --- Facturacion.Persistencia\RepositorioAltas.cs
Planear 'Facturacion.Persistencia\RepositorioAltas.cs' '' @'
using System.Security.Cryptography;
using Dapper;
using Npgsql;

namespace Facturacion.Persistencia;

/// <summary>Una clave de alta ya comprobada: quién llama a POST /alta/emisores.</summary>
public sealed record ClaveAltaResuelta(Guid Id, string Nombre, string Prefijo, short TopeDiario);

/// <summary>Una clave de alta vista desde el panel. Nunca el secreto.</summary>
public sealed record ClaveAltaAdmin(
    Guid Id,
    string Nombre,
    string Prefijo,
    short TopeDiario,
    bool Activo,
    DateTime CreadoEn,
    string? CreadaPor,
    DateTime? UltimoUso,
    DateTime? RevocadoEn,
    string? RevocadaPor,
    int AltasHoy,
    int AltasTotal,
    DateTime? UltimaAlta);

/// <summary>Los datos del emisor que manda la plataforma. Ya revisados.</summary>
public sealed record DatosAltaEmisor(
    string Ruc,
    string RazonSocial,
    string? NombreComercial,
    string Ubigeo,
    string Direccion,
    string Distrito,
    string Provincia,
    string Departamento,
    string WebhookUrl);

public enum ResultadoAlta
{
    Creado,

    /// <summary>El RUC ya tiene un emisor vigente. No se creó nada.</summary>
    YaExiste,

    /// <summary>
    /// Hay un alta «sin confirmar» de este RUC de hace menos de dos minutos:
    /// probablemente la del clic anterior, todavía en camino. No se toca.
    /// </summary>
    EnCurso,

    /// <summary>La clave llegó a su tope del día. No se creó nada.</summary>
    TopeAlcanzado
}

/// <summary>
/// Lo que devuelve un alta.
///
/// LA CLAVE Y EL SECRETO SOLO EXISTEN AQUÍ, en memoria, el tiempo de responder.
/// En la base quedan el hash de la clave y el secreto del webhook (este en
/// claro, como todos: punto 22). Quien reciba este objeto no lo registra.
/// </summary>
public sealed record AltaEmisor(
    ResultadoAlta Resultado,
    Guid? EmisorId = null,
    DateTime? CreadoEn = null,
    string? Clave = null,
    Guid? WebhookId = null,
    string? WebhookUrl = null,
    string? WebhookSecreto = null,
    Guid? Abandonado = null,
    bool AvisarTope = false)
{
    public override string ToString() =>
        // Por si alguien lo escribe en un registro: sin secretos.
        $"AltaEmisor {{ {Resultado}, {EmisorId}, abandonado {Abandonado} }}";
}

/// <summary>
/// Lo que el emisor de una clave sabe de sí mismo para GET /v1/emisor: si su
/// alta está confirmada, su marca, y si está listo para emitir.
///
/// SOLO «ESTÁ O NO ESTÁ», y datos de la propia empresa. Ningún secreto: ni la
/// clave SOL, ni el certificado. El correo de respuesta y el identificador sí
/// salen: son de la empresa y la plataforma los necesita para avisar.
/// </summary>
public sealed record EstadoEmisor(
    string EstadoAlta,
    DateTime CreadoEn,
    DateTime? AltaConfirmadaEn,
    string? Identificador,
    string? CorreoRespuesta,
    bool TieneLogo,
    string? UsuarioSol,
    bool TieneClaveSol,
    string Ubigeo,
    string Direccion,
    string Distrito,
    string Provincia,
    string Departamento,
    DateTime? DireccionRevisadaEn,
    DateTime? CertificadoValidoHasta,
    string? SeriesTexto)
{
    public string[] Series =>
        string.IsNullOrWhiteSpace(SeriesTexto)
            ? []
            : SeriesTexto.Split(',', StringSplitOptions.RemoveEmptyEntries);

    public bool CertificadoListo =>
        CertificadoValidoHasta is { } h && h > DateTime.UtcNow;

    /// <summary>
    /// El usuario SOL secundario de verdad. MODDATOS es el de pruebas de SUNAT:
    /// sirve en beta, pero el día de pasar a producción no hay con qué entrar.
    /// </summary>
    public bool SolListo =>
        !string.IsNullOrWhiteSpace(UsuarioSol) &&
        !UsuarioSol.Equals("MODDATOS", StringComparison.OrdinalIgnoreCase) &&
        TieneClaveSol;

    public bool SeriesListas => Series.Length > 0;

    /// <summary>
    /// Revisada a propósito, y con todo. Una dirección con los valores por
    /// defecto (LIMA) no se distingue de una revisada: por eso cuenta la fecha,
    /// no solo que los campos tengan algo.
    /// </summary>
    public bool DireccionLista =>
        DireccionRevisadaEn is not null &&
        !string.IsNullOrWhiteSpace(Direccion) &&
        !string.IsNullOrWhiteSpace(Distrito) &&
        !string.IsNullOrWhiteSpace(Provincia) &&
        !string.IsNullOrWhiteSpace(Departamento) &&
        Ubigeo.Length == 6 && Ubigeo.All(char.IsDigit);

    public bool ListoParaEmitir => CertificadoListo && SolListo && SeriesListas && DireccionLista;

    /// <summary>Sin estos dos, ningún receptor recibe nunca su correo (migración 022).</summary>
    public bool CorreosAlReceptor =>
        !string.IsNullOrWhiteSpace(Identificador) && !string.IsNullOrWhiteSpace(CorreoRespuesta);

    /// <summary>Lo que falta para emitir, en palabras. En el orden en que se hace.</summary>
    public IReadOnlyList<string> Faltan()
    {
        var faltan = new List<string>();

        if (!DireccionLista)
            faltan.Add(DireccionRevisadaEn is null
                ? "Revisar la dirección (nadie la confirmó: puede tener los valores por defecto)."
                : "Completar la dirección.");

        if (CertificadoValidoHasta is null)
            faltan.Add("Cargar el certificado digital.");
        else if (!CertificadoListo)
            faltan.Add("El certificado venció: cargar uno vigente.");

        if (!SolListo)
            faltan.Add("Guardar el usuario SOL secundario y su clave.");

        if (!SeriesListas)
            faltan.Add("Crear al menos una serie.");

        return faltan;
    }
}

/// <summary>
/// El alta de emisores desde la plataforma, y las claves de alta.
///
/// Diseño: alta-empresa-diseno.md §13.
///
/// LO ESTRECHO DE LA CLAVE DE ALTA ESTÁ EN ESTE ARCHIVO. Usa la conexión de
/// operador, igual que el panel, porque crea filas en tablas que la aplicación
/// solo puede leer. Lo que la acota es que el único método que una clave de
/// alta puede disparar es <see cref="CrearEmisorAsync"/>, y ese método solo
/// inserta —salvo dar por abandonado un «sin confirmar» que creó otra clave de
/// alta—. La segunda barrera, un rol de base propio que solo pueda insertar en
/// estas tablas, es el punto 23, para antes de producción.
/// </summary>
public sealed class RepositorioAltas
{
    /// <summary>
    /// Cuánto tiene que llevar un alta «sin confirmar» para que otra la pueda
    /// dar por abandonada. Menos que esto es casi seguro el clic anterior, que
    /// todavía va por el camino.
    /// </summary>
    public static readonly TimeSpan EsperaAntesDeAbandonar = TimeSpan.FromMinutes(2);

    public const string NombreClaveEmisor = "Plataforma (creada por el alta)";

    // El día de Lima, no el del servidor: «20 al día» lo cuenta una persona
    // que está en Perú.
    private const string InicioDelDia =
        "(date_trunc('day', now() AT TIME ZONE 'America/Lima') AT TIME ZONE 'America/Lima')";

    private readonly string _cadenaOperador;

    public RepositorioAltas(string cadenaConexionOperador)
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
    /// Una clave de alta nueva. Prefijo propio para que no se confunda con una
    /// fac_ ni en un registro ni a la vista.
    /// </summary>
    public static string GenerarClave() =>
        "alt_" + Convert.ToBase64String(RandomNumberGenerator.GetBytes(32))
            .Replace("+", "").Replace("/", "").Replace("=", "");

    // ------------------------------------------------------ claves (panel)

    public async Task<IReadOnlyList<ClaveAltaAdmin>> ListarClavesAsync(CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);

        var filas = await conexion.QueryAsync<ClaveAltaAdmin>(new CommandDefinition(
            $"""
            SELECT k.id          AS "Id",
                   k.nombre      AS "Nombre",
                   k.prefijo     AS "Prefijo",
                   k.tope_diario AS "TopeDiario",
                   k.activo      AS "Activo",
                   k.creado_en   AS "CreadoEn",
                   uc.correo::text AS "CreadaPor",
                   k.ultimo_uso  AS "UltimoUso",
                   k.revocado_en AS "RevocadoEn",
                   ur.correo::text AS "RevocadaPor",

                   (SELECT count(*)::int FROM tenants t
                     WHERE t.creado_por_clave_alta = k.id
                       AND t.creado_en >= {InicioDelDia})        AS "AltasHoy",

                   (SELECT count(*)::int FROM tenants t
                     WHERE t.creado_por_clave_alta = k.id)       AS "AltasTotal",

                   (SELECT max(t.creado_en) FROM tenants t
                     WHERE t.creado_por_clave_alta = k.id)       AS "UltimaAlta"

              FROM claves_alta k
              LEFT JOIN usuarios uc ON uc.id = k.creado_por
              LEFT JOIN usuarios ur ON ur.id = k.revocado_por
             ORDER BY k.activo DESC, k.creado_en DESC
            """,
            cancellationToken: ct));

        return filas.ToList();
    }

    /// <summary>Emite una clave de alta y devuelve el secreto EN CLARO, una sola vez.</summary>
    public async Task<(Guid Id, string Clave, string Prefijo)> CrearClaveAsync(
        string nombre, short topeDiario, Guid usuarioId, CancellationToken ct = default)
    {
        var clave = GenerarClave();
        var prefijo = clave[..20];

        await using var conexion = await AbrirAsync(ct);

        var id = await conexion.ExecuteScalarAsync<Guid>(new CommandDefinition(
            """
            INSERT INTO claves_alta (nombre, prefijo, hash, tope_diario, creado_por)
            VALUES (@nombre, @prefijo, @hash, @topeDiario, @usuarioId)
            RETURNING id
            """,
            new
            {
                nombre = nombre.Trim(),
                prefijo,
                hash = RepositorioTenants.CalcularHash(clave),
                topeDiario,
                usuarioId
            },
            cancellationToken: ct));

        return (id, clave, prefijo);
    }

    /// <summary>Revoca una clave de alta. No se borra: queda quién y cuándo.</summary>
    public async Task<bool> RevocarClaveAsync(Guid id, Guid usuarioId, CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);

        var filas = await conexion.ExecuteAsync(new CommandDefinition(
            """
            UPDATE claves_alta
               SET activo = false, revocado_en = now(), revocado_por = @usuarioId
             WHERE id = @id AND activo
            """,
            new { id, usuarioId }, cancellationToken: ct));

        return filas > 0;
    }

    /// <summary>
    /// Comprueba una clave de alta y anota su uso. Null si no existe o está
    /// revocada: quien llama responde lo mismo en los dos casos.
    /// </summary>
    public async Task<ClaveAltaResuelta?> ResolverClaveAsync(string clave, CancellationToken ct = default)
    {
        if (string.IsNullOrWhiteSpace(clave) || !clave.StartsWith("alt_", StringComparison.Ordinal))
            return null;

        await using var conexion = await AbrirAsync(ct);

        return await conexion.QuerySingleOrDefaultAsync<ClaveAltaResuelta>(new CommandDefinition(
            """
            UPDATE claves_alta
               SET ultimo_uso = now()
             WHERE hash = @hash AND activo
            RETURNING id          AS "Id",
                      nombre      AS "Nombre",
                      prefijo     AS "Prefijo",
                      tope_diario AS "TopeDiario"
            """,
            new { hash = RepositorioTenants.CalcularHash(clave) }, cancellationToken: ct));
    }

    /// <summary>
    /// Los correos de quienes pueden gestionar claves de alta: a ellos va el
    /// aviso de «tope alcanzado».
    /// </summary>
    public async Task<IReadOnlyList<string>> DestinatariosAvisoAsync(CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);

        var filas = await conexion.QueryAsync<string>(new CommandDefinition(
            """
            SELECT DISTINCT u.correo::text
              FROM usuarios u
              JOIN rol_permisos rp ON rp.rol_id = u.rol_id
             WHERE u.activo AND rp.permiso = 'altas.gestionar'
            """,
            cancellationToken: ct));

        return filas.ToList();
    }

    // ------------------------------------------------------- el alta en sí

    /// <summary>
    /// Crea el emisor, su clave fac_ y su webhook, EN UNA SOLA TRANSACCIÓN, y
    /// lo deja «sin confirmar». O todo o nada.
    ///
    /// Los datos tienen que venir ya revisados (Direccion.Revisar y
    /// DestinoWebhook). Aquí solo se decide si se puede crear.
    /// </summary>
    public async Task<AltaEmisor> CrearEmisorAsync(
        ClaveAltaResuelta clave, DatosAltaEmisor datos, CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);
        await using var transaccion = await conexion.BeginTransactionAsync(ct);

        // --- 1. El tope del día --------------------------------------------
        //
        // Con el candado de la clave, dos altas a la vez con la misma clave no
        // pueden contarse las dos por debajo del tope.
        await conexion.ExecuteAsync(new CommandDefinition(
            "SELECT pg_advisory_xact_lock(hashtextextended('clave_alta:' || @id::text, 0))",
            new { id = clave.Id }, transaccion, cancellationToken: ct));

        var hoy = await conexion.ExecuteScalarAsync<int>(new CommandDefinition(
            $"""
            SELECT count(*)::int FROM tenants
             WHERE creado_por_clave_alta = @id
               AND creado_en >= {InicioDelDia}
            """,
            new { id = clave.Id }, transaccion, cancellationToken: ct));

        if (hoy >= clave.TopeDiario)
        {
            // Se marca el aviso una vez al día: si esto lo provoca una clave
            // filtrada, el correo llega una vez, no veinte.
            var avisar = await conexion.ExecuteScalarAsync<bool?>(new CommandDefinition(
                $"""
                UPDATE claves_alta
                   SET tope_avisado_en = now()
                 WHERE id = @id
                   AND (tope_avisado_en IS NULL OR tope_avisado_en < {InicioDelDia})
                RETURNING true
                """,
                new { id = clave.Id }, transaccion, cancellationToken: ct));

            await transaccion.CommitAsync(ct);

            return new AltaEmisor(ResultadoAlta.TopeAlcanzado, AvisarTope: avisar == true);
        }

        // --- 2. ¿Existe ya ese RUC? -----------------------------------------
        //
        // El candado por RUC hace que dos altas del mismo RUC vayan en fila: la
        // segunda ve lo que dejó la primera.
        await conexion.ExecuteAsync(new CommandDefinition(
            "SELECT pg_advisory_xact_lock(hashtextextended('alta_ruc:' || @ruc, 0))",
            new { ruc = datos.Ruc }, transaccion, cancellationToken: ct));

        var existente = await conexion.QuerySingleOrDefaultAsync<FilaExistente>(new CommandDefinition(
            """
            SELECT id                    AS "Id",
                   estado_alta           AS "EstadoAlta",
                   creado_por_clave_alta AS "ClaveAlta",
                   creado_en             AS "CreadoEn"
              FROM tenants
             WHERE ruc = @ruc
               AND estado_alta <> 'abandonada'
               FOR UPDATE
            """,
            new { ruc = datos.Ruc }, transaccion, cancellationToken: ct));

        Guid? abandonado = null;

        if (existente is not null)
        {
            // Solo se abandona lo que nadie confirmó y creó una clave de alta.
            // Una empresa del panel, o una confirmada, NUNCA.
            var abandonable = existente.EstadoAlta == "sin_confirmar" && existente.ClaveAlta is not null;

            if (!abandonable)
                return new AltaEmisor(ResultadoAlta.YaExiste);

            if (existente.CreadoEn > DateTime.UtcNow - EsperaAntesDeAbandonar)
                return new AltaEmisor(ResultadoAlta.EnCurso);

            await AbandonarAsync(conexion, transaccion, existente.Id, clave.Prefijo, ct);
            abandonado = existente.Id;
        }

        // --- 3. El emisor ----------------------------------------------------
        //
        // Siempre en beta y con MODDATOS: producción es una decisión humana, en
        // el panel, con su revisión. La dirección cuenta como revisada: la
        // tecleó una persona en el alta de la plataforma.
        var creado = await conexion.QuerySingleAsync<FilaCreada>(new CommandDefinition(
            """
            INSERT INTO tenants
                (ruc, razon_social, nombre_comercial, ubigeo, direccion,
                 distrito, provincia, departamento, ambiente, usuario_sol,
                 max_concurrencia, estado_alta, creado_por_clave_alta,
                 direccion_revisada_en)
            VALUES
                (@Ruc, @RazonSocial, @NombreComercial, @Ubigeo, @Direccion,
                 @Distrito, @Provincia, @Departamento, 'beta', 'MODDATOS',
                 1, 'sin_confirmar', @ClaveAlta,
                 now())
            RETURNING id AS "Id", creado_en AS "CreadoEn"
            """,
            new
            {
                datos.Ruc, datos.RazonSocial, datos.NombreComercial, datos.Ubigeo,
                datos.Direccion, datos.Distrito, datos.Provincia, datos.Departamento,
                ClaveAlta = clave.Id
            },
            transaccion, cancellationToken: ct));

        // --- 4. Su clave fac_ (de pruebas: nace en beta) ---------------------
        var fac = RepositorioTenants.GenerarClave(produccion: false);

        await conexion.ExecuteAsync(new CommandDefinition(
            """
            INSERT INTO api_keys (tenant_id, nombre, prefijo, hash)
            VALUES (@tenantId, @nombre, @prefijo, @hash)
            """,
            new
            {
                tenantId = creado.Id,
                nombre = NombreClaveEmisor,
                prefijo = fac[..20],
                hash = RepositorioTenants.CalcularHash(fac)
            },
            transaccion, cancellationToken: ct));

        // --- 5. Su webhook de la API, como el de POST /v1/webhook -----------
        var secreto = RepositorioWebhooks.GenerarSecreto();

        var webhookId = await conexion.ExecuteScalarAsync<Guid>(new CommandDefinition(
            """
            INSERT INTO webhooks
                   (tenant_id, nombre, url, secreto, eventos, origen, secreto_cambiado_en)
            VALUES (@tenantId, @nombre, @url, @secreto, '{}', 'api', now())
            RETURNING id
            """,
            new
            {
                tenantId = creado.Id,
                nombre = RepositorioWebhookApi.NombreWebhook,
                url = datos.WebhookUrl,
                secreto
            },
            transaccion, cancellationToken: ct));

        // El rastro: quién lo creó es la clave de alta (su prefijo). Sin secreto.
        await conexion.ExecuteAsync(new CommandDefinition(
            """
            INSERT INTO webhook_cambios
                   (webhook_id, tenant_id, accion, url_antes, url_despues, hecho_desde, prefijo_clave)
            VALUES (@webhookId, @tenantId, 'alta', NULL, @url, 'alta', @prefijo)
            """,
            new { webhookId, tenantId = creado.Id, url = datos.WebhookUrl, prefijo = clave.Prefijo },
            transaccion, cancellationToken: ct));

        await transaccion.CommitAsync(ct);

        return new AltaEmisor(
            ResultadoAlta.Creado,
            EmisorId: creado.Id,
            CreadoEn: creado.CreadoEn,
            Clave: fac,
            WebhookId: webhookId,
            WebhookUrl: datos.WebhookUrl,
            WebhookSecreto: secreto,
            Abandonado: abandonado);
    }

    /// <summary>
    /// Da por abandonado un alta sin confirmar: se desactiva, su clave se
    /// revoca y su webhook se apaga. NADA SE BORRA: la fila queda con la fecha,
    /// y su RUC queda libre para el alta nueva.
    /// </summary>
    private static async Task AbandonarAsync(
        NpgsqlConnection conexion, NpgsqlTransaction transaccion,
        Guid tenantId, string prefijoClaveAlta, CancellationToken ct)
    {
        await conexion.ExecuteAsync(new CommandDefinition(
            """
            INSERT INTO webhook_cambios
                   (webhook_id, tenant_id, accion, url_antes, url_despues, hecho_desde, prefijo_clave)
            SELECT id, tenant_id, 'desactivado', url, url, 'alta', @prefijo
              FROM webhooks
             WHERE tenant_id = @tenantId AND activo
            """,
            new { tenantId, prefijo = prefijoClaveAlta }, transaccion, cancellationToken: ct));

        await conexion.ExecuteAsync(new CommandDefinition(
            "UPDATE webhooks SET activo = false WHERE tenant_id = @tenantId AND activo",
            new { tenantId }, transaccion, cancellationToken: ct));

        await conexion.ExecuteAsync(new CommandDefinition(
            """
            UPDATE api_keys SET activo = false, revocado_en = now()
             WHERE tenant_id = @tenantId AND activo
            """,
            new { tenantId }, transaccion, cancellationToken: ct));

        await conexion.ExecuteAsync(new CommandDefinition(
            """
            UPDATE tenants
               SET estado_alta = 'abandonada', activo = false, abandonada_en = now()
             WHERE id = @tenantId AND estado_alta = 'sin_confirmar'
            """,
            new { tenantId }, transaccion, cancellationToken: ct));
    }

    /// <summary>
    /// La plataforma confirma que guardó lo suyo. Se puede llamar de más: si
    /// ya estaba confirmada, no cambia nada. Devuelve el estado y la fecha.
    /// </summary>
    public async Task<(string Estado, DateTime? ConfirmadaEn)> ConfirmarAsync(
        Guid tenantId, CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);

        await conexion.ExecuteAsync(new CommandDefinition(
            """
            UPDATE tenants
               SET estado_alta = 'confirmada', alta_confirmada_en = now()
             WHERE id = @tenantId AND estado_alta = 'sin_confirmar'
            """,
            new { tenantId }, cancellationToken: ct));

        var fila = await conexion.QuerySingleAsync<FilaConfirmada>(new CommandDefinition(
            """
            SELECT estado_alta AS "Estado", alta_confirmada_en AS "ConfirmadaEn"
              FROM tenants WHERE id = @tenantId
            """,
            new { tenantId }, cancellationToken: ct));

        return (fila.Estado, fila.ConfirmadaEn);
    }

    // ----------------------------------------------------- lo que refleja

    /// <summary>Para GET /v1/emisor: el alta, la marca y lo que falta para emitir.</summary>
    public async Task<EstadoEmisor> EstadoAsync(Guid tenantId, CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);

        return await conexion.QuerySingleAsync<EstadoEmisor>(new CommandDefinition(
            """
            SELECT t.estado_alta           AS "EstadoAlta",
                   t.creado_en             AS "CreadoEn",
                   t.alta_confirmada_en    AS "AltaConfirmadaEn",
                   t.identificador         AS "Identificador",
                   t.correo_respuesta      AS "CorreoRespuesta",
                   (t.logo_ruta IS NOT NULL) AS "TieneLogo",
                   t.usuario_sol           AS "UsuarioSol",
                   (t.clave_sol_cifrada IS NOT NULL) AS "TieneClaveSol",
                   t.ubigeo::text          AS "Ubigeo",
                   t.direccion             AS "Direccion",
                   t.distrito              AS "Distrito",
                   t.provincia             AS "Provincia",
                   t.departamento          AS "Departamento",
                   t.direccion_revisada_en AS "DireccionRevisadaEn",

                   (SELECT c.valido_hasta FROM certificados c
                     WHERE c.tenant_id = t.id AND c.activo
                     LIMIT 1)              AS "CertificadoValidoHasta",

                   (SELECT string_agg(s.serie::text, ',' ORDER BY s.tipo_comprobante, s.serie)
                      FROM series s
                     WHERE s.tenant_id = t.id AND s.activo) AS "SeriesTexto"

              FROM tenants t
             WHERE t.id = @tenantId
            """,
            new { tenantId }, cancellationToken: ct));
    }

    // ----------------------------------------------------------- filas

    // CLASES Y NO record struct: Dapper no materializa bien un struct envuelto
    // en Nullable (ver ProveedorCredenciales).
    private sealed record FilaExistente(Guid Id, string EstadoAlta, Guid? ClaveAlta, DateTime CreadoEn);

    private sealed record FilaCreada(Guid Id, DateTime CreadoEn);

    private sealed record FilaConfirmada(string Estado, DateTime? ConfirmadaEn);
}
'@

# --- Facturacion.Api\EndpointsAlta.cs
Planear 'Facturacion.Api\EndpointsAlta.cs' '' @'
using Facturacion.Persistencia;

namespace Facturacion.Api;

/// <summary>La clave de alta de la petición en curso. Con ámbito de petición.</summary>
public sealed class ContextoClaveAlta
{
    public ClaveAltaResuelta? Clave { get; private set; }

    public ClaveAltaResuelta Exigir() =>
        Clave ?? throw new InvalidOperationException(
            "No hay clave de alta en el contexto. El endpoint debería estar protegido.");

    internal void Establecer(ClaveAltaResuelta clave) => Clave = clave;
}

/// <summary>
/// Exige una clave de alta (alt_) en las rutas de /alta.
///
/// SOLO ESTA RUTA LA ACEPTA, y por eso la clave es estrecha sin tener que
/// restringirla en ningún otro sitio:
///
///   /v1/*     la autentica AutenticacionApiKey contra api_keys: una alt_ no
///             está ahí, da 401.
///   /admin/*  va con la sesión del panel (cookie): una cabecera no abre nada.
///   /alta/*   este filtro, contra claves_alta. Una fac_ no está ahí: 401.
///
/// Se lee de «Authorization: Bearer alt_…» o de «X-Clave-Alta: alt_…».
/// </summary>
public sealed class AutenticacionClaveAlta : IEndpointFilter
{
    public const string Cabecera = "X-Clave-Alta";

    public async ValueTask<object?> InvokeAsync(
        EndpointFilterInvocationContext contexto, EndpointFilterDelegate siguiente)
    {
        var http = contexto.HttpContext;

        var autorizacion = http.Request.Headers.Authorization.ToString();
        var clave = autorizacion.StartsWith("Bearer ", StringComparison.OrdinalIgnoreCase)
            ? autorizacion["Bearer ".Length..].Trim()
            : http.Request.Headers[Cabecera].ToString().Trim();

        var resuelta = await http.RequestServices.GetRequiredService<RepositorioAltas>()
            .ResolverClaveAsync(clave, http.RequestAborted);

        if (resuelta is null)
        {
            // Un solo mensaje para «no hay», «no existe» y «revocada»:
            // distinguirlos le diría a quien prueba cuáles existen.
            return Results.Json(
                new RespuestaError("Clave de alta no válida.",
                    $"Envíala en la cabecera Authorization: Bearer <clave> o {Cabecera}: <clave>."),
                statusCode: StatusCodes.Status401Unauthorized);
        }

        http.RequestServices.GetRequiredService<ContextoClaveAlta>().Establecer(resuelta);

        return await siguiente(contexto);
    }
}

/// <summary>
/// El alta de un emisor desde la plataforma, y lo que la rodea.
/// Diseño: alta-empresa-diseno.md §13.
///
///   POST   /alta/emisores                 clave alt_   crea emisor + fac_ + webhook
///   POST   /v1/alta/confirmar             clave fac_   la plataforma ya guardó lo suyo
///   GET    /admin/claves-alta             panel        las claves de alta
///   POST   /admin/claves-alta             panel        emitir una (se ve una vez)
///   DELETE /admin/claves-alta/{id}        panel        revocar
///   PUT    /admin/tenants/{id}/direccion  panel        corregir la dirección
/// </summary>
public static class EndpointsAlta
{
    public static void MapearAlta(this WebApplication app)
    {
        // ------------------------------------------------- POST /alta/emisores

        app.MapPost("/alta/emisores", async (
            PeticionAltaEmisor p,
            HttpContext http,
            ContextoClaveAlta contexto,
            RepositorioAltas altas,
            RepositorioUsuarios usuarios,
            ReglasDestinoWebhook reglas,
            ServicioCorreo correo,
            OpcionesCorreo opcionesCorreo,
            ILoggerFactory registros,
            CancellationToken ct) =>
        {
            var clave = contexto.Exigir();
            var log = registros.CreateLogger("Facturacion.Api.Alta");

            // La respuesta lleva la fac_ y el whsec_: que nada la guarde.
            http.Response.Headers.CacheControl = "no-store";

            var ruc = p.Ruc?.Trim() ?? "";

            var (resultado, emisorId) = await Procesar();

            async Task<(IResult, Guid?)> Procesar()
            {
                if (Direccion.ProblemaRuc(ruc) is { } problemaRuc)
                    return (Results.BadRequest(new RespuestaError("RUC inválido.", problemaRuc)), null);

                var razon = p.RazonSocial?.Trim() ?? "";

                if (razon.Length is < 3 or > 300)
                    return (Results.BadRequest(new RespuestaError(
                        "Falta la razón social.", "Tal como sale en la ficha RUC.")), null);

                var (dir, problemaDir) = Direccion.Revisar(
                    p.Ubigeo, p.Direccion, p.Distrito, p.Provincia, p.Departamento);

                if (dir is null)
                    return (Results.BadRequest(new RespuestaError("La dirección no es válida.", problemaDir)), null);

                // Las mismas reglas que POST /v1/webhook y que el worker al
                // despachar: https y dirección pública (salvo desarrollo).
                if (await DestinoWebhook.RevisarAsync(p.WebhookUrl, reglas.PermitirLocales, ct) is { } problemaUrl)
                    return (Results.BadRequest(new RespuestaError("La URL del webhook no es válida.", problemaUrl)), null);

                var datos = new DatosAltaEmisor(
                    ruc, razon,
                    string.IsNullOrWhiteSpace(p.NombreComercial) ? null : p.NombreComercial.Trim(),
                    dir.Ubigeo, dir.Direccion, dir.Distrito, dir.Provincia, dir.Departamento,
                    p.WebhookUrl!.Trim());

                AltaEmisor alta;

                try
                {
                    alta = await altas.CrearEmisorAsync(clave, datos, ct);
                }
                catch (Npgsql.PostgresException ex) when (
                    ex.SqlState == "23505" && ex.ConstraintName == "ux_tenants_ruc_vigente")
                {
                    // Alguien lo dio de alta en el panel en el mismo instante.
                    alta = new AltaEmisor(ResultadoAlta.YaExiste);
                }

                return (await Responder(alta, clave, ruc, correo, opcionesCorreo, altas, log, ct), alta.EmisorId);
            }

            // EL RASTRO, SIEMPRE: quién (la clave), qué ruta, qué empresa y cómo
            // terminó. Nunca la clave ni el secreto. Que falle no tumba el alta.
            try
            {
                await usuarios.RegistrarAccionAsync(
                    null, $"clave-alta:{clave.Prefijo}", "POST", "/alta/emisores", emisorId,
                    CodigoDe(resultado),
                    http.Connection.RemoteIpAddress?.ToString(),
                    http.Request.Headers.UserAgent.ToString(), CancellationToken.None);
            }
            catch (Exception ex)
            {
                log.LogError(ex, "No se pudo anotar en la bitácora el alta del RUC {Ruc}.", ruc);
            }

            return resultado;
        })
        .AddEndpointFilter<AutenticacionClaveAlta>()
        .WithTags("Alta de emisores")
        .WithSummary("Crea un emisor con su clave y su webhook (clave de alta)")
        .WithDescription(
            "Solo con una clave de alta (alt_), en Authorization: Bearer o en X-Clave-Alta. " +
            "Crea, en una sola transacción, el emisor (siempre en beta), su clave fac_ y su " +
            "webhook de la API, y lo deja «sin confirmar»: quien llama guarda lo suyo y " +
            "después confirma con POST /v1/alta/confirmar usando la fac_ recibida. " +
            "409 si el RUC ya existe; 429 si la clave llegó a su tope del día. " +
            "La clave y el secreto se devuelven solo aquí.");

        // --------------------------------------------- POST /v1/alta/confirmar

        app.MapPost("/v1/alta/confirmar", async (
            ContextoEmisor emisor, RepositorioAltas altas, CancellationToken ct) =>
        {
            var tenant = emisor.Exigir();
            var (estado, confirmadaEn) = await altas.ConfirmarAsync(tenant.Id, ct);

            return Results.Ok(new
            {
                estado,
                confirmadaEn,
                mensaje = estado == "confirmada"
                    ? "Alta confirmada."
                    : $"El alta está «{estado}»."
            });
        })
        .WithTags("Alta de emisores")
        .WithSummary("Confirma el alta de la empresa de la clave")
        .WithDescription(
            "La llama la plataforma cuando ya guardó la empresa. Se puede llamar de más: " +
            "si ya estaba confirmada, no cambia nada. Una empresa creada en el panel ya " +
            "está confirmada.");

        // ---------------------------------------------- las claves, en el panel

        var claves = app.MapGroup("/admin/claves-alta")
            .AddEndpointFilter<AutenticacionPanel>()
            .AddEndpointFilter(new ExigirPermiso(Permiso.AltasGestionar))
            .WithTags("Alta de emisores");

        claves.MapGet("", async (RepositorioAltas altas, CancellationToken ct) =>
            Results.Ok(await altas.ListarClavesAsync(ct)))
            .WithSummary("Las claves de alta, con su uso");

        claves.MapPost("", async (
            NuevaClaveAlta nueva, ContextoOperador operador,
            RepositorioAltas altas, CancellationToken ct) =>
        {
            var nombre = nueva.Nombre?.Trim() ?? "";

            if (nombre.Length is < 1 or > 100)
                return Results.BadRequest(new RespuestaError(
                    "Ponle un nombre a la clave.",
                    "Dónde se va a usar: «Plataforma producción», por ejemplo. Máximo 100 caracteres."));

            var tope = nueva.TopeDiario ?? 20;

            if (tope is < 1 or > 100)
                return Results.BadRequest(new RespuestaError(
                    "El tope diario va de 1 a 100.",
                    "Es cuántas empresas puede crear al día. Bajo a propósito: si se filtra, " +
                    "es todo lo que puede hacer."));

            var (id, clave, prefijo) = await altas.CrearClaveAsync(
                nombre, (short)tope, operador.Exigir().Id, ct);

            return Results.Ok(new
            {
                id,
                prefijo,
                clave,
                aviso =
                    "Esta es la ÚNICA vez que se muestra. Va en el .env de la plataforma " +
                    "(FACTURACION_CLAVE_ALTA). No la pegues en ningún chat ni correo."
            });
        })
        .WithSummary("Emite una clave de alta")
        .WithDescription("Devuelve el secreto en claro UNA sola vez. En la base solo queda su hash.");

        claves.MapDelete("/{id:guid}", async (
            Guid id, ContextoOperador operador, RepositorioAltas altas, CancellationToken ct) =>
        {
            var revocada = await altas.RevocarClaveAsync(id, operador.Exigir().Id, ct);

            return revocada
                ? Results.Ok(new { mensaje = "Clave de alta revocada. La plataforma ya no puede crear emisores con ella." })
                : Results.NotFound(new RespuestaError("No se encontró la clave, o ya estaba revocada."));
        })
        .WithSummary("Revoca una clave de alta")
        .WithDescription("No se borra: queda quién la revocó y cuándo.");

        // ------------------------------------- PUT /admin/tenants/{id}/direccion

        app.MapPut("/admin/tenants/{id:guid}/direccion", async (
            Guid id, CambioDireccion cambio, RepositorioAdmin admin, CancellationToken ct) =>
        {
            var (dir, problema) = Direccion.Revisar(
                cambio.Ubigeo, cambio.Direccion, cambio.Distrito, cambio.Provincia, cambio.Departamento);

            if (dir is null)
                return Results.BadRequest(new RespuestaError("La dirección no es válida.", problema));

            var guardada = await admin.GuardarDireccionAsync(
                id, dir.Ubigeo, dir.Direccion, dir.Distrito, dir.Provincia, dir.Departamento, ct);

            return guardada
                ? Results.Ok(new { mensaje = "Dirección guardada. Sale así en los próximos comprobantes." })
                : Results.NotFound(new RespuestaError("No se encontró la empresa."));
        })
        .AddEndpointFilter<AutenticacionPanel>()
        .AddEndpointFilter(new ExigirPermiso(Permiso.EmpresasEditar))
        .WithTags("Administración")
        .WithSummary("Corrige la dirección de la empresa")
        .WithDescription(
            "Los comprobantes ya emitidos no cambian: llevan la dirección que tenían. " +
            "Guardarla la marca como revisada.");
    }

    private static async Task<IResult> Responder(
        AltaEmisor alta, ClaveAltaResuelta clave, string ruc,
        ServicioCorreo correo, OpcionesCorreo opcionesCorreo,
        RepositorioAltas altas, ILogger log, CancellationToken ct)
    {
        switch (alta.Resultado)
        {
            case ResultadoAlta.Creado:
                // Al registro va QUÉ pasó. Nunca la clave ni el secreto.
                log.LogInformation(
                    "Emisor {Ruc} creado por la clave de alta {Prefijo}… ({Emisor}){Abandonado}",
                    ruc, clave.Prefijo, alta.EmisorId,
                    alta.Abandonado is { } a ? $"; el alta anterior sin confirmar ({a}) quedó abandonada" : "");

                return Results.Ok(new
                {
                    emisorId = alta.EmisorId,
                    estado = "sin_confirmar",
                    creadoEn = alta.CreadoEn,
                    ambiente = "beta",
                    clave = alta.Clave,
                    webhook = new
                    {
                        id = alta.WebhookId,
                        url = alta.WebhookUrl,
                        secreto = alta.WebhookSecreto
                    },
                    abandonado = alta.Abandonado,
                    siguiente = "POST /v1/alta/confirmar con la clave recibida, en cuanto lo hayas guardado.",
                    aviso =
                        "La clave y el secreto solo se muestran aquí. Mientras no se confirme, " +
                        "el emisor queda «sin confirmar», y otro alta del mismo RUC lo dará por abandonado."
                });

            case ResultadoAlta.YaExiste:
                return Results.Conflict(new RespuestaError(
                    "Ese RUC ya está registrado en el servicio.",
                    "No se creó nada. Si es la misma empresa, conéctala con su clave " +
                    "(«Comprobar» y «Conectar»)."));

            case ResultadoAlta.EnCurso:
                return Results.Conflict(new RespuestaError(
                    "Hay un alta de este RUC en curso.",
                    "Empezó hace menos de " +
                    $"{(int)RepositorioAltas.EsperaAntesDeAbandonar.TotalMinutes} minutos y todavía " +
                    "no se confirmó. No se creó nada: espera un poco y vuelve a intentarlo."));

            default:
                log.LogWarning(
                    "La clave de alta {Prefijo}… llegó a su tope de {Tope} altas hoy.",
                    clave.Prefijo, clave.TopeDiario);

                if (alta.AvisarTope)
                    await AvisarTopeAsync(clave, correo, opcionesCorreo, altas, log, ct);

                return Results.Json(new RespuestaError(
                    $"La clave de alta llegó a su tope de {clave.TopeDiario} empresas por hoy.",
                    "No se creó nada. Si no esperabas tantas altas, revisa en el panel del " +
                    "servicio quién las hizo y revoca la clave."),
                    statusCode: StatusCodes.Status429TooManyRequests);
        }
    }

    /// <summary>
    /// Un correo, una vez al día, a quienes pueden revocar la clave. Si la
    /// clave se filtró, es el aviso que llega antes que el cliente molesto.
    /// </summary>
    private static async Task AvisarTopeAsync(
        ClaveAltaResuelta clave, ServicioCorreo correo, OpcionesCorreo opciones,
        RepositorioAltas altas, ILogger log, CancellationToken ct)
    {
        try
        {
            var para = await altas.DestinatariosAvisoAsync(ct);

            var nombre = System.Net.WebUtility.HtmlEncode(clave.Nombre);
            var prefijo = System.Net.WebUtility.HtmlEncode(clave.Prefijo);
            var panel = System.Net.WebUtility.HtmlEncode(opciones.UrlPanel.TrimEnd('/') + "/admin.html");

            var cuerpo =
                $"<p>La clave de alta <strong>{nombre}</strong> (<code>{prefijo}…</code>) " +
                $"llegó hoy a su tope de <strong>{clave.TopeDiario}</strong> empresas.</p>" +
                "<p>Desde ahora y hasta mañana, las altas con esa clave se rechazan.</p>" +
                "<p><strong>Si no esperabas tantas altas, la clave puede haberse filtrado.</strong> " +
                $"Revisa las empresas creadas hoy y revócala en <a href=\"{panel}\">el panel</a> " +
                "(bloque «Claves de alta»).</p>";

            foreach (var destino in para)
                await correo.EnviarAsync(destino, "Tope de altas alcanzado: revisa la clave de alta", cuerpo, ct);

            if (para.Count == 0)
                log.LogWarning("Nadie tiene el permiso altas.gestionar: el aviso del tope no se mandó.");
        }
        catch (Exception ex)
        {
            log.LogError(ex, "No se pudo mandar el aviso del tope de la clave de alta {Prefijo}…", clave.Prefijo);
        }
    }

    private static int CodigoDe(IResult resultado) =>
        resultado is IStatusCodeHttpResult { StatusCode: { } codigo } ? codigo : 200;
}

/// <summary>Cuerpo de POST /alta/emisores. Ni ambiente ni SOL: eso es del panel.</summary>
public record PeticionAltaEmisor(
    string? Ruc,
    string? RazonSocial,
    string? NombreComercial,
    string? Direccion,
    string? Ubigeo,
    string? Distrito,
    string? Provincia,
    string? Departamento,
    string? WebhookUrl);

public record NuevaClaveAlta(string? Nombre, int? TopeDiario);

public record CambioDireccion(
    string? Ubigeo, string? Direccion, string? Distrito, string? Provincia, string? Departamento);
'@

# --- Facturacion.Api\Direccion.cs
Planear 'Facturacion.Api\Direccion.cs' '' @'
using System.Globalization;
using System.Text;

namespace Facturacion.Api;

/// <summary>La dirección del emisor, ya limpia y comprobada.</summary>
public sealed record DireccionRevisada(
    string Ubigeo, string Direccion, string Distrito, string Provincia, string Departamento);

/// <summary>
/// Las reglas de la dirección del emisor y del RUC, para el alta desde la
/// plataforma, el alta del panel y la edición de la dirección.
///
/// POR QUÉ IMPORTA: la dirección sale en cada comprobante. SUNAT no rechaza
/// una dirección de Lima en una empresa de Arequipa, pero el comprobante sale
/// mal y nadie se da cuenta. El caso real: el formulario traía LIMA y 150101
/// por defecto.
///
/// LO QUE SE COMPRUEBA: que esté todo, y que los dos primeros dígitos del
/// ubigeo (el departamento, catálogo del INEI) correspondan al departamento
/// escrito. NO se comprueban provincia ni distrito contra el ubigeo: eso
/// exige el catálogo completo de distritos (unos 1.900), y la idea de
/// derivarlos del ubigeo en vez de comprobarlos está anotada para más
/// adelante (alta-empresa-diseno.md §14).
/// </summary>
public static class Direccion
{
    /// <summary>Los 25 departamentos del INEI por su código. Sin tildes y en mayúsculas.</summary>
    private static readonly Dictionary<string, string[]> Departamentos = new()
    {
        ["01"] = ["AMAZONAS"],
        ["02"] = ["ANCASH"],
        ["03"] = ["APURIMAC"],
        ["04"] = ["AREQUIPA"],
        ["05"] = ["AYACUCHO"],
        ["06"] = ["CAJAMARCA"],
        ["07"] = ["CALLAO", "PROVINCIA CONSTITUCIONAL DEL CALLAO"],
        ["08"] = ["CUSCO", "CUZCO"],
        ["09"] = ["HUANCAVELICA"],
        ["10"] = ["HUANUCO"],
        ["11"] = ["ICA"],
        ["12"] = ["JUNIN"],
        ["13"] = ["LA LIBERTAD"],
        ["14"] = ["LAMBAYEQUE"],
        ["15"] = ["LIMA"],
        ["16"] = ["LORETO"],
        ["17"] = ["MADRE DE DIOS"],
        ["18"] = ["MOQUEGUA"],
        ["19"] = ["PASCO"],
        ["20"] = ["PIURA"],
        ["21"] = ["PUNO"],
        ["22"] = ["SAN MARTIN"],
        ["23"] = ["TACNA"],
        ["24"] = ["TUMBES"],
        ["25"] = ["UCAYALI"]
    };

    /// <summary>
    /// Para comparar: sin tildes, en mayúsculas y con un solo espacio entre
    /// palabras. «Lima», «LIMA » y «lima» valen igual; «Junín» y «JUNIN» también.
    /// </summary>
    public static string Normalizar(string? texto)
    {
        if (string.IsNullOrWhiteSpace(texto)) return "";

        var sinTildes = new StringBuilder();

        foreach (var c in texto.Normalize(NormalizationForm.FormD))
            if (CharUnicodeInfo.GetUnicodeCategory(c) != UnicodeCategory.NonSpacingMark)
                sinTildes.Append(c);

        return string.Join(' ',
            sinTildes.ToString().Normalize(NormalizationForm.FormC)
                .ToUpperInvariant()
                .Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries));
    }

    /// <summary>
    /// Limpia y comprueba. Devuelve la dirección lista para guardar, o el
    /// motivo por el que no vale, escrito para quien la tecleó.
    ///
    /// SE GUARDA COMO SE ESCRIBIÓ (solo sin espacios de sobra): la
    /// normalización es para comparar, no para cambiar lo que sale en el
    /// comprobante.
    /// </summary>
    public static (DireccionRevisada? Direccion, string? Problema) Revisar(
        string? ubigeo, string? direccion, string? distrito, string? provincia, string? departamento)
    {
        static string Limpio(string? s) =>
            string.Join(' ', (s ?? "").Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries));

        var u = Limpio(ubigeo);
        var d = Limpio(direccion);
        var di = Limpio(distrito);
        var p = Limpio(provincia);
        var de = Limpio(departamento);

        if (d.Length < 3) return (null, "Falta la dirección (calle y número).");
        if (d.Length > 200) return (null, "La dirección es demasiado larga (máximo 200 caracteres).");
        if (di.Length == 0) return (null, "Falta el distrito.");
        if (p.Length == 0) return (null, "Falta la provincia.");
        if (de.Length == 0) return (null, "Falta el departamento.");
        if (di.Length > 60 || p.Length > 60 || de.Length > 60)
            return (null, "Distrito, provincia y departamento: máximo 60 caracteres cada uno.");

        if (u.Length != 6 || !u.All(char.IsAsciiDigit))
            return (null, "El ubigeo son 6 dígitos (por ejemplo 040101 para Arequipa, Arequipa, Arequipa).");

        if (!Departamentos.TryGetValue(u[..2], out var nombres))
            return (null, $"El ubigeo {u} no existe: los dos primeros dígitos van de 01 a 25.");

        var escrito = Normalizar(de);

        if (!nombres.Contains(escrito))
            return (null,
                $"El ubigeo {u} es de {Titulo(nombres[0])}, y el departamento dice «{de}». " +
                "Uno de los dos está mal: revisa el ubigeo del distrito en la ficha RUC.");

        return (new DireccionRevisada(u, d, di, p, de), null);
    }

    /// <summary>
    /// El RUC: 11 dígitos, empieza por 10, 15, 16, 17 o 20, y el último es el
    /// dígito verificador (módulo 11, el mismo cálculo que hace SUNAT). Así un
    /// dedazo no crea un emisor que no existe.
    /// </summary>
    public static string? ProblemaRuc(string? ruc)
    {
        if (ruc is null || ruc.Length != 11 || !ruc.All(char.IsAsciiDigit))
            return "El RUC son 11 dígitos.";

        if (ruc[..2] is not ("10" or "15" or "16" or "17" or "20"))
            return "Un RUC empieza por 10, 15, 16, 17 o 20.";

        int[] pesos = [5, 4, 3, 2, 7, 6, 5, 4, 3, 2];

        var suma = 0;
        for (var i = 0; i < 10; i++) suma += (ruc[i] - '0') * pesos[i];

        var digito = 11 - suma % 11;
        if (digito == 10) digito = 0;
        if (digito == 11) digito = 1;

        return digito == ruc[10] - '0'
            ? null
            : "Ese RUC no existe: el último dígito no cuadra. Revisa que esté bien copiado.";
    }

    private static string Titulo(string s) =>
        CultureInfo.GetCultureInfo("es-PE").TextInfo.ToTitleCase(s.ToLowerInvariant());
}
'@

# --- Facturacion.Persistencia\RepositorioAdmin.cs
Planear 'Facturacion.Persistencia\RepositorioAdmin.cs' 'CB98B33D1EF97899F3A8EEF50D26538F6170C26DB0D64B177FEA7CCFAE01C68C' @'
using Dapper;
using Npgsql;

namespace Facturacion.Persistencia;

/// <summary>Una empresa vista desde el panel de administración.</summary>
public record TenantAdmin(
    Guid Id,
    string Ruc,
    string RazonSocial,
    string NombreComercial,
    string Ambiente,
    short MaxConcurrencia,
    bool Activo,
    DateTime CreadoEn,
    int Comprobantes,
    bool TieneCertificado,
    DateTime? CertificadoVence,
    int Series,
    int Claves,
    string? UsuarioSol,
    bool TieneClaveSol,
    bool GreHabilitado,
    string? GreClientId,
    bool TieneGreSecret,

    // La marca (migración 020). LogoVersion es un resumen de la ruta del
    // logo: cambia cuando se sube otro, y así el panel sabe que tiene que
    // volver a pedir la imagen en vez de enseñar la que tiene guardada. La
    // ruta en sí no sale del servicio.
    string? Identificador,
    string? ColorMarca,
    string? CorreoRespuesta,
    string? LogoVersion,

    // El alta (migración 024). DAPPER EMPAREJA POR POSICIÓN: estas columnas
    // van al final de la consulta en este mismo orden.
    string EstadoAlta,
    DateTime? AltaConfirmadaEn,
    DateTime? AbandonadaEn,
    string? ClaveAltaNombre,
    string? ClaveAltaPrefijo,

    // La dirección, para poder corregirla desde el panel, y si alguien la
    // revisó a propósito.
    string Ubigeo,
    string Direccion,
    string Distrito,
    string Provincia,
    string Departamento,
    DateTime? DireccionRevisadaEn)
{
    public bool EsProduccion => Ambiente == "produccion";

    public bool TieneLogo => LogoVersion is not null;

    /// <summary>Puede emitir guías en producción.</summary>
    public bool GreListo =>
        GreHabilitado &&
        !string.IsNullOrWhiteSpace(GreClientId) &&
        TieneGreSecret;
}

/// <summary>Datos para dar de alta una empresa.</summary>
public class NuevoTenant
{
    public string Ruc { get; set; } = "";
    public string RazonSocial { get; set; } = "";
    public string NombreComercial { get; set; } = "";
    public string Ubigeo { get; set; } = "150101";
    public string Direccion { get; set; } = "";
    public string Distrito { get; set; } = "";
    public string Provincia { get; set; } = "";
    public string Departamento { get; set; } = "";
    public string Ambiente { get; set; } = "beta";
    public string UsuarioSol { get; set; } = "MODDATOS";
    public short MaxConcurrencia { get; set; } = 1;

    /// <summary>
    /// El {empresa} del portal. Opcional al dar de alta: se puede poner
    /// después, pero una sola vez.
    /// </summary>
    public string? Identificador { get; set; }
}

/// <summary>Cómo terminó un intento de guardar la marca.</summary>
public enum ResultadoMarca
{
    Guardada,
    NoExiste,

    /// <summary>
    /// Ya tenía otro identificador. No se guardó NADA de la petición: ni el
    /// color ni el correo. A medias sería peor, porque el panel diría
    /// "error" y la mitad sí habría cambiado.
    /// </summary>
    IdentificadorFijo
}

/// <summary>Solo para leer el identificador actual con FOR UPDATE.</summary>
public record IdentificadorTenant(Guid Id, string? Identificador);

/// <summary>Lo que hace falta para guardar o servir el logo.</summary>
public record LogoTenant(string Ruc, string? LogoRuta);

/// <summary>Una serie de numeración.</summary>
/// <param name="Comprobantes">
/// Cuántos comprobantes se emitieron con esta serie. Determina si se puede
/// eliminar: con uno solo, ya hay histórico que conservar.
/// </param>
public record SerieAdmin(
    Guid Id,
    string TipoComprobante,
    string Serie,
    int UltimoCorrelativo,
    bool Activo,
    DateTime CreadoEn,
    int Comprobantes)
{
    /// <summary>
    /// Una serie sin comprobantes se puede borrar sin consecuencias.
    /// Con comprobantes, borrarla dejaría huérfano el rastro de esa
    /// numeración, y eso es un problema tributario, no de datos.
    /// </summary>
    public bool SePuedeEliminar => Comprobantes == 0;
}

/// <summary>Una clave de acceso, sin el secreto.</summary>
public record ClaveAdmin(
    Guid Id,
    string Nombre,
    string Prefijo,
    bool Activo,
    DateTime? UltimoUso,
    DateTime CreadoEn);

/// <summary>
/// Administración de empresas, series y claves de acceso.
///
/// Usa el rol de operador porque trabaja sobre todas las empresas y porque
/// crea filas en tablas que la aplicación normal solo puede leer.
///
/// TODO lo que hay aquí se hacía hasta ahora escribiendo SQL a mano. Eso
/// funciona mientras el sistema lo maneja quien lo construyó, y deja de
/// funcionar el día que hay que delegarlo. Un alta de empresa no debería
/// requerir saber PostgreSQL.
/// </summary>
public sealed class RepositorioAdmin
{
    private readonly string _cadenaOperador;

    public RepositorioAdmin(string cadenaConexionOperador)
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

    // ------------------------------------------------------------- empresas

    public async Task<IReadOnlyList<TenantAdmin>> ListarTenantsAsync(
        CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);

        var filas = await conexion.QueryAsync<TenantAdmin>(
            new CommandDefinition(
                """
                SELECT t.id               AS "Id",
                       t.ruc              AS "Ruc",
                       t.razon_social     AS "RazonSocial",
                       t.nombre_comercial AS "NombreComercial",
                       t.ambiente         AS "Ambiente",
                       t.max_concurrencia AS "MaxConcurrencia",
                       t.activo           AS "Activo",
                       t.creado_en        AS "CreadoEn",

                       (SELECT count(*)::int FROM comprobantes c
                         WHERE c.tenant_id = t.id)              AS "Comprobantes",

                       EXISTS (SELECT 1 FROM certificados ce
                                WHERE ce.tenant_id = t.id AND ce.activo)
                                                                AS "TieneCertificado",

                       (SELECT ce.valido_hasta FROM certificados ce
                         WHERE ce.tenant_id = t.id AND ce.activo
                         LIMIT 1)                               AS "CertificadoVence",

                       (SELECT count(*)::int FROM series s
                         WHERE s.tenant_id = t.id AND s.activo)  AS "Series",

                       (SELECT count(*)::int FROM api_keys k
                         WHERE k.tenant_id = t.id AND k.activo)  AS "Claves",

                       t.usuario_sol      AS "UsuarioSol",
                       (t.clave_sol_cifrada IS NOT NULL) AS "TieneClaveSol",
                       t.gre_habilitado   AS "GreHabilitado",
                       t.gre_client_id    AS "GreClientId",
                       (t.gre_client_secret_cifrado IS NOT NULL) AS "TieneGreSecret",

                       t.identificador    AS "Identificador",
                       t.color_marca      AS "ColorMarca",
                       t.correo_respuesta AS "CorreoRespuesta",
                       md5(t.logo_ruta)   AS "LogoVersion",

                       t.estado_alta        AS "EstadoAlta",
                       t.alta_confirmada_en AS "AltaConfirmadaEn",
                       t.abandonada_en      AS "AbandonadaEn",
                       ka.nombre            AS "ClaveAltaNombre",
                       ka.prefijo::text     AS "ClaveAltaPrefijo",

                       t.ubigeo::text       AS "Ubigeo",
                       t.direccion          AS "Direccion",
                       t.distrito           AS "Distrito",
                       t.provincia          AS "Provincia",
                       t.departamento       AS "Departamento",
                       t.direccion_revisada_en AS "DireccionRevisadaEn"

                  FROM tenants t
                  LEFT JOIN claves_alta ka ON ka.id = t.creado_por_clave_alta
                 -- Alfabético por razón social. Con cincuenta empresas, el
                 -- orden por fecha de alta obliga a recorrer toda la lista
                 -- para encontrar una; el alfabético permite ir directo.
                 ORDER BY t.razon_social
                """,
                cancellationToken: ct));

        return filas.ToList();
    }

    public async Task<Guid> CrearTenantAsync(
        NuevoTenant nuevo, CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);

        return await conexion.ExecuteScalarAsync<Guid>(new CommandDefinition(
            """
            INSERT INTO tenants
                (ruc, razon_social, nombre_comercial, ubigeo, direccion,
                 distrito, provincia, departamento, ambiente, usuario_sol,
                 max_concurrencia, identificador, direccion_revisada_en)
            VALUES
                (@Ruc, @RazonSocial, @NombreComercial, @Ubigeo, @Direccion,
                 @Distrito, @Provincia, @Departamento, @Ambiente, @UsuarioSol,
                 @MaxConcurrencia, @Identificador,
                 -- El panel ya no trae LIMA por defecto y exige la
                 -- dirección: quien la escribió la revisó.
                 now())
            RETURNING id
            """,
            nuevo, cancellationToken: ct));
    }

    public async Task<bool> ActualizarTenantAsync(
        Guid id, bool? activo, short? maxConcurrencia,
        CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);

        var filas = await conexion.ExecuteAsync(new CommandDefinition(
            """
            UPDATE tenants
               SET activo = COALESCE(@activo, activo),
                   max_concurrencia = COALESCE(@maxConcurrencia, max_concurrencia)
             WHERE id = @id
            """,
            new { id, activo, maxConcurrencia }, cancellationToken: ct));

        return filas > 0;
    }

    /// <summary>
    /// Corrige la dirección y la marca como revisada.
    ///
    /// LOS COMPROBANTES YA EMITIDOS NO CAMBIAN: su XML se firmó con la que
    /// tenían. Esto vale para los siguientes.
    /// </summary>
    public async Task<bool> GuardarDireccionAsync(
        Guid id, string ubigeo, string direccion, string distrito,
        string provincia, string departamento, CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);

        var filas = await conexion.ExecuteAsync(new CommandDefinition(
            """
            UPDATE tenants
               SET ubigeo = @ubigeo,
                   direccion = @direccion,
                   distrito = @distrito,
                   provincia = @provincia,
                   departamento = @departamento,
                   direccion_revisada_en = now()
             WHERE id = @id
            """,
            new { id, ubigeo, direccion, distrito, provincia, departamento },
            cancellationToken: ct));

        return filas > 0;
    }

    // ---------------------------------------------------------------- marca

    /// <summary>
    /// Guarda el identificador del portal, el color y el correo de respuesta.
    ///
    /// EL COLOR Y EL CORREO SE REEMPLAZAN SIEMPRE: null los quita. El panel
    /// manda los tres campos cada vez, así que lo que llega es el estado
    /// completo que se quiere.
    ///
    /// EL IDENTIFICADOR SOLO SE PONE SI NO HABÍA. Si ya había uno y llega
    /// otro, no se guarda nada y se devuelve IdentificadorFijo con el actual.
    /// La base lo impediría igual (disparador de la 020), pero aquí se
    /// detecta antes para dar un mensaje claro y no dejar nada a medias.
    ///
    /// Un identificador que ya usa otra empresa sale como PostgresException
    /// 23505: lo traduce el endpoint.
    /// </summary>
    public async Task<(ResultadoMarca Resultado, string? IdentificadorActual)> GuardarMarcaAsync(
        Guid id, string? identificador, string? colorMarca, string? correoRespuesta,
        CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);
        await using var transaccion = await conexion.BeginTransactionAsync(ct);

        // FOR UPDATE: dos pestañas guardando a la vez no pueden poner cada
        // una un identificador distinto.
        var fila = await conexion.QuerySingleOrDefaultAsync<IdentificadorTenant>(
            new CommandDefinition(
                """
                SELECT id AS "Id", identificador AS "Identificador"
                  FROM tenants
                 WHERE id = @id
                   FOR UPDATE
                """,
                new { id }, transaccion, cancellationToken: ct));

        if (fila is null)
            return (ResultadoMarca.NoExiste, null);

        if (fila.Identificador is not null &&
            identificador is not null &&
            identificador != fila.Identificador)
            return (ResultadoMarca.IdentificadorFijo, fila.Identificador);

        await conexion.ExecuteAsync(new CommandDefinition(
            """
            UPDATE tenants
               SET identificador    = COALESCE(identificador, @identificador),
                   color_marca      = @colorMarca,
                   correo_respuesta = @correoRespuesta
             WHERE id = @id
            """,
            new { id, identificador, colorMarca, correoRespuesta },
            transaccion, cancellationToken: ct));

        await transaccion.CommitAsync(ct);

        return (ResultadoMarca.Guardada, fila.Identificador ?? identificador);
    }

    /// <summary>El RUC (para la carpeta del almacén) y la ruta del logo actual.</summary>
    public async Task<LogoTenant?> ObtenerLogoAsync(Guid id, CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);

        return await conexion.QuerySingleOrDefaultAsync<LogoTenant>(new CommandDefinition(
            """
            SELECT ruc AS "Ruc", logo_ruta AS "LogoRuta"
              FROM tenants
             WHERE id = @id
            """,
            new { id }, cancellationToken: ct));
    }

    /// <summary>
    /// Apunta la empresa a un logo ya guardado en el almacén.
    ///
    /// EL LOGO ANTERIOR NO SE BORRA del almacén: solo deja de apuntarse.
    /// Pesa unos kilobytes, y así un cambio por error se deshace volviendo a
    /// apuntar la ruta vieja.
    /// </summary>
    public async Task<bool> GuardarLogoAsync(Guid id, string ruta, CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);

        var filas = await conexion.ExecuteAsync(new CommandDefinition(
            "UPDATE tenants SET logo_ruta = @ruta WHERE id = @id",
            new { id, ruta }, cancellationToken: ct));

        return filas > 0;
    }

    /// <summary>
    /// Guarda las credenciales SOL de una empresa. La clave se cifra igual
    /// que los certificados.
    ///
    /// DEBE SER EL USUARIO SOL SECUNDARIO del contribuyente, nunca el
    /// principal. El principal puede hacer todo en el portal de SUNAT:
    /// declarar, pagar, modificar datos. Ese nivel de acceso no tiene por
    /// qué vivir en la base de datos de un proveedor.
    /// </summary>
    public async Task<bool> GuardarCredencialesSolAsync(
        Guid tenantId, string usuario, string clave,
        IProtectorDeSecretos protector, CancellationToken ct = default)
    {
        if (string.IsNullOrWhiteSpace(usuario))
            throw new ArgumentException("Falta el usuario SOL.", nameof(usuario));

        if (string.IsNullOrWhiteSpace(clave))
            throw new ArgumentException("Falta la clave SOL.", nameof(clave));

        var cifrada = protector.ProtegerTexto(clave);

        await using var conexion = await AbrirAsync(ct);

        var filas = await conexion.ExecuteAsync(new CommandDefinition(
            """
            UPDATE tenants
               SET usuario_sol = @usuario,
                   clave_sol_cifrada = @cifrada
             WHERE id = @tenantId
            """,
            new { tenantId, usuario, cifrada }, cancellationToken: ct));

        return filas > 0;
    }

    /// <summary>
    /// Guarda las credenciales de la API de guías de remisión.
    ///
    /// SON DISTINTAS DE LAS CREDENCIALES SOL. El contribuyente las genera en
    /// su menú SOL, opción "Credenciales de API SUNAT", una sola vez, y solo
    /// sirven para guías.
    ///
    /// Una empresa que emita facturas y guías tendrá los dos juegos: la clave
    /// SOL para las facturas, y estas dos para las guías.
    /// </summary>
    public async Task<bool> GuardarCredencialesGreAsync(
        Guid tenantId, string clientId, string clientSecret,
        IProtectorDeSecretos protector, CancellationToken ct = default)
    {
        if (string.IsNullOrWhiteSpace(clientId))
            throw new ArgumentException("Falta el client_id.", nameof(clientId));

        if (string.IsNullOrWhiteSpace(clientSecret))
            throw new ArgumentException("Falta el client_secret.", nameof(clientSecret));

        var cifrado = protector.ProtegerTexto(clientSecret);

        await using var conexion = await AbrirAsync(ct);

        var filas = await conexion.ExecuteAsync(new CommandDefinition(
            """
            UPDATE tenants
               SET gre_client_id = @clientId,
                   gre_client_secret_cifrado = @cifrado,

                   -- Guardar las credenciales habilita las guías: no tiene
                   -- sentido tenerlas cargadas y el módulo apagado.
                   gre_habilitado = true
             WHERE id = @tenantId
            """,
            new { tenantId, clientId = clientId.Trim(), cifrado },
            cancellationToken: ct));

        return filas > 0;
    }

    /// <summary>Activa o desactiva la emisión de guías.</summary>
    public async Task<bool> CambiarGreHabilitadoAsync(
        Guid tenantId, bool habilitado, CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);

        var filas = await conexion.ExecuteAsync(new CommandDefinition(
            "UPDATE tenants SET gre_habilitado = @habilitado WHERE id = @tenantId",
            new { tenantId, habilitado }, cancellationToken: ct));

        return filas > 0;
    }

    /// <summary>
    /// Cambia el ambiente de una empresa entre beta y producción.
    ///
    /// Quien llame debe haber comprobado antes que está lista: pasar a
    /// producción sin certificado válido o sin clave SOL hace que todas sus
    /// facturas fallen desde el primer minuto.
    /// </summary>
    public async Task<bool> CambiarAmbienteAsync(
        Guid tenantId, string ambiente, CancellationToken ct = default)
    {
        if (ambiente is not ("beta" or "produccion"))
            throw new ArgumentException(
                "El ambiente solo puede ser 'beta' o 'produccion'.", nameof(ambiente));

        await using var conexion = await AbrirAsync(ct);

        var filas = await conexion.ExecuteAsync(new CommandDefinition(
            "UPDATE tenants SET ambiente = @ambiente WHERE id = @tenantId",
            new { tenantId, ambiente }, cancellationToken: ct));

        return filas > 0;
    }

    // --------------------------------------------------------------- series

    public async Task<IReadOnlyList<SerieAdmin>> ListarSeriesAsync(
        Guid tenantId, CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);

        var filas = await conexion.QueryAsync<SerieAdmin>(
            new CommandDefinition(
                """
                SELECT s.id                 AS "Id",
                       s.tipo_comprobante   AS "TipoComprobante",
                       s.serie              AS "Serie",
                       s.ultimo_correlativo AS "UltimoCorrelativo",
                       s.activo             AS "Activo",
                       s.creado_en          AS "CreadoEn",

                       (SELECT count(*)::int FROM comprobantes c
                         WHERE c.tenant_id = s.tenant_id
                           AND c.tipo_comprobante = s.tipo_comprobante
                           AND c.serie = s.serie)  AS "Comprobantes"

                  FROM series s
                 WHERE s.tenant_id = @tenantId
                 -- La más reciente primero.
                 --
                 -- El orden por tipo y serie se lee mejor, pero obliga a
                 -- buscar en toda la tabla la que acabas de crear. Como una
                 -- empresa tiene pocas series, la comodidad de verla arriba
                 -- pesa más que la prolijidad del agrupamiento.
                 ORDER BY s.creado_en DESC
                """,
                new { tenantId }, cancellationToken: ct));

        return filas.ToList();
    }

    /// <summary>
    /// Da de alta una serie.
    ///
    /// EL CORRELATIVO INICIAL PUEDE NO SER CERO, y eso importa: cuando una
    /// empresa migra desde otro sistema, ya emitió comprobantes con esa serie.
    /// Empezar de nuevo en 1 generaría duplicados que SUNAT rechazaría, y
    /// obligaría a resolverlo con la administración tributaria.
    /// </summary>
    public async Task<Guid> CrearSerieAsync(
        Guid tenantId, string tipoComprobante, string serie,
        int correlativoInicial = 0, CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);

        return await conexion.ExecuteScalarAsync<Guid>(new CommandDefinition(
            """
            INSERT INTO series (tenant_id, tipo_comprobante, serie, ultimo_correlativo)
            VALUES (@tenantId, @tipoComprobante, @serie, @correlativoInicial)
            ON CONFLICT (tenant_id, tipo_comprobante, serie)
            DO UPDATE SET activo = true
            RETURNING id
            """,
            new { tenantId, tipoComprobante, serie, correlativoInicial },
            cancellationToken: ct));
    }

    /// <summary>
    /// Elimina una serie, pero SOLO si nunca se usó.
    ///
    /// La comprobación va dentro del mismo DELETE, no en una consulta previa:
    /// entre comprobar y borrar hay una ventana en la que alguien podría
    /// emitir un comprobante con esa serie. Hacerlo en una sola sentencia
    /// cierra esa ventana.
    ///
    /// Devuelve false si la serie no existe o si ya tiene comprobantes.
    /// </summary>
    public async Task<bool> EliminarSerieAsync(
        Guid tenantId, Guid serieId, CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);

        var filas = await conexion.ExecuteAsync(new CommandDefinition(
            """
            DELETE FROM series s
             WHERE s.id = @serieId
               AND s.tenant_id = @tenantId
               AND NOT EXISTS (
                     SELECT 1 FROM comprobantes c
                      WHERE c.tenant_id = s.tenant_id
                        AND c.tipo_comprobante = s.tipo_comprobante
                        AND c.serie = s.serie)
            """,
            new { tenantId, serieId }, cancellationToken: ct));

        return filas > 0;
    }

    /// <summary>
    /// Activa o desactiva una serie.
    ///
    /// Desactivarla impide emitir con ella, pero NO toca el histórico: los
    /// comprobantes ya emitidos siguen consultándose y descargándose igual.
    /// Es lo que se hace cuando una sucursal cierra, cuando cambia el esquema
    /// de numeración, o cuando hay que cerrar una serie y abrir otra.
    /// </summary>
    public async Task<bool> CambiarEstadoSerieAsync(
        Guid tenantId, Guid serieId, bool activo, CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);

        var filas = await conexion.ExecuteAsync(new CommandDefinition(
            """
            UPDATE series SET activo = @activo
             WHERE id = @serieId AND tenant_id = @tenantId
            """,
            new { tenantId, serieId, activo }, cancellationToken: ct));

        return filas > 0;
    }

    // --------------------------------------------------------------- claves

    public async Task<IReadOnlyList<ClaveAdmin>> ListarClavesAsync(
        Guid tenantId, CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);

        var filas = await conexion.QueryAsync<ClaveAdmin>(
            new CommandDefinition(
                """
                SELECT id         AS "Id",
                       nombre     AS "Nombre",
                       prefijo    AS "Prefijo",
                       activo     AS "Activo",
                       ultimo_uso AS "UltimoUso",
                       creado_en  AS "CreadoEn"
                  FROM api_keys
                 WHERE tenant_id = @tenantId
                 ORDER BY creado_en DESC
                """,
                new { tenantId }, cancellationToken: ct));

        return filas.ToList();
    }

    /// <summary>
    /// Crea una clave de acceso y devuelve el secreto EN CLARO.
    ///
    /// ES LA ÚNICA VEZ QUE ESE VALOR EXISTE FUERA DEL CLIENTE. En la base solo
    /// queda su hash, igual que con una contraseña. Si el cliente la pierde,
    /// no hay forma de recuperarla: se revoca y se emite otra.
    ///
    /// Eso es una molestia deliberada. La alternativa —guardarla en claro para
    /// poder mostrarla después— significaría que cualquiera con acceso a la
    /// base puede suplantar a todos tus clientes.
    /// </summary>
    public async Task<(Guid Id, string Clave)> CrearClaveAsync(
        Guid tenantId, string nombre, bool produccion = false,
        CancellationToken ct = default)
    {
        var clave = RepositorioTenants.GenerarClave(produccion);
        var hash = RepositorioTenants.CalcularHash(clave);
        var prefijo = clave[..Math.Min(20, clave.Length)];

        await using var conexion = await AbrirAsync(ct);

        var id = await conexion.ExecuteScalarAsync<Guid>(new CommandDefinition(
            """
            INSERT INTO api_keys (tenant_id, nombre, prefijo, hash)
            VALUES (@tenantId, @nombre, @prefijo, @hash)
            RETURNING id
            """,
            new { tenantId, nombre, prefijo, hash }, cancellationToken: ct));

        return (id, clave);
    }

    /// <summary>
    /// Revoca una clave. No se borra: se desactiva.
    ///
    /// Borrarla dejaría sin rastro quién tenía acceso y hasta cuándo, y esa
    /// es justo la pregunta que hay que poder responder después de un
    /// incidente de seguridad.
    /// </summary>
    public async Task<bool> RevocarClaveAsync(
        Guid claveId, CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);

        var filas = await conexion.ExecuteAsync(new CommandDefinition(
            """
            UPDATE api_keys
               SET activo = false, revocado_en = now()
             WHERE id = @claveId AND activo
            """,
            new { claveId }, cancellationToken: ct));

        return filas > 0;
    }
}
'@

# --- Facturacion.Persistencia\RepositorioRoles.cs
Planear 'Facturacion.Persistencia\RepositorioRoles.cs' '4E6E27512C3D788183C7E2C38E16F2E788670279CDAD7A222678D5024502BC9E' @'
using Dapper;
using Npgsql;

namespace Facturacion.Persistencia;

/// <summary>
/// Las claves de permiso, como constantes.
///
/// POR QUÉ CONSTANTES Y NO CADENAS SUELTAS: escribir "comprobantes.reprocesar"
/// a mano en veinte endpoints garantiza que alguno lleve una errata, y una
/// errata en una clave de permiso no falla: simplemente nadie la tiene, y el
/// endpoint queda cerrado para todos sin que nadie entienda por qué.
///
/// Con constantes, la errata la detecta el compilador.
/// </summary>
public static class Permiso
{
    public const string DiagnosticoVer = "diagnostico.ver";

    public const string ComprobantesVer = "comprobantes.ver";
    public const string ComprobantesReprocesar = "comprobantes.reprocesar";

    public const string EmpresasVer = "empresas.ver";
    public const string EmpresasEditar = "empresas.editar";
    public const string ClavesGestionar = "claves.gestionar";
    public const string WebhooksGestionar = "webhooks.gestionar";

    public const string CertificadosGestionar = "certificados.gestionar";
    public const string ProduccionCambiar = "produccion.cambiar";

    /// <summary>Emitir y revocar claves de alta (migración 024).</summary>
    public const string AltasGestionar = "altas.gestionar";

    public const string UsuariosGestionar = "usuarios.gestionar";
    public const string AuditoriaVer = "auditoria.ver";

    /// <summary>
    /// Áreas del producto.
    ///
    /// NO SE LLAMAN PSE NI OSE A PROPÓSITO. Esas son figuras que define SUNAT,
    /// con requisitos legales y registro propio. Usar esos nombres para
    /// permisos internos haría creer que un usuario o la empresa tienen esa
    /// condición ante la administración tributaria.
    ///
    /// Se nombran por lo que hacen.
    /// </summary>
    public const string EmisionVer = "emision.ver";
    public const string ValidacionVer = "validacion.ver";
}

/// <summary>Un permiso del catálogo.</summary>
public record PermisoInfo(
    string Clave,
    string Area,
    string Nombre,
    string Descripcion,
    short Orden);

/// <summary>Un rol con sus permisos.</summary>
public record RolInfo(
    Guid Id,
    string Clave,
    string Nombre,
    string Descripcion,
    bool DelSistema,
    string? PermisosTexto,
    int Usuarios,
    DateTime CreadoEn)
{
    /// <summary>
    /// Los permisos llegan como texto separado por comas, no como arreglo.
    ///
    /// Dapper entrega un text[] de PostgreSQL como System.Array sin
    /// convertirlo, y falla al materializar con un mensaje que habla de
    /// constructores. Aplanar y dividir aquí cuesta menos que configurar un
    /// conversor.
    /// </summary>
    public string[] Permisos =>
        string.IsNullOrWhiteSpace(PermisosTexto)
            ? []
            : PermisosTexto.Split(',', StringSplitOptions.RemoveEmptyEntries);
}

/// <summary>
/// Roles y permisos del panel.
/// </summary>
public sealed class RepositorioRoles
{
    private readonly string _cadenaOperador;

    public RepositorioRoles(string cadenaConexionOperador)
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

    /// <summary>Catálogo completo de permisos, para las pantallas de roles.</summary>
    public async Task<IReadOnlyList<PermisoInfo>> CatalogoAsync(
        CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);

        var filas = await conexion.QueryAsync<PermisoInfo>(
            new CommandDefinition(
                """
                SELECT clave       AS "Clave",
                       area        AS "Area",
                       nombre      AS "Nombre",
                       descripcion AS "Descripcion",
                       orden       AS "Orden"
                  FROM permisos
                 ORDER BY orden, clave
                """,
                cancellationToken: ct));

        return filas.ToList();
    }

    public async Task<IReadOnlyList<RolInfo>> ListarAsync(
        CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);

        var filas = await conexion.QueryAsync<RolInfo>(
            new CommandDefinition(
                """
                SELECT r.id          AS "Id",
                       r.clave       AS "Clave",
                       r.nombre      AS "Nombre",
                       r.descripcion AS "Descripcion",
                       r.del_sistema AS "DelSistema",

                       (SELECT string_agg(rp.permiso, ',' ORDER BY rp.permiso)
                          FROM rol_permisos rp
                         WHERE rp.rol_id = r.id)      AS "PermisosTexto",

                       (SELECT count(*)::int FROM usuarios u
                         WHERE u.rol_id = r.id)       AS "Usuarios",

                       r.creado_en   AS "CreadoEn"
                  FROM roles r
                 ORDER BY r.del_sistema DESC, r.nombre
                """,
                cancellationToken: ct));

        return filas.ToList();
    }

    public async Task<Guid> CrearAsync(
        string nombre, string descripcion, string[] permisos,
        CancellationToken ct = default)
    {
        // La clave sale del nombre: es lo que aparece en la configuración y
        // conviene que sea legible, no un identificador al azar.
        var clave = AClave(nombre);

        await using var conexion = await AbrirAsync(ct);
        await using var transaccion = await conexion.BeginTransactionAsync(ct);

        var id = await conexion.ExecuteScalarAsync<Guid>(new CommandDefinition(
            """
            INSERT INTO roles (clave, nombre, descripcion)
            VALUES (@clave, @nombre, @descripcion)
            RETURNING id
            """,
            new { clave, nombre = nombre.Trim(), descripcion = descripcion.Trim() },
            transaccion, cancellationToken: ct));

        await AsignarAsync(conexion, transaccion, id, permisos, ct);

        await transaccion.CommitAsync(ct);

        return id;
    }

    /// <summary>
    /// Cambia el nombre, la descripción y los permisos de un rol.
    ///
    /// Los roles del sistema no se tocan: dejar que alguien le quite permisos
    /// a 'administrador' permitiría bloquear el panel sin forma de recuperarlo
    /// desde dentro.
    /// </summary>
    public async Task<(bool Exitoso, string? Motivo)> ActualizarAsync(
        Guid rolId, string nombre, string descripcion, string[] permisos,
        CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);

        var delSistema = await conexion.ExecuteScalarAsync<bool?>(
            new CommandDefinition(
                "SELECT del_sistema FROM roles WHERE id = @rolId",
                new { rolId }, cancellationToken: ct));

        if (delSistema is null)
            return (false, "No se encontró el rol.");

        if (delSistema.Value)
            return (false,
                "Este rol es del sistema y no se puede modificar. " +
                "Si necesitas algo parecido, crea uno nuevo.");

        await using var transaccion = await conexion.BeginTransactionAsync(ct);

        await conexion.ExecuteAsync(new CommandDefinition(
            """
            UPDATE roles SET nombre = @nombre, descripcion = @descripcion
             WHERE id = @rolId
            """,
            new { rolId, nombre = nombre.Trim(), descripcion = descripcion.Trim() },
            transaccion, cancellationToken: ct));

        // Se reemplazan todos: borrar y volver a insertar es más simple que
        // calcular qué cambió, y a esta escala no tiene ningún coste.
        await conexion.ExecuteAsync(new CommandDefinition(
            "DELETE FROM rol_permisos WHERE rol_id = @rolId",
            new { rolId }, transaccion, cancellationToken: ct));

        await AsignarAsync(conexion, transaccion, rolId, permisos, ct);

        await transaccion.CommitAsync(ct);

        return (true, null);
    }

    /// <summary>
    /// Elimina un rol, siempre que no sea del sistema y nadie lo tenga.
    /// </summary>
    public async Task<(bool Exitoso, string? Motivo)> EliminarAsync(
        Guid rolId, CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);

        var datos = await conexion.QuerySingleOrDefaultAsync<FilaBorrado>(
            new CommandDefinition(
                """
                SELECT r.del_sistema AS "DelSistema",
                       r.nombre      AS "Nombre",
                       (SELECT count(*)::int FROM usuarios u
                         WHERE u.rol_id = r.id) AS "Usuarios"
                  FROM roles r
                 WHERE r.id = @rolId
                """,
                new { rolId }, cancellationToken: ct));

        if (datos is null)
            return (false, "No se encontró el rol.");

        if (datos.DelSistema)
            return (false, "Los roles del sistema no se pueden eliminar.");

        if (datos.Usuarios > 0)
            return (false,
                $"Hay {datos.Usuarios} usuario(s) con este rol. " +
                "Cámbiales el rol antes de eliminarlo: si desapareciera, " +
                "quedarían sin permisos y sin saber por qué.");

        await conexion.ExecuteAsync(new CommandDefinition(
            "DELETE FROM roles WHERE id = @rolId",
            new { rolId }, cancellationToken: ct));

        return (true, null);
    }

    /// <summary>Los permisos de un usuario, por su rol.</summary>
    public async Task<string[]> PermisosDeUsuarioAsync(
        Guid usuarioId, CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);

        var texto = await conexion.ExecuteScalarAsync<string?>(
            new CommandDefinition(
                """
                SELECT string_agg(rp.permiso, ',')
                  FROM usuarios u
                  JOIN rol_permisos rp ON rp.rol_id = u.rol_id
                 WHERE u.id = @usuarioId AND u.activo
                """,
                new { usuarioId }, cancellationToken: ct));

        return string.IsNullOrWhiteSpace(texto)
            ? []
            : texto.Split(',', StringSplitOptions.RemoveEmptyEntries);
    }

    /// <summary>Cuántos usuarios activos tienen un permiso concreto.</summary>
    public async Task<int> ContarConPermisoAsync(
        string permiso, CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);

        return await conexion.ExecuteScalarAsync<int>(new CommandDefinition(
            """
            SELECT count(DISTINCT u.id)::int
              FROM usuarios u
              JOIN rol_permisos rp ON rp.rol_id = u.rol_id
             WHERE u.activo AND rp.permiso = @permiso
            """,
            new { permiso }, cancellationToken: ct));
    }

    public async Task<Guid?> BuscarPorClaveAsync(
        string clave, CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);

        return await conexion.ExecuteScalarAsync<Guid?>(new CommandDefinition(
            "SELECT id FROM roles WHERE clave = @clave",
            new { clave }, cancellationToken: ct));
    }

    // ----------------------------------------------------------------- apoyo

    private static async Task AsignarAsync(
        NpgsqlConnection conexion, NpgsqlTransaction transaccion,
        Guid rolId, string[] permisos, CancellationToken ct)
    {
        foreach (var permiso in permisos.Distinct())
        {
            // Se ignoran los permisos que no existen en el catálogo en vez de
            // fallar: si el panel manda uno viejo tras una actualización, es
            // mejor guardar el resto que rechazar la operación entera.
            await conexion.ExecuteAsync(new CommandDefinition(
                """
                INSERT INTO rol_permisos (rol_id, permiso)
                SELECT @rolId, @permiso
                 WHERE EXISTS (SELECT 1 FROM permisos WHERE clave = @permiso)
                ON CONFLICT DO NOTHING
                """,
                new { rolId, permiso },
                transaccion, cancellationToken: ct));
        }
    }

    private static string AClave(string nombre)
    {
        var limpio = nombre.Trim().ToLowerInvariant()
            .Replace('á', 'a').Replace('é', 'e').Replace('í', 'i')
            .Replace('ó', 'o').Replace('ú', 'u').Replace('ñ', 'n');

        var clave = new string(limpio
            .Select(c => char.IsLetterOrDigit(c) ? c : '_')
            .ToArray());

        while (clave.Contains("__")) clave = clave.Replace("__", "_");

        clave = clave.Trim('_');

        return clave.Length == 0
            ? "rol_" + Guid.NewGuid().ToString("N")[..8]
            : clave[..Math.Min(40, clave.Length)];
    }

    private sealed record FilaBorrado(bool DelSistema, string Nombre, int Usuarios);
}
'@

# --- Facturacion.Persistencia\RepositorioTenants.cs
Planear 'Facturacion.Persistencia\RepositorioTenants.cs' '0BE224FFAFDAD4C76D354F72ACEE0C43D93FDC190C3597C88DFBDF62DF8C144D' @'
using System.Security.Cryptography;
using System.Text;
using Dapper;

namespace Facturacion.Persistencia;

/// <summary>Datos del emisor, resueltos desde la clave de acceso.</summary>
public record TenantResuelto(
    Guid Id,
    string Ruc,
    string RazonSocial,
    string NombreComercial,
    string Ubigeo,
    string Direccion,
    string Distrito,
    string Provincia,
    string Departamento,
    string Ambiente,
    string? UsuarioSol,
    short MaxConcurrencia,
    bool Activo)
{
    public bool EsProduccion => Ambiente == "produccion";
}

/// <summary>
/// Resuelve tenants y valida claves de acceso.
///
/// Esta clase trabaja SIN contexto de tenant, porque es la que lo determina.
/// Es la única excepción a la regla de que todo pasa por SesionTenant, y por
/// eso conviene que sea pequeña y que no haga nada más.
/// </summary>
public sealed class RepositorioTenants
{
    private readonly FabricaSesiones _sesiones;

    public RepositorioTenants(FabricaSesiones sesiones)
    {
        _sesiones = sesiones ?? throw new ArgumentNullException(nameof(sesiones));
    }

    /// <summary>
    /// Calcula el hash de una clave. SHA-256 en hexadecimal minúsculo.
    ///
    /// POR QUÉ SHA-256 A SECAS Y NO BCRYPT O ARGON2, que sería lo correcto
    /// para contraseñas de personas: una clave de API es un valor aleatorio
    /// largo generado por el sistema, no algo que alguien eligió. No hay
    /// diccionario que probar contra ella, así que el coste computacional
    /// de un algoritmo lento no aporta nada y sí encarece cada petición.
    ///
    /// Esto deja de ser cierto si alguna vez permites claves elegidas por
    /// el usuario. No lo permitas.
    /// </summary>
    public static string CalcularHash(string clave)
    {
        var bytes = SHA256.HashData(Encoding.UTF8.GetBytes(clave));
        return Convert.ToHexString(bytes).ToLowerInvariant();
    }

    /// <summary>Genera una clave nueva, legible y con prefijo reconocible.</summary>
    public static string GenerarClave(bool produccion = false)
    {
        var aleatorio = Convert.ToBase64String(RandomNumberGenerator.GetBytes(32))
            .Replace("+", "").Replace("/", "").Replace("=", "");

        return $"fac_{(produccion ? "live" : "test")}_{aleatorio}";
    }

    /// <summary>
    /// Resuelve el tenant a partir de una clave de acceso.
    /// Devuelve null si la clave no existe, está revocada, o el tenant
    /// está desactivado.
    /// </summary>
    public async Task<TenantResuelto?> ResolverPorClaveAsync(
        string clave, CancellationToken ct = default)
    {
        if (string.IsNullOrWhiteSpace(clave)) return null;

        var hash = CalcularHash(clave);

        await using var conexion = await _sesiones.AbrirCatalogoAsync(ct);

        // Una sola consulta que resuelve el tenant Y registra el uso de la clave.
        //
        // POR QUÉ EN UNA SOLA SENTENCIA Y NO EN DOS:
        //
        // La versión anterior lanzaba el UPDATE sin esperarlo, con un
        // descarte (_ = ...), pensando que así no retrasaba la petición.
        // Eso era un error grave: la conexión se liberaba al salir del
        // 'await using' con el comando todavía en vuelo, volvía al pool en
        // mal estado, y la siguiente petición se quedaba esperando una
        // conexión que nunca se recuperaba. El síntoma no era un error:
        // era un cuelgue silencioso.
        //
        // La lección general: nunca lances trabajo sin esperar sobre un
        // recurso que estás a punto de liberar. Si de verdad debe ser en
        // segundo plano, el trabajo necesita su propia conexión y su propio
        // ciclo de vida.
        //
        // Aquí ni siquiera hace falta: un CTE hace ambas cosas en un viaje.
        // El UPDATE solo ocurre si la clave existe y está activa.

        var tenant = await conexion.QuerySingleOrDefaultAsync<TenantResuelto?>(
            new CommandDefinition(
                """
                WITH clave_usada AS (
                    UPDATE api_keys
                       SET ultimo_uso = now()
                     WHERE hash = @hash
                       AND activo
                    RETURNING tenant_id
                )
                SELECT t.id               AS "Id",
                       t.ruc              AS "Ruc",
                       t.razon_social     AS "RazonSocial",
                       t.nombre_comercial AS "NombreComercial",
                       t.ubigeo           AS "Ubigeo",
                       t.direccion        AS "Direccion",
                       t.distrito         AS "Distrito",
                       t.provincia        AS "Provincia",
                       t.departamento     AS "Departamento",
                       t.ambiente         AS "Ambiente",
                       t.usuario_sol      AS "UsuarioSol",
                       t.max_concurrencia AS "MaxConcurrencia",
                       t.activo           AS "Activo"
                  FROM clave_usada k
                  JOIN tenants     t ON t.id = k.tenant_id
                 WHERE t.activo
                """,
                new { hash }, cancellationToken: ct));

        return tenant;
    }

    public async Task<TenantResuelto?> ObtenerPorRucAsync(
        string ruc, CancellationToken ct = default)
    {
        await using var conexion = await _sesiones.AbrirCatalogoAsync(ct);

        return await conexion.QuerySingleOrDefaultAsync<TenantResuelto?>(
            new CommandDefinition(
                """
                SELECT id               AS "Id",
                       ruc              AS "Ruc",
                       razon_social     AS "RazonSocial",
                       nombre_comercial AS "NombreComercial",
                       ubigeo           AS "Ubigeo",
                       direccion        AS "Direccion",
                       distrito         AS "Distrito",
                       provincia        AS "Provincia",
                       departamento     AS "Departamento",
                       ambiente         AS "Ambiente",
                       usuario_sol      AS "UsuarioSol",
                       max_concurrencia AS "MaxConcurrencia",
                       activo           AS "Activo"
                  FROM tenants
                 WHERE ruc = @ruc
                   -- Desde la 024 puede haber varias filas con el mismo RUC:
                   -- las abandonadas y, como mucho, una vigente.
                   AND estado_alta <> 'abandonada'
                """,
                new { ruc }, cancellationToken: ct));
    }
}
'@

# --- Facturacion.Api\Autenticacion.cs
Planear 'Facturacion.Api\Autenticacion.cs' '4A0C015931012A7432FC7DB18C96A43A824DCEF27FB1A92C1560478B027C826B' @'
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

        // El alta de emisores tampoco: va con la CLAVE DE ALTA (alt_), que
        // comprueba su propio filtro contra claves_alta (EndpointsAlta). Una
        // fac_ no abre esta ruta, y una alt_ no abre ninguna de /v1.
        ruta.StartsWithSegments("/alta") ||

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

# --- Facturacion.Api\EndpointsAdmin.cs
Planear 'Facturacion.Api\EndpointsAdmin.cs' 'A63270554C5E969471E9A088CEC4361D710DA1B3590AD83A305F9466F50F9ADC' @'
using System.Security.Cryptography;
using Facturacion.Persistencia;
using Microsoft.AspNetCore.Mvc;

namespace Facturacion.Api;

/// <summary>
/// Administración de la plataforma: empresas, certificados, series y claves.
///
/// Todo esto se hacía hasta ahora escribiendo SQL a mano, lo cual funciona
/// mientras el sistema lo maneja quien lo construyó. Deja de funcionar el día
/// que hay que delegarlo, y ese día llega antes de lo que parece.
/// </summary>
public static class EndpointsAdmin
{
    public static void MapearAdministracion(this WebApplication app)
    {
        // CADA ACCIÓN EXIGE SU PROPIO PERMISO, no un rol entero.
        //
        // Quien da de alta clientes no necesita cargar certificados, y quien
        // atiende llamadas no necesita crear empresas. Repartirlo así permite
        // dar a cada persona exactamente lo que usa.
        var grupo = app.MapGroup("/admin")
            .AddEndpointFilter<AutenticacionPanel>()
            .WithTags("Administración");

        // ------------------------------------------------------------ empresas

        grupo.MapGet("/tenants", async (
            RepositorioAdmin admin, CancellationToken ct) =>
            Results.Ok(await admin.ListarTenantsAsync(ct)))
            .AddEndpointFilter(new ExigirPermiso(Permiso.EmpresasVer))
        .WithSummary("Lista las empresas");

        grupo.MapPost("/tenants", async (
            NuevoTenant nuevo, RepositorioAdmin admin, CancellationToken ct) =>
        {
            if (nuevo.Ruc.Length != 11 || !nuevo.Ruc.All(char.IsDigit))
                return Results.BadRequest(new RespuestaError(
                    "RUC inválido.", "Debe tener exactamente 11 dígitos."));

            if (string.IsNullOrWhiteSpace(nuevo.RazonSocial))
                return Results.BadRequest(new RespuestaError(
                    "Falta la razón social."));

            // El identificador del portal es opcional al dar de alta.
            nuevo.Identificador = Marca.LimpiarIdentificador(nuevo.Identificador);

            if (Marca.ProblemaIdentificador(nuevo.Identificador) is { } problema)
                return Results.BadRequest(new RespuestaError(
                    "El identificador del portal no es válido.", problema));

            // LA DIRECCIÓN, COMPLETA Y COHERENTE CON EL UBIGEO (diseño §13.4).
            // El formulario ya no trae LIMA por defecto: lo que llega lo
            // escribió alguien, y por eso queda como revisada.
            var (dir, problemaDir) = Direccion.Revisar(
                nuevo.Ubigeo, nuevo.Direccion, nuevo.Distrito, nuevo.Provincia, nuevo.Departamento);

            if (dir is null)
                return Results.BadRequest(new RespuestaError("La dirección no es válida.", problemaDir));

            nuevo.Ubigeo = dir.Ubigeo;
            nuevo.Direccion = dir.Direccion;
            nuevo.Distrito = dir.Distrito;
            nuevo.Provincia = dir.Provincia;
            nuevo.Departamento = dir.Departamento;

            try
            {
                var id = await admin.CrearTenantAsync(nuevo, ct);
                return Results.Ok(new { id, mensaje = "Empresa creada." });
            }
            catch (Npgsql.PostgresException ex) when (
                ex.SqlState == "23505" && ex.ConstraintName == "ux_tenants_identificador")
            {
                return Results.Conflict(IdentificadorEnUso(nuevo.Identificador));
            }
            catch (Npgsql.PostgresException ex) when (ex.SqlState == "23505")
            {
                // Violación de unicidad: el RUC ya existe (ux_tenants_ruc_vigente,
                // desde la 024: entre las empresas no abandonadas).
                return Results.Conflict(new RespuestaError(
                    "Ese RUC ya está registrado.",
                    "Cada empresa se da de alta una sola vez. Si la creó la plataforma y " +
                    "sale «sin confirmar», espera a que se confirme o se dé por abandonada."));
            }
        })
        .AddEndpointFilter(new ExigirPermiso(Permiso.EmpresasEditar))
        .WithSummary("Da de alta una empresa");

        grupo.MapPatch("/tenants/{id:guid}", async (
            Guid id, ActualizacionTenant cambios,
            RepositorioAdmin admin, CancellationToken ct) =>
        {
            bool actualizado;

            try
            {
                actualizado = await admin.ActualizarTenantAsync(
                    id, cambios.Activo, cambios.MaxConcurrencia, ct);
            }
            catch (Npgsql.PostgresException ex) when (ex.SqlState == "P0001")
            {
                // El disparador de la 024: un alta abandonada no se reactiva.
                return Results.Conflict(new RespuestaError(
                    "Esta empresa no se puede reactivar.", ex.MessageText));
            }

            return actualizado
                ? Results.Ok(new { mensaje = "Empresa actualizada." })
                : Results.NotFound(new RespuestaError("No se encontró la empresa."));
        })
        .AddEndpointFilter(new ExigirPermiso(Permiso.EmpresasEditar))
        .WithSummary("Activa, desactiva o ajusta la concurrencia");

        // --------------------------------------------------------------- marca

        grupo.MapPut("/tenants/{id:guid}/marca", async (
            Guid id, CambioMarca cambio,
            RepositorioAdmin admin, CancellationToken ct) =>
        {
            var identificador = Marca.LimpiarIdentificador(cambio.Identificador);
            var color = Marca.LimpiarColor(cambio.ColorMarca);
            var correo = Marca.LimpiarCorreo(cambio.CorreoRespuesta);

            if (Marca.ProblemaIdentificador(identificador) is { } pi)
                return Results.BadRequest(new RespuestaError(
                    "El identificador del portal no es válido.", pi));

            if (Marca.ProblemaColor(color) is { } pc)
                return Results.BadRequest(new RespuestaError("El color no es válido.", pc));

            if (Marca.ProblemaCorreo(correo) is { } pr)
                return Results.BadRequest(new RespuestaError(
                    "El correo de respuesta no es válido.", pr));

            try
            {
                var (resultado, actual) = await admin.GuardarMarcaAsync(
                    id, identificador, color, correo, ct);

                return resultado switch
                {
                    ResultadoMarca.NoExiste =>
                        Results.NotFound(new RespuestaError("No se encontró la empresa.")),

                    ResultadoMarca.IdentificadorFijo =>
                        Results.Conflict(new RespuestaError(
                            "El identificador del portal no se puede cambiar.",
                            $"Esta empresa ya es «{actual}». Es la dirección que va " +
                            "en los correos ya enviados: cambiarla rompería esos " +
                            "enlaces. No se guardó nada.")),

                    _ => Results.Ok(new { mensaje = "Marca guardada.", identificador = actual })
                };
            }
            catch (Npgsql.PostgresException ex) when (
                ex.SqlState == "23505" && ex.ConstraintName == "ux_tenants_identificador")
            {
                return Results.Conflict(IdentificadorEnUso(identificador));
            }
        })
        .AddEndpointFilter(new ExigirPermiso(Permiso.EmpresasEditar))
        .WithSummary("Guarda el identificador del portal, el color y el correo de respuesta")
        .WithDescription(
            "Se mandan los tres campos cada vez. El color y el correo se " +
            "reemplazan: vacío los quita. El identificador solo se puede poner " +
            "una vez; si ya tiene uno y llega otro, responde 409 y no guarda " +
            "nada.");

        grupo.MapGet("/tenants/{id:guid}/logo", async (
            Guid id, HttpContext contexto,
            RepositorioAdmin admin, IAlmacenArchivos archivos, CancellationToken ct) =>
        {
            var logo = await admin.ObtenerLogoAsync(id, ct);

            if (logo?.LogoRuta is not { } ruta)
                return Results.NotFound(new RespuestaError("Esta empresa no tiene logo."));

            var datos = await archivos.LeerAsync(ruta, ct);

            if (datos is null || Marca.TipoDeImagen(datos) is not { } tipo)
                return Results.NotFound(new RespuestaError(
                    "No se encontró el archivo del logo en el almacén."));

            // La dirección lleva ?v=<versión>, que cambia al subir otro logo.
            // Por eso se puede guardar un día sin miedo a enseñar el viejo.
            contexto.Response.Headers.CacheControl = "private, max-age=86400";
            contexto.Response.Headers["X-Content-Type-Options"] = "nosniff";

            return Results.File(datos, tipo.TipoMime);
        })
        .AddEndpointFilter(new ExigirPermiso(Permiso.EmpresasVer))
        .WithSummary("El logo de la empresa, para verlo en el panel");

        grupo.MapPost("/tenants/{id:guid}/logo", async (
            Guid id, IFormFile archivo,
            RepositorioAdmin admin, IAlmacenArchivos archivos, CancellationToken ct) =>
        {
            if (archivo.Length == 0)
                return Results.BadRequest(new RespuestaError("El archivo está vacío."));

            if (archivo.Length > Marca.LogoMaximoBytes)
                return Results.BadRequest(new RespuestaError(
                    "El logo es demasiado grande.",
                    $"Pesa {archivo.Length / 1024} KB y el máximo es " +
                    $"{Marca.LogoMaximoBytes / 1024} KB. Exporta una versión más " +
                    "pequeña: en el PDF se imprime a 50 puntos de alto."));

            using var memoria = new MemoryStream();
            await archivo.CopyToAsync(memoria, ct);
            var datos = memoria.ToArray();

            if (Marca.TipoDeImagen(datos) is not { } tipo)
                return Results.BadRequest(new RespuestaError(
                    "El logo tiene que ser PNG o JPG.",
                    "Se comprueba por el contenido del archivo, no por su nombre."));

            if (Marca.ProblemaAlDibujar(datos) is { } problema)
                return Results.BadRequest(new RespuestaError("No se puede usar ese logo.", problema));

            var empresa = await admin.ObtenerLogoAsync(id, ct);

            if (empresa is null)
                return Results.NotFound(new RespuestaError("No se encontró la empresa."));

            // El nombre sale del contenido: el mismo logo subido dos veces es
            // el mismo archivo, y uno distinto nunca pisa al anterior.
            var huella = Convert.ToHexString(SHA256.HashData(datos))[..16].ToLowerInvariant();

            var ruta = await archivos.GuardarAsync(
                empresa.Ruc, DateTime.UtcNow, $"logo-{huella}.{tipo.Extension}", datos, ct);

            await admin.GuardarLogoAsync(id, ruta, ct);

            return Results.Ok(new { mensaje = "Logo guardado. Ya sale en los PDF." });
        })
        .DisableAntiforgery()
        .AddEndpointFilter(new ExigirPermiso(Permiso.EmpresasEditar))
        .WithSummary("Sube el logo de la empresa")
        .WithDescription(
            "PNG o JPG, máximo 300 KB. Se comprueba que se puede dibujar antes " +
            "de guardarlo. El anterior no se borra del almacén: solo deja de " +
            "usarse.");

        // ------------------------------------------------- credenciales SOL

        grupo.MapPost("/tenants/{id:guid}/credenciales-sol", async (
            Guid id, CredencialesSol credenciales,
            RepositorioAdmin admin, IProtectorDeSecretos protector,
            CancellationToken ct) =>
        {
            if (credenciales.Usuario.Equals("MODDATOS", StringComparison.OrdinalIgnoreCase))
            {
                return Results.BadRequest(new RespuestaError(
                    "MODDATOS es el usuario del ambiente de pruebas.",
                    "Para producción hace falta el usuario SOL secundario real " +
                    "del contribuyente."));
            }

            try
            {
                var guardadas = await admin.GuardarCredencialesSolAsync(
                    id, credenciales.Usuario, credenciales.Clave, protector, ct);

                return guardadas
                    ? Results.Ok(new { mensaje = "Credenciales guardadas y cifradas." })
                    : Results.NotFound(new RespuestaError("No se encontró la empresa."));
            }
            catch (ArgumentException ex)
            {
                return Results.BadRequest(new RespuestaError("Datos inválidos.", ex.Message));
            }
        })
        .AddEndpointFilter(new ExigirPermiso(Permiso.ProduccionCambiar))
        .WithSummary("Guarda las credenciales SOL del contribuyente")
        .WithDescription(
            "La clave se cifra igual que el certificado.\n\n" +
            "Debe ser el usuario SOL SECUNDARIO, nunca el principal: el " +
            "principal puede declarar, pagar y modificar datos en el portal " +
            "de SUNAT, y ese nivel de acceso no tiene por qué vivir aquí.");

        // ------------------------------------------- credenciales de guías

        grupo.MapPost("/tenants/{id:guid}/credenciales-gre", async (
            Guid id, CredencialesGre credenciales,
            RepositorioAdmin admin, IProtectorDeSecretos protector,
            CancellationToken ct) =>
        {
            try
            {
                var guardadas = await admin.GuardarCredencialesGreAsync(
                    id, credenciales.ClientId, credenciales.ClientSecret,
                    protector, ct);

                return guardadas
                    ? Results.Ok(new
                    {
                        mensaje =
                            "Credenciales de guías guardadas y cifradas. " +
                            "La emisión de guías queda habilitada."
                    })
                    : Results.NotFound(new RespuestaError("No se encontró la empresa."));
            }
            catch (ArgumentException ex)
            {
                return Results.BadRequest(new RespuestaError("Datos inválidos.", ex.Message));
            }
        })
        .AddEndpointFilter(new ExigirPermiso(Permiso.ProduccionCambiar))
        .WithSummary("Guarda las credenciales de API para guías de remisión")
        .WithDescription(
            "El client_id y el client_secret los genera el contribuyente en " +
            "su menú SOL, opción 'Credenciales de API SUNAT'.\n\n" +
            "Son DISTINTAS de la clave SOL: esta sirve para las facturas, " +
            "aquellas solo para guías. Una empresa que emita ambas cosas " +
            "necesita los dos juegos.");

        grupo.MapPost("/tenants/{id:guid}/gre-habilitado", async (
            Guid id, CambioGreHabilitado cambio,
            RepositorioAdmin admin, CancellationToken ct) =>
        {
            var cambiado = await admin.CambiarGreHabilitadoAsync(
                id, cambio.Habilitado, ct);

            return cambiado
                ? Results.Ok(new
                {
                    mensaje = cambio.Habilitado
                        ? "Emisión de guías habilitada."
                        : "Emisión de guías deshabilitada."
                })
                : Results.NotFound(new RespuestaError("No se encontró la empresa."));
        })
        .AddEndpointFilter(new ExigirPermiso(Permiso.ProduccionCambiar))
        .WithSummary("Activa o desactiva la emisión de guías");

        grupo.MapGet("/tenants/{id:guid}/revision-produccion", async (
            Guid id, ProveedorCredenciales credenciales, CancellationToken ct) =>
            Results.Ok(await credenciales.RevisarAsync(id, ct)))
            .AddEndpointFilter(new ExigirPermiso(Permiso.EmpresasVer))
            .WithSummary("Comprueba si la empresa puede pasar a producción")
            .WithDescription(
                "Revisa certificado, credenciales SOL y series. Pasar a " +
                "producción sin alguno de ellos hace que todas las facturas " +
                "de esa empresa fallen desde el primer minuto.");

        grupo.MapPost("/tenants/{id:guid}/ambiente", async (
            Guid id, CambioAmbiente cambio,
            RepositorioAdmin admin, ProveedorCredenciales credenciales,
            CancellationToken ct) =>
        {
            // Volver a beta siempre se permite: es la salida cuando algo va mal.
            if (cambio.Ambiente == "beta")
            {
                var vuelto = await admin.CambiarAmbienteAsync(id, "beta", ct);

                return vuelto
                    ? Results.Ok(new { mensaje = "La empresa volvió al ambiente de pruebas." })
                    : Results.NotFound(new RespuestaError("No se encontró la empresa."));
            }

            // Pasar a producción NO. Se comprueba antes.
            var revision = await credenciales.RevisarAsync(id, ct);

            if (!revision.Listo)
            {
                return Results.BadRequest(new RespuestaError(
                    "La empresa todavía no puede pasar a producción.",
                    string.Join(" ", revision.Faltantes)));
            }

            var cambiado = await admin.CambiarAmbienteAsync(id, "produccion", ct);

            return cambiado
                ? Results.Ok(new
                {
                    mensaje = "La empresa pasó a producción.",
                    advertencias = revision.Advertencias
                })
                : Results.NotFound(new RespuestaError("No se encontró la empresa."));
        })
        .AddEndpointFilter(new ExigirPermiso(Permiso.ProduccionCambiar))
        .WithSummary("Cambia el ambiente de la empresa")
        .WithDescription(
            "Pasar a producción exige superar la revisión previa. Volver a " +
            "beta siempre se permite: es la salida cuando algo va mal.");

        // -------------------------------------------------------- certificados

        grupo.MapPost("/tenants/{id:guid}/certificado", async (
            Guid id,
            IFormFile archivo,

            // LA CONTRASEÑA VA EN EL CUERPO, NO EN LA DIRECCIÓN.
            //
            // Antes llegaba como ?clave=... y una dirección queda escrita en
            // los registros de acceso del proxy, en los de cualquier
            // intermediario y en las trazas de error. La contraseña de un
            // certificado no puede acabar en un log.
            [FromForm] string? clave,
            AlmacenCertificados certificados,
            CancellationToken ct) =>
        {
            if (archivo.Length == 0)
                return Results.BadRequest(new RespuestaError("El archivo está vacío."));

            // Un PFX legítimo no llega a este tamaño. El límite evita que
            // alguien suba un archivo enorme y agote la memoria del proceso.
            if (archivo.Length > 512 * 1024)
                return Results.BadRequest(new RespuestaError(
                    "El archivo es demasiado grande.",
                    "Un certificado PFX pesa unos pocos kilobytes."));

            using var memoria = new MemoryStream();
            await archivo.CopyToAsync(memoria, ct);

            try
            {
                var certificadoId = await certificados.GuardarAsync(
                    id, memoria.ToArray(), clave ?? "", ct);

                return Results.Ok(new
                {
                    id = certificadoId,
                    mensaje = "Certificado guardado y cifrado."
                });
            }
            catch (InvalidOperationException ex)
            {
                // Contraseña incorrecta, certificado vencido, o sin llave
                // privada. El mensaje de AlmacenCertificados ya explica cuál.
                return Results.BadRequest(new RespuestaError(
                    "No se pudo guardar el certificado.", ex.Message));
            }
        })
        .DisableAntiforgery()
        .AddEndpointFilter(new ExigirPermiso(Permiso.CertificadosGestionar))
        .WithSummary("Carga el certificado digital de una empresa")
        .WithDescription(
            "El archivo .pfx se cifra antes de guardarse. Solo se descifra en " +
            "memoria y solo en el momento de firmar.\\n\\n" +
            "Reemplaza al certificado activo anterior, que queda desactivado " +
            "en la misma operación: nunca hay dos activos ni un hueco sin " +
            "ninguno.");

        grupo.MapGet("/tenants/{id:guid}/certificados", async (
            Guid id, AlmacenCertificados certificados, CancellationToken ct) =>
            Results.Ok(await certificados.ListarAsync(id, ct)))
            .AddEndpointFilter(new ExigirPermiso(Permiso.EmpresasVer))
            .WithSummary("Lista los certificados de una empresa");

        grupo.MapDelete("/tenants/{id:guid}/certificados/{certificadoId:guid}", async (
            Guid id, Guid certificadoId,
            AlmacenCertificados certificados, CancellationToken ct) =>
        {
            var eliminado = await certificados.EliminarAsync(id, certificadoId, ct);

            return eliminado
                ? Results.Ok(new { mensaje = "Certificado eliminado." })
                : Results.Conflict(new RespuestaError(
                    "No se puede eliminar este certificado.",
                    "O está activo, o ya firmó comprobantes. Un certificado " +
                    "que firmó hay que conservarlo: sin él no se puede " +
                    "verificar esas firmas durante una fiscalización."));
        })
        .AddEndpointFilter(new ExigirPermiso(Permiso.CertificadosGestionar))
        .WithSummary("Elimina un certificado nunca usado")
        .WithDescription(
            "Para el caso de haber cargado el archivo equivocado. Solo " +
            "funciona si el certificado está inactivo y nunca firmó nada.");

        // -------------------------------------------------------------- series

        grupo.MapGet("/tenants/{id:guid}/series", async (
            Guid id, RepositorioAdmin admin, CancellationToken ct) =>
            Results.Ok(await admin.ListarSeriesAsync(id, ct)))
            .AddEndpointFilter(new ExigirPermiso(Permiso.EmpresasVer))
            .WithSummary("Lista las series de una empresa");

        grupo.MapPost("/tenants/{id:guid}/series", async (
            Guid id, NuevaSerie nueva,
            RepositorioAdmin admin, CancellationToken ct) =>
        {
            if (string.IsNullOrWhiteSpace(nueva.Serie) || nueva.Serie.Length != 4)
                return Results.BadRequest(new RespuestaError(
                    "Serie inválida.",
                    "Debe tener 4 caracteres. Ej: F001 para facturas, B001 para boletas."));

            var serieId = await admin.CrearSerieAsync(
                id, nueva.TipoComprobante, nueva.Serie.ToUpperInvariant(),
                nueva.CorrelativoInicial, ct);

            return Results.Ok(new { id = serieId, mensaje = "Serie dada de alta." });
        })
        .AddEndpointFilter(new ExigirPermiso(Permiso.EmpresasEditar))
        .WithSummary("Da de alta una serie")
        .WithDescription(
            "El correlativo inicial normalmente es 0, pero si la empresa migra " +
            "desde otro sistema hay que poner el último número que ya emitió. " +
            "Empezar de nuevo en 1 generaría duplicados que SUNAT rechaza.");

        grupo.MapDelete("/tenants/{id:guid}/series/{serieId:guid}", async (
            Guid id, Guid serieId, RepositorioAdmin admin, CancellationToken ct) =>
        {
            var eliminada = await admin.EliminarSerieAsync(id, serieId, ct);

            return eliminada
                ? Results.Ok(new { mensaje = "Serie eliminada." })
                : Results.Conflict(new RespuestaError(
                    "No se puede eliminar esta serie.",
                    "Ya tiene comprobantes emitidos. Borrarla dejaría huérfano " +
                    "el rastro de esa numeración. Desactívala: deja de poder " +
                    "emitir y el histórico queda intacto."));
        })
        .AddEndpointFilter(new ExigirPermiso(Permiso.EmpresasEditar))
        .WithSummary("Elimina una serie sin usar")
        .WithDescription(
            "Solo funciona si la serie nunca emitió comprobantes. En caso " +
            "contrario hay que desactivarla.");

        grupo.MapPatch("/tenants/{id:guid}/series/{serieId:guid}", async (
            Guid id, Guid serieId, CambioEstadoSerie cambio,
            RepositorioAdmin admin, CancellationToken ct) =>
        {
            var cambiada = await admin.CambiarEstadoSerieAsync(
                id, serieId, cambio.Activo, ct);

            return cambiada
                ? Results.Ok(new { mensaje = cambio.Activo
                    ? "Serie reactivada." : "Serie desactivada." })
                : Results.NotFound(new RespuestaError("No se encontró la serie."));
        })
        .AddEndpointFilter(new ExigirPermiso(Permiso.EmpresasEditar))
        .WithSummary("Activa o desactiva una serie")
        .WithDescription(
            "Una serie desactivada no puede emitir, pero sus comprobantes " +
            "siguen consultándose y descargándose igual.");

        // -------------------------------------------------------------- claves

        grupo.MapGet("/tenants/{id:guid}/claves", async (
            Guid id, RepositorioAdmin admin, CancellationToken ct) =>
            Results.Ok(await admin.ListarClavesAsync(id, ct)))
            .AddEndpointFilter(new ExigirPermiso(Permiso.EmpresasVer))
            .WithSummary("Lista las claves de acceso de una empresa");

        grupo.MapPost("/tenants/{id:guid}/claves", async (
            Guid id, NuevaClave nueva,
            RepositorioAdmin admin, CancellationToken ct) =>
        {
            var (claveId, secreto) = await admin.CrearClaveAsync(
                id, nueva.Nombre, nueva.Produccion, ct);

            return Results.Ok(new
            {
                id = claveId,
                clave = secreto,
                aviso =
                    "Esta es la ÚNICA vez que se muestra la clave. En la base " +
                    "solo queda su hash. Si se pierde, hay que revocarla y " +
                    "emitir otra."
            });
        })
        .AddEndpointFilter(new ExigirPermiso(Permiso.ClavesGestionar))
        .WithSummary("Emite una clave de acceso")
        .WithDescription(
            "Devuelve el secreto en claro UNA sola vez. Después ya no se puede " +
            "recuperar, igual que con una contraseña.");

        grupo.MapDelete("/claves/{claveId:guid}", async (
            Guid claveId, RepositorioAdmin admin, CancellationToken ct) =>
        {
            var revocada = await admin.RevocarClaveAsync(claveId, ct);

            return revocada
                ? Results.Ok(new { mensaje = "Clave revocada." })
                : Results.NotFound(new RespuestaError(
                    "No se encontró la clave, o ya estaba revocada."));
        })
        .AddEndpointFilter(new ExigirPermiso(Permiso.ClavesGestionar))
        .WithSummary("Revoca una clave")
        .WithDescription(
            "La clave se desactiva, no se borra. Borrarla dejaría sin rastro " +
            "quién tuvo acceso y hasta cuándo, que es justo lo que hay que " +
            "poder responder después de un incidente.");
    }

    private static RespuestaError IdentificadorEnUso(string? identificador) =>
        new("Ese identificador ya lo usa otra empresa.",
            $"«{identificador}» está tomado. Prueba con el nombre comercial y la " +
            "ciudad, por ejemplo ferreteria-lopez-arequipa.");
}

public record ActualizacionTenant(bool? Activo, short? MaxConcurrencia);

public record CambioMarca(string? Identificador, string? ColorMarca, string? CorreoRespuesta);

public record NuevaSerie(
    string TipoComprobante,
    string Serie,
    int CorrelativoInicial = 0);

public record NuevaClave(string Nombre, bool Produccion = false);

public record CambioEstadoSerie(bool Activo);

public record CredencialesSol(string Usuario, string Clave);

public record CambioAmbiente(string Ambiente);

public record CredencialesGre(string ClientId, string ClientSecret);

public record CambioGreHabilitado(bool Habilitado);
'@

# --- Facturacion.Api\Program.cs
Planear 'Facturacion.Api\Program.cs' '38370EE92343ED647F611F18B25AC31A8FB568BE96D8EAC1FA1E6BA316316ADA' @'
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

// El alta de emisores desde la plataforma y las claves de alta (024). Con el
// rol de operador, como el panel: crea filas que la aplicación solo lee. Lo
// que la acota está en RepositorioAltas (y el rol propio es el punto 23).
builder.Services.AddSingleton(new RepositorioAltas(cadenaOperador));
builder.Services.AddScoped<ContextoClaveAlta>();
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
app.MapearAlta();
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
    ContextoEmisor emisor, AlmacenCertificados certificados,
    RepositorioAltas altas, CancellationToken ct) =>
{
    var tenant = emisor.Exigir();

    // EL VENCIMIENTO DEL CERTIFICADO, para que quien integra avise antes.
    //
    // El dato existía, pero solo en `/admin/tenants/{id}/certificados`, que va
    // con la sesión del panel y cruza empresas: nadie de fuera puede ni debe
    // usar esa ruta. Aquí sale solo la fecha del activo de ESTA empresa.
    // Null si no tiene certificado cargado.
    var validoHasta = await certificados.VencimientoActivoAsync(tenant.Id, ct);

    // LO QUE LA PLATAFORMA REFLEJA (diseño §13.4): si el alta está confirmada,
    // la marca, y qué falta para poder emitir. Solo «está o no está» y datos
    // de esta misma empresa: ningún secreto.
    var e = await altas.EstadoAsync(tenant.Id, ct);

    return Results.Ok(new
    {
        ruc = tenant.Ruc,
        razonSocial = tenant.RazonSocial,
        nombreComercial = tenant.NombreComercial,
        ambiente = tenant.Ambiente,
        certificadoValidoHasta = validoHasta,
        certificadoDiasParaVencer = validoHasta is { } h
            ? (int?)Math.Ceiling((h - DateTime.UtcNow).TotalDays)
            : null,

        alta = new
        {
            estado = e.EstadoAlta,
            creadoEn = e.CreadoEn,
            confirmadaEn = e.AltaConfirmadaEn
        },

        // Sin los dos, NINGÚN receptor recibe su correo: el disparador de la
        // 022 se lo salta sin avisar, y lo aceptado mientras tanto no lo
        // recibe nunca.
        portal = new
        {
            identificador = e.Identificador,
            correoRespuesta = e.CorreoRespuesta,
            tieneLogo = e.TieneLogo,
            correosAlReceptor = e.CorreosAlReceptor
        },

        direccion = new
        {
            ubigeo = e.Ubigeo,
            direccion = e.Direccion,
            distrito = e.Distrito,
            provincia = e.Provincia,
            departamento = e.Departamento,
            revisadaEn = e.DireccionRevisadaEn
        },

        listo = new
        {
            paraEmitir = e.ListoParaEmitir,
            certificado = e.CertificadoListo,
            sol = e.SolListo,
            series = e.Series,
            direccion = e.DireccionLista,
            faltan = e.Faltan()
        }
    });
})
.WithName("Emisor")
.WithTags("Servicio")
.WithSummary("Datos del emisor autenticado")
.WithDescription(
    "Sirve para verificar que una clave de acceso funciona, y para saber qué le " +
    "falta a la empresa: «listo» dice si puede emitir (certificado vigente, usuario " +
    "SOL secundario, al menos una serie y la dirección revisada) y «portal» si sus " +
    "receptores van a recibir el correo de entrega (identificador y correo de respuesta).");

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
Planear 'Facturacion.Api\wwwroot\admin.html' '96037223337797D7520E008D09171D40C938DFB348002F2529DCB9C6849EEA16' @'
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

           /* Las claves de alta (024): encima de la lista de empresas. */
           .bloque-altas {
               padding: 14px 18px;
               margin-bottom: 14px;
           }

               .bloque-altas.alerta {
                   border-color: var(--mal);
               }

               .bloque-altas .cab {
                   display: flex;
                   justify-content: space-between;
                   align-items: center;
                   gap: 12px;
                   flex-wrap: wrap;
               }

               .bloque-altas h3 {
                   margin: 0;
                   font-size: 14px;
                   font-weight: 600;
               }

               .bloque-altas .explica {
                   font-size: 12.5px;
                   color: var(--tenue);
                   margin-top: 2px;
               }

           /* Un aviso que se lee de una línea, con la raya del color del aviso. */
           .aviso-linea {
               border-left: 2px solid var(--aviso);
               padding-left: 11px;
               font-size: 12.5px;
               color: var(--aviso);
               margin: 6px 0 12px;
           }

               .aviso-linea.ok {
                   border-left-color: var(--ok);
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
                Lo normal es dar de alta al cliente <strong>desde la
                plataforma</strong>, que crea la empresa aquí sola. Este
                formulario es para un cliente que integra por API sin la
                plataforma. Después habrá que cargarle un certificado, dar de
                alta al menos una serie y emitirle una clave de acceso.
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
                <!-- SIN VALORES POR DEFECTO, a propósito (024): un LIMA puesto
                     de antemano no se distingue de uno revisado, y un cliente de
                     Arequipa terminaba emitiendo con dirección de Lima. -->
                <label>
                    Dirección fiscal<input id="n-direccion" placeholder="Av. Ejército 101">
                    <div class="err" id="e-direccion"></div>
                </label>
                <label>Distrito<input id="n-distrito" placeholder="como en la ficha RUC"></label>
                <label>Provincia<input id="n-provincia"></label>
                <label>Departamento<input id="n-departamento"></label>
                <label>
                    Ubigeo<input id="n-ubigeo" maxlength="6" inputmode="numeric" placeholder="6 dígitos">
                    <div class="err" id="e-ubigeo"></div>
                </label>
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

            // Las claves de alta (024). Solo con altas.gestionar.
            clavesAlta: [],
            altasAbierto: false,

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
                await cargarClavesAlta();
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
        ${bloqueClavesAlta()}

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

            enlazarClavesAlta();

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
          ${e.estadoAlta === "sin_confirmar"
                    ? `<div style="font-size:12px;color:var(--aviso)">sin confirmar desde ${fechaHora(e.creadoEn)}</div>`
                    : e.estadoAlta === "abandonada"
                        ? `<div style="font-size:12px;color:var(--tenue)">alta abandonada</div>`
                        : ""}
        </div>`;
        }

        /// Lo que hace falta mirar en esta empresa. Aparece como punto en la lista
        /// para que los problemas se vean sin abrir una por una.
        function problemaDe(e) {
            if (!e.activo) return null;

            // La creó la plataforma y todavía no confirmó que guardó lo suyo.
            if (e.estadoAlta === "sin_confirmar")
                return `Alta sin confirmar desde ${fechaHora(e.creadoEn)}. Si la plataforma ` +
                    "no llegó a guardarla, el próximo alta de este RUC la dará por abandonada.";

            if (!e.tieneCertificado) return "Sin certificado: no puede emitir.";

            const dias = Math.ceil((new Date(e.certificadoVence) - new Date()) / 86400000);

            if (dias < 0) return "Certificado vencido: no puede emitir.";
            if (dias <= 30) return `El certificado vence en ${dias} días.`;
            if (e.series === 0) return "Sin series: no puede emitir.";
            if (e.claves === 0) return "Sin claves: el cliente no puede conectarse.";
            if (!e.direccionRevisadaEn) return "Dirección sin revisar: puede tener los valores por defecto.";

            return null;
        }

        function pintarDetalle() {
            const t = estado.seleccionada;

            elem("detalle").innerHTML = `
        <div class="cabecera-detalle">
          <div>
            <h2>${esc(t.razonSocial)}</h2>
            <div class="sub">${esc(t.ruc)} · ${t.ambiente}</div>
            ${origenAlta(t)}
          </div>
          <div style="display:flex;gap:8px;align-items:center">
            ${t.estadoAlta === "sin_confirmar"
                    ? `<span class="insignia i-aviso" title="La plataforma todavía no confirmó que la guardó.">sin confirmar</span>` : ""}
            ${t.estadoAlta === "abandonada"
                    ? `<span class="insignia i-tenue" title="Abandonada el ${fechaHora(t.abandonadaEn)}">abandonada</span>`
                    : `<span class="insignia ${t.activo ? "i-ok" : "i-tenue"}">
              ${t.activo ? "Activa" : "Inactiva"}</span>`}
            ${puede("empresas.editar") && t.estadoAlta !== "abandonada"
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

        ${vistaDireccion(t, editar)}

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
            if (elem("btn-direccion")) elem("btn-direccion").onclick = guardarDireccion;
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

        // -------------------------------------------------------- dirección fiscal
        //
        // La que sale en cada comprobante. «Revisada» quiere decir que alguien
        // la escribió a propósito: una dirección con los valores por defecto
        // no se distingue de una buena, y por eso cuenta la fecha (024).

        function vistaDireccion(t, editar) {
            const dis = editar ? "" : "disabled";

            return `
        <h2>Dirección fiscal</h2>
        ${t.direccionRevisadaEn
                    ? `<div class="aviso-linea ok">Revisada el ${fechaHora(t.direccionRevisadaEn)}.</div>`
                    : `<div class="aviso-linea"><strong>Sin revisar.</strong> Puede tener los valores
                 por defecto (LIMA). Compárala con la ficha RUC y guárdala: hasta entonces, la
                 plataforma no deja activar la facturación de un cliente nuevo.</div>`}

        <div class="rejilla" style="margin-top:0">
          <label>Dirección<input id="d-direccion" ${dis} value="${esc(t.direccion ?? "")}"></label>
          <label>Distrito<input id="d-distrito" ${dis} value="${esc(t.distrito ?? "")}"></label>
          <label>Provincia<input id="d-provincia" ${dis} value="${esc(t.provincia ?? "")}"></label>
          <label>Departamento<input id="d-departamento" ${dis} value="${esc(t.departamento ?? "")}"></label>
          <label>Ubigeo<input id="d-ubigeo" ${dis} maxlength="6" inputmode="numeric"
                              value="${esc(t.ubigeo ?? "")}"></label>
        </div>
        <div class="err" id="e-dir" style="margin:-6px 0 8px"></div>

        <div class="tenue" style="font-size:12.5px;margin-bottom:12px">
          Los comprobantes ya emitidos no cambian: llevan la dirección con la que se firmaron.
        </div>

        ${editar ? `<button id="btn-direccion" style="margin-bottom:26px">Guardar dirección</button>` : ""}`;
        }

        async function guardarDireccion() {
            const t = estado.seleccionada;
            const valor = id => elem(id).value.trim();

            const cuerpo = {
                direccion: valor("d-direccion"),
                distrito: valor("d-distrito"),
                provincia: valor("d-provincia"),
                departamento: valor("d-departamento"),
                ubigeo: valor("d-ubigeo")
            };

            elem("e-dir").textContent = "";

            const boton = elem("btn-direccion");
            boton.disabled = true;

            try {
                const r = await api(`/admin/tenants/${t.id}/direccion`, {
                    method: "PUT",
                    headers: { "Content-Type": "application/json" },
                    body: JSON.stringify(cuerpo)
                });

                avisar("Dirección guardada", r.mensaje, "ok");
                await recargar();

            } catch (ex) {
                // El motivo exacto (por ejemplo, el ubigeo es de otro
                // departamento) queda a la vista, no solo en el aviso.
                elem("e-dir").textContent = ex.detalle || ex.message;
                boton.disabled = false;
            }
        }

        /// Quién creó la empresa: el panel o una clave de alta (la plataforma).
        function origenAlta(t) {
            if (!t.claveAltaNombre)
                return "";

            const confirmada = t.estadoAlta === "confirmada" && t.altaConfirmadaEn
                ? ` · confirmada el ${fechaHora(t.altaConfirmadaEn)}` : "";

            return `<div class="tenue" style="font-size:12.5px;margin-top:3px">
                Creada por la clave de alta «${esc(t.claveAltaNombre)}»
                (<span class="mono">${esc(t.claveAltaPrefijo)}…</span>) el
                ${fechaHora(t.creadoEn)}${confirmada}</div>`;
        }

        // ---------------------------------------------------------- claves de alta
        //
        // La clave con la que la plataforma crea emisores (024). Solo crea: no
        // lee ni cambia las empresas que ya existen. Si se filtra, lo peor es
        // que alguien ocupe el RUC de un cliente; por eso el tope diario, el
        // aviso al alcanzarlo y la fecha del último uso a la vista.

        const DIAS_SIN_USO = 90;

        async function cargarClavesAlta() {
            if (!puede("altas.gestionar")) return;

            estado.clavesAlta = await api("/admin/claves-alta");

            // Una clave en su tope se ve sin tener que abrir nada.
            if (estado.clavesAlta.some(k => k.activo && k.altasHoy >= k.topeDiario))
                estado.altasAbierto = true;
        }

        const diasDesde = f => f ? Math.floor((new Date() - new Date(f)) / 86400000) : null;

        function bloqueClavesAlta() {
            if (!puede("altas.gestionar")) return "";

            const activas = estado.clavesAlta.filter(k => k.activo);
            const enTope = activas.filter(k => k.altasHoy >= k.topeDiario);

            return `
        <div class="tarjeta bloque-altas ${enTope.length ? "alerta" : ""}">
          <div class="cab">
            <div>
              <h3>Claves de alta
                ${enTope.length
                    ? `<span class="insignia i-mal" style="margin-left:6px">tope alcanzado hoy</span>` : ""}
              </h3>
              <div class="explica">
                Con ellas la plataforma crea empresas aquí. Solo crean: no leen ni cambian las existentes.
                ${activas.length} ${activas.length === 1 ? "activa" : "activas"}.
              </div>
            </div>
            <button class="mini" id="btn-altas-abrir">${estado.altasAbierto ? "Ocultar" : "Ver"}</button>
          </div>

          ${estado.altasAbierto ? `
            <div class="rejilla">
              <label>Nombre<input id="ka-nombre" maxlength="100" placeholder="Plataforma producción"></label>
              <label>Tope por día<input id="ka-tope" type="number" min="1" max="100" value="20"></label>
            </div>
            <div style="display:flex;align-items:center;gap:12px;margin-bottom:12px;flex-wrap:wrap">
              <button id="btn-alta-emitir">Emitir clave de alta</button>
              <span class="tenue" style="font-size:12.5px">
                Se muestra una sola vez. Va al .env de la plataforma (FACTURACION_CLAVE_ALTA).
              </span>
            </div>
            <div id="ka-resultado"></div>
            ${tablaClavesAlta()}` : ""}
        </div>`;
        }

        function tablaClavesAlta() {
            if (estado.clavesAlta.length === 0)
                return `<div class="vacio" style="border-top:1px solid var(--borde)">
                  Ninguna todavía. Sin una, la plataforma no puede crear empresas.</div>`;

            return `<table>
          <tr><th>Nombre</th><th>Prefijo</th><th>Hoy</th><th>Total</th>
              <th>Último uso</th><th>Estado</th><th></th></tr>
          ${estado.clavesAlta.map(k => {
                const enTope = k.activo && k.altasHoy >= k.topeDiario;
                const sinUso = diasDesde(k.ultimoUso ?? k.creadoEn);
                const vieja = k.activo && sinUso !== null && sinUso >= DIAS_SIN_USO;

                return `<tr class="${k.activo ? "" : "fila-inactiva"}">
              <td>${esc(k.nombre)}
                <div class="tenue" style="font-size:12px">
                  emitida el ${diaDe(k.creadoEn)}${k.creadaPor ? ` por ${esc(k.creadaPor)}` : ""}</div></td>
              <td class="mono">${esc(k.prefijo)}…</td>
              <td class="${enTope ? "mal" : ""}" style="white-space:nowrap">${k.altasHoy} de ${k.topeDiario}</td>
              <td>${k.altasTotal}</td>
              <td class="tenue">
                ${k.ultimoUso ? fechaHora(k.ultimoUso) : "nunca"}
                ${vieja ? `<div style="color:var(--aviso);font-size:12px"
                     title="Una clave que nadie usa solo sirve para que alguien la encuentre.">
                     ${sinUso} días sin usarse: ¿sigue haciendo falta?</div>` : ""}</td>
              <td>${k.activo
                    ? `<span class="insignia i-ok">activa</span>`
                    : `<span class="insignia i-tenue" title="${k.revocadaPor ? "por " + esc(k.revocadaPor) : ""}">
                         revocada el ${diaDe(k.revocadoEn)}</span>`}</td>
              <td>${k.activo
                    ? `<button class="mini peligro" data-revocar-alta="${k.id}"
                               data-nombre="${esc(k.nombre)}">Revocar</button>` : ""}</td>
            </tr>`;
            }).join("")}
        </table>`;
        }

        function enlazarClavesAlta() {
            const abrir = elem("btn-altas-abrir");
            if (!abrir) return;

            abrir.onclick = () => {
                estado.altasAbierto = !estado.altasAbierto;
                pintar();
            };

            if (elem("btn-alta-emitir")) elem("btn-alta-emitir").onclick = emitirClaveAlta;

            document.querySelectorAll("[data-revocar-alta]").forEach(b =>
                b.onclick = () => revocarClaveAlta(b.dataset.revocarAlta, b.dataset.nombre));
        }

        async function emitirClaveAlta() {
            const nombre = elem("ka-nombre").value.trim();
            const tope = parseInt(elem("ka-tope").value || "20", 10);

            if (!nombre) {
                avisar("Ponle un nombre", "Dónde se va a usar: «Plataforma producción», por ejemplo.", "mal");
                return;
            }

            const boton = elem("btn-alta-emitir");
            boton.disabled = true;

            try {
                const r = await api("/admin/claves-alta", {
                    method: "POST",
                    headers: { "Content-Type": "application/json" },
                    body: JSON.stringify({ nombre, topeDiario: tope })
                });

                estado.clavesAlta = await api("/admin/claves-alta");
                pintar();

                // Se muestra fija y DESPUÉS de repintar: es la única vez que
                // existe, y un repintado la borraría.
                elem("ka-resultado").innerHTML = `
          <div class="secreto" style="margin-bottom:12px">
            <strong>Cópiala ahora y pégala en el .env de la plataforma.</strong>
            <code>${esc(r.clave)}</code>
            <button class="mini" id="btn-copiar-alta">Copiar</button>
            <div class="tenue" style="font-size:12.5px;margin-top:8px">${esc(r.aviso)}</div>
          </div>`;

                elem("btn-copiar-alta").onclick = async () => {
                    await navigator.clipboard.writeText(r.clave);
                    avisar("Clave de alta copiada", "", "ok");
                };

            } catch (e) {
                avisar(e.message, e.detalle, "mal");
                boton.disabled = false;
            }
        }

        async function revocarClaveAlta(id, nombre) {
            const seguro = await confirmar(
                `Revocar la clave de alta «${nombre}»`,
                "La plataforma que la use dejará de poder crear empresas de inmediato. Las " +
                "empresas que ya creó no cambian. No se puede deshacer: habría que emitir otra.",
                "Revocar");

            if (!seguro) return;

            try {
                await api(`/admin/claves-alta/${id}`, { method: "DELETE" });
                avisar("Clave de alta revocada", "", "ok");
                estado.clavesAlta = await api("/admin/claves-alta");
                pintar();
            } catch (e) { avisar(e.message, e.detalle, "mal"); }
        }

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
            ["ruc", "razon", "identificador", "direccion", "ubigeo"].forEach(c => {
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

            // La dirección entera, sin valores por defecto. El servidor
            // comprueba además que el ubigeo sea del departamento escrito.
            const faltaDir = ["n-direccion", "n-distrito", "n-provincia", "n-departamento"]
                .some(id => !elem(id).value.trim());
            marcar("direccion", faltaDir ? "Completa dirección, distrito, provincia y departamento." : "");
            marcar("ubigeo", /^\d{6}$/.test(elem("n-ubigeo").value.trim()) ? "" : "Son 6 dígitos.");

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
                ["n-direccion", "n-distrito", "n-provincia", "n-departamento", "n-ubigeo",
                    "n-identificador"].forEach(id => elem(id).value = "");

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
Write-Host 'FALTA APLICAR LA MIGRACIÓN 024 (este script NO la aplica). Desde esta carpeta:' -ForegroundColor Cyan
Write-Host ''
Write-Host '  Get-Content migraciones\024_alta_emisores.sql -Raw | docker compose exec -T postgres psql -U facturacion_owner -d facturacion -v ON_ERROR_STOP=1' -ForegroundColor White
Write-Host ''
Write-Host 'Tiene que terminar con la línea «024: ... permiso listo» y COMMIT.' -ForegroundColor Cyan
Write-Host 'Después, reinicia la API del servicio (el worker no cambia).' -ForegroundColor Cyan
Write-Host ''
