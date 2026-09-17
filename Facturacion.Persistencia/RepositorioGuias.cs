using System.Text.Json;
using Dapper;
using Facturacion.Cpe;
using Npgsql;

namespace Facturacion.Persistencia;

/// <summary>Una guía guardada, con lo que el cliente necesita saber.</summary>
public record GuiaGuardada(
    Guid Id,
    string Numero,
    string TipoGuia,
    string Estado,
    DateTime FechaEmision,
    DateTime FechaTraslado,
    string DestinatarioNombre,
    string? Ticket,
    string? CodigoSunat,
    string? MensajeSunat,
    bool Duplicada = false);

/// <summary>Una guía pendiente de enviar o de consultar.</summary>
public record TrabajoGuia(
    Guid Id,
    Guid TenantId,
    string TipoGuia,
    string Numero,
    string Estado,
    string? Ticket,
    string GreJson,
    short IntentosFallidos);

/// <summary>
/// Guías de remisión en la base de datos.
///
/// SEPARADO DE LOS COMPROBANTES A PROPÓSITO. Comparten la forma —correlativo
/// atómico, estados, reintentos— pero no los datos ni el canal: una guía va
/// por REST con OAuth2 y no tiene importes.
///
/// Lo que sí comparten es la tabla de series: los tipos 09 y 31 conviven con
/// 01, 03, 07 y 08, y el correlativo se reserva con el mismo mecanismo ya
/// probado.
/// </summary>
public sealed class RepositorioGuias
{ 
    private readonly FabricaSesiones _sesiones;
    private readonly string _cadenaOperador;

