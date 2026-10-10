using Facturacion.Cpe;
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
/// EstadoLinea ES PARÁMETRO DEL RECORD Y NO UNA PROPIEDAD SUELTA, y se
/// intentó al revés primero.
///
/// Dapper, para un tipo sin constructor sin parámetros, busca uno que
/// encaje con TODAS las columnas que devuelve la consulta. Declararlo como
/// propiedad aparte y devolverlo igualmente en el SELECT lo deja buscando
/// un constructor de siete argumentos que no existe, y revienta con un
/// mensaje que habla de constructores y no de lo que pasa:
///
///     A parameterless default constructor or one matching signature
///     (Guid Id, String Serie, ... Int16 EstadoLinea) is required
///
/// Es el mismo desajuste que el de las fechas de arriba: Dapper decide, y
/// alinearse con él sale más barato que pelearse.
///
/// El valor por defecto 1 está para el código C# que construya uno a mano;
/// las consultas lo devuelven siempre, explícito.
public record BoletaPendiente(
    Guid Id,
    string Serie,
    int Correlativo,
    DateTime FechaEmision,
    string Moneda,
    string CpeJson,
    short EstadoLinea = 1)
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

    // -----------------------------------------------------------------------
    // ANULACIÓN DE BOLETAS
    // -----------------------------------------------------------------------
    //
    // UNA BOLETA NO SE DA DE BAJA CON UNA COMUNICACIÓN RA. Se anula volviendo
    // a informarla en un resumen diario, esta vez con el estado 3 del
    // catálogo 19. Es el mismo documento que la comunicó la primera vez, con
    // otra intención dentro.
    //
    // Eso obliga a un segundo vínculo entre la boleta y un resumen:
    //
    //     resumen_id  el resumen que la INFORMÓ
    //     baja_id     el resumen que la ANULA
    //
    // Son dos resúmenes distintos y los dos tienen que quedar registrados:
    // el primero prueba que la venta se declaró, el segundo que se deshizo.
    // Una sola columna no puede contar esa historia.
    //
    // `baja_id` es la misma columna que usan las facturas para su comunicación
    // RA, y no es casualidad ni ahorro: significa exactamente lo mismo —el
    // documento que mata a este comprobante—, solo que para una factura ese
    // documento es una RA y para una boleta es un RC con estado 3.

    /// <summary>
    /// Boletas que alguien pidió anular y todavía no viajan en ningún
    /// resumen.
    ///
    /// La marca es `baja_motivo` puesto y `baja_id` vacío: el motivo lo
    /// escribe el endpoint cuando se pide la anulación, y el identificador
    /// lo pone este repositorio al armar el resumen. Entre esos dos momentos
    /// la boleta está esperando, y eso es justo lo que busca esta consulta.
    /// </summary>
    public async Task<IReadOnlyList<LotePendiente>> BuscarLotesDeAnulacionAsync(
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
                 WHERE tipo_comprobante IN ('03','07','08')
                   AND serie LIKE 'B%'
                   AND estado IN ('ACEPTADO','ACEPTADO_CON_OBSERVACIONES')
                   AND baja_motivo IS NOT NULL
                   AND baja_id IS NULL
                 GROUP BY tenant_id, fecha_emision
                 ORDER BY fecha_emision
                """,
                cancellationToken: ct));

        return filas.ToList();
    }

    /// <summary>
    /// Crea el resumen que anula las boletas marcadas de un día.
    ///
    /// SE AGRUPA POR FECHA DE EMISIÓN, igual que el resumen normal: el
    /// documento lleva un solo ReferenceDate y tiene que ser el día en que
    /// se emitieron las boletas que anula, no el día en que se pidió
    /// anularlas.
    ///
    /// LAS ANULACIONES VIAJAN EN SU PROPIO RESUMEN y no mezcladas con las
    /// altas del día. SUNAT admitiría las dos cosas juntas, pero entonces un
    /// rechazo por una anulación se llevaría por delante las ventas del día,
    /// que no tenían nada que ver. Separados, cada fallo solo se arrastra a
    /// sí mismo.
    ///
    /// Devuelve null si entre la búsqueda y ahora ya no quedaba ninguna.
    /// </summary>
    public async Task<(ResumenGuardado Resumen, IReadOnlyList<BoletaPendiente> Boletas)?>
        ArmarResumenDeAnulacionAsync(
            Guid tenantId, DateTime fechaEmision, CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);
        await using var transaccion = await conexion.BeginTransactionAsync(ct);

        var hoy = RelojPeru.Hoy;

        // El correlativo es el MISMO CONTADOR que el de los resúmenes de
        // altas, y tiene que serlo: para SUNAT los dos son RC del mismo día
        // y el identificador no se puede repetir.
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

        // LAS BOLETAS NO CAMBIAN DE ESTADO AQUÍ, y esa es la diferencia con
        // el resumen de altas.
        //
        // Una boleta que se va a anular sigue ACEPTADA mientras SUNAT no
        // confirme la anulación. Pasarla a ENCOLADO diría que dejó de estar
        // declarada, y no es verdad: lo está, y lo seguirá estando si la
        // anulación se rechaza.
        var boletas = (await conexion.QueryAsync<BoletaPendiente>(
            new CommandDefinition(
                """
                WITH candidatas AS (
                    SELECT id
                      FROM comprobantes
                     WHERE tenant_id = @tenantId
                       AND tipo_comprobante IN ('03','07','08')
                       AND serie LIKE 'B%'
                       AND estado IN ('ACEPTADO','ACEPTADO_CON_OBSERVACIONES')
                       AND baja_motivo IS NOT NULL
                       AND baja_id IS NULL
                       AND fecha_emision = @fechaEmision
                     ORDER BY correlativo
                     FOR UPDATE SKIP LOCKED
                )
                UPDATE comprobantes c
                   SET baja_id = @resumenId
                  FROM candidatas
                 WHERE c.id = candidatas.id
                RETURNING c.id            AS "Id",
                          c.serie         AS "Serie",
                          c.correlativo   AS "Correlativo",
                          c.fecha_emision AS "FechaEmision",
                          c.moneda        AS "Moneda",
                          c.cpe::text     AS "CpeJson",
                          3::smallint     AS "EstadoLinea"
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

        var hoy = RelojPeru.Hoy;

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
                          c.cpe::text     AS "CpeJson",
                          1::smallint     AS "EstadoLinea"
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
                 WHERE tipo = 'RC'
                   AND estado = 'ENVIADO'
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
                 WHERE tipo = 'RC'
                   AND estado IN ('BORRADOR','ENCOLADO')
                   AND (proximo_intento_en IS NULL OR proximo_intento_en <= now())
                 ORDER BY proximo_intento_en NULLS FIRST, creado_en
                 LIMIT @limite
                """,
                new { limite }, cancellationToken: ct));

        return filas.ToList();
    }

    /// <summary>
    /// Las boletas que informa un resumen, sea para darlas de alta o para
    /// anularlas.
    ///
    /// LAS DOS COSAS SALEN DE LA MISMA CONSULTA porque el resumen es el
    /// mismo documento: lo único que cambia es el estado de cada línea, y
    /// eso lo dice de qué columna cuelga la boleta.
    ///
    ///     resumen_id = este resumen   →  1, se informa
    ///     baja_id    = este resumen   →  3, se anula
    ///
    /// Un resumen tiene boletas por una vía o por la otra, nunca por las
    /// dos: las anulaciones viajan siempre en su propio envío.
    /// </summary>
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
                       cpe::text     AS "CpeJson",
                       CASE WHEN baja_id = @resumenId THEN 3 ELSE 1 END::smallint
                                     AS "EstadoLinea"
                  FROM comprobantes
                 WHERE resumen_id = @resumenId
                    OR baja_id = @resumenId
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

        // --- Y AHORA LAS QUE COLGABAN DE baja_id, que son otra historia ------
        //
        // Esas boletas no se estaban informando: se estaban anulando. El
        // desenlace del resumen significa para ellas lo contrario que para
        // las de arriba.
        //
        //   ACEPTADO   → ANULADO. La anulación llegó y surtió efecto.
        //
        //   RECHAZADO  → siguen ACEPTADAS, tal cual estaban. Se les suelta
        //                el vínculo Y el motivo, para que no vuelvan a la
        //                cola solas: quien quiera anularlas otra vez tiene
        //                que pedirlo de nuevo, sabiendo por qué falló la
        //                primera vez. Dejarlas marcadas las haría reintentar
        //                en bucle contra el mismo rechazo.

        var aceptado = estado is EstadoResumenCpe.Aceptado
            or EstadoResumenCpe.ConObservaciones;

        if (aceptado)
        {
            await conexion.ExecuteAsync(new CommandDefinition(
                """
                UPDATE comprobantes
                   SET estado = 'ANULADO',
                       codigo_sunat = @codigoSunat,
                       mensaje_sunat = @mensaje
                 WHERE baja_id = @resumenId
                """,
                new { resumenId, codigoSunat, mensaje },
                transaccion, cancellationToken: ct));
        }
        else
        {
            await conexion.ExecuteAsync(new CommandDefinition(
                """
                UPDATE comprobantes
                   SET baja_id = NULL,
                       baja_motivo = NULL,
                       mensaje_sunat = @mensaje
                 WHERE baja_id = @resumenId
                """,
                new { resumenId, mensaje },
                transaccion, cancellationToken: ct));
        }

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
                 WHERE tipo = 'RC'
                   AND tenant_id = @tenantId
                 ORDER BY creado_en DESC
                 LIMIT @limite
                """,
                new { tenantId, limite }, cancellationToken: ct));

        return filas.ToList();
    }

    // TODAS LAS BUSQUEDAS FILTRAN POR tipo = 'RC', Y NO SOBRA.
    //
    // La tabla `resumenes` guarda tres documentos distintos: los resumenes
    // diarios (RC), las comunicaciones de baja (RA) y los resumenes de
    // reversiones (RR). Los tres tienen estado, ticket y reintentos, y por
    // eso comparten tabla.
    //
    // Sin el filtro, este repositorio se llevaba tambien las filas de los
    // otros dos y ProcesadorResumenes intentaba enviarlas como si fueran
    // resumenes de boletas. SUNAT lo rechazaba con el error 2513, quejandose
    // del formato del numero de linea — un mensaje que no menciona en ningun
    // sitio que el documento entero era de otra clase.
    //
    // El bug estuvo ahi desde que se creo la comunicacion de baja y no se vio
    // por pura suerte: el servicio de bajas corre cada 30 segundos y el de
    // resumenes cada 60, asi que las bajas se cerraban antes de que este
    // repositorio las viera.

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