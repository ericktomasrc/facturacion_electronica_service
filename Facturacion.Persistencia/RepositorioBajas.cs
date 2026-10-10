using Dapper;
using Facturacion.Cpe;
using Npgsql;

namespace Facturacion.Persistencia;

/// <summary>Un comprobante que entra en una comunicación de baja.</summary>
///
/// LAS FECHAS VAN COMO DateTime Y NO COMO DateOnly, por el mismo motivo que
/// en BoletaPendiente: Dapper lee las columnas `date` como DateTime, y si el
/// record declara DateOnly no encuentra constructor que encaje. El error que
/// suelta habla de constructores y manda a buscar en la dirección equivocada.
public record ComprobanteEnBaja(
    Guid Id,
    string TipoComprobante,
    string Serie,
    int Correlativo,
    DateTime FechaEmision,
    string Motivo)
{
    public string NumeroCompleto => $"{Serie}-{Correlativo:D8}";
}

/// <summary>
/// Guarda y consulta comunicaciones de baja.
///
/// ESTA CLASE NO TIENE TABLA PROPIA: escribe en `resumenes` con tipo 'RA'.
/// El documento, el servicio de SUNAT y el ciclo de ticket son los mismos que
/// los del resumen diario, y duplicar la tabla habría significado duplicar
/// también el estado, los reintentos y el ticket, que es donde acaban
/// divergiendo dos copias.
///
/// Lo que SÍ es distinto, y por eso esta clase existe aparte:
///
///   - El resumen lo arma el worker buscando boletas de un día cerrado.
///     La baja la pide una persona, ahora, por un comprobante concreto.
///
///   - Cuando SUNAT acepta un resumen, sus boletas quedan ACEPTADAS.
///     Cuando acepta una baja, sus comprobantes quedan ANULADOS.
///
///   - Un resumen rechazado deja a sus boletas sin comunicar. Una baja
///     rechazada deja a sus comprobantes exactamente como estaban: siguen
///     siendo válidos, y se puede volver a intentar.
///
/// Usa dos conexiones, como el repositorio de guías: la del emisor para crear
/// —ahí Row Level Security protege de que una empresa anule comprobantes de
/// otra— y la de operador para que el worker busque trabajo entre todas.
/// </summary>
public sealed class RepositorioBajas
{
    private readonly FabricaSesiones _sesiones;
    private readonly string _cadenaOperador;

    public RepositorioBajas(FabricaSesiones sesiones, string cadenaConexionOperador)
    {
        _sesiones = sesiones
            ?? throw new ArgumentNullException(nameof(sesiones));

        _cadenaOperador = cadenaConexionOperador
            ?? throw new ArgumentNullException(nameof(cadenaConexionOperador));
    }

    private async Task<NpgsqlConnection> AbrirOperadorAsync(CancellationToken ct)
    {
        var conexion = new NpgsqlConnection(_cadenaOperador);
        await conexion.OpenAsync(ct);
        return conexion;
    }

    // ------------------------------------------------------------- crear