    private static readonly JsonSerializerOptions Json = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        PropertyNameCaseInsensitive = true,
        DefaultIgnoreCondition =
            System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull
    };

    public RepositorioGuias(FabricaSesiones sesiones, string cadenaConexionOperador)
    {
        _sesiones = sesiones ?? throw new ArgumentNullException(nameof(sesiones));

        _cadenaOperador = cadenaConexionOperador
            ?? throw new ArgumentNullException(nameof(cadenaConexionOperador));
    }

    // ------------------------------------------------------------------ alta

    /// <summary>
    /// Da de alta una guía y reserva su correlativo.
    ///
    /// EL CORRELATIVO SE RESERVA CON UPDATE ... RETURNING, igual que en los
    /// comprobantes. Nunca con MAX+1: dos peticiones simultáneas leerían el
    /// mismo máximo y generarían el mismo número, y un correlativo duplicado
    /// no se puede arreglar después.
    /// </summary>
    public async Task<GuiaGuardada> CrearAsync(
        Guid tenantId,
        GuiaRemision guia,
        string? idempotencyKey = null,
        object? extra = null,
        CancellationToken ct = default)
    {
        await using var sesion = await _sesiones.AbrirAsync(tenantId, ct);

        // Si ya se procesó esta misma petición, se devuelve lo que salió
        // entonces en vez de emitir otra guía.
        //
        // Sin esto, un cliente que reintenta por un timeout acabaría con dos
        // guías para el mismo traslado, y anular una guía es más engorroso
        // que anular una factura.
        if (!string.IsNullOrWhiteSpace(idempotencyKey))
        {
            var previa = await sesion.Conexion.QuerySingleOrDefaultAsync<GuiaGuardada>(
                new CommandDefinition(
                    """
                    SELECT id AS "Id",
                           serie || '-' || lpad(correlativo::text, 8, '0') AS "Numero",
                           tipo_guia      AS "TipoGuia",
                           estado         AS "Estado",
                           fecha_emision  AS "FechaEmision",
                           fecha_traslado AS "FechaTraslado",
                           destinatario_nombre AS "DestinatarioNombre",
                           ticket         AS "Ticket",
                           codigo_sunat   AS "CodigoSunat",
                           mensaje_sunat  AS "MensajeSunat",
                           true           AS "Duplicada"
                      FROM guias
                     WHERE tenant_id = @tenantId AND idempotency_key = @clave
                    """,
                    new { tenantId, clave = idempotencyKey },
                    sesion.Transaccion, cancellationToken: ct));

            if (previa is not null)
            {
                await sesion.ConfirmarAsync(ct);
                return previa;
            }
        }

        var correlativo = await sesion.Conexion.ExecuteScalarAsync<int?>(
            new CommandDefinition(
                """
                UPDATE series
                   SET ultimo_correlativo = ultimo_correlativo + 1
                 WHERE tenant_id = @tenantId
                   AND tipo_comprobante = @tipo
                   AND serie = @serie
                   AND activo
                RETURNING ultimo_correlativo
                """,
                new { tenantId, tipo = CatalogosGre.TipoGuiaRemitente, serie = guia.Serie },
                sesion.Transaccion, cancellationToken: ct));

        if (correlativo is null)
        {
            throw new InvalidOperationException(
                $"La serie {guia.Serie} no existe o está cerrada para guías de " +
                "remisión. Créala en el panel antes de emitir.");
        }

        guia.Correlativo = correlativo.Value;

        var id = await sesion.Conexion.ExecuteScalarAsync<Guid>(new CommandDefinition(
            """
            INSERT INTO guias (
                tenant_id, tipo_guia, serie, correlativo,
                fecha_emision, fecha_traslado,
                motivo_traslado, modalidad_traslado,
                destinatario_doc, destinatario_nombre,
                peso_bruto, numero_bultos,
                estado, gre, extra, idempotency_key)
            VALUES (
                @tenantId, @tipo, @serie, @correlativo,
                @fechaEmision, @fechaTraslado,
                @motivo, @modalidad,
                @destDoc, @destNombre,
                @peso, @bultos,
                'BORRADOR', @gre::jsonb, @extra::jsonb, @clave)
            RETURNING id
            """,
            new
            {
                tenantId,
                tipo = CatalogosGre.TipoGuiaRemitente,
                serie = guia.Serie,
                correlativo = guia.Correlativo,
                fechaEmision = DateOnly.FromDateTime(guia.FechaEmision),
                fechaTraslado = DateOnly.FromDateTime(guia.FechaTraslado),
                motivo = guia.MotivoTraslado,
                modalidad = guia.ModalidadTraslado,
                destDoc = guia.Destinatario.NumeroDocumento,
                destNombre = guia.Destinatario.RazonSocial,
                peso = guia.PesoBruto,
                bultos = guia.NumeroBultos,

                // El modelo canónico va tal cual: es lo que se convertirá en
                // XML. Nada de "extra" toca el documento que ve SUNAT.
                gre = JsonSerializer.Serialize(guia, Json),

                extra = extra is null ? "{}" : JsonSerializer.Serialize(extra, Json),
                clave = idempotencyKey
            },
            sesion.Transaccion, cancellationToken: ct));

        await sesion.ConfirmarAsync(ct);

        return new GuiaGuardada(
            id, guia.Numero, CatalogosGre.TipoGuiaRemitente, "BORRADOR",
            guia.FechaEmision, guia.FechaTraslado,
            guia.Destinatario.RazonSocial, null, null, null);
    }

    // ------------------------------------------------------------------ cola

    /// <summary>
    /// Reclama guías pendientes de enviar o de consultar.
    ///
    /// SE CONSULTAN MÁS SEGUIDO QUE LOS RESÚMENES, y no es un detalle: la
    /// constancia aceptada debe existir ANTES de que el vehículo salga. Una
    /// factura puede esperar; una guía tiene un camión detrás.
    ///
    /// Usa SKIP LOCKED para que varios workers no se pisen.
    /// </summary>
    public async Task<IReadOnlyList<TrabajoGuia>> ReclamarAsync(
        int limite, CancellationToken ct = default)
    {
        await using var conexion = new NpgsqlConnection(_cadenaOperador);
        await conexion.OpenAsync(ct);

        var filas = await conexion.QueryAsync<TrabajoGuia>(new CommandDefinition(
            """
            WITH tomadas AS (
                SELECT id
                  FROM guias
                 WHERE estado IN ('BORRADOR', 'ENCOLADO', 'ENVIADO')
                   AND (proximo_intento_en IS NULL OR proximo_intento_en <= now())
                   AND intentos_fallidos < 8
                 ORDER BY
                   -- Las que ya tienen ticket van primero: están a un paso
                   -- de resolverse y alguien puede estar esperándolas.
                   CASE WHEN estado = 'ENVIADO' THEN 0 ELSE 1 END,
                   creado_en
                 LIMIT @limite
                 FOR UPDATE SKIP LOCKED
            )
            UPDATE guias g
               SET estado = CASE WHEN g.estado = 'BORRADOR' THEN 'ENCOLADO'
                                 ELSE g.estado END
              FROM tomadas t
             WHERE g.id = t.id
            RETURNING
                g.id          AS "Id",
                g.tenant_id   AS "TenantId",
                g.tipo_guia   AS "TipoGuia",
                g.serie || '-' || lpad(g.correlativo::text, 8, '0') AS "Numero",
                g.estado      AS "Estado",
                g.ticket      AS "Ticket",
                g.gre::text   AS "GreJson",
                g.intentos_fallidos AS "IntentosFallidos"
            """,
            new { limite }, cancellationToken: ct));

        return filas.ToList();
    }

    /// <summary>Guarda el ticket devuelto por SUNAT.</summary>
    public async Task GuardarTicketAsync(
        Guid tenantId, Guid guiaId, string ticket, string? rutaXml,
        CancellationToken ct = default)
    {
        await using var sesion = await _sesiones.AbrirAsync(tenantId, ct);

        await sesion.Conexion.ExecuteAsync(new CommandDefinition(
            """
            UPDATE guias
               SET estado = 'ENVIADO',
                   ticket = @ticket,
                   ruta_xml = COALESCE(@rutaXml, ruta_xml),
                   intentos_fallidos = 0,

                   -- Se consulta en quince segundos, no en un minuto: hay un
                   -- vehículo esperando la constancia para salir.
                   proximo_intento_en = now() + interval '15 seconds'
             WHERE id = @guiaId
            """,
            new { guiaId, ticket, rutaXml },
            sesion.Transaccion, cancellationToken: ct));

        await sesion.ConfirmarAsync(ct);
    }

    /// <summary>Guarda el resultado final.</summary>
    public async Task ResolverAsync(
        Guid tenantId, Guid guiaId, bool aceptado,
        string? codigo, string? mensaje, string? rutaCdr,
        CancellationToken ct = default)
    {
        await using var sesion = await _sesiones.AbrirAsync(tenantId, ct);

        var estado = aceptado ? "ACEPTADO" : "RECHAZADO";

        await sesion.Conexion.ExecuteAsync(new CommandDefinition(
            """
            UPDATE guias
               SET estado = @estado,
                   codigo_sunat = @codigo,
                   mensaje_sunat = @mensaje,
                   ruta_cdr = COALESCE(@rutaCdr, ruta_cdr),
                   proximo_intento_en = NULL,
                   intentos_fallidos = 0
             WHERE id = @guiaId
            """,
            new { guiaId, estado, codigo, mensaje, rutaCdr },
            sesion.Transaccion, cancellationToken: ct));

        await sesion.ConfirmarAsync(ct);
    }

    /// <summary>
    /// Anota un fallo y programa el siguiente intento.
    ///
    /// La espera crece con cada fallo, pero MUCHO MÁS DESPACIO que en las
    /// facturas. Ahí el primer reintento llega al minuto y el quinto a las
    /// seis horas; aquí sería inútil, porque para entonces el traslado ya
    /// habría empezado sin guía o se habría cancelado.
    /// </summary>
    public async Task AnotarFalloAsync(
        Guid tenantId, Guid guiaId, string motivo, bool reintentable,
        CancellationToken ct = default)
    {
        await using var sesion = await _sesiones.AbrirAsync(tenantId, ct);

        await sesion.Conexion.ExecuteAsync(new CommandDefinition(
            """
            UPDATE guias
               SET intentos_fallidos = intentos_fallidos + 1,
                   mensaje_sunat = @motivo,

                   estado = CASE WHEN @reintentable AND intentos_fallidos < 7
                                 THEN CASE WHEN ticket IS NULL
                                           THEN 'ENCOLADO' ELSE 'ENVIADO' END
                                 ELSE 'RECHAZADO' END,

                   -- 15s, 30s, 1min, 2min, 5min, 10min, 15min.
                   proximo_intento_en = CASE
                       WHEN @reintentable AND intentos_fallidos < 7
                       THEN now() + (CASE intentos_fallidos
                               WHEN 0 THEN interval '15 seconds'
                               WHEN 1 THEN interval '30 seconds'
                               WHEN 2 THEN interval '1 minute'
                               WHEN 3 THEN interval '2 minutes'
                               WHEN 4 THEN interval '5 minutes'
                               WHEN 5 THEN interval '10 minutes'
                               ELSE interval '15 minutes' END)
                       ELSE NULL END
             WHERE id = @guiaId
            """,
            new { guiaId, motivo, reintentable },
            sesion.Transaccion, cancellationToken: ct));

        await sesion.ConfirmarAsync(ct);
    }

    // -------------------------------------------------------------- consulta

    public async Task<GuiaGuardada?> ObtenerAsync(
        Guid tenantId, Guid guiaId, CancellationToken ct = default)
    {
        await using var sesion = await _sesiones.AbrirAsync(tenantId, ct);

        var fila = await sesion.Conexion.QuerySingleOrDefaultAsync<GuiaGuardada>(
            new CommandDefinition(
                """
                SELECT id AS "Id",
                       serie || '-' || lpad(correlativo::text, 8, '0') AS "Numero",
                       tipo_guia      AS "TipoGuia",
                       estado         AS "Estado",
                       fecha_emision  AS "FechaEmision",
                       fecha_traslado AS "FechaTraslado",
                       destinatario_nombre AS "DestinatarioNombre",
                       ticket         AS "Ticket",
                       codigo_sunat   AS "CodigoSunat",
                       mensaje_sunat  AS "MensajeSunat",
                       false          AS "Duplicada"
                  FROM guias
                 WHERE id = @guiaId
                """,
                new { guiaId }, sesion.Transaccion, cancellationToken: ct));

        await sesion.ConfirmarAsync(ct);
        return fila;
    }

    public async Task<IReadOnlyList<GuiaGuardada>> ListarAsync(
        Guid tenantId, int limite = 50, CancellationToken ct = default)
    {
        await using var sesion = await _sesiones.AbrirAsync(tenantId, ct);

        var filas = await sesion.Conexion.QueryAsync<GuiaGuardada>(
            new CommandDefinition(
                """
                SELECT id AS "Id",
                       serie || '-' || lpad(correlativo::text, 8, '0') AS "Numero",
                       tipo_guia      AS "TipoGuia",
                       estado         AS "Estado",
                       fecha_emision  AS "FechaEmision",
                       fecha_traslado AS "FechaTraslado",
                       destinatario_nombre AS "DestinatarioNombre",
                       ticket         AS "Ticket",
                       codigo_sunat   AS "CodigoSunat",
                       mensaje_sunat  AS "MensajeSunat",
                       false          AS "Duplicada"
                  FROM guias
                 ORDER BY creado_en DESC
                 LIMIT @limite
                """,
                new { limite }, sesion.Transaccion, cancellationToken: ct));

        await sesion.ConfirmarAsync(ct);
        return filas.ToList();
    }

    /// <summary>Rutas de los archivos, para descargarlos.</summary>
    public async Task<(string Numero, string Estado, string? Xml, string? Cdr)?>
        RutasAsync(Guid tenantId, Guid guiaId, CancellationToken ct = default)
    {
        await using var sesion = await _sesiones.AbrirAsync(tenantId, ct);

        var fila = await sesion.Conexion
            .QuerySingleOrDefaultAsync<(string, string, string?, string?)?>(
                new CommandDefinition(
                    """
                    SELECT serie || '-' || lpad(correlativo::text, 8, '0') AS "Numero",
                           estado   AS "Estado",
                           ruta_xml AS "Xml",
                           ruta_cdr AS "Cdr"
                      FROM guias
                     WHERE id = @guiaId
                    """,
                    new { guiaId }, sesion.Transaccion, cancellationToken: ct));

        await sesion.ConfirmarAsync(ct);
        return fila;
    }

    /// <summary>Reconstruye el modelo desde lo guardado.</summary>
    public static GuiaRemision Deserializar(string greJson) =>
        JsonSerializer.Deserialize<GuiaRemision>(greJson, Json)
            ?? throw new InvalidOperationException(
                "La guía guardada no se pudo leer. El JSON está corrupto.");
}
