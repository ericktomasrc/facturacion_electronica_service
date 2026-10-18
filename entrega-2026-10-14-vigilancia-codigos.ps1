# =============================================================================
# Entrega 2026-10-14 — VIGILANCIA SUNAT, PARTE 1: LA ALARMA DE CÓDIGOS NUEVOS
# (SERVICIO de facturación)
#
# Se ejecuta desde la raíz del servicio:
#   cd "D:\Reyban Consulting\facturacion electronica\facturacion_electronica_service"
#   .\entrega-2026-10-14-vigilancia-codigos.ps1
#
# NUEVOS
#   migraciones\029_vigilancia_sunat.sql          Tablas de códigos, correos y
#                                                 alertas. NO se aplica sola
#   Facturacion.Persistencia\RepositorioVigilancia.cs
#   Facturacion.Api\VigilanciaSunat.cs            Revisa cada 5 min y avisa
#   Facturacion.Api\EndpointsVigilancia.cs        /admin/vigilancia/...
#   Facturacion.Api\wwwroot\vigilancia.html       La pestaña nueva del panel
#
# CAMBIOS PUNTUALES
#   Facturacion.Api\Program.cs                    Registra la vigilancia
#   Facturacion.Persistencia\RepositorioDiagnostico.cs
#                                                 Un código nuevo sin revisar
#                                                 sube el semáforo
#   wwwroot: diagnostico, cuenta, admin, comprobantes, usuarios
#                                                 «Vigilancia SUNAT» en el menú
#
# Cómo trabaja: comprueba TODO antes de escribir. Si un texto a cambiar no
# está tal cual, o un archivo nuevo ya existe distinto, NO TOCA NADA. Copia
# .bak de lo que cambia. Respeta los saltos de línea. No pregunta nada.
# =============================================================================

$ErrorActionPreference = 'Stop'
$raiz = (Get-Location).Path

if (-not (Test-Path (Join-Path $raiz 'Facturacion.Api')) -or -not (Test-Path (Join-Path $raiz 'migraciones'))) {
    Write-Host "No encuentro 'Facturacion.Api' y 'migraciones' aquí ($raiz)." -ForegroundColor Red
    Write-Host "Ejecuta el script desde la raíz del servicio (facturacion_electronica_service). No se tocó nada." -ForegroundColor Red
    exit 1
}

$utf8SinBom = New-Object System.Text.UTF8Encoding $false

