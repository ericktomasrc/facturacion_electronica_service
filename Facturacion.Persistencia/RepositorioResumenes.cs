using Dapper;
using Npgsql;

namespace Facturacion.Persistencia;

/// <summary>Estados de un resumen.</summary>
public static class EstadoResumenCpe
{
    public const string Borrador = "BORRADOR";
    public const string Encolado = "ENCOLADO";

    /// <summary>
    /// SUNAT recibió el resumen y devolvió un ticket, pero todavía no dijo
    /// si lo acepta. Es un estado propio de este flujo: en las facturas no
    /// existe, porque ahí la respuesta llega de inmediato.
    /// </summary>
    public const string Enviado = "ENVIADO";

    public const string Aceptado = "ACEPTADO";
    public const string ConObservaciones = "ACEPTADO_CON_OBSERVACIONES";
    public const string Rechazado = "RECHAZADO";
}

/// <summary>Una boleta esperando a ser comunicada.</summary>
///
/// LAS FECHAS SE DECLARAN COMO DateTime, NO DateOnly.
///
/// Dapper lee las columnas de tipo date como DateTime, y si el record las
/// declara como DateOnly no encuentra un constructor que encaje. El error
/// que produce habla de constructores, no de tipos de fecha, así que manda
/// a buscar en la dirección equivocada.
///
/// Es el mismo desajuste que con count(*) devolviendo bigint. Alinear los
/// tipos con lo que el driver entrega sale más barato que pelearse con el
/// mapeo.
public record BoletaPendiente(
    Guid Id,
    string Serie,
    int Correlativo,
    DateTime FechaEmision,
    string Moneda,
    string CpeJson)
{
    public string NumeroCompleto => $"{Serie}-{Correlativo:D8}";
}

/// <summary>Un grupo de boletas del mismo emisor y la misma fecha.</summary>
public record LotePendiente(
    Guid TenantId,
    DateTime FechaEmision,
    int Cantidad);

/// <summary>Un resumen, tal como está guardado.</summary>
public record ResumenGuardado(
    Guid Id,
    Guid TenantId,
    string Tipo,
    string Identificador,
    DateTime FechaReferencia,
    DateTime FechaGeneracion,
    int Correlativo,
    string Estado,
    string? Ticket,
    string? CodigoSunat,
    string? MensajeSunat,
    int Comprobantes,
    short IntentosFallidos,
    DateTime CreadoEn);

/// <summary>
/// Guarda y consulta resúmenes diarios.
///
/// Usa el rol de operador para buscar trabajo entre todas las empresas, igual
/// que la cola de comprobantes: el proceso que arma resúmenes es
/// infraestructura, no un cliente.
/// </summary>
public sealed class RepositorioResumenes
{
    private readonly string _cadenaOperador;

    public RepositorioResumenes(string cadenaConexionOperador)
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
    /// Busca grupos de boletas listas para agruparse en un resumen.
    ///
    /// SE AGRUPAN POR EMISOR Y POR FECHA DE EMISIÓN, no por fecha de creación:
    /// un resumen informa los comprobantes de UN día concreto. Mezclar días
    /// distintos en un resumen lo hace rechazable.
    ///
    /// Solo se toman fechas ya cerradas. Agrupar las boletas de hoy dejaría
    /// fuera las que se emitan en lo que resta del día, y habría que enviar
    /// un segundo resumen por la misma fecha, que se puede pero complica la
    /// conciliación sin necesidad.
    /// </summary>
    public async Task<IReadOnlyList<LotePendiente>> BuscarLotesAsync(
        CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);

        var filas = await conexion.QueryAsync<LotePendiente>(
            new CommandDefinition(
                """
                SELECT tenant_id      AS "TenantId",
                       fecha_emision  AS "FechaEmision",
                       count(*)::int  AS "Cantidad"
                  FROM comprobantes
                 WHERE tipo_comprobante = '03'
                   AND estado = 'BORRADOR'
                   AND resumen_id IS NULL
                   AND fecha_emision < current_date
                 GROUP BY tenant_id, fecha_emision
                 ORDER BY fecha_emision
                """,
                cancellationToken: ct));

