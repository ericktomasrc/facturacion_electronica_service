# =============================================================================
# Entrega 2026-10-14 — VIGILANCIA SUNAT, PARTE 2: LA PRUEBA DE MADRUGADA
# (SERVICIO de facturación)
#
# Se ejecuta desde la raíz del servicio:
#   cd "D:\Reyban Consulting\facturacion electronica\facturacion_electronica_service"
#   .\entrega-2026-10-14-prueba-madrugada.ps1
#
# NUEVOS
#   migraciones\030_prueba_de_madrugada.sql      Corridas y casos; la empresa
#                                                 interna nunca pasa a producción.
#                                                 NO se aplica sola
#   Facturacion.Persistencia\RepositorioMadrugada.cs
#   Facturacion.Api\PruebaMadrugada.cs           Los 8 casos, el reloj de las
#                                                 03:00 y la comparación
#   Facturacion.Api\EndpointsMadrugada.cs        /admin/vigilancia/madrugada
#
# CAMBIOS PUNTUALES
#   Facturacion.Api\Program.cs                   Registra la prueba
#   Facturacion.Api\VigilanciaSunat.cs           Compara cada 5 min y avisa
#   Facturacion.Api\wwwroot\vigilancia.html      La sección nueva, arriba
#
# La primera corrida prepara sola la empresa interna: RUC 20999999990, en
# beta, certificado autofirmado, series F900, B900, FC90 y FD90.
#
# Comprueba TODO antes de escribir; si algo no cuadra, NO TOCA NADA. Copia
# .bak de lo que cambia. No pregunta nada.
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
    @{ Ruta = 'migraciones\030_prueba_de_madrugada.sql'; Texto = @'
-- =============================================================================
-- 030 - VIGILANCIA SUNAT, PARTE 2: LA PRUEBA DE MADRUGADA
--
-- Cada madrugada (3:00, hora de Lima) el servicio emite contra SUNAT beta un
-- comprobante de cada tipo desde una empresa INTERNA, y compara con la noche
-- anterior. Si SUNAT rechaza algo que antes aceptaba, avisa: cambio una regla.
--
--   prueba_madrugada_config   la empresa interna y su clave fac_ (cifrada)
--   pruebas_madrugada         una fila por noche (o por "Correr ahora")
--   pruebas_madrugada_casos   un caso por fila: que se emitio y que paso
--
-- LA EMPRESA INTERNA NUNCA PUEDE PASAR A PRODUCCION: un disparador lo impide.
-- Asi la prueba nunca gasta un correlativo real ni manda nada a SUNAT de
-- verdad.
--
-- El resultado de cada caso NO se copia: se lee del comprobante (o de la
-- baja) cada vez, para que nunca se desfase. Solo se anota el desenlace al
-- compararlo con la noche anterior.
--
-- NADA SE BORRA: nadie tiene DELETE. Idempotente. Sin tildes a proposito:
-- PowerShell 5.1 la manda a psql en ASCII.
-- =============================================================================

BEGIN;

CREATE TABLE IF NOT EXISTS prueba_madrugada_config (
    id               smallint    PRIMARY KEY DEFAULT 1,
    tenant_id        uuid        NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
    -- La clave fac_ de la empresa interna, cifrada con la llave maestra
    -- (como las claves SOL). Sin ella la prueba no puede entrar por la API.
    clave_cifrada    bytea       NOT NULL,
    preparada_en     timestamptz NOT NULL DEFAULT now(),
    preparada_por    text        NOT NULL,
    CONSTRAINT ck_prueba_madrugada_config_una CHECK (id = 1)
);

COMMENT ON TABLE prueba_madrugada_config IS
    'La empresa interna de la prueba de madrugada. Siempre en beta (disparador tg_tenants_interna_solo_beta).';

CREATE TABLE IF NOT EXISTS pruebas_madrugada (
    id             bigserial   PRIMARY KEY,
    -- 'reloj': la de las 3:00. 'panel': el boton "Correr ahora".
    origen         text        NOT NULL,
    iniciada_por   text        NOT NULL,
    fecha_lima     date        NOT NULL,
    iniciada_en    timestamptz NOT NULL DEFAULT now(),
    terminada_en   timestamptz,
    -- Si la corrida entera fallo (por ejemplo, la API no respondia).
    error          text,
    CONSTRAINT ck_pruebas_madrugada_origen CHECK (origen IN ('reloj', 'panel'))
);

-- Una sola corrida del reloj por dia: si la API se reinicia a las 3:05, no
-- vuelve a correr.
CREATE UNIQUE INDEX IF NOT EXISTS ux_pruebas_madrugada_reloj_dia
    ON pruebas_madrugada (fecha_lima) WHERE origen = 'reloj';

CREATE TABLE IF NOT EXISTS pruebas_madrugada_casos (
    id              bigserial   PRIMARY KEY,
    prueba_id       bigint      NOT NULL REFERENCES pruebas_madrugada(id) ON DELETE RESTRICT,
    caso            text        NOT NULL,
    orden           smallint    NOT NULL,

    -- Lo que se emitio. Un comprobante, o una baja (tabla resumenes).
    comprobante_id  uuid,
    resumen_id      uuid,
    numero          text,
    enviado_en      timestamptz,

    -- Si nuestra propia API no lo acepto (400, 500...). Es una alarma igual:
    -- algo de nuestro lado se rompio.
    error_api       text,

    -- Se llena al compararlo con la noche anterior, cuando ya hay desenlace.
    estado_final    text,
    codigo          text,
    mensaje         text,
    comparado_en    timestamptz,
    cambio          text,

    CONSTRAINT ux_pruebas_madrugada_casos UNIQUE (prueba_id, caso),
    CONSTRAINT ck_pruebas_madrugada_casos_estado CHECK (
        estado_final IS NULL OR estado_final IN ('ok', 'obs', 'mal', 'error_api'))
);

CREATE INDEX IF NOT EXISTS ix_pruebas_madrugada_casos_sin_comparar
    ON pruebas_madrugada_casos (prueba_id) WHERE comparado_en IS NULL;

-- ------------------------------------------- la interna nunca a produccion
CREATE OR REPLACE FUNCTION fn_tenants_interna_solo_beta() RETURNS trigger AS $$
BEGIN
    IF NEW.ambiente <> 'beta'
       AND EXISTS (SELECT 1 FROM prueba_madrugada_config WHERE tenant_id = NEW.id) THEN
        RAISE EXCEPTION 'La empresa de la prueba de madrugada es interna y siempre va en beta.'
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS tg_tenants_interna_solo_beta ON tenants;
CREATE TRIGGER tg_tenants_interna_solo_beta
    BEFORE UPDATE OF ambiente ON tenants
    FOR EACH ROW EXECUTE FUNCTION fn_tenants_interna_solo_beta();

-- --------------------------------------------------------------- permisos
REVOKE ALL ON prueba_madrugada_config, pruebas_madrugada, pruebas_madrugada_casos FROM PUBLIC;

GRANT SELECT, INSERT         ON prueba_madrugada_config TO facturacion_operador;
GRANT SELECT, INSERT, UPDATE ON pruebas_madrugada       TO facturacion_operador;
GRANT SELECT, INSERT, UPDATE ON pruebas_madrugada_casos TO facturacion_operador;
GRANT USAGE, SELECT ON SEQUENCE pruebas_madrugada_id_seq, pruebas_madrugada_casos_id_seq
    TO facturacion_operador;

DO $$
DECLARE
    t text;
BEGIN
    FOREACH t IN ARRAY ARRAY['prueba_madrugada_config', 'pruebas_madrugada', 'pruebas_madrugada_casos'] LOOP
        IF has_table_privilege('facturacion_operador', t, 'DELETE') THEN
            RAISE EXCEPTION '030: el operador no deberia poder borrar en %.', t;
        END IF;
        IF has_table_privilege('facturacion_app', t, 'SELECT') THEN
            RAISE EXCEPTION '030: la aplicacion no deberia ver %.', t;
        END IF;
    END LOOP;

    IF has_table_privilege('facturacion_operador', 'prueba_madrugada_config', 'UPDATE') THEN
        RAISE EXCEPTION '030: la empresa interna no se cambia una vez preparada.';
    END IF;

    RAISE NOTICE '030: prueba de madrugada lista.';
END $$;

COMMIT;
'@ },
    @{ Ruta = 'Facturacion.Persistencia\RepositorioMadrugada.cs'; Texto = @'
using Dapper;
using Npgsql;

namespace Facturacion.Persistencia;

/// <summary>La empresa interna de la prueba de madrugada.</summary>
public record ConfigMadrugada(Guid TenantId, byte[] ClaveCifrada, string Ruc, string RazonSocial,
    DateTime PreparadaEn, string PreparadaPor);

/// <summary>Una noche (o un «Correr ahora»).</summary>
public record CorridaMadrugada(long Id, string Origen, string IniciadaPor, DateTime IniciadaEn,
    DateTime? TerminadaEn, string? Error);

/// <summary>
/// Un caso de una corrida, con su estado LEÍDO EN VIVO del comprobante o de la
/// baja: nunca se desfasa de lo que dice la base.
/// </summary>
public record CasoMadrugada(
    long Id, long PruebaId, string Caso, short Orden,
    Guid? ComprobanteId, Guid? ResumenId, string? Numero, DateTime? EnviadoEn,
    string? ErrorApi, string? MensajeCaso,
    string? EstadoDoc, string? CodigoDoc, string? MensajeDoc, short IntentosFallidos,
    string? EstadoFinal, string? CodigoFinal, string? Cambio, DateTime? ComparadoEn)
{
    /// <summary>
    /// ok · obs · mal · error_api · caida (SUNAT no respondió) · pend.
    /// </summary>
    public string Estado
    {
        get
        {
            if (EstadoFinal is not null) return EstadoFinal;
            if (ErrorApi is not null) return "error_api";

            switch (EstadoDoc)
            {
                case "ACEPTADO":
                case "ANULADO": return "ok";
                case "ACEPTADO_CON_OBSERVACIONES": return "obs";
                case "RECHAZADO": return "mal";
            }

            // Sin documento (no se pudo emitir) o esperando hace demasiado:
            // SUNAT beta no respondió. No es alarma de regla.
            var esperando = EnviadoEn is null || DateTime.UtcNow - EnviadoEn.Value.ToUniversalTime() > TimeSpan.FromHours(36);
            return (ComprobanteId is null && ResumenId is null) || esperando ? "caida" : "pend";
        }
    }

    public string? Codigo => CodigoFinal ?? CodigoDoc;
}

/// <summary>
/// LA PRUEBA DE MADRUGADA (migración 030, Vigilancia SUNAT parte 2): lo que
/// se guarda y se lee de la base. Usa el rol de operador, como la vigilancia:
/// lee la empresa interna sin entrar en su sesión.
/// </summary>
public sealed class RepositorioMadrugada
{
    private readonly string _cadenaOperador;

    public RepositorioMadrugada(string cadenaConexionOperador)
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

    // ================================================================ empresa

    public async Task<ConfigMadrugada?> ConfigAsync(CancellationToken ct = default)
    {
        await using var c = await AbrirAsync(ct);

        return await c.QuerySingleOrDefaultAsync<ConfigMadrugada>(new CommandDefinition(
            """
            SELECT p.tenant_id     AS "TenantId",
                   p.clave_cifrada AS "ClaveCifrada",
                   t.ruc           AS "Ruc",
                   t.razon_social  AS "RazonSocial",
                   p.preparada_en  AS "PreparadaEn",
                   p.preparada_por AS "PreparadaPor"
              FROM prueba_madrugada_config p
              JOIN tenants t ON t.id = p.tenant_id
             WHERE p.id = 1
            """,
            cancellationToken: ct));
    }

    public async Task<Guid?> TenantPorRucAsync(string ruc, CancellationToken ct = default)
    {
        await using var c = await AbrirAsync(ct);

        return await c.ExecuteScalarAsync<Guid?>(new CommandDefinition(
            "SELECT id FROM tenants WHERE ruc = @ruc",
            new { ruc }, cancellationToken: ct));
    }

    /// <summary>Una sola vez: después no se cambia (no hay UPDATE).</summary>
    public async Task GuardarConfigAsync(
        Guid tenantId, byte[] claveCifrada, string preparadaPor, CancellationToken ct = default)
    {
        await using var c = await AbrirAsync(ct);

        await c.ExecuteAsync(new CommandDefinition(
            """
            INSERT INTO prueba_madrugada_config (id, tenant_id, clave_cifrada, preparada_por)
            VALUES (1, @tenantId, @claveCifrada, @preparadaPor)
            """,
            new { tenantId, claveCifrada, preparadaPor }, cancellationToken: ct));
    }

    // =============================================================== corridas

    /// <summary>
    /// Empieza una corrida. Devuelve null si el reloj ya corrió hoy (índice
    /// único por día): así un reinicio de la API no repite la prueba.
    /// </summary>
    public async Task<long?> IniciarAsync(
        string origen, string iniciadaPor, DateOnly fechaLima, CancellationToken ct = default)
    {
        await using var c = await AbrirAsync(ct);

        try
        {
            return await c.ExecuteScalarAsync<long>(new CommandDefinition(
                """
                INSERT INTO pruebas_madrugada (origen, iniciada_por, fecha_lima)
                VALUES (@origen, @iniciadaPor, @fecha)
                RETURNING id
                """,
                new { origen, iniciadaPor, fecha = fechaLima.ToDateTime(TimeOnly.MinValue) },
                cancellationToken: ct));
        }
        catch (PostgresException ex) when (ex.SqlState == "23505")
        {
            return null;
        }
    }

    public async Task<bool> RelojYaCorrioAsync(DateOnly fechaLima, CancellationToken ct = default)
    {
        await using var c = await AbrirAsync(ct);

        return await c.ExecuteScalarAsync<bool>(new CommandDefinition(
            "SELECT EXISTS (SELECT 1 FROM pruebas_madrugada WHERE origen = 'reloj' AND fecha_lima = @fecha)",
            new { fecha = fechaLima.ToDateTime(TimeOnly.MinValue) }, cancellationToken: ct));
    }

    public async Task<bool> HayUnaEnCursoAsync(CancellationToken ct = default)
    {
        await using var c = await AbrirAsync(ct);

        return await c.ExecuteScalarAsync<bool>(new CommandDefinition(
            """
            SELECT EXISTS (SELECT 1 FROM pruebas_madrugada
                            WHERE terminada_en IS NULL AND iniciada_en > now() - interval '30 minutes')
            """,
            cancellationToken: ct));
    }

    public async Task TerminarAsync(long pruebaId, string? error, CancellationToken ct = default)
    {
        await using var c = await AbrirAsync(ct);

        await c.ExecuteAsync(new CommandDefinition(
            "UPDATE pruebas_madrugada SET terminada_en = now(), error = @error WHERE id = @pruebaId",
            new { pruebaId, error }, cancellationToken: ct));
    }

    public async Task RegistrarCasoAsync(
        long pruebaId, string caso, short orden,
        Guid? comprobanteId, Guid? resumenId, string? numero,
        string? errorApi, string? mensaje, CancellationToken ct = default)
    {
        await using var c = await AbrirAsync(ct);

        await c.ExecuteAsync(new CommandDefinition(
            """
            INSERT INTO pruebas_madrugada_casos
                (prueba_id, caso, orden, comprobante_id, resumen_id, numero,
                 enviado_en, error_api, mensaje)
            VALUES
                (@pruebaId, @caso, @orden, @comprobanteId, @resumenId, @numero,
                 CASE WHEN @comprobanteId IS NULL AND @resumenId IS NULL THEN NULL ELSE now() END,
                 @errorApi, @mensaje)
            ON CONFLICT (prueba_id, caso) DO NOTHING
            """,
            new { pruebaId, caso, orden, comprobanteId, resumenId, numero, errorApi, mensaje },
            cancellationToken: ct));
    }

    /// <summary>Estado de un comprobante de la empresa interna (para esperar su desenlace).</summary>
    public async Task<string?> EstadoComprobanteAsync(Guid comprobanteId, CancellationToken ct = default)
    {
        await using var c = await AbrirAsync(ct);

        return await c.ExecuteScalarAsync<string?>(new CommandDefinition(
            "SELECT estado FROM comprobantes WHERE id = @comprobanteId",
            new { comprobanteId }, cancellationToken: ct));
    }

    // ================================================================ lectura

    private const string SelectCasos =
        """
        SELECT k.id              AS "Id",
               k.prueba_id       AS "PruebaId",
               k.caso            AS "Caso",
               k.orden           AS "Orden",
               k.comprobante_id  AS "ComprobanteId",
               k.resumen_id      AS "ResumenId",
               k.numero          AS "Numero",
               k.enviado_en      AS "EnviadoEn",
               k.error_api       AS "ErrorApi",
               k.mensaje         AS "MensajeCaso",
               coalesce(c.estado, r.estado)                   AS "EstadoDoc",
               coalesce(c.codigo_sunat, r.codigo_sunat)       AS "CodigoDoc",
               coalesce(c.mensaje_sunat, r.mensaje_sunat)     AS "MensajeDoc",
               coalesce(c.intentos_fallidos, r.intentos_fallidos, 0)::smallint AS "IntentosFallidos",
               k.estado_final    AS "EstadoFinal",
               k.codigo          AS "CodigoFinal",
               k.cambio          AS "Cambio",
               k.comparado_en    AS "ComparadoEn"
          FROM pruebas_madrugada_casos k
          LEFT JOIN comprobantes c ON c.id = k.comprobante_id
          LEFT JOIN resumenes    r ON r.id = k.resumen_id
        """;

    /// <summary>Las últimas corridas (más nuevas primero) con todos sus casos.</summary>
    public async Task<(IReadOnlyList<CorridaMadrugada> Corridas, IReadOnlyList<CasoMadrugada> Casos)>
        UltimasAsync(int cuantas, CancellationToken ct = default)
    {
        await using var c = await AbrirAsync(ct);

        var corridas = (await c.QueryAsync<CorridaMadrugada>(new CommandDefinition(
            """
            SELECT id           AS "Id",
                   origen       AS "Origen",
                   iniciada_por AS "IniciadaPor",
                   iniciada_en  AS "IniciadaEn",
                   terminada_en AS "TerminadaEn",
                   error        AS "Error"
              FROM pruebas_madrugada
             ORDER BY iniciada_en DESC
             LIMIT @cuantas
            """,
            new { cuantas }, cancellationToken: ct))).ToList();

        if (corridas.Count == 0) return (corridas, []);

        var casos = (await c.QueryAsync<CasoMadrugada>(new CommandDefinition(
            SelectCasos + " WHERE k.prueba_id = ANY(@ids) ORDER BY k.prueba_id, k.orden",
            new { ids = corridas.Select(x => x.Id).ToArray() }, cancellationToken: ct))).ToList();

        return (corridas, casos);
    }

    /// <summary>Los casos que todavía no se compararon con la noche anterior.</summary>
    public async Task<IReadOnlyList<CasoMadrugada>> SinCompararAsync(CancellationToken ct = default)
    {
        await using var c = await AbrirAsync(ct);

        return (await c.QueryAsync<CasoMadrugada>(new CommandDefinition(
            SelectCasos + " WHERE k.comparado_en IS NULL ORDER BY k.prueba_id, k.orden",
            cancellationToken: ct))).ToList();
    }

    /// <summary>
    /// El último desenlace comparado de ese caso, en una corrida anterior.
    /// Las noches en que SUNAT no respondió no cuentan: no dicen nada de la regla.
    /// </summary>
    public async Task<(string Estado, string? Codigo, string? Numero, DateTime Cuando)?> AnteriorAsync(
        string caso, long antesDe, CancellationToken ct = default)
    {
        await using var c = await AbrirAsync(ct);

        var fila = await c.QuerySingleOrDefaultAsync<FilaAnterior>(new CommandDefinition(
            """
            SELECT k.estado_final AS "Estado", k.codigo AS "Codigo", k.numero AS "Numero",
                   p.iniciada_en  AS "Cuando"
              FROM pruebas_madrugada_casos k
              JOIN pruebas_madrugada p ON p.id = k.prueba_id
             WHERE k.caso = @caso AND k.prueba_id < @antesDe
               AND k.estado_final IN ('ok', 'obs', 'mal', 'error_api')
             ORDER BY k.prueba_id DESC
             LIMIT 1
            """,
            new { caso, antesDe }, cancellationToken: ct));

        return fila is null ? null : (fila.Estado, fila.Codigo, fila.Numero, fila.Cuando);
    }

    private sealed record FilaAnterior(string Estado, string? Codigo, string? Numero, DateTime Cuando);

    public async Task MarcarComparadoAsync(
        long casoId, string estado, string? codigo, string? mensaje, string cambio,
        CancellationToken ct = default)
    {
        await using var c = await AbrirAsync(ct);

        await c.ExecuteAsync(new CommandDefinition(
            """
            UPDATE pruebas_madrugada_casos
               SET estado_final = CASE WHEN @estado = 'caida' THEN NULL ELSE @estado END,
                   codigo = @codigo,
                   mensaje = coalesce(mensaje, @mensaje),
                   cambio = @cambio,
                   comparado_en = now()
             WHERE id = @casoId AND comparado_en IS NULL
            """,
            new { casoId, estado, codigo, mensaje, cambio }, cancellationToken: ct));
    }

    /// <summary>
    /// ¿Las últimas tres corridas terminaron sin una sola respuesta de SUNAT?
    /// Y si es así, ¿ya se avisó en los últimos tres días?
    /// </summary>
    public async Task<bool> BetaCaidaSinAvisarAsync(CancellationToken ct = default)
    {
        await using var c = await AbrirAsync(ct);

        return await c.ExecuteScalarAsync<bool>(new CommandDefinition(
            """
            WITH ultimas AS (
                SELECT id FROM pruebas_madrugada
                 WHERE terminada_en IS NOT NULL
                 ORDER BY iniciada_en DESC LIMIT 3
            )
            SELECT (SELECT count(*) FROM ultimas) = 3
               AND NOT EXISTS (
                    SELECT 1 FROM pruebas_madrugada_casos k
                     WHERE k.prueba_id IN (SELECT id FROM ultimas)
                       AND (k.estado_final IS NOT NULL OR k.comparado_en IS NULL))
               AND NOT EXISTS (
                    SELECT 1 FROM vigilancia_alertas
                     WHERE tipo = 'beta_caida' AND creada_en > now() - interval '3 days')
            """,
            cancellationToken: ct));
    }

    /// <summary>Una alerta de la prueba (va por el mismo correo que las de códigos).</summary>
    public async Task CrearAlertaAsync(
        string tipo, string gravedad, string titulo, string detalle, CancellationToken ct = default)
    {
        await using var c = await AbrirAsync(ct);

        await c.ExecuteAsync(new CommandDefinition(
            """
            INSERT INTO vigilancia_alertas (tipo, gravedad, titulo, detalle)
            VALUES (@tipo, @gravedad, @titulo, @detalle)
            """,
            new { tipo, gravedad, titulo, detalle = detalle.Length > 3000 ? detalle[..3000] : detalle },
            cancellationToken: ct));
    }
}
'@ },
    @{ Ruta = 'Facturacion.Api\PruebaMadrugada.cs'; Texto = @'
using System.Net.Http.Headers;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using System.Text.Json;
using Facturacion.Persistencia;

namespace Facturacion.Api;

/// <summary>Un caso de la prueba: qué se emite y por qué ruta.</summary>
/// <param name="Clave">Identificador estable: con él se compara noche contra noche.</param>
/// <param name="Cuerpo">Arma la petición. Recibe la fecha de Lima y lo ya emitido esa noche.</param>
public sealed record CasoPrueba(
    string Clave, string Nombre, string Ruta,
    Func<DateOnly, IReadOnlyDictionary<string, (Guid Id, string Numero)>, object?> Cuerpo,
    string? Depende = null, bool EsperaAceptado = false);

/// <summary>
/// LOS CASOS DE LA PRUEBA DE MADRUGADA. Para agregar uno, se agrega aquí.
///
/// Van en este orden porque algunos dependen de otros: las notas modifican la
/// «factura simple» de esa misma noche, y la baja se pide sobre una factura
/// que SUNAT ya aceptó (la espera hasta 5 minutos).
///
/// LA BOLETA tarda un día: viaja en el resumen diario, que el servicio arma con
/// las boletas del día anterior. Su casilla sale «esperando» hasta entonces.
///
/// Las guías no están: SUNAT no tiene ambiente de pruebas para ellas.
/// </summary>
public static class CasosMadrugada
{
    // RUC del cliente de las facturas: la empresa de prueba de la plataforma.
    private const string RucCliente = "20610878564";

    private static object Cliente() => new
    {
        tipoDocumento = "6", numeroDocumento = RucCliente,
        razonSocial = "EMPRESA DE PRUEBA", direccion = "AV. PRUEBA 123, LIMA"
    };

    private static object Linea(string codigo, string descripcion, decimal cantidad, decimal valor,
                                string afectacion = "10") => new
    {
        codigoProducto = codigo, descripcion, unidadMedida = "NIU",
        cantidad, valorUnitario = valor, tipoAfectacionIgv = afectacion
    };

    private static string F(DateOnly d) => d.ToString("yyyy-MM-dd");

    public static readonly IReadOnlyList<CasoPrueba> Todos =
    [
        new("factura-simple", "Factura simple", "/v1/comprobantes", (hoy, _) => new
        {
            tipo = "01", serie = "F900", fechaEmision = F(hoy), moneda = "PEN",
            receptor = Cliente(),
            lineas = new[] { Linea("PM-001", "SERVICIO DE PRUEBA DE MADRUGADA", 1, 100m) }
        }),

        new("factura-dolares", "Factura en dólares con descuento", "/v1/comprobantes", (hoy, _) => new
        {
            tipo = "01", serie = "F900", fechaEmision = F(hoy), moneda = "USD",
            tipoCambio = new { monedaOrigen = "USD", monedaDestino = "PEN", tasa = 3.750m, fecha = F(hoy) },
            descuentoGlobalPorcentaje = 5m,
            receptor = Cliente(),
            lineas = new[] { Linea("PM-002", "PRODUCTO DE PRUEBA EN DOLARES", 2, 50m) }
        }),

        new("factura-bonificacion", "Factura con bonificación", "/v1/comprobantes", (hoy, _) => new
        {
            tipo = "01", serie = "F900", fechaEmision = F(hoy), moneda = "PEN",
            receptor = Cliente(),
            lineas = new[]
            {
                Linea("PM-003", "PRODUCTO DE PRUEBA", 3, 20m),
                Linea("PM-004", "PRODUCTO DE REGALO (BONIFICACION)", 1, 20m, afectacion: "15")
            }
        }),

        new("boleta", "Boleta (va en el resumen del día siguiente)", "/v1/comprobantes", (hoy, _) => new
        {
            tipo = "03", serie = "B900", fechaEmision = F(hoy), moneda = "PEN",
            receptor = new { tipoDocumento = "1", numeroDocumento = "12345678",
                             razonSocial = "CLIENTE DE PRUEBA", direccion = "LIMA" },
            lineas = new[] { Linea("PM-005", "VENTA DE PRUEBA", 1, 50m) }
        }),

        new("nota-credito", "Nota de crédito", "/v1/notas-credito", (hoy, hechos) =>
            !hechos.TryGetValue("factura-simple", out var f) ? null : new
            {
                serie = "FC90", fechaEmision = F(hoy), moneda = "PEN",
                codigoMotivo = "01", descripcionMotivo = "ANULACION DE LA OPERACION (PRUEBA)",
                afectado = Afectado(f.Numero),
                receptor = Cliente(),
                lineas = new[] { Linea("PM-001", "SERVICIO DE PRUEBA DE MADRUGADA", 1, 100m) }
            }, Depende: "factura-simple"),

        new("nota-debito", "Nota de débito", "/v1/notas-debito", (hoy, hechos) =>
            !hechos.TryGetValue("factura-simple", out var f) ? null : new
            {
                serie = "FD90", fechaEmision = F(hoy), moneda = "PEN",
                codigoMotivo = "01", descripcionMotivo = "INTERESES POR MORA (PRUEBA)",
                afectado = Afectado(f.Numero),
                receptor = Cliente(),
                lineas = new[] { Linea("PM-006", "INTERESES POR MORA", 1, 10m) }
            }, Depende: "factura-simple"),

        new("factura-para-baja", "Factura que luego se da de baja", "/v1/comprobantes", (hoy, _) => new
        {
            tipo = "01", serie = "F900", fechaEmision = F(hoy), moneda = "PEN",
            receptor = Cliente(),
            lineas = new[] { Linea("PM-007", "SERVICIO QUE SE ANULA", 1, 30m) }
        }),

        new("baja", "Baja de una factura", "/v1/bajas", (_, hechos) =>
            !hechos.TryGetValue("factura-para-baja", out var f) ? null : new
            {
                motivo = "PRUEBA DE MADRUGADA",
                comprobantes = new[] { new { tipoDocumento = "01", serie = f.Numero[..4],
                                             correlativo = int.Parse(f.Numero[5..]),
                                             motivo = "PRUEBA DE MADRUGADA" } }
            }, Depende: "factura-para-baja", EsperaAceptado: true),
    ];

    private static object Afectado(string numero) =>
        new { tipoDocumento = "01", serie = numero[..4], correlativo = int.Parse(numero[5..]) };
}

/// <summary>
/// LA PRUEBA DE MADRUGADA (migración 030).
///
/// Prepara la empresa interna si hace falta, emite los casos POR LA API —igual
/// que un cliente, con su clave fac_— y anota qué se emitió. El desenlace lo
/// pone el worker como a cualquier comprobante; la comparación con la noche
/// anterior la hace <see cref="EvaluarAsync"/>, que corre con la vigilancia
/// cada 5 minutos.
///
/// LA EMPRESA INTERNA: RUC 20999999990, siempre en beta (la base no la deja
/// pasar a producción), certificado autofirmado (SUNAT beta lo acepta),
/// series F900, B900, FC90 y FD90. Ningún correlativo real se toca.
/// </summary>
public sealed class PruebaMadrugada
{
    public const string RucInterno = "20999999990";
    private const string ClaveCertificado = "prueba-de-madrugada";

    private readonly RepositorioMadrugada _repo;
    private readonly RepositorioAdmin _admin;
    private readonly AlmacenCertificados _certificados;
    private readonly IProtectorDeSecretos _protector;
    private readonly IHttpClientFactory _http;
    private readonly ILogger<PruebaMadrugada> _log;

    // Una sola corrida a la vez dentro de este proceso.
    private readonly SemaphoreSlim _uno = new(1, 1);

    public PruebaMadrugada(
        RepositorioMadrugada repo, RepositorioAdmin admin, AlmacenCertificados certificados,
        IProtectorDeSecretos protector, IHttpClientFactory http, ILogger<PruebaMadrugada> log)
    {
        _repo = repo;
        _admin = admin;
        _certificados = certificados;
        _protector = protector;
        _http = http;
        _log = log;
    }

    public bool Corriendo => _uno.CurrentCount == 0;

    public static DateTime AhoraLima()
    {
        TimeZoneInfo zona;
        try { zona = TimeZoneInfo.FindSystemTimeZoneById("America/Lima"); }
        catch (TimeZoneNotFoundException)
        {
            try { zona = TimeZoneInfo.FindSystemTimeZoneById("SA Pacific Standard Time"); }
            catch (TimeZoneNotFoundException) { return DateTime.UtcNow.AddHours(-5); }
        }
        return TimeZoneInfo.ConvertTimeFromUtc(DateTime.UtcNow, zona);
    }

    // =============================================================== preparar

    /// <summary>
    /// Deja lista la empresa interna. Si ya está, no hace nada. Si la empresa
    /// existe pero sin configuración (una preparación que se cortó), la reusa.
    /// </summary>
    public async Task<ConfigMadrugada> PrepararAsync(string quien, CancellationToken ct)
    {
        var cfg = await _repo.ConfigAsync(ct);
        if (cfg is not null) return cfg;

        var tenantId = await _repo.TenantPorRucAsync(RucInterno, ct)
            ?? await _admin.CrearTenantAsync(new NuevoTenant
            {
                Ruc = RucInterno,
                RazonSocial = "PRUEBA DE MADRUGADA (INTERNA)",
                NombreComercial = "PRUEBA DE MADRUGADA",
                Ubigeo = "150101",
                Direccion = "EMPRESA INTERNA DE PRUEBAS - NO FACTURA",
                Distrito = "LIMA", Provincia = "LIMA", Departamento = "LIMA",
                Ambiente = "beta", UsuarioSol = "MODDATOS", MaxConcurrencia = 1
            }, ct);

        foreach (var (tipo, serie) in new[] { ("01", "F900"), ("03", "B900"), ("07", "FC90"), ("08", "FD90") })
            await _admin.CrearSerieAsync(tenantId, tipo, serie, 0, null, quien, ct);

        // Certificado autofirmado, 10 años. Solo vale en beta, que es donde vive.
        using (var rsa = RSA.Create(2048))
        {
            var pedido = new CertificateRequest(
                $"CN=PRUEBA DE MADRUGADA, SERIALNUMBER={RucInterno}", rsa,
                HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
            using var cert = pedido.CreateSelfSigned(
                DateTimeOffset.UtcNow.AddDays(-1), DateTimeOffset.UtcNow.AddYears(10));
            await _certificados.GuardarAsync(
                tenantId, cert.Export(X509ContentType.Pfx, ClaveCertificado), ClaveCertificado, ct);
        }

        var (_, clave) = await _admin.CrearClaveAsync(tenantId, "Prueba de madrugada", ct: ct);
        await _repo.GuardarConfigAsync(tenantId, _protector.ProtegerTexto(clave), quien, ct);

        _log.LogInformation("Prueba de madrugada: empresa interna {Ruc} preparada por {Quien}.", RucInterno, quien);

        return (await _repo.ConfigAsync(ct))!;
    }

    // ================================================================= correr

    /// <summary>
    /// Una corrida completa. Devuelve null si no corrió (otra en curso, o el
    /// reloj ya corrió hoy), o el id de la corrida.
    /// </summary>
    public async Task<long?> CorrerAsync(string origen, string quien, CancellationToken ct)
    {
        if (!await _uno.WaitAsync(0, ct)) return null;

        try
        {
            if (await _repo.HayUnaEnCursoAsync(ct)) return null;

            var cfg = await PrepararAsync(quien, ct);
            var hoy = DateOnly.FromDateTime(AhoraLima());

            var pruebaId = await _repo.IniciarAsync(origen, quien, hoy, ct);
            if (pruebaId is null) return null;

            string? errorGeneral = null;

            try
            {
                await EmitirCasosAsync(pruebaId.Value, cfg, hoy, ct);
            }
            catch (Exception ex) when (ex is not OperationCanceledException)
            {
                errorGeneral = ex.Message;
                _log.LogError(ex, "Prueba de madrugada {Id}: falló.", pruebaId);
            }

            await _repo.TerminarAsync(pruebaId.Value, errorGeneral, CancellationToken.None);

            _log.LogInformation("Prueba de madrugada {Id} terminada ({Origen}, {Quien}).", pruebaId, origen, quien);

            return pruebaId;
        }
        finally
        {
            _uno.Release();
        }
    }

    private async Task EmitirCasosAsync(long pruebaId, ConfigMadrugada cfg, DateOnly hoy, CancellationToken ct)
    {
        var clave = _protector.DesprotegerTexto(cfg.ClaveCifrada);
        var cliente = _http.CreateClient("madrugada");
        var hechos = new Dictionary<string, (Guid Id, string Numero)>();
        short orden = 0;

        foreach (var caso in CasosMadrugada.Todos)
        {
            orden++;

            if (caso.EsperaAceptado && caso.Depende is not null && hechos.TryGetValue(caso.Depende, out var previo))
            {
                var estado = await EsperarDesenlaceAsync(previo.Id, TimeSpan.FromMinutes(5), ct);
                if (estado is not ("ACEPTADO" or "ACEPTADO_CON_OBSERVACIONES"))
                {
                    await _repo.RegistrarCasoAsync(pruebaId, caso.Clave, orden, null, null, null, null,
                        $"No se pudo probar: {previo.Numero} no fue aceptada a tiempo (estado {estado ?? "desconocido"}).", ct);
                    continue;
                }
            }

            var cuerpo = caso.Cuerpo(hoy, hechos);

            if (cuerpo is null)
            {
                await _repo.RegistrarCasoAsync(pruebaId, caso.Clave, orden, null, null, null, null,
                    $"No se pudo probar: depende de «{caso.Depende}», que no se emitió.", ct);
                continue;
            }

            using var pedido = new HttpRequestMessage(HttpMethod.Post, caso.Ruta)
            {
                Content = new StringContent(JsonSerializer.Serialize(cuerpo), Encoding.UTF8, "application/json")
            };
            pedido.Headers.Authorization = new AuthenticationHeaderValue("Bearer", clave);
            pedido.Headers.Add("Idempotency-Key", $"madrugada-{pruebaId}-{caso.Clave}");

            HttpResponseMessage respuesta;
            string texto;

            try
            {
                respuesta = await cliente.SendAsync(pedido, ct);
                texto = await respuesta.Content.ReadAsStringAsync(ct);
            }
            catch (HttpRequestException ex)
            {
                // No llegamos a nuestra propia API: no es SUNAT. Se anota y se sigue.
                await _repo.RegistrarCasoAsync(pruebaId, caso.Clave, orden, null, null, null,
                    $"No se pudo llamar a la API: {ex.Message}", null, ct);
                continue;
            }

            if (!respuesta.IsSuccessStatusCode)
            {
                await _repo.RegistrarCasoAsync(pruebaId, caso.Clave, orden, null, null, null,
                    $"La API respondió {(int)respuesta.StatusCode}: {Recortar(texto, 600)}", null, ct);
                continue;
            }

            using var json = JsonDocument.Parse(texto);
            var raiz = json.RootElement;
            var id = raiz.GetProperty("id").GetGuid();
            var numero = raiz.TryGetProperty("numero", out var n) ? n.GetString()
                       : raiz.TryGetProperty("identificador", out var i) ? i.GetString() : null;

            var esBaja = caso.Ruta.StartsWith("/v1/bajas", StringComparison.Ordinal);

            await _repo.RegistrarCasoAsync(pruebaId, caso.Clave, orden,
                esBaja ? null : id, esBaja ? id : null, numero, null, null, ct);

            if (!esBaja && numero is not null) hechos[caso.Clave] = (id, numero);
        }
    }

    private async Task<string?> EsperarDesenlaceAsync(Guid comprobanteId, TimeSpan tope, CancellationToken ct)
    {
        var hasta = DateTime.UtcNow + tope;
        string? estado = null;

        while (DateTime.UtcNow < hasta)
        {
            estado = await _repo.EstadoComprobanteAsync(comprobanteId, ct);
            if (estado is "ACEPTADO" or "ACEPTADO_CON_OBSERVACIONES" or "RECHAZADO" or "ANULADO") return estado;
            await Task.Delay(TimeSpan.FromSeconds(10), ct);
        }

        return estado;
    }

    // =============================================================== comparar

    /// <summary>
    /// Compara cada caso que ya tiene desenlace con el de la noche anterior y
    /// crea una alerta solo si cambió. Lo llama la vigilancia cada 5 minutos.
    /// </summary>
    public async Task<int> EvaluarAsync(CancellationToken ct)
    {
        var alertas = 0;

        foreach (var caso in await _repo.SinCompararAsync(ct))
        {
            var estado = caso.Estado;
            if (estado == "pend") continue;

            var nombre = CasosMadrugada.Todos.FirstOrDefault(c => c.Clave == caso.Caso)?.Nombre ?? caso.Caso;
            var mensaje = caso.ErrorApi ?? caso.MensajeDoc ?? caso.MensajeCaso;

            if (estado == "caida")
            {
                await _repo.MarcarComparadoAsync(caso.Id, "caida", null, mensaje, "sin respuesta", ct);
                continue;
            }

            var anterior = await _repo.AnteriorAsync(caso.Caso, caso.PruebaId, ct);
            var codigo = caso.Codigo;
            var (cambio, gravedad, titulo) = Comparar(nombre, estado, codigo, anterior?.Estado, anterior?.Codigo);

            if (titulo is not null)
            {
                var detalle =
                    $"Caso: {nombre}\n" +
                    $"Antes ({anterior?.Cuando:yyyy-MM-dd}): {Texto(anterior?.Estado)}{(anterior?.Codigo is { } ca ? $", código {ca}" : "")}" +
                    $"{(anterior?.Numero is { } na ? $" · {na}" : "")}\n" +
                    $"Ahora: {Texto(estado)}{(codigo is not null ? $", código {codigo}" : "")}" +
                    $"{(caso.Numero is { } nn ? $" · {nn}" : "")}\n" +
                    $"Qué dijo: {mensaje ?? "—"}";

                await _repo.CrearAlertaAsync("prueba_cambio", gravedad!, titulo, detalle, ct);
                alertas++;
            }

            await _repo.MarcarComparadoAsync(caso.Id, estado, codigo, mensaje, cambio, ct);
        }

        if (await _repo.BetaCaidaSinAvisarAsync(ct))
        {
            await _repo.CrearAlertaAsync("beta_caida", "atencion",
                "SUNAT beta no responde desde hace tres pruebas",
                "Las tres últimas pruebas de madrugada no recibieron respuesta de SUNAT beta. " +
                "Así la prueba no puede detectar cambios de reglas. Suele ser una caída de SUNAT; " +
                "si sigue varios días, revisa la conexión del servicio.", ct);
            alertas++;
        }

        return alertas;
    }

    /// <summary>Qué cambió, y si amerita alerta (título) o no (null).</summary>
    public static (string Cambio, string? Gravedad, string? Titulo) Comparar(
        string nombre, string ahora, string? codigo, string? antes, string? codigoAntes)
    {
        static bool Pasa(string? e) => e is "ok" or "obs";
        static bool Falla(string? e) => e is "mal" or "error_api";

        if (antes is null) return ("primera vez", null, null);

        if (Pasa(antes) && ahora == "mal")
            return ("ahora rechaza", "problema", $"Prueba de madrugada: SUNAT ahora rechaza «{nombre}»");

        if (Pasa(antes) && ahora == "error_api")
            return ("nuestra API falla", "problema", $"Prueba de madrugada: nuestra API ya no acepta «{nombre}»");

        if (Falla(antes) && Pasa(ahora))
            return ("volvió a pasar", "atencion", $"Prueba de madrugada: «{nombre}» volvió a pasar");

        if (ahora == "mal" && antes == "mal" && codigo != codigoAntes)
            return ("otro rechazo", "problema", $"Prueba de madrugada: «{nombre}» se rechaza por otro motivo");

        if (ahora == "obs" && (antes == "ok" || codigo != codigoAntes))
            return ("nueva observación", "atencion", $"Prueba de madrugada: «{nombre}» trae una observación nueva");

        return ("igual", null, null);
    }

    private static string Texto(string? e) => e switch
    {
        "ok" => "aceptado", "obs" => "aceptado con observaciones", "mal" => "rechazado",
        "error_api" => "nuestra API no lo aceptó", null => "—", _ => e
    };

    private static string Recortar(string t, int n) => t.Length <= n ? t : t[..n] + "…";
}

/// <summary>
/// El reloj de la prueba: una vez al día, a partir de la hora de Lima que diga
/// PRUEBA_MADRUGADA_HORA (por defecto 03:00). Si la API estaba apagada a esa
/// hora, corre en cuanto arranque ese mismo día. PRUEBA_MADRUGADA_ACTIVA=false
/// la apaga.
/// </summary>
public sealed class ServicioMadrugada : BackgroundService
{
    private readonly PruebaMadrugada _prueba;
    private readonly RepositorioMadrugada _repo;
    private readonly ILogger<ServicioMadrugada> _log;
    private readonly TimeSpan _hora;
    private readonly bool _activa;

    public ServicioMadrugada(PruebaMadrugada prueba, RepositorioMadrugada repo, ILogger<ServicioMadrugada> log)
    {
        _prueba = prueba;
        _repo = repo;
        _log = log;
        _hora = TimeSpan.TryParse(ConfiguracionSecretos.Opcional("PRUEBA_MADRUGADA_HORA", "03:00"), out var h)
            ? h : new TimeSpan(3, 0, 0);
        _activa = !ConfiguracionSecretos.Opcional("PRUEBA_MADRUGADA_ACTIVA", "true")
            .Equals("false", StringComparison.OrdinalIgnoreCase);
    }

    public TimeSpan Hora => _hora;

    protected override async Task ExecuteAsync(CancellationToken ct)
    {
        if (!_activa)
        {
            _log.LogInformation("Prueba de madrugada apagada (PRUEBA_MADRUGADA_ACTIVA=false).");
            return;
        }

        try { await Task.Delay(TimeSpan.FromMinutes(2), ct); }
        catch (OperationCanceledException) { return; }

        _log.LogInformation("Prueba de madrugada: todos los días desde las {Hora} (hora de Lima).", _hora);

        while (!ct.IsCancellationRequested)
        {
            try
            {
                var ahora = PruebaMadrugada.AhoraLima();
                if (ahora.TimeOfDay >= _hora && !await _repo.RelojYaCorrioAsync(DateOnly.FromDateTime(ahora), ct))
                    await _prueba.CorrerAsync("reloj", "reloj de las " + _hora.ToString(@"hh\:mm"), ct);
            }
            catch (OperationCanceledException) when (ct.IsCancellationRequested) { break; }
            catch (Npgsql.PostgresException ex) when (ex.SqlState == "42P01")
            {
                _log.LogWarning("Prueba de madrugada apagada: falta aplicar la migración 030 ({Mensaje}).", ex.MessageText);
                return;
            }
            catch (Exception ex)
            {
                _log.LogError(ex, "Falló el reloj de la prueba de madrugada. Se reintenta en un minuto.");
            }

            try { await Task.Delay(TimeSpan.FromMinutes(1), ct); }
            catch (OperationCanceledException) { break; }
        }
    }
}
'@ },
    @{ Ruta = 'Facturacion.Api\EndpointsMadrugada.cs'; Texto = @'
using Facturacion.Persistencia;

namespace Facturacion.Api;

/// <summary>
/// La sección «Prueba de madrugada» de Vigilancia SUNAT (migración 030).
///
/// Ver y «Correr ahora»: quien ve el estado del servicio (diagnostico.ver).
/// Correrla solo emite en SUNAT beta, con la empresa interna: no toca nada
/// real. Todo lo que no es GET queda en la bitácora del panel.
/// </summary>
public static class EndpointsMadrugada
{
    public static void MapearPruebaMadrugada(this WebApplication app)
    {
        var grupo = app.MapGroup("/admin/vigilancia/madrugada")
            .AddEndpointFilter<AutenticacionPanel>()
            .WithTags("Vigilancia SUNAT");

        grupo.MapGet("", async (
            RepositorioMadrugada repo, PruebaMadrugada prueba, CancellationToken ct) =>
        {
            ConfigMadrugada? cfg;

            try { cfg = await repo.ConfigAsync(ct); }
            catch (Npgsql.PostgresException ex) when (ex.SqlState == "42P01")
            {
                return Results.Json(new RespuestaError(
                    "Falta aplicar la migración 030.",
                    "Sin ella no existe la prueba de madrugada."),
                    statusCode: StatusCodes.Status503ServiceUnavailable);
            }

            var (corridas, casos) = await repo.UltimasAsync(7, ct);

            return Results.Ok(new
            {
                preparada = cfg is not null,
                empresa = cfg is null ? null : new { cfg.Ruc, cfg.RazonSocial, cfg.PreparadaEn, cfg.PreparadaPor },
                hora = ConfiguracionSecretos.Opcional("PRUEBA_MADRUGADA_HORA", "03:00"),
                corriendo = prueba.Corriendo,
                definicion = CasosMadrugada.Todos.Select(c => new { clave = c.Clave, nombre = c.Nombre }),
                corridas = corridas.Select(x => new
                {
                    x.Id, x.Origen, x.IniciadaPor, x.IniciadaEn, x.TerminadaEn, x.Error
                }),
                casos = casos.Select(k => new
                {
                    k.PruebaId, caso = k.Caso, estado = k.Estado, codigo = k.Codigo,
                    mensaje = k.ErrorApi ?? k.MensajeDoc ?? k.MensajeCaso,
                    k.Numero, k.Cambio, k.EnviadoEn
                })
            });
        })
        .AddEndpointFilter(new ExigirPermiso(Permiso.DiagnosticoVer))
        .WithSummary("La prueba de madrugada: las últimas 7 corridas, caso por caso");

        grupo.MapPost("/correr", (
            ContextoOperador operador, PruebaMadrugada prueba, IHostApplicationLifetime vida,
            ILogger<PruebaMadrugada> log) =>
        {
            if (prueba.Corriendo)
                return Results.Conflict(new RespuestaError(
                    "Ya hay una prueba corriendo.", "Espera a que termine; tarda unos minutos."));

            var quien = operador.Exigir().Correo;

            // Corre aparte: tarda minutos (espera a que SUNAT acepte la factura
            // que después se da de baja). La pantalla se va actualizando sola.
            _ = Task.Run(async () =>
            {
                try { await prueba.CorrerAsync("panel", quien, vida.ApplicationStopping); }
                catch (Exception ex) { log.LogError(ex, "Falló la prueba de madrugada pedida desde el panel."); }
            });

            return Results.Accepted(value: new
            {
                mensaje = "La prueba empezó. Los resultados van apareciendo en unos minutos; " +
                          "la boleta, al día siguiente."
            });
        })
        .AddEndpointFilter(new ExigirPermiso(Permiso.DiagnosticoVer))
        .WithSummary("Corre la prueba ahora, sin esperar a la madrugada");
    }
}
'@ }
)

$reemplazos = @(
    @{ Ruta = 'Facturacion.Api\Program.cs'
       Antes = @'
builder.Services.AddHostedService<ServicioVigilancia>();
'@
       Despues = @'
builder.Services.AddHostedService<ServicioVigilancia>();

// PRUEBA DE MADRUGADA (migración 030): cada día a las 03:00 (Lima) emite en
// SUNAT beta un comprobante de cada tipo con una empresa interna y lo compara
// con la vez anterior. Entra por la propia API, como un cliente: la URL es la
// del panel salvo que PRUEBA_MADRUGADA_URL diga otra. El certificado de
// desarrollo solo se acepta si la llamada es a esta misma máquina.
builder.Services.AddSingleton(new RepositorioMadrugada(cadenaOperador));
builder.Services.AddSingleton<PruebaMadrugada>();
builder.Services.AddHostedService<ServicioMadrugada>();
builder.Services.AddHttpClient("madrugada", cliente =>
    {
        cliente.BaseAddress = new Uri(ConfiguracionSecretos.Opcional(
            "PRUEBA_MADRUGADA_URL", opcionesCorreo.UrlPanel).TrimEnd('/') + "/");
        cliente.Timeout = TimeSpan.FromSeconds(60);
    })
    .ConfigurePrimaryHttpMessageHandler(() => new HttpClientHandler
    {
        ServerCertificateCustomValidationCallback = (mensaje, _, _, errores) =>
            errores == System.Net.Security.SslPolicyErrors.None
            || (mensaje.RequestUri?.IsLoopback ?? false)
    });
'@ },
    @{ Ruta = 'Facturacion.Api\Program.cs'
       Antes = @'
app.MapearVigilancia();
'@
       Despues = @'
app.MapearVigilancia();
app.MapearPruebaMadrugada();
'@ },
    @{ Ruta = 'Facturacion.Api\VigilanciaSunat.cs'
       Antes = @'
    private readonly ILogger<VigilanciaSunat> _log;

    public VigilanciaSunat(
        RepositorioVigilancia repo, ServicioCorreo correo, OpcionesCorreo opciones,
        ILogger<VigilanciaSunat> log)
    {
        _repo = repo;
'@
       Despues = @'
    private readonly ILogger<VigilanciaSunat> _log;
    private readonly PruebaMadrugada _madrugada;

    public VigilanciaSunat(
        RepositorioVigilancia repo, ServicioCorreo correo, OpcionesCorreo opciones,
        ILogger<VigilanciaSunat> log, PruebaMadrugada madrugada)
    {
        _madrugada = madrugada;
        _repo = repo;
'@ },
    @{ Ruta = 'Facturacion.Api\VigilanciaSunat.cs'
       Antes = @'
        await AvisarPendientesAsync(ct);

        return r;
'@
       Despues = @'
        // PRUEBA DE MADRUGADA (migración 030): compara con la noche anterior
        // los casos que ya tienen desenlace. Si la 030 no está, no dice nada.
        try
        {
            var cambios = await _madrugada.EvaluarAsync(ct);
            if (cambios > 0)
                _log.LogWarning("Prueba de madrugada: {Cambios} cambio(s) respecto a la noche anterior.", cambios);
        }
        catch (Npgsql.PostgresException ex) when (ex.SqlState == "42P01") { }

        await AvisarPendientesAsync(ct);

        return r;
'@ },
    @{ Ruta = 'Facturacion.Api\VigilanciaSunat.cs'
       Antes = @'
        var asunto = alertas.Count == 1
            ? alertas[0].Titulo
            : $"{alertas.Count} códigos de SUNAT nunca vistos";

        var sb = new StringBuilder();

        sb.Append(alertas.Count == 1
'@
       Despues = @'
        var soloCodigos = alertas.All(a => a.Tipo == "codigo_nuevo");

        var asunto = alertas.Count == 1
            ? alertas[0].Titulo
            : soloCodigos ? $"{alertas.Count} códigos de SUNAT nunca vistos"
                          : $"Vigilancia SUNAT: {alertas.Count} avisos";

        var sb = new StringBuilder();

        if (!soloCodigos)
            sb.Append("<p>Vigilancia SUNAT encontró algo que mirar. Puede ser una regla nueva de SUNAT: " +
                      "si es así, los clientes que emitan ese tipo de comprobante van a recibir lo mismo.</p>");
        else sb.Append(alertas.Count == 1
'@ },
    @{ Ruta = 'Facturacion.Api\wwwroot\vigilancia.html'
       Antes = @'
  [hidden] { display:none !important; }
'@
       Despues = @'
  /* --- Prueba de madrugada (migración 030) --------------------------- */
  .rejilla td, .rejilla th { padding:5px 6px; }
  .rejilla th.noche { text-align:center; font-size:12.5px; white-space:nowrap; }
  .rejilla td:first-child { min-width:220px; }
  .celda { display:block; width:30px; height:22px; margin:0 auto; border-radius:5px; border:0; padding:0; cursor:pointer; }
  .c-ok { background:var(--sano); }
  .c-obs { background:var(--atencion); }
  .c-mal, .c-error_api { background:var(--problema); }
  .c-caida { background:repeating-linear-gradient(45deg, var(--borde) 0 4px, var(--sutil) 4px 8px); }
  .c-pend { background:transparent; border:1px dashed var(--tenue); }
  .c-vacia { background:transparent; cursor:default; }
  .celda.abierta { outline:2px solid var(--acento); outline-offset:2px; }
  .ficha { margin-top:14px; border:1px solid var(--borde); border-radius:10px; padding:14px 16px; background:var(--sutil); }
  .ficha dl { display:grid; grid-template-columns:max-content 1fr; gap:6px 14px; margin:0; font-size:14px; }
  .ficha dt { color:var(--tenue); }
  .ficha dd { margin:0; min-width:0; overflow-wrap:anywhere; }
  [hidden] { display:none !important; }
'@ },
    @{ Ruta = 'Facturacion.Api\wwwroot\vigilancia.html'
       Antes = @'
let filtro = "nuevos";
'@
       Despues = @'
let filtro = "nuevos";
let madrugada = null;      // la prueba de madrugada (migración 030)
let casoAbierto = null;    // { corrida, caso } de la casilla elegida
let relojPantalla = null;  // vuelve a cargar mientras una prueba corre
'@ },
    @{ Ruta = 'Facturacion.Api\wwwroot\vigilancia.html'
       Antes = @'
    datos = await pedir("/admin/vigilancia");
'@
       Despues = @'
    datos = await pedir("/admin/vigilancia");
    madrugada = await pedir("/admin/vigilancia/madrugada")
      .catch(e => ({ error: e.message, detalle: e.detalle }));
'@ },
    @{ Ruta = 'Facturacion.Api\wwwroot\vigilancia.html'
       Antes = @'
  const partes = [];
'@
       Despues = @'
  const partes = [seccionMadrugada()];
'@ },
    @{ Ruta = 'Facturacion.Api\wwwroot\vigilancia.html'
       Antes = @'
  document.querySelectorAll("[data-filtro]").forEach(b =>
'@
       Despues = @'
  enlazarMadrugada();

  document.querySelectorAll("[data-filtro]").forEach(b =>
'@ },
    @{ Ruta = 'Facturacion.Api\wwwroot\vigilancia.html'
       Antes = @'
// --------------------------------------------------------------- revisado
'@
       Despues = @'
// ------------------------------------------------------ prueba de madrugada
const NOMBRE_ESTADO = {
  ok: "Aceptado", obs: "Aceptado con observaciones", mal: "Rechazado por SUNAT",
  error_api: "Nuestra API no lo aceptó", caida: "SUNAT no respondió", pend: "Esperando respuesta"
};

const diaCorto = v => new Date(v).toLocaleDateString("es-PE", { timeZone: "America/Lima", day: "numeric", month: "short" });
const horaCorta = v => new Date(v).toLocaleTimeString("es-PE", { timeZone: "America/Lima", hour: "2-digit", minute: "2-digit" });

function seccionMadrugada() {
  const m = madrugada;
  if (!m) return "";

  if (m.error) {
    return `<section><h2>Prueba de madrugada</h2>
      <p class="mal">${esc(m.error)} ${esc(m.detalle || "")}</p></section>`;
  }

  const corridas = [...m.corridas].reverse();          // de la más vieja a la más nueva
  const ultima = corridas.at(-1);
  const buscar = (corrida, caso) => m.casos.find(k => k.pruebaId === corrida && k.caso === caso);

  // Si nadie eligió una casilla, se abre la que cambió en la última corrida.
  if (!casoAbierto && ultima) {
    const cambiada = m.casos.find(k => k.pruebaId === ultima.id && k.cambio &&
                                       !["igual", "primera vez", "sin respuesta"].includes(k.cambio));
    if (cambiada) casoAbierto = { corrida: ultima.id, caso: cambiada.caso };
  }

  const explicacion = m.preparada
    ? `Todos los días a las ${esc(m.hora)} (hora de Lima) se envía a SUNAT beta un comprobante de cada tipo,
       desde la empresa interna <b>${esc(m.empresa.razonSocial)}</b> (RUC ${esc(m.empresa.ruc)}), que nunca sale de beta.
       Si SUNAT rechaza algo que la vez anterior aceptaba, llega un correo: es que cambió una regla.`
    : `Todos los días a las ${esc(m.hora)} (hora de Lima) se envía a SUNAT beta un comprobante de cada tipo y se
       compara con la vez anterior. La primera vez que corra, prepara sola una empresa interna
       (RUC 20999999990), que nunca sale de beta ni gasta correlativos reales.`;

  let cuerpo;

  if (corridas.length === 0) {
    cuerpo = `<p class="vacio">Todavía no corrió. Pulsa «Correr ahora» para verla funcionar sin esperar a la madrugada.</p>`;
  } else {
    const cabeza = corridas.map(c => `
      <th class="noche" title="${esc(c.origen === "reloj" ? "Automática" : "Pedida por " + c.iniciadaPor)}">
        ${diaCorto(c.iniciadaEn)}<div class="sub">${c.origen === "reloj" ? horaCorta(c.iniciadaEn) : "a mano"}</div></th>`).join("");

    const filas = m.definicion.map(d => {
      const celdas = corridas.map(c => {
        const k = buscar(c.id, d.clave);
        if (!k) return `<td><span class="celda c-vacia" title="No se probó en esta corrida"></span></td>`;
        const abierta = casoAbierto && casoAbierto.corrida === c.id && casoAbierto.caso === d.clave;
        const nombre = NOMBRE_ESTADO[k.estado] || k.estado;
        return `<td><button class="celda c-${esc(k.estado)}${abierta ? " abierta" : ""}" data-corrida="${c.id}"
                  data-caso="${esc(d.clave)}" title="${esc(nombre)}" aria-label="${esc(d.nombre)}: ${esc(nombre)}"></button></td>`;
      }).join("");

      const k = ultima && buscar(ultima.id, d.clave);
      const marca = k && k.cambio && !["igual", "primera vez", "sin respuesta"].includes(k.cambio)
        ? ` <span class="pildora ${k.estado === "ok" || k.estado === "obs" ? "atencion" : "problema"}">${esc(k.cambio)}</span>` : "";

      return `<tr><td>${esc(d.nombre)}${marca}</td>${celdas}</tr>`;
    }).join("");

    cuerpo = `
      <div class="desplazable"><table class="rejilla">
        <tr><th>Caso</th>${cabeza}</tr>${filas}
      </table></div>
      <div class="leyenda" style="margin-top:12px">
        <span><i style="background:var(--sano)"></i>Aceptado</span>
        <span><i style="background:var(--atencion)"></i>Con observación</span>
        <span><i style="background:var(--problema)"></i>Rechazado, o nuestra API no lo aceptó</span>
        <span><i class="c-caida"></i>SUNAT no respondió (no es alarma)</span>
        <span><i class="c-pend"></i>Esperando respuesta</span>
      </div>
      ${fichaMadrugada(buscar)}`;
  }

  return `
    <section>
      <div class="cabecera-seccion">
        <h2>Prueba de madrugada</h2>
        <button class="mini" id="correr-madrugada" ${m.corriendo ? "disabled" : ""}>
          ${m.corriendo ? "Corriendo…" : "Correr ahora"}</button>
      </div>
      <p class="bajada">${explicacion}</p>
      ${cuerpo}
    </section>`;
}

function fichaMadrugada(buscar) {
  if (!casoAbierto) return `<p class="sub" style="margin:12px 0 0">Toca una casilla para ver qué se envió y qué dijo SUNAT.</p>`;

  const k = buscar(casoAbierto.corrida, casoAbierto.caso);
  const c = madrugada.corridas.find(x => x.id === casoAbierto.corrida);
  const d = madrugada.definicion.find(x => x.clave === casoAbierto.caso);
  if (!k || !c || !d) return "";

  const pildora = { ok: "", obs: "atencion", mal: "problema", error_api: "problema" }[k.estado] ?? "";

  return `
    <div class="ficha">
      <dl>
        <dt>Caso</dt><dd><b>${esc(d.nombre)}</b></dd>
        <dt>Corrida</dt><dd>${fecha(c.iniciadaEn)} · ${c.origen === "reloj" ? "automática" : "pedida por " + esc(c.iniciadaPor)}</dd>
        <dt>Comprobante</dt><dd class="mono">${esc(k.numero || "—")}</dd>
        <dt>Resultado</dt><dd><span class="pildora ${pildora}">${esc(NOMBRE_ESTADO[k.estado] || k.estado)}</span>
          ${k.codigo ? ` <span class="mono">código ${esc(k.codigo)}</span>` : ""}</dd>
        <dt>Qué dijo</dt><dd>${esc(k.mensaje || "—")}</dd>
        <dt>Contra la anterior</dt><dd>${esc(k.cambio || "todavía no se compara")}</dd>
      </dl>
    </div>`;
}

function enlazarMadrugada() {
  document.querySelectorAll("[data-corrida]").forEach(b => b.onclick = () => {
    casoAbierto = { corrida: Number(b.dataset.corrida), caso: b.dataset.caso };
    pintar();
  });

  const boton = elem("correr-madrugada");
  if (boton) boton.onclick = async () => {
    boton.disabled = true;
    boton.textContent = "Corriendo…";
    try {
      const r = await pedir("/admin/vigilancia/madrugada/correr", { method: "POST" });
      avisar("Prueba en marcha", r.mensaje, "ok");
      setTimeout(cargar, 4000);
    } catch (e) {
      avisar(e.message, e.detalle, "mal");
      boton.disabled = false;
      boton.textContent = "Correr ahora";
    }
  };

  // Mientras corre, la pantalla se actualiza sola cada 15 segundos.
  clearTimeout(relojPantalla);
  if (madrugada && madrugada.corriendo) relojPantalla = setTimeout(cargar, 15000);
}

// --------------------------------------------------------------- revisado
'@ }
)

$lineas = @()

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
Write-Host 'FALTA APLICAR LA MIGRACIÓN 030 (este script NO la aplica). Desde esta carpeta:' -ForegroundColor Cyan
Write-Host ''
Write-Host '  Get-Content migraciones\030_prueba_de_madrugada.sql -Raw | docker compose exec -T postgres psql -U facturacion_owner -d facturacion -v ON_ERROR_STOP=1' -ForegroundColor White
Write-Host ''
Write-Host 'Tiene que terminar en COMMIT. Después, reinicia la API del servicio.' -ForegroundColor Cyan
Write-Host ''