$nuevos = @(
    @{ Ruta = 'migraciones\029_vigilancia_sunat.sql'; Texto = @'
-- =============================================================================
-- 029 - VIGILANCIA SUNAT, PARTE 1: LA ALARMA DE CODIGOS NUEVOS
--
-- Cada codigo que SUNAT devuelve (a cualquier empresa) queda anotado. Si
-- aparece uno que nunca habia salido, se avisa: por correo y en el panel
-- (Vigilancia SUNAT). El primer cliente que se topa con una regla nueva de
-- SUNAT protege a los demas.
--
--   codigos_sunat           un codigo por fila: respuesta (0, 2xxx, 3xxx...)
--                           u observacion (4xxx). Cuantas veces, cuando, un
--                           ejemplo, y quien lo reviso.
--   codigos_sunat_empresas  que empresas lo recibieron (para contarlas)
--   vigilancia_estado       hasta donde se reviso envio_intentos (una fila)
--   vigilancia_correos      la lista de correos para alertas, ademas de los
--                           administradores del panel
--   vigilancia_alertas      cada aviso, y si su correo ya salio
--
-- LA PRIMERA VUELTA DEL SERVICIO llena codigos_sunat con todo lo que SUNAT
-- ya respondio hasta hoy, marcado como 'historico', SIN avisar. Solo avisan
-- los codigos que salgan despues. Lo hace el servicio y no esta migracion
-- para que la lectura de las observaciones viva en un solo sitio.
--
-- Tablas de la plataforma entera, no de una empresa: sin RLS y solo para el
-- operador (el panel). La aplicacion (clave fac_) no las ve.
--
-- NADA SE BORRA: nadie tiene DELETE. Un correo de la lista se "quita"
-- poniendole fecha, y queda quien lo agrego y quien lo quito.
--
-- Idempotente. Sin tildes a proposito: PowerShell 5.1 la manda a psql en ASCII.
-- =============================================================================

BEGIN;

-- --------------------------------------------------------------- codigos
CREATE TABLE IF NOT EXISTS codigos_sunat (
    codigo             varchar(20) NOT NULL,

    -- 'respuesta':   el codigo del CDR o del error (0 aceptado, 2xxx-3xxx
    --                rechazo, 0100-1999 excepcion del envio)
    -- 'observacion': una nota del CDR de un comprobante aceptado (4xxx)
    clase              text        NOT NULL,

    primera_vez        timestamptz NOT NULL,
    ultima_vez         timestamptz NOT NULL,
    veces              bigint      NOT NULL DEFAULT 1,

    -- Un ejemplo, el de la primera vez: lo que dijo SUNAT y a quien.
    ejemplo_mensaje    text,
    ejemplo_tenant_id  uuid,
    ejemplo_documento  text,

    -- 'historico': ya estaba cuando se instalo la vigilancia (no avisa).
    -- 'nuevo':     aparecio despues (avisa una vez).
    origen             text        NOT NULL,

    -- Quien lo reviso, cuando, y que dijo. El correo se copia: si el usuario
    -- cambia de correo, aqui queda el que tenia ese dia.
    revisado_en        timestamptz,
    revisado_por       uuid,
    revisado_correo    text,
    nota               text,

    CONSTRAINT pk_codigos_sunat PRIMARY KEY (codigo, clase),
    CONSTRAINT ck_codigos_sunat_clase  CHECK (clase IN ('respuesta', 'observacion')),
    CONSTRAINT ck_codigos_sunat_origen CHECK (origen IN ('historico', 'nuevo')),
    CONSTRAINT ck_codigos_sunat_veces  CHECK (veces >= 1),
    CONSTRAINT ck_codigos_sunat_nota   CHECK (nota IS NULL OR length(btrim(nota)) BETWEEN 1 AND 1000),
    CONSTRAINT ck_codigos_sunat_revisado CHECK (
        (revisado_en IS NULL AND revisado_correo IS NULL AND nota IS NULL)
        OR (revisado_en IS NOT NULL AND revisado_correo IS NOT NULL AND nota IS NOT NULL))
);

COMMENT ON TABLE codigos_sunat IS
    'Cada codigo que SUNAT devolvio alguna vez, a cualquier empresa. Los nuevos sin revisar son la alarma de Vigilancia SUNAT.';

CREATE INDEX IF NOT EXISTS ix_codigos_sunat_sin_revisar
    ON codigos_sunat (primera_vez DESC) WHERE origen = 'nuevo' AND revisado_en IS NULL;

CREATE TABLE IF NOT EXISTS codigos_sunat_empresas (
    codigo       varchar(20) NOT NULL,
    clase        text        NOT NULL,
    tenant_id    uuid        NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
    primera_vez  timestamptz NOT NULL,
    CONSTRAINT pk_codigos_sunat_empresas PRIMARY KEY (codigo, clase, tenant_id),
    CONSTRAINT fk_codigos_sunat_empresas_codigo FOREIGN KEY (codigo, clase)
        REFERENCES codigos_sunat (codigo, clase) ON DELETE RESTRICT
);

-- ------------------------------------------------- hasta donde se reviso
CREATE TABLE IF NOT EXISTS vigilancia_estado (
    id                  smallint    PRIMARY KEY DEFAULT 1,
    -- El mayor envio_intentos.id ya revisado. NULL: todavia no se hizo la
    -- primera vuelta (la del historico).
    ultimo_intento_id   bigint,
    inicializado_en     timestamptz,
    ultima_revision_en  timestamptz,
    CONSTRAINT ck_vigilancia_estado_una_fila CHECK (id = 1)
);

INSERT INTO vigilancia_estado (id) VALUES (1) ON CONFLICT (id) DO NOTHING;

-- ------------------------------------------------- correos para alertas
CREATE TABLE IF NOT EXISTS vigilancia_correos (
    id               bigserial   PRIMARY KEY,
    correo           text        NOT NULL,
    agregado_por     uuid,
    agregado_correo  text        NOT NULL,
    agregado_en      timestamptz NOT NULL DEFAULT now(),
    quitado_por      uuid,
    quitado_correo   text,
    quitado_en       timestamptz,
    CONSTRAINT ck_vigilancia_correos_forma CHECK (
        length(correo) BETWEEN 6 AND 254 AND correo ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
    CONSTRAINT ck_vigilancia_correos_quitado CHECK (
        (quitado_en IS NULL AND quitado_correo IS NULL)
        OR (quitado_en IS NOT NULL AND quitado_correo IS NOT NULL))
);

-- Un mismo correo no puede estar dos veces en la lista vigente.
CREATE UNIQUE INDEX IF NOT EXISTS ux_vigilancia_correos_vigente
    ON vigilancia_correos (lower(correo)) WHERE quitado_en IS NULL;

-- ------------------------------------------------------------- alertas
CREATE TABLE IF NOT EXISTS vigilancia_alertas (
    id                 bigserial   PRIMARY KEY,
    -- 'codigo_nuevo' ahora. La prueba de madrugada (parte 2) agregara sus tipos.
    tipo               text        NOT NULL,
    gravedad           text        NOT NULL,
    titulo             text        NOT NULL,
    detalle            text        NOT NULL,
    codigo             varchar(20),
    clase              text,
    creada_en          timestamptz NOT NULL DEFAULT now(),

    -- El correo de la alerta: cuando salio, cuantas veces se intento y por
    -- que fallo la ultima. A quienes se mando queda en enviado_a.
    correo_enviado_en  timestamptz,
    enviado_a          text,
    correo_intentos    smallint    NOT NULL DEFAULT 0,
    correo_error       text,
    proximo_intento_en timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT ck_vigilancia_alertas_gravedad CHECK (gravedad IN ('problema', 'atencion'))
);

CREATE INDEX IF NOT EXISTS ix_vigilancia_alertas_pendientes
    ON vigilancia_alertas (proximo_intento_en) WHERE correo_enviado_en IS NULL;

-- --------------------------------------------------------------- permisos
REVOKE ALL ON codigos_sunat, codigos_sunat_empresas, vigilancia_estado,
              vigilancia_correos, vigilancia_alertas FROM PUBLIC;

GRANT SELECT, INSERT, UPDATE ON codigos_sunat          TO facturacion_operador;
GRANT SELECT, INSERT         ON codigos_sunat_empresas TO facturacion_operador;
GRANT SELECT, UPDATE         ON vigilancia_estado      TO facturacion_operador;
GRANT SELECT, INSERT, UPDATE ON vigilancia_correos     TO facturacion_operador;
GRANT SELECT, INSERT, UPDATE ON vigilancia_alertas     TO facturacion_operador;
GRANT USAGE, SELECT ON SEQUENCE vigilancia_correos_id_seq, vigilancia_alertas_id_seq
    TO facturacion_operador;

DO $$
DECLARE
    t text;
BEGIN
    FOREACH t IN ARRAY ARRAY['codigos_sunat', 'codigos_sunat_empresas', 'vigilancia_estado',
                             'vigilancia_correos', 'vigilancia_alertas'] LOOP
        IF has_table_privilege('facturacion_operador', t, 'DELETE') THEN
            RAISE EXCEPTION '029: el operador no deberia poder borrar en %.', t;
        END IF;
        IF has_table_privilege('facturacion_app', t, 'SELECT') THEN
            RAISE EXCEPTION '029: la aplicacion no deberia ver %.', t;
        END IF;
    END LOOP;

    IF NOT EXISTS (SELECT 1 FROM vigilancia_estado WHERE id = 1) THEN
        RAISE EXCEPTION '029: falta la fila de vigilancia_estado.';
    END IF;

    RAISE NOTICE '029: vigilancia SUNAT (codigos nuevos) lista.';
END $$;

COMMIT;
'@ },
    @{ Ruta = 'Facturacion.Persistencia\RepositorioVigilancia.cs'; Texto = @'
using System.Text.RegularExpressions;
using Dapper;
using Npgsql;

namespace Facturacion.Persistencia;

/// <summary>Un código de SUNAT tal como se ve en el panel.</summary>
public record CodigoSunatVisto(
    string Codigo,
    string Clase,
    DateTime PrimeraVez,
    DateTime UltimaVez,
    long Veces,
    int Empresas,
    string? EjemploMensaje,
    string? EjemploEmpresa,
    string? EjemploRuc,
    string? EjemploDocumento,
    string Origen,
    DateTime? RevisadoEn,
    string? RevisadoCorreo,
    string? Nota)
{
    /// <summary>Apareció después de instalar la vigilancia y nadie lo revisó.</summary>
    public bool EsNuevoSinRevisar => Origen == "nuevo" && RevisadoEn is null;

    public string Gravedad => RepositorioVigilancia.Gravedad(Codigo, Clase);
}

/// <summary>Un correo de la lista de alertas.</summary>
public record CorreoAlerta(long Id, string Correo, string AgregadoCorreo, DateTime AgregadoEn);

/// <summary>Una alerta cuyo correo todavía no salió.</summary>
public record AlertaPendiente(
    long Id, string Tipo, string Gravedad, string Titulo, string Detalle,
    DateTime CreadaEn, short CorreoIntentos);

/// <summary>Cómo fue una vuelta de revisión.</summary>
public record ResultadoRevision(
    bool FueLaPrimera, int IntentosRevisados, int CodigosNuevos, int AlertasCreadas);

/// <summary>Hasta dónde llegó la vigilancia.</summary>
public record EstadoVigilancia(DateTime? InicializadoEn, DateTime? UltimaRevisionEn);

/// <summary>
/// LA ALARMA DE CÓDIGOS NUEVOS (migración 029, Vigilancia SUNAT parte 1).
///
/// Anota cada código que SUNAT devuelve, a cualquier empresa, y avisa cuando
/// aparece uno que nunca había salido. Con cincuenta clientes, el primero que
/// se topa con una regla nueva de SUNAT protege a los otros cuarenta y nueve.
///
/// SOLO LEE LO QUE YA PASÓ. No toca el camino de la emisión: si esto falla,
/// la facturación sigue exactamente igual. Lee tres sitios:
///
///   envio_intentos   cada respuesta a facturas, notas, liquidaciones,
///                    retenciones y percepciones. Se recorre por id, una vez.
///   resumenes        resúmenes de boletas, bajas y reversiones.
///   guias            guías de remisión.
///
/// Las observaciones (4xxx) no tienen columna propia: viajan dentro del
/// mensaje, después de «Observaciones:». Se sacan de ahí (ver Observaciones).
///
/// LA PRIMERA VUELTA anota todo lo que ya existía como 'historico' y NO avisa.
/// Así, al instalarlo, no llegan cien correos de códigos que ya se conocían.
///
/// Usa el rol de operador: mira todas las empresas, como el diagnóstico.
/// </summary>
public sealed class RepositorioVigilancia
{
    private const int Tanda = 5000;

    private readonly string _cadenaOperador;

    /// <summary>Las tablas que la última vuelta no pudo leer (sin permiso).</summary>
    public List<string> TablasSinPermiso { get; } = [];

    public RepositorioVigilancia(string cadenaConexionOperador)
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

    // ================================================================ revisión

    /// <summary>
    /// Una vuelta: lee lo nuevo, anota los códigos y crea las alertas.
    ///
    /// Todo en UNA transacción, con la fila de vigilancia_estado bloqueada:
    /// si dos vueltas coinciden (el reloj y el botón «Revisar ahora»), la
    /// segunda espera a la primera y no cuenta dos veces lo mismo.
    /// </summary>
    public async Task<ResultadoRevision> RevisarAsync(CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);
        await using var tx = await conexion.BeginTransactionAsync(ct);

        var ultimoId = await conexion.QuerySingleAsync<long?>(new CommandDefinition(
            "SELECT ultimo_intento_id FROM vigilancia_estado WHERE id = 1 FOR UPDATE",
            transaction: tx, cancellationToken: ct));

        var primera = ultimoId is null;
        var origen = primera ? "historico" : "nuevo";

        TablasSinPermiso.Clear();
        var vistos = new Dictionary<(string Codigo, string Clase), Acumulado>();
        var revisados = 0;
        var hasta = ultimoId ?? 0;

        // --- 1. envio_intentos, por id, en tandas ----------------------------
        while (true)
        {
            var filas = (await conexion.QueryAsync<FilaIntento>(new CommandDefinition(
                """
                SELECT e.id              AS "Id",
                       e.tenant_id       AS "TenantId",
                       e.codigo_sunat    AS "Codigo",
                       e.mensaje         AS "Mensaje",
                       e.creado_en       AS "CreadoEn",
                       c.serie || '-' || lpad(c.correlativo::text, 8, '0') AS "Documento"
                  FROM envio_intentos e
                  LEFT JOIN comprobantes c ON c.id = e.comprobante_id
                 WHERE e.id > @hasta
                   AND (e.codigo_sunat IS NOT NULL OR e.mensaje LIKE '%Observaciones:%')
                 ORDER BY e.id
                 LIMIT @tanda
                """,
                new { hasta, tanda = Tanda }, tx, cancellationToken: ct))).ToList();

            foreach (var f in filas)
                Anotar(vistos, f.TenantId, f.Codigo, f.Mensaje, f.CreadoEn, f.Documento);

            revisados += filas.Count;

            if (filas.Count < Tanda) break;
            hasta = filas[^1].Id;
        }

        // El tope de verdad, no el de las filas con código: así la próxima
        // vuelta no vuelve a leer intentos sin código.
        var maximo = await conexion.QuerySingleAsync<long?>(new CommandDefinition(
            "SELECT max(id) FROM envio_intentos", transaction: tx, cancellationToken: ct));

        // --- 2. resúmenes y guías --------------------------------------------
        //
        // No tienen un id que crezca, y su código se escribe días después de
        // crearse. Se mira:
        //   - la respuesta, si su código todavía no está anotado (es barato:
        //     son pocas filas por empresa y por día);
        //   - las observaciones, solo de los últimos 15 días (la primera vez,
        //     de todos).
        foreach (var tabla in new[] { "resumenes", "guias" })
        {
            // Si el operador no puede leer la tabla, se salta (y se dice en
            // el log de la API): mejor vigilar dos de tres que ninguna.
            var puedeLeer = await conexion.ExecuteScalarAsync<bool>(new CommandDefinition(
                "SELECT has_table_privilege(current_user, @tabla, 'SELECT')",
                new { tabla }, tx, cancellationToken: ct));

            if (!puedeLeer) { TablasSinPermiso.Add(tabla); continue; }

            var documento = tabla == "resumenes"
                ? "r.identificador"
                : "r.serie || '-' || lpad(r.correlativo::text, 8, '0')";

            var filas = await conexion.QueryAsync<FilaIntento>(new CommandDefinition(
                $"""
                SELECT 0::bigint         AS "Id",
                       r.tenant_id       AS "TenantId",
                       r.codigo_sunat    AS "Codigo",
                       r.mensaje_sunat   AS "Mensaje",
                       r.creado_en       AS "CreadoEn",
                       {documento}       AS "Documento"
                  FROM {tabla} r
                 WHERE (r.codigo_sunat IS NOT NULL
                        AND NOT EXISTS (SELECT 1 FROM codigos_sunat v
                                         WHERE v.codigo = btrim(r.codigo_sunat)
                                           AND v.clase = 'respuesta'))
                    OR (r.mensaje_sunat LIKE '%Observaciones:%'
                        AND (@primera OR r.creado_en >= now() - interval '15 days'))
                """,
                new { primera }, tx, cancellationToken: ct));

            foreach (var f in filas)
            {
                // De estas solo cuentan los códigos que todavía no existen:
                // las observaciones de los últimos 15 días se leen en cada
                // vuelta, y sumarlas cada vez inflaría las «veces».
                Anotar(vistos, f.TenantId, f.Codigo, f.Mensaje, f.CreadoEn, f.Documento,
                       soloSiEsNuevo: true);
            }
        }

        // --- 3. guardar -------------------------------------------------------
        var nuevos = 0;
        var alertas = 0;

        foreach (var ((codigo, clase), a) in vistos)
        {
            var existia = await conexion.ExecuteScalarAsync<bool>(new CommandDefinition(
                "SELECT EXISTS (SELECT 1 FROM codigos_sunat WHERE codigo = @codigo AND clase = @clase)",
                new { codigo, clase }, tx, cancellationToken: ct));

            if (existia)
            {
                if (a.Veces > 0)
                {
                    await conexion.ExecuteAsync(new CommandDefinition(
                        """
                        UPDATE codigos_sunat
                           SET veces = veces + @veces,
                               ultima_vez = greatest(ultima_vez, @ultima)
                         WHERE codigo = @codigo AND clase = @clase
                        """,
                        new { codigo, clase, veces = a.Veces, ultima = a.Ultima },
                        tx, cancellationToken: ct));
                }
            }
            else
            {
                await conexion.ExecuteAsync(new CommandDefinition(
                    """
                    INSERT INTO codigos_sunat
                        (codigo, clase, primera_vez, ultima_vez, veces,
                         ejemplo_mensaje, ejemplo_tenant_id, ejemplo_documento, origen)
                    VALUES
                        (@codigo, @clase, @primera, @ultima, @veces,
                         @mensaje, @tenantId, @documento, @origen)
                    """,
                    new
                    {
                        codigo, clase,
                        primera = a.Primera, ultima = a.Ultima,
                        veces = Math.Max(1, a.Veces),
                        mensaje = Recortar(a.Mensaje, 1000),
                        tenantId = a.TenantId,
                        documento = Recortar(a.Documento, 60),
                        origen
                    },
                    tx, cancellationToken: ct));

                nuevos++;

                // El 0 es «aceptado»: no es una regla nueva, no avisa nunca.
                if (!primera && !(clase == "respuesta" && codigo == "0"))
                {
                    await CrearAlertaCodigoAsync(conexion, tx, codigo, clase, a, ct);
                    alertas++;
                }
            }

            foreach (var tenantId in a.Empresas)
            {
                await conexion.ExecuteAsync(new CommandDefinition(
                    """
                    INSERT INTO codigos_sunat_empresas (codigo, clase, tenant_id, primera_vez)
                    VALUES (@codigo, @clase, @tenantId, @cuando)
                    ON CONFLICT DO NOTHING
                    """,
                    new { codigo, clase, tenantId, cuando = a.Primera },
                    tx, cancellationToken: ct));
            }
        }

        await conexion.ExecuteAsync(new CommandDefinition(
            """
            UPDATE vigilancia_estado
               SET ultimo_intento_id  = greatest(coalesce(ultimo_intento_id, 0), @maximo),
                   inicializado_en    = coalesce(inicializado_en, now()),
                   ultima_revision_en = now()
             WHERE id = 1
            """,
            new { maximo = maximo ?? 0 }, tx, cancellationToken: ct));

        await tx.CommitAsync(ct);

        return new ResultadoRevision(primera, revisados, nuevos, alertas);
    }

    private static async Task CrearAlertaCodigoAsync(
        NpgsqlConnection conexion, NpgsqlTransaction tx,
        string codigo, string clase, Acumulado a, CancellationToken ct)
    {
        var empresa = a.TenantId is null ? null : await conexion.QuerySingleOrDefaultAsync<FilaEmpresa>(
            new CommandDefinition(
                """SELECT razon_social AS "RazonSocial", ruc AS "Ruc" FROM tenants WHERE id = @id""",
                new { id = a.TenantId }, tx, cancellationToken: ct));

        var gravedad = Gravedad(codigo, clase);
        var que = clase == "observacion" ? "observación" : "respuesta";

        var titulo = $"Código de SUNAT nunca visto: {codigo} ({que})";

        var detalle =
            $"SUNAT dijo: {a.Mensaje ?? "(sin mensaje)"}\n" +
            $"Empresa: {(empresa is null ? "—" : $"{empresa.RazonSocial} ({empresa.Ruc})")}\n" +
            $"Documento: {a.Documento ?? "—"}\n" +
            $"Cuándo: {a.Primera:yyyy-MM-dd HH:mm} (hora del servidor)";

        await conexion.ExecuteAsync(new CommandDefinition(
            """
            INSERT INTO vigilancia_alertas (tipo, gravedad, titulo, detalle, codigo, clase)
            VALUES ('codigo_nuevo', @gravedad, @titulo, @detalle, @codigo, @clase)
            """,
            new { gravedad, titulo, detalle = Recortar(detalle, 3000), codigo, clase },
            tx, cancellationToken: ct));
    }

    // ============================================================ observaciones

    private static readonly Regex CodigoAlInicio =
        new(@"^\W*(\d{3,4})\b", RegexOptions.Compiled);

    /// <summary>
    /// Saca las observaciones de un mensaje guardado.
    ///
    /// El worker escribe «… Observaciones: A | B» (comprobantes y resúmenes)
    /// o «… | Observaciones: A; B» (guías). Cada observación de SUNAT empieza
    /// por su código («4287 - El precio…»). La que no empiece por un código
    /// de 3 o 4 cifras se ignora: mejor no anotar nada que anotar basura.
    /// </summary>
    public static IEnumerable<(string Codigo, string Texto)> Observaciones(string? mensaje)
    {
        if (string.IsNullOrEmpty(mensaje)) yield break;

        var i = mensaje.IndexOf("Observaciones:", StringComparison.Ordinal);
        if (i < 0) yield break;

        var resto = mensaje[(i + "Observaciones:".Length)..];

        foreach (var trozo in resto.Split(new[] { '|', ';' }, StringSplitOptions.RemoveEmptyEntries))
        {
            var texto = trozo.Trim();
            var m = CodigoAlInicio.Match(texto);
            if (m.Success) yield return (m.Groups[1].Value, texto);
        }
    }

    /// <summary>
    /// Qué tan grave es un código nuevo.
    ///
    /// Respuestas: 0100–1999 son excepciones (SUNAT ni siquiera lo recibió) y
    /// 2000–3999 son rechazos: «problema», porque un cliente no puede emitir.
    /// Las observaciones (4000 en adelante) dejan pasar el comprobante:
    /// «atención». Lo que no sea un número también es «atención».
    /// </summary>
    public static string Gravedad(string codigo, string clase)
    {
        if (clase == "observacion") return "atencion";

        var digitos = new string(codigo.Reverse().TakeWhile(char.IsDigit).Reverse().ToArray());

        return int.TryParse(digitos, out var n) && n is >= 100 and < 4000
            ? "problema"
            : "atencion";
    }

    private static void Anotar(
        Dictionary<(string, string), Acumulado> vistos,
        Guid? tenantId, string? codigo, string? mensaje, DateTime cuando, string? documento,
        bool soloSiEsNuevo = false)
    {
        var codigoLimpio = codigo?.Trim();

        if (!string.IsNullOrEmpty(codigoLimpio))
        {
            // El mensaje de ejemplo es lo que SUNAT dijo, sin las observaciones.
            var i = mensaje?.IndexOf(" Observaciones:", StringComparison.Ordinal) ?? -1;
            var propio = i > 0 ? mensaje![..i] : mensaje;

            Sumar(vistos, (Recortar(codigoLimpio, 20)!, "respuesta"),
                  tenantId, propio, cuando, documento, soloSiEsNuevo);
        }

        foreach (var (cod, texto) in Observaciones(mensaje))
            Sumar(vistos, (cod, "observacion"), tenantId, texto, cuando, documento, soloSiEsNuevo);
    }

    private static void Sumar(
        Dictionary<(string, string), Acumulado> vistos, (string, string) clave,
        Guid? tenantId, string? mensaje, DateTime cuando, string? documento, bool soloSiEsNuevo)
    {
        if (!vistos.TryGetValue(clave, out var a))
        {
            a = new Acumulado { Primera = cuando, Ultima = cuando, Mensaje = mensaje,
                                TenantId = tenantId, Documento = documento };
            vistos[clave] = a;
        }

        if (!soloSiEsNuevo) a.Veces++;

        if (cuando < a.Primera)
        {
            a.Primera = cuando; a.Mensaje = mensaje; a.TenantId = tenantId; a.Documento = documento;
        }
        if (cuando > a.Ultima) a.Ultima = cuando;
        if (tenantId is { } t) a.Empresas.Add(t);
    }

    private static string? Recortar(string? t, int largo) =>
        t is null ? null : t.Length <= largo ? t : t[..largo];

    private sealed class Acumulado
    {
        public DateTime Primera;
        public DateTime Ultima;
        public long Veces;
        public string? Mensaje;
        public Guid? TenantId;
        public string? Documento;
        public HashSet<Guid> Empresas { get; } = [];
    }

    private sealed record FilaIntento(
        long Id, Guid? TenantId, string? Codigo, string? Mensaje, DateTime CreadoEn, string? Documento);

    private sealed record FilaEmpresa(string RazonSocial, string Ruc);

    // ================================================================= panel

    public async Task<EstadoVigilancia> EstadoAsync(CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);

        return await conexion.QuerySingleAsync<EstadoVigilancia>(new CommandDefinition(
            """
            SELECT inicializado_en    AS "InicializadoEn",
                   ultima_revision_en AS "UltimaRevisionEn"
              FROM vigilancia_estado WHERE id = 1
            """,
            cancellationToken: ct));
    }

    /// <summary>Los códigos: primero los nuevos sin revisar, después el resto.</summary>
    public async Task<IReadOnlyList<CodigoSunatVisto>> ListarCodigosAsync(CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);

        return (await conexion.QueryAsync<CodigoSunatVisto>(new CommandDefinition(
            """
            SELECT c.codigo            AS "Codigo",
                   c.clase             AS "Clase",
                   c.primera_vez       AS "PrimeraVez",
                   c.ultima_vez        AS "UltimaVez",
                   c.veces             AS "Veces",
                   (SELECT count(*)::int FROM codigos_sunat_empresas e
                     WHERE e.codigo = c.codigo AND e.clase = c.clase) AS "Empresas",
                   c.ejemplo_mensaje   AS "EjemploMensaje",
                   t.razon_social      AS "EjemploEmpresa",
                   t.ruc               AS "EjemploRuc",
                   c.ejemplo_documento AS "EjemploDocumento",
                   c.origen            AS "Origen",
                   c.revisado_en       AS "RevisadoEn",
                   c.revisado_correo   AS "RevisadoCorreo",
                   c.nota              AS "Nota"
              FROM codigos_sunat c
              LEFT JOIN tenants t ON t.id = c.ejemplo_tenant_id
             ORDER BY (c.origen = 'nuevo' AND c.revisado_en IS NULL) DESC,
                      c.ultima_vez DESC
             LIMIT 1000
            """,
            cancellationToken: ct))).ToList();
    }

    /// <summary>
    /// Deja dicho quién revisó un código, cuándo y qué es. Una sola vez: la
    /// revisión no se sobrescribe (nada se borra). Devuelve false si el código
    /// no existe o ya estaba revisado.
    /// </summary>
    public async Task<bool> MarcarRevisadoAsync(
        string codigo, string clase, Guid usuarioId, string correo, string nota,
        CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);

        var filas = await conexion.ExecuteAsync(new CommandDefinition(
            """
            UPDATE codigos_sunat
               SET revisado_en = now(),
                   revisado_por = @usuarioId,
                   revisado_correo = @correo,
                   nota = @nota
             WHERE codigo = @codigo AND clase = @clase AND revisado_en IS NULL
            """,
            new { codigo, clase, usuarioId, correo, nota },
            cancellationToken: ct));

        return filas > 0;
    }

    /// <summary>Para el semáforo de «Estado del servicio».</summary>
    public async Task<IReadOnlyList<CodigoSunatVisto>> NuevosSinRevisarAsync(CancellationToken ct = default)
    {
        var todos = await ListarCodigosAsync(ct);
        return todos.Where(c => c.EsNuevoSinRevisar).ToList();
    }

    // ================================================================ correos

    public async Task<IReadOnlyList<CorreoAlerta>> ListarCorreosAsync(CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);

        return (await conexion.QueryAsync<CorreoAlerta>(new CommandDefinition(
            """
            SELECT id              AS "Id",
                   correo          AS "Correo",
                   agregado_correo AS "AgregadoCorreo",
                   agregado_en     AS "AgregadoEn"
              FROM vigilancia_correos
             WHERE quitado_en IS NULL
             ORDER BY agregado_en
            """,
            cancellationToken: ct))).ToList();
    }

    /// <summary>Los administradores del panel: los que pueden gestionar usuarios.</summary>
    public async Task<IReadOnlyList<string>> CorreosAdministradoresAsync(CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);

        return (await conexion.QueryAsync<string>(new CommandDefinition(
            """
            SELECT DISTINCT u.correo
              FROM usuarios u
              JOIN rol_permisos rp ON rp.rol_id = u.rol_id
             WHERE u.activo AND rp.permiso = 'usuarios.gestionar'
             ORDER BY u.correo
            """,
            cancellationToken: ct))).ToList();
    }

    /// <summary>
    /// A quién le llega una alerta: los administradores y la lista. Sin
    /// repetidos. Si la lista está vacía, igual llega a los administradores.
    /// </summary>
    public async Task<IReadOnlyList<string>> DestinatariosAsync(CancellationToken ct = default)
    {
        var admins = await CorreosAdministradoresAsync(ct);
        var lista = await ListarCorreosAsync(ct);

        return admins.Concat(lista.Select(c => c.Correo))
            .GroupBy(c => c.Trim().ToLowerInvariant())
            .Select(g => g.First().Trim())
            .ToList();
    }

    /// <summary>Devuelve null si se agregó, o el motivo si no.</summary>
    public async Task<string?> AgregarCorreoAsync(
        string correo, Guid usuarioId, string correoUsuario, CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);

        try
        {
            await conexion.ExecuteAsync(new CommandDefinition(
                """
                INSERT INTO vigilancia_correos (correo, agregado_por, agregado_correo)
                VALUES (@correo, @usuarioId, @correoUsuario)
                """,
                new { correo, usuarioId, correoUsuario },
                cancellationToken: ct));

            return null;
        }
        catch (PostgresException ex) when (ex.SqlState == "23505")
        {
            return "Ese correo ya está en la lista.";
        }
        catch (PostgresException ex) when (ex.SqlState == "23514")
        {
            return "Ese correo no tiene forma de correo.";
        }
    }

    /// <summary>Lo quita de la lista sin borrarlo: queda quién y cuándo.</summary>
    public async Task<bool> QuitarCorreoAsync(
        long id, Guid usuarioId, string correoUsuario, CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);

        return await conexion.ExecuteAsync(new CommandDefinition(
            """
            UPDATE vigilancia_correos
               SET quitado_en = now(), quitado_por = @usuarioId, quitado_correo = @correoUsuario
             WHERE id = @id AND quitado_en IS NULL
            """,
            new { id, usuarioId, correoUsuario },
            cancellationToken: ct)) > 0;
    }

    // ================================================================ alertas

    /// <summary>
    /// Las alertas cuyo correo toca mandar ahora. SKIP LOCKED: si algún día
    /// corren dos API, no mandan el mismo correo dos veces.
    /// </summary>
    public async Task<(NpgsqlConnection Conexion, NpgsqlTransaction Tx, IReadOnlyList<AlertaPendiente> Alertas)>
        TomarPendientesAsync(int maximo, CancellationToken ct = default)
    {
        var conexion = await AbrirAsync(ct);
        var tx = await conexion.BeginTransactionAsync(ct);

        var alertas = (await conexion.QueryAsync<AlertaPendiente>(new CommandDefinition(
            """
            SELECT id              AS "Id",
                   tipo            AS "Tipo",
                   gravedad        AS "Gravedad",
                   titulo          AS "Titulo",
                   detalle         AS "Detalle",
                   creada_en       AS "CreadaEn",
                   correo_intentos AS "CorreoIntentos"
              FROM vigilancia_alertas
             WHERE correo_enviado_en IS NULL
               AND correo_intentos < 6
               AND proximo_intento_en <= now()
             ORDER BY creada_en
             LIMIT @maximo
             FOR UPDATE SKIP LOCKED
            """,
            new { maximo }, tx, cancellationToken: ct))).ToList();

        return (conexion, tx, alertas);
    }

    public static Task MarcarEnviadasAsync(
        NpgsqlConnection conexion, NpgsqlTransaction tx,
        IEnumerable<long> ids, string enviadoA, CancellationToken ct) =>
        conexion.ExecuteAsync(new CommandDefinition(
            """
            UPDATE vigilancia_alertas
               SET correo_enviado_en = now(),
                   enviado_a = @enviadoA,
                   correo_intentos = correo_intentos + 1,
                   correo_error = NULL
             WHERE id = ANY(@ids)
            """,
            new { ids = ids.ToArray(), enviadoA }, tx, cancellationToken: ct));

    public static Task MarcarFalloAsync(
        NpgsqlConnection conexion, NpgsqlTransaction tx,
        IEnumerable<long> ids, string error, TimeSpan espera, CancellationToken ct) =>
        conexion.ExecuteAsync(new CommandDefinition(
            """
            UPDATE vigilancia_alertas
               SET correo_intentos = correo_intentos + 1,
                   correo_error = @error,
                   proximo_intento_en = now() + @espera
             WHERE id = ANY(@ids)
            """,
            new { ids = ids.ToArray(), error, espera }, tx, cancellationToken: ct));
}
'@ },
    @{ Ruta = 'Facturacion.Api\VigilanciaSunat.cs'; Texto = @'
using System.Net;
using System.Text;
using Facturacion.Persistencia;

namespace Facturacion.Api;

/// <summary>
/// VIGILANCIA SUNAT, PARTE 1: la alarma de códigos nuevos (migración 029).
///
/// Dos pasos, siempre en este orden:
///   1. Revisar: anotar los códigos que SUNAT devolvió desde la última vuelta
///      y crear una alerta por cada uno que nunca había salido.
///   2. Avisar: mandar por correo las alertas pendientes, todas juntas en un
///      solo correo, a los administradores del panel y a la lista de correos
///      para alertas.
///
/// Lo usan el reloj (ServicioVigilancia, cada 5 minutos) y el botón «Revisar
/// ahora» del panel.
///
/// VIVE EN LA API, como los correos de entrega: aquí ya están el correo y el
/// panel. Solo lee lo que ya pasó: si algo de esto falla, la facturación
/// sigue exactamente igual.
/// </summary>
public sealed class VigilanciaSunat
{
    // Esperas entre intentos del correo: seis intentos en unas nueve horas,
    // igual que los correos de entrega.
    private static readonly TimeSpan[] Esperas =
    {
        TimeSpan.FromMinutes(1), TimeSpan.FromMinutes(5), TimeSpan.FromMinutes(30),
        TimeSpan.FromHours(2), TimeSpan.FromHours(6)
    };

    private readonly RepositorioVigilancia _repo;
    private readonly ServicioCorreo _correo;
    private readonly OpcionesCorreo _opciones;
    private readonly ILogger<VigilanciaSunat> _log;

    public VigilanciaSunat(
        RepositorioVigilancia repo, ServicioCorreo correo, OpcionesCorreo opciones,
        ILogger<VigilanciaSunat> log)
    {
        _repo = repo;
        _correo = correo;
        _opciones = opciones;
        _log = log;
    }

    public string UrlPanel => _opciones.UrlPanel.TrimEnd('/') + "/vigilancia.html";

    /// <summary>Una vuelta completa: revisar y avisar.</summary>
    public async Task<ResultadoRevision> VueltaAsync(CancellationToken ct)
    {
        var r = await _repo.RevisarAsync(ct);

        if (r.FueLaPrimera)
            _log.LogInformation(
                "Vigilancia SUNAT: primera vuelta. Se anotaron {Codigos} códigos que ya existían, " +
                "sin avisar. Desde ahora avisa solo los nuevos.", r.CodigosNuevos);
        else if (r.AlertasCreadas > 0)
            _log.LogWarning(
                "Vigilancia SUNAT: {Alertas} código(s) de SUNAT nunca visto(s).", r.AlertasCreadas);

        if (_repo.TablasSinPermiso.Count > 0)
            _log.LogWarning(
                "Vigilancia SUNAT: el rol operador no puede leer {Tablas}; esos códigos no se vigilan.",
                string.Join(", ", _repo.TablasSinPermiso));

        await AvisarPendientesAsync(ct);

        return r;
    }

    /// <summary>
    /// Manda las alertas pendientes en UN correo. Si sale para al menos un
    /// destinatario, se dan por avisadas; si no sale para nadie, se reintenta
    /// más tarde.
    /// </summary>
    public async Task AvisarPendientesAsync(CancellationToken ct)
    {
        if (!_correo.Disponible) return; // Se quedan pendientes, no se pierden.

        var (conexion, tx, alertas) = await _repo.TomarPendientesAsync(20, ct);

        await using (conexion)
        await using (tx)
        {
            if (alertas.Count == 0) { await tx.CommitAsync(ct); return; }

            var ids = alertas.Select(a => a.Id).ToList();
            var destinatarios = await _repo.DestinatariosAsync(ct);

            if (destinatarios.Count == 0)
            {
                await RepositorioVigilancia.MarcarFalloAsync(conexion, tx, ids,
                    "No hay a quién avisar: ningún administrador activo ni correos en la lista.",
                    Esperas[^1], ct);
                await tx.CommitAsync(ct);
                return;
            }

            var (asunto, html) = Armar(alertas);
            var salieron = new List<string>();

            foreach (var para in destinatarios)
                if (await _correo.EnviarAsync(para, asunto, html, ct))
                    salieron.Add(para);

            if (salieron.Count > 0)
            {
                await RepositorioVigilancia.MarcarEnviadasAsync(
                    conexion, tx, ids, string.Join(", ", salieron), ct);
            }
            else
            {
                var intento = alertas.Max(a => a.CorreoIntentos);
                await RepositorioVigilancia.MarcarFalloAsync(conexion, tx, ids,
                    "El correo no salió para ningún destinatario. Mira el log de la API.",
                    Esperas[Math.Min(intento, Esperas.Length - 1)], ct);
            }

            await tx.CommitAsync(ct);
        }
    }

    /// <summary>Un correo de prueba, para comprobar que las alertas llegan.</summary>
    public async Task<(IReadOnlyList<string> Salieron, IReadOnlyList<string> Fallaron)>
        ProbarCorreoAsync(string quien, CancellationToken ct)
    {
        var destinatarios = await _repo.DestinatariosAsync(ct);
        var salieron = new List<string>();
        var fallaron = new List<string>();

        var html =
            Marco(
                "<p>Este es un correo de prueba de <b>Vigilancia SUNAT</b>. Si te llegó, las " +
                "alertas también te van a llegar.</p>" +
                $"<p>Lo pidió {E(quien)} desde el panel.</p>" +
                $"<p>Hoy llega a: {E(string.Join(", ", destinatarios))}.</p>");

        foreach (var para in destinatarios)
        {
            if (await _correo.EnviarAsync(para, "Prueba de las alertas de Vigilancia SUNAT", html, ct))
                salieron.Add(para);
            else
                fallaron.Add(para);
        }

        return (salieron, fallaron);
    }

    private (string Asunto, string Html) Armar(IReadOnlyList<AlertaPendiente> alertas)
    {
        var asunto = alertas.Count == 1
            ? alertas[0].Titulo
            : $"{alertas.Count} códigos de SUNAT nunca vistos";

        var sb = new StringBuilder();

        sb.Append(alertas.Count == 1
            ? "<p>SUNAT devolvió un código que nunca había salido. Puede ser una regla nueva de SUNAT: " +
              "si es así, otros clientes van a recibir lo mismo.</p>"
            : "<p>SUNAT devolvió códigos que nunca habían salido. Puede ser una regla nueva de SUNAT: " +
              "si es así, otros clientes van a recibir lo mismo.</p>");

        foreach (var a in alertas)
        {
            var color = a.Gravedad == "problema" ? "#b91c1c" : "#a16207";
            sb.Append(
                "<div style=\"background:#f1f3f5;border-radius:8px;padding:12px 14px;margin:12px 0;" +
                $"border-left:3px solid {color}\">" +
                $"<b>{E(a.Titulo)}</b><br>" +
                E(a.Detalle).Replace("\n", "<br>") +
                "</div>");
        }

        sb.Append(
            "<p><b>Qué hacer:</b> abrir el panel, pestaña Vigilancia SUNAT, leer el mensaje completo " +
            "y buscar si SUNAT publicó un cambio. Después, «Marcar revisado» con una nota.</p>" +
            $"<p><a href=\"{E(UrlPanel)}\">{E(UrlPanel)}</a></p>" +
            "<p style=\"color:#5c6570;font-size:13px\">Cada código avisa una sola vez. " +
            "Te llega por ser administrador del panel o por estar en la lista de correos para alertas.</p>");

        return (asunto, Marco(sb.ToString()));
    }

    private static string Marco(string cuerpo) =>
        "<div style=\"font-family:Segoe UI,system-ui,sans-serif;font-size:15px;line-height:1.55;" +
        "color:#1b1f24;max-width:620px\">" + cuerpo + "</div>";

    private static string E(string? t) => WebUtility.HtmlEncode(t ?? "");
}

/// <summary>
/// El reloj de la vigilancia: una vuelta cada 5 minutos. La primera, al minuto
/// de arrancar, para no competir con el arranque de la API.
/// </summary>
public sealed class ServicioVigilancia : BackgroundService
{
    private static readonly TimeSpan Ciclo = TimeSpan.FromMinutes(5);

    private readonly VigilanciaSunat _vigilancia;
    private readonly ILogger<ServicioVigilancia> _log;

    public ServicioVigilancia(VigilanciaSunat vigilancia, ILogger<ServicioVigilancia> log)
    {
        _vigilancia = vigilancia;
        _log = log;
    }

    protected override async Task ExecuteAsync(CancellationToken ct)
    {
        try { await Task.Delay(TimeSpan.FromMinutes(1), ct); }
        catch (OperationCanceledException) { return; }

        _log.LogInformation("Vigilancia SUNAT: revisa los códigos de SUNAT cada {Ciclo}.", Ciclo);

        while (!ct.IsCancellationRequested)
        {
            try
            {
                await _vigilancia.VueltaAsync(ct);
            }
            catch (OperationCanceledException) when (ct.IsCancellationRequested)
            {
                break;
            }
            catch (Npgsql.PostgresException ex) when (ex.SqlState == "42P01")
            {
                // Falta la migración 029. Se dice una vez y se deja de intentar:
                // no tiene arreglo hasta que se aplique y se reinicie la API.
                _log.LogWarning(
                    "Vigilancia SUNAT apagada: falta aplicar la migración 029 ({Mensaje}).",
                    ex.MessageText);
                return;
            }
            catch (Exception ex)
            {
                // Un fallo aquí no puede tumbar la API.
                _log.LogError(ex, "Falló una vuelta de Vigilancia SUNAT. Se reintenta en {Ciclo}.", Ciclo);
            }

            try { await Task.Delay(Ciclo, ct); }
            catch (OperationCanceledException) { break; }
        }
    }
}
'@ },
    @{ Ruta = 'Facturacion.Api\EndpointsVigilancia.cs'; Texto = @'
using System.Text.RegularExpressions;
using Facturacion.Persistencia;

namespace Facturacion.Api;

/// <summary>Lo que manda el panel al marcar un código como revisado.</summary>
public record PeticionRevisado(string? Codigo, string? Clase, string? Nota);

/// <summary>Lo que manda el panel al agregar un correo para alertas.</summary>
public record PeticionCorreoAlerta(string? Correo);

/// <summary>
/// La pestaña «Vigilancia SUNAT» del panel (migración 029).
///
/// Ver y revisar códigos: quien ve el estado del servicio (diagnostico.ver),
/// que es soporte. Tocar la lista de correos y mandar la prueba: solo quien
/// administra usuarios, porque decide a quién le llegan avisos.
///
/// Todo lo que no es GET queda en la bitácora del panel (AuditoriaPanel).
/// </summary>
public static class EndpointsVigilancia
{
    private static readonly Regex FormaCorreo =
        new(@"^[^@\s]+@[^@\s]+\.[^@\s]+$", RegexOptions.Compiled);

    public static void MapearVigilancia(this WebApplication app)
    {
        var grupo = app.MapGroup("/admin/vigilancia")
            .AddEndpointFilter<AutenticacionPanel>()
            .WithTags("Vigilancia SUNAT");

        grupo.MapGet("", async (
            RepositorioVigilancia repo, CancellationToken ct) =>
        {
            var estado = await repo.EstadoAsync(ct);
            var codigos = await repo.ListarCodigosAsync(ct);

            return Results.Ok(new
            {
                inicializadoEn = estado.InicializadoEn,
                ultimaRevisionEn = estado.UltimaRevisionEn,
                codigos = codigos.Select(c => new
                {
                    c.Codigo, c.Clase, c.PrimeraVez, c.UltimaVez, c.Veces, c.Empresas,
                    c.EjemploMensaje, c.EjemploEmpresa, c.EjemploRuc, c.EjemploDocumento,
                    c.Origen, c.RevisadoEn, c.RevisadoCorreo, c.Nota,
                    nuevo = c.EsNuevoSinRevisar,
                    gravedad = c.Gravedad
                }),
                administradores = await repo.CorreosAdministradoresAsync(ct),
                correos = await repo.ListarCorreosAsync(ct)
            });
        })
        .AddEndpointFilter(new ExigirPermiso(Permiso.DiagnosticoVer))
        .WithSummary("Códigos de SUNAT vistos y correos para alertas");

        grupo.MapPost("/revisar", async (
            VigilanciaSunat vigilancia, CancellationToken ct) =>
        {
            var r = await vigilancia.VueltaAsync(ct);

            return Results.Ok(new
            {
                mensaje = r.FueLaPrimera
                    ? $"Primera revisión: se anotaron {r.CodigosNuevos} códigos que ya existían, sin avisar."
                    : r.AlertasCreadas > 0
                        ? $"Hay {r.AlertasCreadas} código(s) nuevo(s). Se avisó por correo."
                        : "Revisado. No hay códigos nuevos.",
                r.IntentosRevisados,
                r.CodigosNuevos,
                r.AlertasCreadas
            });
        })
        .AddEndpointFilter(new ExigirPermiso(Permiso.DiagnosticoVer))
        .WithSummary("Revisa ahora, sin esperar al reloj de 5 minutos");

        grupo.MapPost("/revisado", async (
            PeticionRevisado peticion, ContextoOperador operador,
            RepositorioVigilancia repo, CancellationToken ct) =>
        {
            var nota = peticion.Nota?.Trim() ?? "";

            if (string.IsNullOrWhiteSpace(peticion.Codigo) ||
                peticion.Clase is not ("respuesta" or "observacion"))
                return Results.BadRequest(new RespuestaError("Falta el código o su clase."));

            if (nota.Length is < 5 or > 1000)
                return Results.BadRequest(new RespuestaError(
                    "Escribe una nota.",
                    "Entre 5 y 1000 caracteres: qué es y si hubo que hacer algo. " +
                    "La lee quien se lo vuelva a encontrar."));

            var usuario = operador.Exigir();

            var hecho = await repo.MarcarRevisadoAsync(
                peticion.Codigo.Trim(), peticion.Clase, usuario.Id, usuario.Correo, nota, ct);

            return hecho
                ? Results.Ok(new { mensaje = "Marcado como revisado." })
                : Results.Conflict(new RespuestaError(
                    "No se pudo marcar.",
                    "Ese código ya estaba revisado, o no existe. Actualiza la pantalla."));
        })
        .AddEndpointFilter(new ExigirPermiso(Permiso.DiagnosticoVer))
        .WithSummary("Marca un código como revisado, con una nota");

        grupo.MapPost("/correos", async (
            PeticionCorreoAlerta peticion, ContextoOperador operador,
            RepositorioVigilancia repo, CancellationToken ct) =>
        {
            var correo = peticion.Correo?.Trim() ?? "";

            if (correo.Length is < 6 or > 254 || !FormaCorreo.IsMatch(correo))
                return Results.BadRequest(new RespuestaError(
                    "Ese correo no tiene forma de correo.", "Ejemplo: soporte@reyban.pe"));

            var usuario = operador.Exigir();
            var problema = await repo.AgregarCorreoAsync(correo, usuario.Id, usuario.Correo, ct);

            return problema is null
                ? Results.Ok(new { mensaje = $"{correo} recibirá las alertas." })
                : Results.Conflict(new RespuestaError(problema));
        })
        .AddEndpointFilter(new ExigirPermiso(Permiso.UsuariosGestionar))
        .WithSummary("Agrega un correo a la lista de alertas");

        grupo.MapPost("/correos/{id:long}/quitar", async (
            long id, ContextoOperador operador,
            RepositorioVigilancia repo, CancellationToken ct) =>
        {
            var usuario = operador.Exigir();

            return await repo.QuitarCorreoAsync(id, usuario.Id, usuario.Correo, ct)
                ? Results.Ok(new { mensaje = "Quitado de la lista. Ya no recibirá alertas." })
                : Results.NotFound(new RespuestaError("Ese correo ya no estaba en la lista."));
        })
        .AddEndpointFilter(new ExigirPermiso(Permiso.UsuariosGestionar))
        .WithSummary("Quita un correo de la lista (no se borra: queda quién y cuándo)");

        grupo.MapPost("/probar-correo", async (
            ContextoOperador operador, VigilanciaSunat vigilancia,
            ServicioCorreo correo, CancellationToken ct) =>
        {
            if (!correo.Disponible)
                return Results.Json(new RespuestaError(
                    "El correo no está configurado.",
                    "Faltan MAIL_HOST y las demás variables MAIL_ en el .env de la API."),
                    statusCode: StatusCodes.Status503ServiceUnavailable);

            var (salieron, fallaron) = await vigilancia.ProbarCorreoAsync(operador.Exigir().Correo, ct);

            return fallaron.Count == 0
                ? Results.Ok(new { mensaje = $"Enviado a {string.Join(", ", salieron)}." })
                : Results.Json(new RespuestaError(
                    salieron.Count == 0 ? "No salió ningún correo." : "Algunos correos no salieron.",
                    $"Fallaron: {string.Join(", ", fallaron)}. Mira el log de la API."),
                    statusCode: StatusCodes.Status502BadGateway);
        })
        .AddEndpointFilter(new ExigirPermiso(Permiso.UsuariosGestionar))
        .WithSummary("Manda un correo de prueba a todos los que reciben alertas");
    }
}
'@ },
    @{ Ruta = 'Facturacion.Api\wwwroot\vigilancia.html'; Texto = @'
<!DOCTYPE html>
<html lang="es">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Vigilancia SUNAT · Facturación electrónica</title>
<style>
  :root {
    --fondo:#f6f7f9; --panel:#ffffff; --sutil:#f1f3f5; --borde:#e3e6ea;
    --texto:#1b1f24; --tenue:#5c6570;
    --sano:#15803d; --atencion:#a16207; --problema:#b91c1c;
    --acento:#2563eb;
  }

  @media (prefers-color-scheme: dark) {
    :root {
      --fondo:#0f1115; --panel:#171a21; --sutil:#1c212b; --borde:#262b36;
      --texto:#e6e8ec; --tenue:#98a1ae;
      --sano:#3fb950; --atencion:#d29922; --problema:#f85149;
      --acento:#4493f8;
    }
  }
  * { box-sizing:border-box; }
  body { margin:0; padding:24px; background:var(--fondo); color:var(--texto);
         font:15px/1.55 ui-sans-serif, system-ui, "Segoe UI", sans-serif; }
  .contenedor { max-width:1000px; margin:0 auto; }

  header { display:flex; align-items:center; justify-content:space-between;
           gap:16px; margin-bottom:8px; flex-wrap:wrap; }
  h1 { font-size:19px; margin:0; font-weight:500; }

  nav { display:flex; gap:18px; border-bottom:1px solid var(--borde);
        margin-bottom:16px; }
  nav a { color:var(--tenue); text-decoration:none; font-size:14px;
          padding:0 2px 9px; border-bottom:2px solid transparent;
          margin-bottom:-1px; }
  nav a:hover { color:var(--texto); }
  nav a.activo { color:var(--texto); border-bottom-color:var(--acento); }

  .controles { display:flex; gap:8px; align-items:center; }
  .usuario { display:flex; align-items:center; gap:12px; font-size:13.5px;
             color:var(--tenue); }
  .usuario .rol { background:var(--sutil); border-radius:var(--radio);
                  padding:2px 9px; font-size:12px; }
  .usuario a { color:var(--acento); text-decoration:none; }
  .usuario a:hover { text-decoration:underline; }

  input, button { background:var(--panel); border:1px solid var(--borde);
    color:var(--texto); padding:7px 11px; border-radius:7px; font:inherit;
    font-size:14px; }
  button { cursor:pointer; }
  button:hover:not(:disabled) { border-color:#3a4152; }
  button:disabled { opacity:.5; cursor:default; }
  button.principal { background:var(--acento); border-color:var(--acento);
                     color:#fff; font-weight:500; }
  button.mini { padding:4px 9px; font-size:13px; }

  .semaforo { display:flex; align-items:center; gap:12px; padding:16px 18px;
    border-radius:10px; border:1px solid var(--borde); background:var(--panel);
    margin-bottom:18px; }
  .punto { width:13px; height:13px; border-radius:50%; flex:none; }
  .Sano .punto { background:var(--sano); }
  .Atencion .punto { background:var(--atencion); }
  .Problema .punto { background:var(--problema); }
  .Sano .etiqueta { color:var(--sano); }
  .Atencion .etiqueta { color:var(--atencion); }
  .Problema .etiqueta { color:var(--problema); }
  .etiqueta { font-weight:500; letter-spacing:.02em; }
  .alertas { margin:0; padding-left:20px; }
  .alertas li { margin:5px 0; }

  .tarjetas { display:grid;
    grid-template-columns:repeat(auto-fit,minmax(150px,1fr));
    gap:12px; margin-bottom:18px; }
  .tarjeta { background:var(--sutil); border-radius:10px; padding:14px 16px; }
  .tarjeta .valor { font-size:26px; font-weight:500; }
  .tarjeta .nombre { color:var(--tenue); font-size:13px; margin-top:2px; }

  section { background:var(--panel); border:1px solid var(--borde);
            border-radius:10px; padding:16px 18px; margin-bottom:14px; }
  h2 { font-size:14px; margin:0 0 12px; color:var(--tenue);
       text-transform:uppercase; letter-spacing:.06em; font-weight:500; }

  table { width:100%; border-collapse:collapse; font-size:14px; }
  th { text-align:left; color:var(--tenue); font-weight:500; padding:6px 8px;
       border-bottom:1px solid var(--borde); }
  td { padding:8px; border-bottom:1px solid #1d222c; vertical-align:top; }
  tr:last-child td { border-bottom:none; }

  .mono { font-family:ui-monospace, Consolas, monospace; font-size:13px; }
  .recorte { max-width:400px; overflow:hidden; text-overflow:ellipsis;
             white-space:nowrap; }
  .vacio { color:var(--tenue); font-style:italic; }
  .mal { color:var(--problema); }
  footer { color:var(--tenue); font-size:13px; margin-top:18px; }

  #avisos { position:fixed; top:20px; right:20px; z-index:100;
            display:flex; flex-direction:column; gap:8px; max-width:380px; }
  .aviso-flotante { background:var(--panel); border:1px solid var(--borde);
    border-left:3px solid var(--acento); border-radius:8px; padding:11px 14px;
    font-size:14px; box-shadow:0 6px 20px rgba(0,0,0,.4);
    animation:entrar .18s ease-out; }
  .aviso-flotante.ok  { border-left-color:var(--sano); }
  .aviso-flotante.mal { border-left-color:var(--problema); }
  .aviso-flotante .titulo { font-weight:500; margin-bottom:2px; }
  .aviso-flotante .detalle { color:var(--tenue); font-size:13px; }
  @keyframes entrar { from { opacity:0; transform:translateX(16px); } }

  /* --- Vigilancia SUNAT --------------------------------------------------- */
  .bajada { color:var(--tenue); font-size:14px; margin:0 0 14px; max-width:72ch; }
  .cabecera-seccion { display:flex; justify-content:space-between; gap:12px;
                      flex-wrap:wrap; align-items:flex-start; }
  .filtros { display:flex; gap:6px; margin-bottom:12px; flex-wrap:wrap; }
  .filtros button.activo { background:var(--acento); border-color:var(--acento); color:#fff; }
  .desplazable { overflow-x:auto; }
  .desplazable table { min-width:760px; }
  .num { text-align:right; font-variant-numeric:tabular-nums; }
  .pildora { display:inline-block; font-size:12px; border-radius:20px; padding:0 8px;
             border:1px solid var(--borde); color:var(--tenue); white-space:nowrap; }
  .pildora.problema { color:var(--problema); border-color:var(--problema); }
  .pildora.atencion { color:var(--atencion); border-color:var(--atencion); }
  tr.nuevo td:first-child { box-shadow:inset 3px 0 0 var(--problema); }
  tr.nuevo.atencion td:first-child { box-shadow:inset 3px 0 0 var(--atencion); }
  .sub { color:var(--tenue); font-size:13px; }
  .mensaje { max-width:420px; overflow-wrap:anywhere; }
  .lista-correos { list-style:none; margin:0 0 12px; padding:0; display:grid; gap:6px; }
  .lista-correos li { display:flex; justify-content:space-between; align-items:center; gap:10px;
                      padding:7px 10px; background:var(--sutil); border-radius:8px; flex-wrap:wrap; }
  .fila-form { display:flex; gap:8px; flex-wrap:wrap; }
  .fila-form input { flex:1 1 240px; min-width:0; }
  .acciones { display:flex; gap:8px; flex-wrap:wrap; margin-bottom:14px; }

  .velo { position:fixed; inset:0; background:rgba(0,0,0,.5); display:flex;
          align-items:center; justify-content:center; padding:16px; z-index:90; }
  .dialogo { background:var(--panel); border:1px solid var(--borde); border-radius:12px;
             width:100%; max-width:480px; padding:18px 20px; }
  .dialogo h3 { margin:0 0 6px; font-size:16px; font-weight:500; }
  .dialogo label { display:block; font-size:13.5px; color:var(--tenue); margin:12px 0 4px; }
  .dialogo textarea { width:100%; background:var(--fondo); color:var(--texto);
             border:1px solid var(--borde); border-radius:7px; padding:8px 10px; font:inherit; font-size:14px; }
  .dialogo .pie { display:flex; justify-content:flex-end; gap:8px; margin-top:14px; }
  .dialogo .error { color:var(--problema); font-size:13.5px; margin-top:8px; }
  [hidden] { display:none !important; }
</style>
</head>
<body>

<div id="avisos"></div>

<div class="contenedor">
  <header>
    <h1>Facturación electrónica</h1>
    <div id="usuario-actual" class="usuario"></div>
  </header>

  <nav></nav>

  <div class="acciones">
    <button id="actualizar" class="principal">Actualizar</button>
    <button id="revisar">Revisar ahora</button>
  </div>

  <div id="contenido">
    <section class="vacio">Cargando…</section>
  </div>

  <footer id="pie"></footer>
</div>

<!-- Ventana para marcar un código como revisado. No se usa prompt(). -->
<div class="velo" id="velo-revisado" hidden>
  <div class="dialogo" role="dialog" aria-modal="true" aria-labelledby="titulo-revisado">
    <h3 id="titulo-revisado">Marcar revisado</h3>
    <p class="sub" style="margin:0">Deja dicho qué es y si hubo que hacer algo. Lo lee quien se lo vuelva a encontrar.
      La revisión no se puede cambiar después.</p>
    <label for="nota-revisado">Nota</label>
    <textarea id="nota-revisado" rows="4" maxlength="1000"
      placeholder="Observación nueva sobre el catálogo de unidades. No afecta la aceptación. Sin cambios."></textarea>
    <div class="error" id="error-revisado" hidden></div>
    <div class="pie">
      <button id="cancelar-revisado">Cancelar</button>
      <button class="principal" id="guardar-revisado">Marcar revisado</button>
    </div>
  </div>
</div>

<!-- Ventana para confirmar que se quita un correo. No se usa confirm(). -->
<div class="velo" id="velo-quitar" hidden>
  <div class="dialogo" role="dialog" aria-modal="true" aria-labelledby="titulo-quitar">
    <h3 id="titulo-quitar">Quitar de la lista</h3>
    <p style="margin:0" id="texto-quitar"></p>
    <div class="pie">
      <button id="cancelar-quitar">Cancelar</button>
      <button class="principal" id="confirmar-quitar">Quitar</button>
    </div>
  </div>
</div>

<script>
// NO SE USA "$" COMO NOMBRE DE FUNCIÓN: Browser Link (Visual Studio) inyecta
// jQuery y espera encontrarlo ahí.
const elem = id => document.getElementById(id);

// Se define antes que cualquier función que la use.
const esc = t => String(t ?? "").replace(/[&<>"']/g,
  c => ({ "&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;" }[c]));

let usuarioActual = null;
let datos = null;
let filtro = "nuevos";

// ------------------------------------------------------------------- menú
// Igual que en las demás páginas. OCULTAR NO ES PROTEGER: el servidor
// comprueba el permiso en cada petición.
const PANTALLAS = [
  { url:"/diagnostico.html", texto:"Estado del servicio", permiso:"diagnostico.ver" },
  { url:"/admin.html",       texto:"Empresas",            permiso:"empresas.ver" },
  { url:"/comprobantes.html",texto:"Comprobantes",        permiso:"comprobantes.ver" },
  { url:"/vigilancia.html",  texto:"Vigilancia SUNAT",    permiso:"diagnostico.ver" },
  { url:"/usuarios.html",    texto:"Usuarios",            permiso:"usuarios.gestionar" },
  { url:"/cuenta.html",      texto:"Mi cuenta",           permiso:null }
];

const puede = permiso => usuarioActual?.permisos?.includes(permiso) === true;

function pintarMenu() {
  const menu = document.querySelector("nav");
  const actual = location.pathname;
  menu.innerHTML = PANTALLAS
    .filter(p => p.permiso === null || puede(p.permiso))
    .map(p => `<a href="${p.url}" class="${actual === p.url ? "activo" : ""}">${esc(p.texto)}</a>`)
    .join("");
}

async function cargarUsuario() {
  const r = await fetch("/admin/yo");
  if (r.status === 401) { location.href = "/login.html"; return false; }

  usuarioActual = await r.json();

  elem("usuario-actual").innerHTML =
    `<span>${esc(usuarioActual.nombre || usuarioActual.correo)}</span>` +
    `<span class="rol">${esc(usuarioActual.rol)}</span>` +
    `<a href="#" id="salir">Salir</a>`;

  elem("salir").onclick = async e => {
    e.preventDefault();
    await fetch("/admin/sesion", { method: "DELETE" });
    location.href = "/login.html";
  };

  pintarMenu();
  return true;
}

function avisar(titulo, detalle = "", tipo = "") {
  const caja = document.createElement("div");
  caja.className = "aviso-flotante " + tipo;
  caja.innerHTML = `<div class="titulo">${esc(titulo)}</div>` +
    (detalle ? `<div class="detalle">${esc(detalle)}</div>` : "");
  elem("avisos").appendChild(caja);
  setTimeout(() => caja.remove(), tipo === "mal" ? 8000 : 4000);
}

// Fechas en hora de Lima, se mire desde donde se mire.
const fecha = v => v ? new Date(v).toLocaleString("es-PE", {
  timeZone: "America/Lima", day: "numeric", month: "short", year: "numeric",
  hour: "2-digit", minute: "2-digit" }) : "—";

async function pedir(url, opciones = {}) {
  const r = await fetch(url, {
    ...opciones,
    headers: opciones.body ? { "Content-Type": "application/json" } : undefined
  });
  if (r.status === 401) { location.href = "/login.html"; throw new Error("Sesión vencida"); }
  const cuerpo = await r.json().catch(() => ({}));
  if (!r.ok) {
    const e = new Error(cuerpo.error || `El servicio respondió ${r.status}.`);
    e.detalle = cuerpo.detalle || "";
    throw e;
  }
  return cuerpo;
}

// ------------------------------------------------------------------ carga
async function cargar() {
  const boton = elem("actualizar");
  boton.disabled = true;
  try {
    datos = await pedir("/admin/vigilancia");
    pintar();
    elem("pie").textContent = datos.ultimaRevisionEn
      ? `Última revisión: ${fecha(datos.ultimaRevisionEn)} · se revisa sola cada 5 minutos.`
      : "Todavía no se hizo la primera revisión. Pulsa «Revisar ahora» o espera unos minutos.";
  } catch (e) {
    elem("contenido").innerHTML =
      `<section class="mal">No se pudo cargar: ${esc(e.message)} ${esc(e.detalle || "")}</section>`;
  } finally {
    boton.disabled = false;
  }
}

function pintar() {
  const nuevos = datos.codigos.filter(c => c.nuevo);
  const lista = filtro === "nuevos" ? nuevos : datos.codigos;

  const filas = lista.map(c => {
    const clase = c.clase === "observacion" ? "observación" : "respuesta";
    const quien = [c.ejemploEmpresa && `${c.ejemploEmpresa} (${c.ejemploRuc})`, c.ejemploDocumento]
      .filter(Boolean).join(" · ");
    const revisado = c.revisadoEn
      ? `<span class="sub">${esc(c.revisadoCorreo)} · ${fecha(c.revisadoEn)}<br>${esc(c.nota)}</span>`
      : `<button class="mini" data-codigo="${esc(c.codigo)}" data-clase="${esc(c.clase)}">Marcar revisado</button>`;
    const etiqueta = c.nuevo
      ? ` <span class="pildora ${c.gravedad}">nuevo</span>`
      : (c.origen === "historico" && !c.revisadoEn ? ` <span class="pildora">conocido</span>` : "");

    return `
      <tr class="${c.nuevo ? "nuevo " + c.gravedad : ""}">
        <td class="mono">${esc(c.codigo)}${etiqueta}<div class="sub">${clase}</div></td>
        <td class="mensaje">${esc(c.ejemploMensaje || "—")}
          ${quien ? `<div class="sub">Primera vez: ${esc(quien)}</div>` : ""}</td>
        <td class="sub">${fecha(c.primeraVez)}</td>
        <td class="sub">${fecha(c.ultimaVez)}</td>
        <td class="num">${Number(c.veces).toLocaleString("es-PE")}</td>
        <td class="num">${c.empresas}</td>
        <td>${revisado}</td>
      </tr>`;
  }).join("");

  const vacio = filtro === "nuevos"
    ? "Ningún código nuevo sin revisar. Cuando SUNAT devuelva uno que nunca había salido, aparece aquí y llega un correo."
    : "Todavía no hay códigos anotados.";

  const partes = [];

  partes.push(`
    <section>
      <h2>Códigos de SUNAT</h2>
      <p class="bajada">Cada código que SUNAT devuelve, a cualquier empresa, queda anotado. Si aparece
        uno que nunca había salido, llega un correo: el primer cliente que se topa con una regla nueva
        de SUNAT protege a los demás. Lo que ya existía al instalar esto quedó como «conocido» y no avisa.</p>
      <div class="filtros">
        <button class="mini ${filtro === "nuevos" ? "activo" : ""}" data-filtro="nuevos">Nuevos sin revisar (${nuevos.length})</button>
        <button class="mini ${filtro === "todos" ? "activo" : ""}" data-filtro="todos">Todos (${datos.codigos.length})</button>
      </div>
      ${lista.length ? `
      <div class="desplazable">
        <table>
          <tr><th>Código</th><th>Qué dijo SUNAT</th><th>Primera vez</th><th>Última vez</th>
              <th class="num">Veces</th><th class="num">Empresas</th><th>Revisado</th></tr>
          ${filas}
        </table>
      </div>` : `<p class="vacio">${vacio}</p>`}
    </section>`);

  const editable = puede("usuarios.gestionar");

  partes.push(`
    <section>
      <h2>Correos para alertas</h2>
      <p class="bajada">Las alertas llegan siempre a los administradores del panel. Aquí puedes sumar
        otros correos, por ejemplo uno compartido de soporte, para que el aviso no dependa de una sola persona.</p>
      <div class="sub" style="margin-bottom:6px">Administradores (les llega siempre):</div>
      <ul class="lista-correos">
        ${datos.administradores.length
          ? datos.administradores.map(a => `<li><span>${esc(a)}</span></li>`).join("")
          : `<li><span class="mal">No hay ningún administrador activo.</span></li>`}
      </ul>
      <div class="sub" style="margin-bottom:6px">Además:</div>
      <ul class="lista-correos">
        ${datos.correos.length
          ? datos.correos.map(c => `
            <li><span>${esc(c.correo)} <span class="sub">· lo agregó ${esc(c.agregadoCorreo)}, ${fecha(c.agregadoEn)}</span></span>
              ${editable ? `<button class="mini" data-quitar="${c.id}" data-correo="${esc(c.correo)}">Quitar</button>` : ""}</li>`).join("")
          : `<li><span class="sub">Nadie más todavía.</span></li>`}
      </ul>
      ${editable ? `
      <form class="fila-form" id="form-correo">
        <input id="nuevo-correo" type="email" placeholder="soporte@reyban.pe" autocomplete="off" aria-label="Correo para alertas">
        <button class="principal" type="submit">Agregar</button>
        <button type="button" id="probar-correo">Enviar correo de prueba</button>
      </form>` : `<p class="sub">Solo un administrador puede cambiar esta lista.</p>`}
    </section>`);

  elem("contenido").innerHTML = partes.join("");

  document.querySelectorAll("[data-filtro]").forEach(b =>
    b.onclick = () => { filtro = b.dataset.filtro; pintar(); });

  document.querySelectorAll("[data-codigo]").forEach(b =>
    b.onclick = () => abrirRevisado(b.dataset.codigo, b.dataset.clase));

  document.querySelectorAll("[data-quitar]").forEach(b =>
    b.onclick = () => abrirQuitar(b.dataset.quitar, b.dataset.correo));

  if (editable) {
    elem("form-correo").onsubmit = agregarCorreo;
    elem("probar-correo").onclick = probarCorreo;
  }
}

// --------------------------------------------------------------- revisado
let enRevision = null;

function abrirRevisado(codigo, clase) {
  enRevision = { codigo, clase };
  elem("titulo-revisado").textContent =
    `Marcar revisado el código ${codigo} (${clase === "observacion" ? "observación" : "respuesta"})`;
  elem("nota-revisado").value = "";
  elem("error-revisado").hidden = true;
  elem("velo-revisado").hidden = false;
  elem("nota-revisado").focus();
}

elem("cancelar-revisado").onclick = () => { elem("velo-revisado").hidden = true; };

elem("guardar-revisado").onclick = async () => {
  const nota = elem("nota-revisado").value.trim();
  if (nota.length < 5) {
    elem("error-revisado").textContent = "Escribe una nota de al menos 5 caracteres.";
    elem("error-revisado").hidden = false;
    return;
  }
  const boton = elem("guardar-revisado");
  boton.disabled = true;
  try {
    const r = await pedir("/admin/vigilancia/revisado", {
      method: "POST", body: JSON.stringify({ ...enRevision, nota }) });
    elem("velo-revisado").hidden = true;
    avisar(r.mensaje, "", "ok");
    await cargar();
  } catch (e) {
    elem("error-revisado").textContent = `${e.message} ${e.detalle || ""}`;
    elem("error-revisado").hidden = false;
  } finally {
    boton.disabled = false;
  }
};

// ---------------------------------------------------------------- correos
async function agregarCorreo(evento) {
  evento.preventDefault();
  const correo = elem("nuevo-correo").value.trim();
  if (!correo) { elem("nuevo-correo").focus(); return; }
  try {
    const r = await pedir("/admin/vigilancia/correos", { method: "POST", body: JSON.stringify({ correo }) });
    avisar(r.mensaje, "", "ok");
    await cargar();
  } catch (e) {
    avisar(e.message, e.detalle, "mal");
  }
}

let porQuitar = null;

function abrirQuitar(id, correo) {
  porQuitar = id;
  elem("texto-quitar").textContent =
    `${correo} dejará de recibir las alertas. Queda anotado quién lo quitó y cuándo.`;
  elem("velo-quitar").hidden = false;
}

elem("cancelar-quitar").onclick = () => { elem("velo-quitar").hidden = true; };

elem("confirmar-quitar").onclick = async () => {
  const boton = elem("confirmar-quitar");
  boton.disabled = true;
  try {
    const r = await pedir(`/admin/vigilancia/correos/${porQuitar}/quitar`, { method: "POST" });
    elem("velo-quitar").hidden = true;
    avisar(r.mensaje, "", "ok");
    await cargar();
  } catch (e) {
    avisar(e.message, e.detalle, "mal");
  } finally {
    boton.disabled = false;
  }
};

async function probarCorreo() {
  const boton = elem("probar-correo");
  boton.disabled = true;
  boton.textContent = "Enviando…";
  try {
    const r = await pedir("/admin/vigilancia/probar-correo", { method: "POST" });
    avisar("Correo de prueba enviado", r.mensaje, "ok");
  } catch (e) {
    avisar(e.message, e.detalle, "mal");
  } finally {
    boton.disabled = false;
    boton.textContent = "Enviar correo de prueba";
  }
}

// ------------------------------------------------------------ revisar ya
elem("revisar").onclick = async () => {
  const boton = elem("revisar");
  boton.disabled = true;
  boton.textContent = "Revisando…";
  try {
    const r = await pedir("/admin/vigilancia/revisar", { method: "POST" });
    avisar(r.mensaje, "", r.alertasCreadas > 0 ? "mal" : "ok");
    await cargar();
  } catch (e) {
    avisar(e.message, e.detalle, "mal");
  } finally {
    boton.disabled = false;
    boton.textContent = "Revisar ahora";
  }
};

document.addEventListener("keydown", e => {
  if (e.key === "Escape") { elem("velo-revisado").hidden = true; elem("velo-quitar").hidden = true; }
});

elem("actualizar").onclick = cargar;

cargarUsuario().then(ok => { if (ok) cargar(); });
</script>
</body>
</html>
'@ }
)

$reemplazos = @(
    @{ Ruta = 'Facturacion.Api\Program.cs'
       Antes = @'
builder.Services.AddHostedService<ServicioCorreosEntrega>();
'@
       Despues = @'
builder.Services.AddHostedService<ServicioCorreosEntrega>();

// VIGILANCIA SUNAT (migración 029): la alarma de códigos nuevos. Cada 5
// minutos anota los códigos que SUNAT devolvió a cualquier empresa y avisa
// por correo cuando aparece uno que nunca había salido. Solo lee: si falla,
// la facturación sigue igual.
builder.Services.AddSingleton(new RepositorioVigilancia(cadenaOperador));
builder.Services.AddSingleton<VigilanciaSunat>();
builder.Services.AddHostedService<ServicioVigilancia>();
'@ },
    @{ Ruta = 'Facturacion.Api\Program.cs'
       Antes = @'
app.MapearDiagnostico();
'@
       Despues = @'
app.MapearDiagnostico();
app.MapearVigilancia();
'@ },
    @{ Ruta = 'Facturacion.Persistencia\RepositorioDiagnostico.cs'
       Antes = @'
        var (nivel, alertas) = Evaluar(
            contadores, certificados, minutosDesdeExito);
'@
       Despues = @'
        var (nivel, alertas) = Evaluar(
            contadores, certificados, minutosDesdeExito);

        // VIGILANCIA SUNAT (migración 029): un código de SUNAT nunca visto,
        // que nadie revisó todavía, sube el semáforo. Es la primera señal de
        // que SUNAT cambió una regla.
        await SumarVigilanciaAsync(conexion, alertas,
            propuesto => { if (propuesto > nivel) nivel = propuesto; }, ct);
'@ },
    @{ Ruta = 'Facturacion.Persistencia\RepositorioDiagnostico.cs'
       Antes = @'
    private record Contadores(
'@
       Despues = @'
    /// <summary>
    /// Los códigos de SUNAT nunca vistos y sin revisar (Vigilancia SUNAT).
    ///
    /// Si la migración 029 no está aplicada, no dice nada: el diagnóstico
    /// tiene que seguir funcionando aunque la vigilancia no exista todavía.
    /// </summary>
    private static async Task SumarVigilanciaAsync(
        NpgsqlConnection conexion, List<string> alertas,
        Action<NivelSalud> subir, CancellationToken ct)
    {
        List<CodigoNuevo> nuevos;

        try
        {
            nuevos = (await conexion.QueryAsync<CodigoNuevo>(new CommandDefinition(
                """
                SELECT codigo          AS "Codigo",
                       clase           AS "Clase",
                       ejemplo_mensaje AS "Mensaje"
                  FROM codigos_sunat
                 WHERE origen = 'nuevo' AND revisado_en IS NULL
                 ORDER BY primera_vez DESC
                 LIMIT 10
                """,
                cancellationToken: ct))).ToList();
        }
        catch (PostgresException ex) when (ex.SqlState is "42P01" or "42501")
        {
            return;
        }

        if (nuevos.Count == 0) return;

        if (alertas.Count == 1 && alertas[0] == "Todo en orden.")
            alertas.Clear();

        // Van primero: es lo más importante que puede decir este panel.
        for (var i = nuevos.Count - 1; i >= 0; i--)
        {
            var n = nuevos[i];
            var que = n.Clase == "observacion" ? "observación" : "respuesta";
            var mensaje = n.Mensaje is { Length: > 140 } m ? m[..140] + "…" : n.Mensaje;

            alertas.Insert(0,
                $"SUNAT devolvió un código nunca visto: {n.Codigo} ({que}). " +
                (mensaje is null ? "" : $"«{mensaje}» ") +
                "Revísalo en Vigilancia SUNAT.");

            subir(RepositorioVigilancia.Gravedad(n.Codigo, n.Clase) == "problema"
                ? NivelSalud.Problema
                : NivelSalud.Atencion);
        }
    }

    private sealed record CodigoNuevo(string Codigo, string Clase, string? Mensaje);

    private record Contadores(
'@ }
)

# Una línea nueva en el menú de cada página, debajo de «Comprobantes». Se
# copia la sangría de la línea de arriba.
$lineas = @(
    @{ Ruta = 'Facturacion.Api\wwwroot\diagnostico.html'; Ancla = @'
{ url:"/comprobantes.html",texto:"Comprobantes",        permiso:"comprobantes.ver" },
'@; Nueva = @'
{ url:"/vigilancia.html",  texto:"Vigilancia SUNAT",    permiso:"diagnostico.ver" },
'@ },
    @{ Ruta = 'Facturacion.Api\wwwroot\cuenta.html'; Ancla = @'
{ url:"/comprobantes.html",texto:"Comprobantes",        permiso:"comprobantes.ver" },
'@; Nueva = @'
{ url:"/vigilancia.html",  texto:"Vigilancia SUNAT",    permiso:"diagnostico.ver" },
'@ },
    @{ Ruta = 'Facturacion.Api\wwwroot\admin.html'; Ancla = @'
{ url: "/comprobantes.html", texto: "Comprobantes", permiso: "comprobantes.ver" },
'@; Nueva = @'
{ url: "/vigilancia.html", texto: "Vigilancia SUNAT", permiso: "diagnostico.ver" },
'@ },
    @{ Ruta = 'Facturacion.Api\wwwroot\comprobantes.html'; Ancla = @'
{ url: "/comprobantes.html", texto: "Comprobantes", permiso: "comprobantes.ver" },
'@; Nueva = @'
{ url: "/vigilancia.html", texto: "Vigilancia SUNAT", permiso: "diagnostico.ver" },
'@ },
    @{ Ruta = 'Facturacion.Api\wwwroot\usuarios.html'; Ancla = @'
{ url: "/comprobantes.html", texto: "Comprobantes", permiso: "comprobantes.ver" },
'@; Nueva = @'
{ url: "/vigilancia.html", texto: "Vigilancia SUNAT", permiso: "diagnostico.ver" },
'@ }
)

# --- 1. Comprobar todo, sin escribir nada ----------------------------------
$problemas = New-Object System.Collections.Generic.List[string]
$archivos = @{}   # ruta -> @{ Texto (con \n); Crlf; Original }

function Cargar([string]$ruta) {
    if ($archivos.ContainsKey($ruta)) { return $archivos[$ruta] }
    $completa = Join-Path $raiz $ruta
    if (-not (Test-Path $completa)) { return $null }
    $original = [System.IO.File]::ReadAllText($completa)
    $a = @{ Completa = $completa; Original = $original; Crlf = $original.Contains("`r`n"); Texto = $original.Replace("`r`n", "`n") }
    $archivos[$ruta] = $a
    return $a
}

foreach ($n in $nuevos) {
    $completa = Join-Path $raiz $n.Ruta
    if (Test-Path $completa) {
        $actual = [System.IO.File]::ReadAllText($completa).Replace("`r", '').TrimEnd()
        if ($actual -ne $n.Texto.Replace("`r", '').TrimEnd()) {
            $problemas.Add("$($n.Ruta) ya existe y es distinto. ¿Ya se aplicó otra versión?")
        }
    }
}

foreach ($r in $reemplazos) {
    $a = Cargar $r.Ruta
    if ($null -eq $a) { $problemas.Add("No existe $($r.Ruta)."); continue }
    $antes = $r.Antes.Replace("`r", '')
    $despues = $r.Despues.Replace("`r", '')
    if ($a.Texto.Contains($despues)) { continue }   # ya estaba aplicado
    $n = ([regex]::Matches($a.Texto, [regex]::Escape($antes))).Count
    if ($n -ne 1) {
        $problemas.Add("En $($r.Ruta) esperaba UNA vez:`n      $(($antes -split "`n")[0].Trim())`n    y aparece $n veces.")
        continue
    }
    $a.Texto = $a.Texto.Replace($antes, $despues)
}

foreach ($l in $lineas) {
    $a = Cargar $l.Ruta
    if ($null -eq $a) { $problemas.Add("No existe $($l.Ruta)."); continue }
    $ancla = $l.Ancla.Replace("`r", '')
    $nueva = $l.Nueva.Replace("`r", '')
    if ($a.Texto.Contains($nueva)) { continue }   # ya estaba
    $patron = '(?m)^([ \t]*)' + [regex]::Escape($ancla) + '[ \t]*$'
    $m = [regex]::Matches($a.Texto, $patron)
    if ($m.Count -ne 1) {
        $problemas.Add("En $($l.Ruta) esperaba UNA vez la línea del menú:`n      $ancla`n    y aparece $($m.Count) veces.")
        continue
    }
    $sangria = $m[0].Groups[1].Value
    $fin = $m[0].Index + $m[0].Length
    $a.Texto = $a.Texto.Substring(0, $fin) + "`n" + $sangria + $nueva + $a.Texto.Substring($fin)
}

if ($problemas.Count -gt 0) {
    Write-Host ''
    Write-Host 'NO SE TOCÓ NINGÚN ARCHIVO. Esto no cuadra:' -ForegroundColor Red
    foreach ($p in $problemas) { Write-Host "  - $p" -ForegroundColor Red }
    Write-Host ''
    exit 2
}

# --- 2. Escribir ------------------------------------------------------------
Write-Host ''
foreach ($n in $nuevos) {
    $completa = Join-Path $raiz $n.Ruta
    if (Test-Path $completa) { Write-Host "  IGUAL        $($n.Ruta)" -ForegroundColor DarkGray; continue }
    New-Item -ItemType Directory -Path (Split-Path $completa) -Force | Out-Null
    [System.IO.File]::WriteAllText($completa, $n.Texto.Replace("`r", '').Replace("`n", "`r`n"), $utf8SinBom)
    Write-Host "  NUEVO        $($n.Ruta)" -ForegroundColor Green
}

foreach ($ruta in $archivos.Keys) {
    $a = $archivos[$ruta]
    $salida = if ($a.Crlf) { $a.Texto.Replace("`n", "`r`n") } else { $a.Texto }
    if ($salida -eq $a.Original) { Write-Host "  IGUAL        $ruta" -ForegroundColor DarkGray; continue }
    $bak = "$($a.Completa).bak"
    if (Test-Path $bak) { $bak = "$($a.Completa).$(Get-Date -Format 'yyyyMMdd-HHmmss').bak" }
    Copy-Item $a.Completa $bak -Force
    [System.IO.File]::WriteAllText($a.Completa, $salida, $utf8SinBom)
    Write-Host "  CAMBIADO     $ruta  (copia: $(Split-Path $bak -Leaf))" -ForegroundColor Green
}

Write-Host ''
Write-Host 'FALTA APLICAR LA MIGRACIÓN 029 (este script NO la aplica). Desde esta carpeta:' -ForegroundColor Cyan
Write-Host ''
Write-Host '  Get-Content migraciones\029_vigilancia_sunat.sql -Raw | docker compose exec -T postgres psql -U facturacion_owner -d facturacion -v ON_ERROR_STOP=1' -ForegroundColor White
Write-Host ''
Write-Host 'Tiene que terminar en COMMIT. Después, reinicia la API del servicio.' -ForegroundColor Cyan
Write-Host ''