    /// <summary>
    /// Crea la comunicación y engancha los comprobantes, todo en una
    /// transacción.
    ///
    /// LOS COMPROBANTES SE TOMAN CON FOR UPDATE Y SE COMPRUEBA SU ESTADO
    /// DENTRO DE LA TRANSACCIÓN, no antes. Entre que el endpoint los valida
    /// y llega aquí puede pasar cualquier cosa: que el worker acabe de
    /// enviarlos, que otra petición pida la misma baja. Si el número de
    /// filas enganchadas no coincide con lo pedido, se deshace todo.
    ///
    /// Devuelve null si alguno ya no estaba disponible.
    /// </summary>
    public async Task<ResumenGuardado?> CrearAsync(
        Guid tenantId,
        string tipo,
        DateTime fechaReferencia,
        IReadOnlyList<(Guid Id, string Motivo)> comprobantes,
        CancellationToken ct = default)
    {
        if (!TipoComunicacionBaja.Existe(tipo))
            throw new ArgumentException(
                $"El tipo de comunicacion '{tipo}' no existe. Solo 'RA' y 'RR'.",
                nameof(tipo));

        if (comprobantes.Count == 0)
            throw new ArgumentException(
                $"Una {TipoComunicacionBaja.Nombre(tipo)} sin comprobantes no " +
                $"tiene sentido.",
                nameof(comprobantes));

        await using var sesion = await _sesiones.AbrirAsync(tenantId, ct);

        var hoy = RelojPeru.Hoy;

        // Correlativo dentro del día de generación.
        //
        // Se calcula dentro de la transacción, y la restricción única
        // ux_resumenes_identificador respalda el resultado: si dos peticiones
        // llegaran a la vez, una de las dos falla en vez de crear dos
        // comunicaciones con el mismo identificador.
        var correlativo = await sesion.Conexion.ExecuteScalarAsync<int>(
            new CommandDefinition(
                """
                SELECT COALESCE(MAX(correlativo), 0) + 1
                  FROM resumenes
                 WHERE tenant_id = @tenantId
                   AND tipo = @tipo
                   AND fecha_generacion = @hoy
                """,
                new { tenantId, tipo, hoy = DateOnly.FromDateTime(hoy) },
                sesion.Transaccion, cancellationToken: ct));

        var identificador = $"{tipo}-{hoy:yyyyMMdd}-{correlativo}";

        var bajaId = await sesion.Conexion.ExecuteScalarAsync<Guid>(
            new CommandDefinition(
                """
                INSERT INTO resumenes
                    (tenant_id, tipo, identificador, fecha_referencia,
                     fecha_generacion, correlativo, estado, comprobantes)
                VALUES
                    (@tenantId, @tipo, @identificador, @fechaReferencia,
                     @hoy, @correlativo, 'ENCOLADO', @cantidad)
                RETURNING id
                """,
                new
                {
                    tenantId,
                    tipo,
                    identificador,
                    fechaReferencia = DateOnly.FromDateTime(fechaReferencia),
                    hoy = DateOnly.FromDateTime(hoy),
                    correlativo,
                    cantidad = comprobantes.Count
                },
                sesion.Transaccion, cancellationToken: ct));

        // Enganchar cada comprobante con su motivo.
        //
        // La condición `baja_id IS NULL` es la que impide pedir dos veces la
        // baja del mismo comprobante: el segundo intento engancha cero filas
        // y la cuenta no cuadra.
        var enganchados = 0;

        foreach (var (id, motivo) in comprobantes)
        {
            enganchados += await sesion.Conexion.ExecuteAsync(
                new CommandDefinition(
                    """
                    UPDATE comprobantes
                       SET baja_id = @bajaId,
                           baja_motivo = @motivo
                     WHERE id = @id
                       AND baja_id IS NULL
                       AND estado IN ('ACEPTADO','ACEPTADO_CON_OBSERVACIONES')
                    """,
                    new { bajaId, id, motivo },
                    sesion.Transaccion, cancellationToken: ct));
        }

        if (enganchados != comprobantes.Count)
        {
            // Alguno cambió de estado o ya tenía una baja pedida. Deshacer
            // es más honesto que enviar una comunicación incompleta: SUNAT
            // la aceptaría y el cliente creería que anuló más de lo que anuló.
            //
            // SE VUELVE SIN CONFIRMAR, y eso basta: la sesión deshace la
            // transacción al cerrarse. Confirmar es el acto deliberado; no
            // hacerlo es la salida segura por defecto.
            return null;
        }

        await sesion.ConfirmarAsync(ct);

        return new ResumenGuardado(
            bajaId, tenantId, tipo, identificador,
            fechaReferencia.Date, hoy,
            correlativo, EstadoResumenCpe.Encolado, null, null, null,
            comprobantes.Count, 0, DateTime.UtcNow);
    }

    // ------------------------------------------------------------ enviar

    /// <summary>Comunicaciones listas para enviarse.</summary>
    public async Task<IReadOnlyList<ResumenGuardado>> BuscarPorEnviarAsync(
        int limite = 10, CancellationToken ct = default)
    {
        await using var conexion = await AbrirOperadorAsync(ct);

        var filas = await conexion.QueryAsync<ResumenGuardado>(
            new CommandDefinition(
                ConsultaBaja + """
                 WHERE tipo IN ('RA','RR')
                   AND estado IN ('BORRADOR','ENCOLADO')
                   AND (proximo_intento_en IS NULL OR proximo_intento_en <= now())
                 ORDER BY proximo_intento_en NULLS FIRST, creado_en
                 LIMIT @limite
                """,
                new { limite }, cancellationToken: ct));

        return filas.ToList();
    }

    /// <summary>Comunicaciones cuyo ticket falta consultar.</summary>
    public async Task<IReadOnlyList<ResumenGuardado>> BuscarTicketsPendientesAsync(
        int limite = 10, CancellationToken ct = default)
    {
        await using var conexion = await AbrirOperadorAsync(ct);

        var filas = await conexion.QueryAsync<ResumenGuardado>(
            new CommandDefinition(
                ConsultaBaja + """
                 WHERE tipo IN ('RA','RR')
                   AND estado = 'ENVIADO'
                   AND ticket IS NOT NULL
                   AND (proximo_intento_en IS NULL OR proximo_intento_en <= now())
                 ORDER BY proximo_intento_en NULLS FIRST, creado_en
                 LIMIT @limite
                """,
                new { limite }, cancellationToken: ct));

        return filas.ToList();
    }

