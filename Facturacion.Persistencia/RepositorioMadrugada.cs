using Dapper;
using Npgsql;

namespace Facturacion.Persistencia;

/// <summary>La empresa interna de la prueba de madrugada.</summary>
public record ConfigMadrugada(Guid TenantId, byte[] ClaveCifrada, string Ruc, string RazonSocial,
    DateTime PreparadaEn, string PreparadaPor);

/// <summary>Una serie de la empresa de control, para verla en el panel.</summary>
public record SerieControl(string Tipo, string Serie, int Ultimo);

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

            // LA ANULACIÓN DE BOLETA sigue al comprobante anulado: mientras la
            // boleta siga ACEPTADA, la anulación todavía no se completó. Si pasa
            // día y medio sin llegar a ANULADO cuenta como «SUNAT no respondió»
            // (gris, sin alarma): desde aquí no se distingue un rechazo de su
            // resumen de una caída de beta, y una falsa alarma es peor.
            if (Caso == "anular-boleta" && EstadoDoc is "ACEPTADO" or "ACEPTADO_CON_OBSERVACIONES")
                return EnviadoEn is { } e && DateTime.UtcNow - e.ToUniversalTime() > TimeSpan.FromHours(36)
                    ? "caida" : "pend";

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

    /// <summary>
    /// «Empresa de control» (17 oct): sus series y cuándo vence su certificado
    /// de prueba. Solo lectura.
    /// </summary>
    public async Task<(IReadOnlyList<SerieControl> Series, DateTime? CertificadoVence)> ControlAsync(
        Guid tenantId, CancellationToken ct = default)
    {
        await using var c = await AbrirAsync(ct);

        var series = (await c.QueryAsync<SerieControl>(new CommandDefinition(
            """
            SELECT tipo_comprobante   AS "Tipo",
                   serie              AS "Serie",
                   ultimo_correlativo AS "Ultimo"
              FROM series
             WHERE tenant_id = @tenantId AND activo
             ORDER BY tipo_comprobante, serie
            """,
            new { tenantId }, cancellationToken: ct))).ToList();

        var vence = await c.ExecuteScalarAsync<DateTime?>(new CommandDefinition(
            "SELECT max(valido_hasta) FROM certificados WHERE tenant_id = @tenantId AND activo",
            new { tenantId }, cancellationToken: ct));

        return (series, vence);
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

    /// <summary>
    /// La «boleta para anular» más reciente de una corrida anterior que SUNAT ya
    /// aceptó, sin anulación pedida y emitida desde <paramref name="desde"/>
    /// (el plazo para anular una boleta es de siete días).
    /// </summary>
    public async Task<(Guid Id, string Numero)?> BoletaParaAnularAsync(
        long antesDe, DateOnly desde, CancellationToken ct = default)
    {
        await using var c = await AbrirAsync(ct);

        var fila = await c.QuerySingleOrDefaultAsync<FilaBoleta>(new CommandDefinition(
            """
            SELECT k.comprobante_id AS "Id", k.numero AS "Numero"
              FROM pruebas_madrugada_casos k
              JOIN comprobantes c ON c.id = k.comprobante_id
             WHERE k.caso = 'boleta-para-anular'
               AND k.prueba_id < @antesDe
               AND k.numero IS NOT NULL
               AND c.estado IN ('ACEPTADO', 'ACEPTADO_CON_OBSERVACIONES')
               AND c.baja_motivo IS NULL
               AND c.baja_id IS NULL
               AND c.fecha_emision >= @desde
             ORDER BY k.prueba_id DESC
             LIMIT 1
            """,
            new { antesDe, desde = desde.ToDateTime(TimeOnly.MinValue) }, cancellationToken: ct));

        return fila is null ? null : (fila.Id, fila.Numero);
    }

    private sealed record FilaBoleta(Guid Id, string Numero);

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