        return filas.ToList();
    }

    /// <summary>
    /// Crea el resumen y le asigna las boletas del lote, en una sola
    /// transacción.
    ///
    /// La asignación marca las boletas con el identificador del resumen y las
    /// pasa a ENCOLADO, así que dejan de estar disponibles para otro proceso.
    /// Si algo falla, no queda ni el resumen ni las boletas a medio asignar.
    /// </summary>
    public async Task<(ResumenGuardado Resumen, IReadOnlyList<BoletaPendiente> Boletas)?>
        ArmarResumenAsync(
            Guid tenantId, DateTime fechaEmision, CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);
        await using var transaccion = await conexion.BeginTransactionAsync(ct);

        var hoy = DateTime.Today;

        // Correlativo del resumen dentro del día de generación.
        //
        // Se calcula dentro de la transacción y la restricción única de la
        // tabla respalda el resultado: si dos procesos lo intentaran a la vez,
        // uno de los dos fallaría en vez de crear dos resúmenes con el mismo
        // identificador.
        var correlativo = await conexion.ExecuteScalarAsync<int>(
            new CommandDefinition(
                """
                SELECT COALESCE(MAX(correlativo), 0) + 1
                  FROM resumenes
                 WHERE tenant_id = @tenantId
                   AND tipo = 'RC'
                   AND fecha_generacion = @hoy
                """,
                new { tenantId, hoy = DateOnly.FromDateTime(hoy) },
                transaccion, cancellationToken: ct));

        var identificador = $"RC-{hoy:yyyyMMdd}-{correlativo}";

        var resumenId = await conexion.ExecuteScalarAsync<Guid>(
            new CommandDefinition(
                """
                INSERT INTO resumenes
                    (tenant_id, tipo, identificador, fecha_referencia,
                     fecha_generacion, correlativo, estado)
                VALUES
                    (@tenantId, 'RC', @identificador, @fechaEmision,
                     @hoy, @correlativo, 'ENCOLADO')
                RETURNING id
                """,
                new
                {
                    tenantId,
                    identificador,
                    fechaEmision = DateOnly.FromDateTime(fechaEmision),
                    hoy = DateOnly.FromDateTime(hoy),
                    correlativo
                },
                transaccion, cancellationToken: ct));

        // Asignar las boletas. FOR UPDATE SKIP LOCKED evita que dos procesos
        // se lleven la misma boleta si algún día hay varios armando resúmenes.
        var boletas = (await conexion.QueryAsync<BoletaPendiente>(
            new CommandDefinition(
                """
                WITH candidatas AS (
                    SELECT id
                      FROM comprobantes
                     WHERE tenant_id = @tenantId
                       AND tipo_comprobante = '03'
                       AND estado = 'BORRADOR'
                       AND resumen_id IS NULL
                       AND fecha_emision = @fechaEmision
                     ORDER BY correlativo
                     FOR UPDATE SKIP LOCKED
                )
                UPDATE comprobantes c
                   SET resumen_id = @resumenId,
                       estado = 'ENCOLADO'
                  FROM candidatas
                 WHERE c.id = candidatas.id
                RETURNING c.id            AS "Id",
                          c.serie         AS "Serie",
                          c.correlativo   AS "Correlativo",
                          c.fecha_emision AS "FechaEmision",
                          c.moneda        AS "Moneda",
                          c.cpe::text     AS "CpeJson"
                """,
                new
                {
                    tenantId,
                    fechaEmision = DateOnly.FromDateTime(fechaEmision),
                    resumenId
                },
                transaccion, cancellationToken: ct))).ToList();

        if (boletas.Count == 0)
        {
            // Otro proceso se las llevó entre la búsqueda y ahora. El resumen
            // vacío no sirve de nada, así que se deshace todo.
            await transaccion.RollbackAsync(ct);
            return null;
        }

        await conexion.ExecuteAsync(new CommandDefinition(
            "UPDATE resumenes SET comprobantes = @cantidad WHERE id = @resumenId",
            new { resumenId, cantidad = boletas.Count },
            transaccion, cancellationToken: ct));

        await transaccion.CommitAsync(ct);

        var resumen = new ResumenGuardado(
            resumenId, tenantId, "RC", identificador,
            fechaEmision.Date, hoy,
            correlativo, EstadoResumenCpe.Encolado, null, null, null,
            boletas.Count, 0, DateTime.UtcNow);

        return (resumen, boletas);
    }

    /// <summary>Guarda el ticket devuelto por SUNAT y pasa a ENVIADO.</summary>
    public async Task RegistrarTicketAsync(
        Guid resumenId, string ticket, string? rutaXml,
        CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);

        await conexion.ExecuteAsync(new CommandDefinition(
            """
            UPDATE resumenes
               SET estado = 'ENVIADO',
                   ticket = @ticket,
                   ruta_xml = COALESCE(@rutaXml, ruta_xml),
                   intentos_fallidos = 0,
                   proximo_intento_en = NULL
             WHERE id = @resumenId
            """,
            new { resumenId, ticket, rutaXml }, cancellationToken: ct));
    }

    /// <summary>
    /// Resúmenes cuyo ticket falta consultar.
    ///
    /// Se consultan con espera creciente: SUNAT tarda en procesar y preguntar
    /// cada cinco segundos no acelera nada, solo gasta peticiones.
    /// </summary>
    public async Task<IReadOnlyList<ResumenGuardado>> BuscarTicketsPendientesAsync(
        int limite = 10, CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);

        var filas = await conexion.QueryAsync<ResumenGuardado>(
            new CommandDefinition(
                ConsultaResumen + """
                 WHERE estado = 'ENVIADO'
                   AND ticket IS NOT NULL
                   AND (proximo_intento_en IS NULL OR proximo_intento_en <= now())
                 ORDER BY proximo_intento_en NULLS FIRST, creado_en
                 LIMIT @limite
                """,
                new { limite }, cancellationToken: ct));

        return filas.ToList();
    }

    /// <summary>Resúmenes listos para enviarse.</summary>
    public async Task<IReadOnlyList<ResumenGuardado>> BuscarPorEnviarAsync(
        int limite = 10, CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);

        var filas = await conexion.QueryAsync<ResumenGuardado>(
            new CommandDefinition(
                ConsultaResumen + """
                 WHERE estado IN ('BORRADOR','ENCOLADO')
                   AND (proximo_intento_en IS NULL OR proximo_intento_en <= now())
                 ORDER BY proximo_intento_en NULLS FIRST, creado_en
                 LIMIT @limite
                """,
                new { limite }, cancellationToken: ct));

        return filas.ToList();
    }

    /// <summary>Las boletas que informa un resumen.</summary>
    public async Task<IReadOnlyList<BoletaPendiente>> BoletasDeAsync(
        Guid resumenId, CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);

        var filas = await conexion.QueryAsync<BoletaPendiente>(
            new CommandDefinition(
                """
                SELECT id            AS "Id",
                       serie         AS "Serie",
                       correlativo   AS "Correlativo",
                       fecha_emision AS "FechaEmision",
                       moneda        AS "Moneda",
                       cpe::text     AS "CpeJson"
                  FROM comprobantes
                 WHERE resumen_id = @resumenId
                 ORDER BY correlativo
                """,
                new { resumenId }, cancellationToken: ct));

        return filas.ToList();
    }

    /// <summary>
    /// Cierra un resumen y arrastra a sus boletas al mismo desenlace.
    ///
    /// LAS DOS COSAS VAN JUNTAS a propósito: una boleta cuyo resumen fue
    /// aceptado está comunicada, y una cuyo resumen fue rechazado no lo está.
    /// Dejar las boletas con un estado distinto al de su resumen sería
    /// mentirle al cliente sobre si su venta está declarada.
    /// </summary>
    public async Task CerrarAsync(
        Guid resumenId, string estado, string? codigoSunat, string? mensaje,
        string? rutaCdr = null, CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);
        await using var transaccion = await conexion.BeginTransactionAsync(ct);

        await conexion.ExecuteAsync(new CommandDefinition(
            """
            UPDATE resumenes
               SET estado = @estado,
                   codigo_sunat = @codigoSunat,
                   mensaje_sunat = @mensaje,
                   ruta_cdr = COALESCE(@rutaCdr, ruta_cdr)
             WHERE id = @resumenId
            """,
            new { resumenId, estado, codigoSunat, mensaje, rutaCdr },
            transaccion, cancellationToken: ct));

        await conexion.ExecuteAsync(new CommandDefinition(
            """
            UPDATE comprobantes
               SET estado = @estado,
                   codigo_sunat = @codigoSunat,
                   mensaje_sunat = @mensaje
             WHERE resumen_id = @resumenId
            """,
            new { resumenId, estado, codigoSunat, mensaje },
            transaccion, cancellationToken: ct));

        await transaccion.CommitAsync(ct);
    }

    /// <summary>Programa un reintento con espera creciente.</summary>
    public async Task ProgramarReintentoAsync(
        Guid resumenId, TimeSpan espera, string? mensaje = null,
        CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);

        await conexion.ExecuteAsync(new CommandDefinition(
            """
            UPDATE resumenes
               SET intentos_fallidos = intentos_fallidos + 1,
                   proximo_intento_en = now() + @espera::interval,
                   mensaje_sunat = COALESCE(@mensaje, mensaje_sunat)
             WHERE id = @resumenId
            """,
            new
            {
                resumenId,
                espera = $"{(int)espera.TotalSeconds} seconds",
                mensaje
            },
            cancellationToken: ct));
    }

    /// <summary>Devuelve un resumen a BORRADOR sin perder el vínculo con sus boletas.</summary>
    public async Task DevolverACorreccionAsync(
        Guid resumenId, CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);

        await conexion.ExecuteAsync(new CommandDefinition(
            "UPDATE resumenes SET estado = 'ENCOLADO' WHERE id = @resumenId",
            new { resumenId }, cancellationToken: ct));
    }

    /// <summary>Lista los resúmenes de una empresa, para el panel.</summary>
    public async Task<IReadOnlyList<ResumenGuardado>> ListarAsync(
        Guid tenantId, int limite = 50, CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);

        var filas = await conexion.QueryAsync<ResumenGuardado>(
            new CommandDefinition(
                ConsultaResumen + """
                 WHERE tenant_id = @tenantId
                 ORDER BY creado_en DESC
                 LIMIT @limite
                """,
                new { tenantId, limite }, cancellationToken: ct));

        return filas.ToList();
    }

    private const string ConsultaResumen =
        """
        SELECT id                AS "Id",
               tenant_id         AS "TenantId",
               tipo              AS "Tipo",
               identificador     AS "Identificador",
               fecha_referencia  AS "FechaReferencia",
               fecha_generacion  AS "FechaGeneracion",
               correlativo       AS "Correlativo",
               estado            AS "Estado",
               ticket            AS "Ticket",
               codigo_sunat      AS "CodigoSunat",
               mensaje_sunat     AS "MensajeSunat",
               comprobantes      AS "Comprobantes",
               intentos_fallidos AS "IntentosFallidos",
               creado_en         AS "CreadoEn"
          FROM resumenes
        """;
}