    /// <summary>Los comprobantes que una comunicación da de baja.</summary>
    public async Task<IReadOnlyList<ComprobanteEnBaja>> ComprobantesDeAsync(
        Guid bajaId, CancellationToken ct = default)
    {
        await using var conexion = await AbrirOperadorAsync(ct);

        var filas = await conexion.QueryAsync<ComprobanteEnBaja>(
            new CommandDefinition(
                """
                SELECT id               AS "Id",
                       tipo_comprobante AS "TipoComprobante",
                       serie            AS "Serie",
                       correlativo      AS "Correlativo",
                       fecha_emision    AS "FechaEmision",
                       COALESCE(baja_motivo, '') AS "Motivo"
                  FROM comprobantes
                 WHERE baja_id = @bajaId
                 ORDER BY tipo_comprobante, serie, correlativo
                """,
                new { bajaId }, cancellationToken: ct));

        return filas.ToList();
    }

    /// <summary>Guarda el ticket devuelto por SUNAT y pasa a ENVIADO.</summary>
    public async Task RegistrarTicketAsync(
        Guid bajaId, string ticket, string? rutaXml,
        CancellationToken ct = default)
    {
        await using var conexion = await AbrirOperadorAsync(ct);

        await conexion.ExecuteAsync(new CommandDefinition(
            """
            UPDATE resumenes
               SET estado = 'ENVIADO',
                   ticket = @ticket,
                   ruta_xml = COALESCE(@rutaXml, ruta_xml),
                   intentos_fallidos = 0,
                   proximo_intento_en = NULL
             WHERE id = @bajaId
            """,
            new { bajaId, ticket, rutaXml }, cancellationToken: ct));
    }

    /// <summary>Programa un reintento con espera creciente.</summary>
    public async Task ProgramarReintentoAsync(
        Guid bajaId, TimeSpan espera, string? mensaje = null,
        CancellationToken ct = default)
    {
        await using var conexion = await AbrirOperadorAsync(ct);

        await conexion.ExecuteAsync(new CommandDefinition(
            """
            UPDATE resumenes
               SET intentos_fallidos = intentos_fallidos + 1,
                   proximo_intento_en = now() + @espera::interval,
                   mensaje_sunat = COALESCE(@mensaje, mensaje_sunat)
             WHERE id = @bajaId
            """,
            new
            {
                bajaId,
                espera = $"{(int)espera.TotalSeconds} seconds",
                mensaje
            },
            cancellationToken: ct));
    }

    // ------------------------------------------------------------- cerrar

    /// <summary>
    /// Cierra la comunicación y aplica el desenlace a sus comprobantes.
    ///
    /// AQUÍ ESTÁ LA DIFERENCIA DE FONDO CON EL RESUMEN, y es lo único que
    /// justifica que esta clase no sea RepositorioResumenes:
    ///
    ///   ACEPTADA   → los comprobantes pasan a ANULADO. Dejan de existir
    ///                para SUNAT y el panel tiene que dejar de ofrecerlos.
    ///
    ///   RECHAZADA  → los comprobantes NO SE TOCAN. Siguen aceptados, siguen
    ///                siendo válidos, y se les suelta el `baja_id` para que
    ///                se pueda volver a intentar. Marcarlos de cualquier otra
    ///                forma sería decirle al cliente que su factura murió
    ///                cuando está perfectamente viva.
    ///
    /// El motivo se conserva en los dos casos: si la baja se rechazó, saber
    /// qué se intentó anular y por qué es justo lo que hace falta para
    /// decidir qué hacer a continuación.
    /// </summary>
    public async Task CerrarAsync(
        Guid bajaId, string estado, string? codigoSunat, string? mensaje,
        string? rutaCdr = null, CancellationToken ct = default)
    {
        var aceptada = estado is EstadoResumenCpe.Aceptado
            or EstadoResumenCpe.ConObservaciones;

        await using var conexion = await AbrirOperadorAsync(ct);
        await using var transaccion = await conexion.BeginTransactionAsync(ct);

        await conexion.ExecuteAsync(new CommandDefinition(
            """
            UPDATE resumenes
               SET estado = @estado,
                   codigo_sunat = @codigoSunat,
                   mensaje_sunat = @mensaje,
                   ruta_cdr = COALESCE(@rutaCdr, ruta_cdr)
             WHERE id = @bajaId
            """,
            new { bajaId, estado, codigoSunat, mensaje, rutaCdr },
            transaccion, cancellationToken: ct));

        if (aceptada)
        {
            await conexion.ExecuteAsync(new CommandDefinition(
                """
                UPDATE comprobantes
                   SET estado = 'ANULADO',
                       mensaje_sunat = @mensaje
                 WHERE baja_id = @bajaId
                """,
                new { bajaId, mensaje },
                transaccion, cancellationToken: ct));
        }
        else
        {
            await conexion.ExecuteAsync(new CommandDefinition(
                """
                UPDATE comprobantes
                   SET baja_id = NULL
                 WHERE baja_id = @bajaId
                """,
                new { bajaId },
                transaccion, cancellationToken: ct));
        }

        await transaccion.CommitAsync(ct);
    }

