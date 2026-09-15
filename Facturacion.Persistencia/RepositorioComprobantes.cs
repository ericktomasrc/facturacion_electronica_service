using System.Text.Json;
using Dapper;
using Facturacion.Cpe;

namespace Facturacion.Persistencia;

/// <summary>
/// Guarda y consulta comprobantes.
///
/// TODO lo que hace pasa por SesionTenant, así que Row Level Security está
/// siempre activo: no existe una ruta para leer o escribir sin declarar de
/// qué empresa se trata.
/// </summary>
public sealed class RepositorioComprobantes
{
    private static readonly JsonSerializerOptions OpcionesJson = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        WriteIndented = false
    };

    private readonly FabricaSesiones _sesiones;

    public RepositorioComprobantes(FabricaSesiones sesiones)
    {
        _sesiones = sesiones ?? throw new ArgumentNullException(nameof(sesiones));
    }

    /// <summary>
    /// Crea un comprobante, asignándole el correlativo que corresponda.
    ///
    /// EL COMPROBANTE ENTRA SIN CORRELATIVO. Lo asigna la base, no el llamador:
    /// permitir que venga desde afuera abriría la puerta a duplicados y saltos.
    ///
    /// Todo ocurre en una sola transacción:
    ///   1. Si hay clave de idempotencia y ya se usó, devuelve el original.
    ///   2. Reserva el siguiente correlativo de la serie.
    ///   3. Inserta el comprobante.
    ///   4. Escribe el primer asiento de la bitácora.
    ///
    /// Si algo falla, nada de eso queda: ni un correlativo quemado ni una
    /// fila a medias.
    /// </summary>
    public async Task<ComprobanteGuardado> CrearAsync(
        Guid tenantId,
        ComprobanteBase comprobante,
        string? extraJson = null,
        string? idempotencyKey = null,
        CancellationToken ct = default)
    {
        ArgumentNullException.ThrowIfNull(comprobante);

        if (comprobante.Lineas.Count == 0)
            throw new ArgumentException(
                "El comprobante no tiene líneas.", nameof(comprobante));

        await using var sesion = await _sesiones.AbrirAsync(tenantId, ct);

        // --- 1. Idempotencia --------------------------------------------------
        // Un doble clic del usuario, o un reintento del cliente tras un timeout,
        // no deben producir dos comprobantes. Se comprueba ANTES de reservar
        // correlativo: si no, cada reintento quemaría un número.

        if (!string.IsNullOrWhiteSpace(idempotencyKey))
        {
            var existente = await sesion.Conexion.QuerySingleOrDefaultAsync<ComprobanteGuardado?>(
                new CommandDefinition(
                    """
                    SELECT id               AS "Id",
                           tenant_id        AS "TenantId",
                           tipo_comprobante AS "TipoComprobante",
                           serie            AS "Serie",
                           correlativo      AS "Correlativo",
                           estado           AS "Estado",
                           importe_total    AS "ImporteTotal",
                           true             AS "YaExistia"
                      FROM comprobantes
                     WHERE tenant_id = @tenantId
                       AND idempotency_key = @idempotencyKey
                    """,
                    new { tenantId, idempotencyKey },
                    sesion.Transaccion, cancellationToken: ct));

            if (existente is not null)
            {
                await sesion.ConfirmarAsync(ct);
                return existente;
            }
        }

        // --- 2. Reservar el correlativo ---------------------------------------
        //
        // UPDATE ... RETURNING en una sola sentencia.
        //
        // POR QUÉ ASÍ Y NO CON MAX(correlativo) + 1: entre leer el máximo y
        // escribir el nuevo valor hay una ventana en la que otra transacción
        // puede leer el mismo número. Bajo carga eso pasa, y produce el error
        // más caro del sistema: dos comprobantes con el mismo número.
        //
        // El UPDATE toma el candado de la fila por sí mismo. Una transacción
        // simultánea sobre la misma serie espera hasta que esta confirme, y
        // entonces lee el valor ya incrementado. Sin ventana.

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
                new
                {
                    tenantId,
                    tipo = comprobante.TipoComprobante,
                    serie = comprobante.Serie
                },
                sesion.Transaccion, cancellationToken: ct));

        if (correlativo is null)
            throw new InvalidOperationException(
                $"No existe la serie {comprobante.Serie} para el tipo " +
                $"{comprobante.TipoComprobante}, o está inactiva. " +
                "Hay que darla de alta antes de emitir.");

        comprobante.Correlativo = correlativo.Value;

        // --- 3. Insertar el comprobante ---------------------------------------

        var totales = CalculadoraTotales.Calcular(comprobante);

        var cpeJson = JsonSerializer.Serialize(
            comprobante, comprobante.GetType(), OpcionesJson);

        var id = await sesion.Conexion.ExecuteScalarAsync<Guid>(
            new CommandDefinition(
                """
                INSERT INTO comprobantes
                    (tenant_id, tipo_comprobante, serie, correlativo,
                     fecha_emision, moneda, importe_total, estado,
                     cpe, extra, idempotency_key)
                VALUES
                    (@tenantId, @tipo, @serie, @correlativo,
                     @fechaEmision, @moneda, @importeTotal, @estado,
                     CAST(@cpe AS jsonb), CAST(@extra AS jsonb), @idempotencyKey)
                RETURNING id
                """,
                new
                {
                    tenantId,
                    tipo = comprobante.TipoComprobante,
                    serie = comprobante.Serie,
                    correlativo = correlativo.Value,
                    fechaEmision = DateOnly.FromDateTime(comprobante.FechaEmision),
                    moneda = comprobante.Moneda,
                    importeTotal = totales.ImporteTotal,
                    estado = EstadoCpe.Borrador,
                    cpe = cpeJson,
                    extra = string.IsNullOrWhiteSpace(extraJson) ? "{}" : extraJson,
                    idempotencyKey
                },
                sesion.Transaccion, cancellationToken: ct));

        // --- 4. Primer asiento de la bitácora ---------------------------------

        await InsertarIntentoAsync(
            sesion, tenantId, id, 1, null,
            new CambioEstado(EstadoCpe.Borrador, Mensaje: "Comprobante creado."),
            ct);

        await sesion.ConfirmarAsync(ct);

        return new ComprobanteGuardado(
            id, tenantId,
            comprobante.TipoComprobante, comprobante.Serie, correlativo.Value,
            EstadoCpe.Borrador, totales.ImporteTotal, YaExistia: false);
    }

    /// <summary>
    /// Registra un cambio de estado y su asiento en la bitácora.
    ///
    /// Las dos cosas van juntas a propósito: un estado que cambia sin dejar
    /// rastro es exactamente lo que no se puede explicar cuando un cliente
    /// pregunta qué pasó con su factura de hace tres meses.
    /// </summary>
    public async Task RegistrarCambioAsync(
        Guid tenantId,
        Guid comprobanteId,
        CambioEstado cambio,
        CancellationToken ct = default)
    {
        ArgumentNullException.ThrowIfNull(cambio);

        await using var sesion = await _sesiones.AbrirAsync(tenantId, ct);

        var anterior = await sesion.Conexion.QuerySingleOrDefaultAsync<string>(
            new CommandDefinition(
                "SELECT estado FROM comprobantes WHERE id = @comprobanteId FOR UPDATE",
                new { comprobanteId },
                sesion.Transaccion, cancellationToken: ct));

        if (anterior is null)
            throw new InvalidOperationException(
                $"No existe el comprobante {comprobanteId} para este tenant.");

        var intentoNro = await sesion.Conexion.ExecuteScalarAsync<short>(
            new CommandDefinition(
                """
                SELECT COALESCE(MAX(intento_nro), 0) + 1
                  FROM envio_intentos
                 WHERE comprobante_id = @comprobanteId
                """,
                new { comprobanteId },
                sesion.Transaccion, cancellationToken: ct));

        await sesion.Conexion.ExecuteAsync(new CommandDefinition(
            """
            UPDATE comprobantes
               SET estado        = @estado,
                   codigo_sunat  = COALESCE(@codigoSunat, codigo_sunat),
                   mensaje_sunat = COALESCE(@mensaje, mensaje_sunat),
                   ticket        = COALESCE(@ticket, ticket)
             WHERE id = @comprobanteId
            """,
            new
            {
                comprobanteId,
                estado = cambio.EstadoNuevo,
                codigoSunat = cambio.CodigoSunat,
                mensaje = cambio.Mensaje,
                ticket = cambio.Ticket
            },
            sesion.Transaccion, cancellationToken: ct));

        await InsertarIntentoAsync(
            sesion, tenantId, comprobanteId, intentoNro, anterior, cambio, ct);

        await sesion.ConfirmarAsync(ct);
    }

    /// <summary>Guarda las rutas de los archivos generados.</summary>
    public async Task GuardarRutasAsync(
        Guid tenantId,
        Guid comprobanteId,
        string? rutaXml = null,
        string? rutaCdr = null,
        string? rutaPdf = null,
        string? hashCpe = null,
        CancellationToken ct = default)
    {
        await using var sesion = await _sesiones.AbrirAsync(tenantId, ct);

        await sesion.Conexion.ExecuteAsync(new CommandDefinition(
            """
            UPDATE comprobantes
               SET ruta_xml = COALESCE(@rutaXml, ruta_xml),
                   ruta_cdr = COALESCE(@rutaCdr, ruta_cdr),
                   ruta_pdf = COALESCE(@rutaPdf, ruta_pdf),
                   hash_cpe = COALESCE(@hashCpe, hash_cpe)
             WHERE id = @comprobanteId
            """,
            new { comprobanteId, rutaXml, rutaCdr, rutaPdf, hashCpe },
            sesion.Transaccion, cancellationToken: ct));

        await sesion.ConfirmarAsync(ct);
    }

    public async Task<ResumenComprobante?> ObtenerAsync(
        Guid tenantId, Guid comprobanteId, CancellationToken ct = default)
    {
        await using var sesion = await _sesiones.AbrirAsync(tenantId, ct);

        var fila = await sesion.Conexion.QuerySingleOrDefaultAsync<ResumenComprobante?>(
            new CommandDefinition(ConsultaResumen + " WHERE id = @comprobanteId",
                new { comprobanteId },
                sesion.Transaccion, cancellationToken: ct));

        await sesion.ConfirmarAsync(ct);
        return fila;
    }

    public async Task<IReadOnlyList<ResumenComprobante>> ListarAsync(
        Guid tenantId, int limite = 50, CancellationToken ct = default)
    {
        await using var sesion = await _sesiones.AbrirAsync(tenantId, ct);

        var filas = await sesion.Conexion.QueryAsync<ResumenComprobante>(
            new CommandDefinition(
                ConsultaResumen + " ORDER BY creado_en DESC LIMIT @limite",
                new { limite },
                sesion.Transaccion, cancellationToken: ct));

        await sesion.ConfirmarAsync(ct);
        return filas.ToList();
    }

    /// <summary>Historial completo de intentos de un comprobante.</summary>
    public async Task<IReadOnlyList<IntentoEnvio>> HistorialAsync(
        Guid tenantId, Guid comprobanteId, CancellationToken ct = default)
    {
        await using var sesion = await _sesiones.AbrirAsync(tenantId, ct);

        var filas = await sesion.Conexion.QueryAsync<IntentoEnvio>(
            new CommandDefinition(
                """
                SELECT id              AS "Id",
                       comprobante_id  AS "ComprobanteId",
                       intento_nro     AS "IntentoNro",
                       estado_anterior AS "EstadoAnterior",
                       estado_nuevo    AS "EstadoNuevo",
                       codigo_sunat    AS "CodigoSunat",
                       mensaje         AS "Mensaje",
                       duracion_ms     AS "DuracionMs",
                       worker          AS "Worker",
                       creado_en       AS "CreadoEn"
                  FROM envio_intentos
                 WHERE comprobante_id = @comprobanteId
                 ORDER BY intento_nro
                """,
                new { comprobanteId },
                sesion.Transaccion, cancellationToken: ct));

        await sesion.ConfirmarAsync(ct);
        return filas.ToList();
    }

    /// <summary>
    /// Rutas de los archivos de un comprobante.
    ///
    /// Va por sesión de tenant, así que Row Level Security garantiza que
    /// nadie pueda pedir las rutas de otra empresa. Eso importa más de lo
    /// que parece: si este método no filtrara por tenant, bastaría adivinar
    /// un identificador para descargar la factura de un competidor.
    /// </summary>
    public async Task<ArchivosComprobante?> ObtenerRutasAsync(
        Guid tenantId, Guid comprobanteId, CancellationToken ct = default)
    {
        await using var sesion = await _sesiones.AbrirAsync(tenantId, ct);

        var fila = await sesion.Conexion.QuerySingleOrDefaultAsync<ArchivosComprobante?>(
            new CommandDefinition(
                """
                SELECT serie || '-' || lpad(correlativo::text, 8, '0') AS "Numero",
                       tipo_comprobante AS "TipoComprobante",
                       estado           AS "Estado",
                       ruta_xml         AS "RutaXml",
                       ruta_cdr         AS "RutaCdr",
                       ruta_pdf         AS "RutaPdf"
                  FROM comprobantes
                 WHERE id = @comprobanteId
                """,
                new { comprobanteId },
                sesion.Transaccion, cancellationToken: ct));

        await sesion.ConfirmarAsync(ct);
        return fila;
    }

    /// <summary>
    /// Busca un comprobante por su número. Devuelve null si no existe para
    /// este emisor.
    ///
    /// SE USA PARA VALIDAR LAS NOTAS antes de emitirlas: una nota que apunta
    /// a un comprobante inexistente la rechaza SUNAT, y para entonces ya
    /// quemaste un correlativo de la serie de notas. Comprobarlo aquí cuesta
    /// una consulta y evita ese desperdicio.
    /// </summary>
    public async Task<ResumenComprobante?> BuscarPorNumeroAsync(
        Guid tenantId,
        string tipoComprobante,
        string serie,
        int correlativo,
        CancellationToken ct = default)
    {
        await using var sesion = await _sesiones.AbrirAsync(tenantId, ct);

        var fila = await sesion.Conexion.QuerySingleOrDefaultAsync<ResumenComprobante?>(
            new CommandDefinition(
                ConsultaResumen + """
                 WHERE tipo_comprobante = @tipoComprobante
                   AND serie = @serie
                   AND correlativo = @correlativo
                """,
                new { tipoComprobante, serie, correlativo },
                sesion.Transaccion, cancellationToken: ct));

        await sesion.ConfirmarAsync(ct);
        return fila;
    }

    /// <summary>
    /// Todo lo necesario para regenerar el PDF de un comprobante.
    ///
    /// POR QUÉ EL PDF NO SE GUARDA:
    ///
    /// Es el 80% del peso del almacén y el único de los tres archivos que se
    /// puede reconstruir. El XML y el CDR son irreemplazables; el PDF sale del
    /// mismo cpe que ya está aquí.
    ///
    /// Con cien mil comprobantes diarios, guardarlo son más de dos terabytes
    /// al año. Generarlo cuando alguien lo pide reduce eso a menos de la
    /// cuarta parte, y cuesta unas décimas de segundo.
    /// </summary>
    public async Task<DatosParaPdf?> ObtenerParaPdfAsync(
        Guid tenantId, Guid comprobanteId, CancellationToken ct = default)
    {
        await using var sesion = await _sesiones.AbrirAsync(tenantId, ct);

        var fila = await sesion.Conexion.QuerySingleOrDefaultAsync<DatosParaPdf?>(
            new CommandDefinition(
                """
                SELECT serie || '-' || lpad(correlativo::text, 8, '0') AS "Numero",
                       tipo_comprobante AS "TipoComprobante",
                       estado           AS "Estado",
                       codigo_sunat     AS "CodigoSunat",
                       mensaje_sunat    AS "MensajeSunat",
                       cpe::text        AS "CpeJson",
                       ruta_xml         AS "RutaXml"
                  FROM comprobantes
                 WHERE id = @comprobanteId
                """,
                new { comprobanteId },
                sesion.Transaccion, cancellationToken: ct));

        await sesion.ConfirmarAsync(ct);
        return fila;
    }

    /// <summary>
    /// Da de alta una serie si no existe. Pensado para el arranque y las
    /// pruebas; en producción esto lo hace el panel de administración.
    /// </summary>
    public async Task AsegurarSerieAsync(
        Guid tenantId,
        string tipoComprobante,
        string serie,
        CancellationToken ct = default)
    {
        await using var sesion = await _sesiones.AbrirAsync(tenantId, ct);

        await sesion.Conexion.ExecuteAsync(new CommandDefinition(
            """
            INSERT INTO series (tenant_id, tipo_comprobante, serie)
            VALUES (@tenantId, @tipo, @serie)
            ON CONFLICT (tenant_id, tipo_comprobante, serie) DO NOTHING
            """,
            new { tenantId, tipo = tipoComprobante, serie },
            sesion.Transaccion, cancellationToken: ct));

        await sesion.ConfirmarAsync(ct);
    }

    // ------------------------------------------------------------------ interno

    private const string ConsultaResumen =
        """
        SELECT id               AS "Id",
               tipo_comprobante AS "TipoComprobante",
               serie            AS "Serie",
               correlativo      AS "Correlativo",
               fecha_emision    AS "FechaEmision",
               moneda           AS "Moneda",
               importe_total    AS "ImporteTotal",
               estado           AS "Estado",
               codigo_sunat     AS "CodigoSunat",
               mensaje_sunat    AS "MensajeSunat",
               ticket           AS "Ticket",
               creado_en        AS "CreadoEn"
          FROM comprobantes
        """;

    private static Task InsertarIntentoAsync(
        SesionTenant sesion,
        Guid tenantId,
        Guid comprobanteId,
        short intentoNro,
        string? estadoAnterior,
        CambioEstado cambio,
        CancellationToken ct) =>
        sesion.Conexion.ExecuteAsync(new CommandDefinition(
            """
            INSERT INTO envio_intentos
                (tenant_id, comprobante_id, intento_nro,
                 estado_anterior, estado_nuevo,
                 codigo_sunat, mensaje, request_raw, response_raw,
                 duracion_ms, worker)
            VALUES
                (@tenantId, @comprobanteId, @intentoNro,
                 @estadoAnterior, @estadoNuevo,
                 @codigoSunat, @mensaje, @requestRaw, @responseRaw,
                 @duracionMs, @worker)
            """,
            new
            {
                tenantId,
                comprobanteId,
                intentoNro,
                estadoAnterior,
                estadoNuevo = cambio.EstadoNuevo,
                codigoSunat = cambio.CodigoSunat,
                mensaje = cambio.Mensaje,
                requestRaw = cambio.RequestRaw,
                responseRaw = cambio.ResponseRaw,
                duracionMs = cambio.DuracionMs,
                worker = cambio.Worker ?? Environment.MachineName
            },
            sesion.Transaccion, cancellationToken: ct));

    private static Task InsertarIntentoAsync(
        SesionTenant sesion, Guid tenantId, Guid comprobanteId,
        int intentoNro, string? estadoAnterior, CambioEstado cambio,
        CancellationToken ct) =>
        InsertarIntentoAsync(
            sesion, tenantId, comprobanteId, (short)intentoNro,
            estadoAnterior, cambio, ct);
}