    // -------------------------------------------------- anular una boleta

    /// <summary>
    /// Marca una boleta para que el próximo resumen la anule.
    ///
    /// POR QUÉ ESTE MÉTODO VIVE AQUÍ Y NO EN RepositorioComprobantes:
    ///
    /// Escribe en `baja_motivo`, que es la columna de esta clase. Quien
    /// entienda qué significa esa columna —y qué quiere decir que `baja_id`
    /// siga vacío— tiene que ser uno solo, o el día que cambie el
    /// significado habrá dos sitios que actualizar y uno se quedará atrás.
    ///
    /// NO MANDA NADA A SUNAT ni cambia el estado de la boleta. Solo deja la
    /// marca. La boleta sigue ACEPTADA, que es la verdad: lo está, y lo
    /// seguirá estando hasta que SUNAT confirme la anulación.
    ///
    /// Devuelve false si la boleta ya no cumplía las condiciones, que es lo
    /// que pasa cuando dos peticiones llegan a la vez o cuando el worker se
    /// adelantó.
    /// </summary>
    public async Task<bool> MarcarBoletaParaAnularAsync(
        Guid tenantId, Guid comprobanteId, string motivo,
        CancellationToken ct = default)
    {
        await using var sesion = await _sesiones.AbrirAsync(tenantId, ct);

        // LAS CONDICIONES SE REPITEN AQUÍ aunque el endpoint ya las comprobó,
        // y no sobra: entre su comprobación y esta línea cabe otra petición
        // entera. Ponerlas en el WHERE es lo único que lo decide de verdad,
        // porque lo decide la base.
        var filas = await sesion.Conexion.ExecuteAsync(
            new CommandDefinition(
                """
                UPDATE comprobantes
                   SET baja_motivo = @motivo
                 WHERE id = @comprobanteId
                   AND serie LIKE 'B%'
                   AND estado IN ('ACEPTADO','ACEPTADO_CON_OBSERVACIONES')
                   AND baja_motivo IS NULL
                   AND baja_id IS NULL
                """,
                new { comprobanteId, motivo },
                sesion.Transaccion, cancellationToken: ct));

        await sesion.ConfirmarAsync(ct);

        return filas == 1;
    }

    // ------------------------------------------------------------ consulta

    /// <summary>Una comunicación concreta, para responder al emisor.</summary>
    public async Task<ResumenGuardado?> ObtenerAsync(
        Guid tenantId, Guid bajaId, CancellationToken ct = default)
    {
        await using var sesion = await _sesiones.AbrirAsync(tenantId, ct);

        var fila = await sesion.Conexion.QuerySingleOrDefaultAsync<ResumenGuardado?>(
            new CommandDefinition(
                ConsultaBaja + """
                 WHERE id = @bajaId
                   AND tipo IN ('RA','RR')
                """,
                new { bajaId },
                sesion.Transaccion, cancellationToken: ct));

        await sesion.ConfirmarAsync(ct);
        return fila;
    }

    /// <summary>Las comunicaciones de una empresa, para el panel.</summary>
    public async Task<IReadOnlyList<ResumenGuardado>> ListarAsync(
        Guid tenantId, int limite = 50, CancellationToken ct = default)
    {
        await using var sesion = await _sesiones.AbrirAsync(tenantId, ct);

        var filas = await sesion.Conexion.QueryAsync<ResumenGuardado>(
            new CommandDefinition(
                ConsultaBaja + """
                 WHERE tipo IN ('RA','RR')
                 ORDER BY creado_en DESC
                 LIMIT @limite
                """,
                new { limite },
                sesion.Transaccion, cancellationToken: ct));

        await sesion.ConfirmarAsync(ct);
        return filas.ToList();
    }

    private const string ConsultaBaja =
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