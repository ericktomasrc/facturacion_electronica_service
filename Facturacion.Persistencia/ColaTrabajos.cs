using Dapper;
using Npgsql;

namespace Facturacion.Persistencia;

/// <summary>Un comprobante pendiente de procesar.</summary>
public record TrabajoComprobante(
    Guid Id,
    Guid TenantId,
    string TipoComprobante,
    string Serie,
    int Correlativo,
    string CpeJson,
    short IntentosFallidos)
{
    public string NumeroCompleto => $"{Serie}-{Correlativo:D8}";
}

/// <summary>
/// Cola de trabajos construida sobre PostgreSQL.
///
/// POR QUÉ LA BASE DE DATOS Y NO RABBITMQ, AL MENOS POR AHORA:
///
/// Con FOR UPDATE SKIP LOCKED, PostgreSQL resuelve el reparto de trabajo entre
/// varios workers sin que dos tomen el mismo comprobante. Aguanta miles de
/// trabajos por segundo, no exige levantar otra pieza de infraestructura, y
/// deja el estado de la cola en el mismo sitio que el resto de los datos:
/// una transacción menos que coordinar y un lugar menos donde mirar cuando
/// algo va mal.
///
/// Cuando el volumen lo justifique, se reemplaza esta clase y nada más.
///
/// EL WORKER NO ES UN TENANT. Necesita ver trabajos de todas las empresas, así
/// que se conecta con el rol de operador, que no está sujeto a Row Level
/// Security. Pero solo lo usa para RECLAMAR: el procesamiento de cada
/// comprobante ocurre después dentro de una sesión de su tenant, con las
/// políticas activas.
/// </summary>
public sealed class ColaTrabajos
{
    private readonly string _cadenaOperador;

    public ColaTrabajos(string cadenaConexionOperador)
    {
        if (string.IsNullOrWhiteSpace(cadenaConexionOperador))
            throw new ArgumentException(
                "Falta la cadena de conexión del operador.",
                nameof(cadenaConexionOperador));

        _cadenaOperador = cadenaConexionOperador;
    }

    /// <summary>
    /// Reclama hasta <paramref name="limite"/> comprobantes pendientes y los
    /// marca como encolados.
    ///
    /// CÓMO FUNCIONA EL REPARTO, que es lo interesante:
    ///
    ///   FOR UPDATE      bloquea las filas seleccionadas.
    ///   SKIP LOCKED     hace que otro worker IGNORE las que ya están tomadas
    ///                   en vez de quedarse esperando.
    ///
    /// Sin SKIP LOCKED, diez workers formarían una fila detrás del mismo
    /// comprobante y el sistema sería más lento cuantos más workers tuviera.
    /// Con él, cada uno se lleva un lote distinto sin coordinarse.
    ///
    /// La transacción es CORTA a propósito: reclama y confirma. El envío a
    /// SUNAT, que tarda segundos, ocurre fuera. Mantener una transacción
    /// abierta mientras se espera a un servicio externo es una de las formas
    /// más rápidas de agotar las conexiones de la base.
    /// </summary>
    public async Task<IReadOnlyList<TrabajoComprobante>> ReclamarAsync(
        int limite = 10, CancellationToken ct = default)
    {
        await using var conexion = new NpgsqlConnection(_cadenaOperador);
        await conexion.OpenAsync(ct);

        await using var transaccion = await conexion.BeginTransactionAsync(ct);

        var trabajos = await conexion.QueryAsync<TrabajoComprobante>(
            new CommandDefinition(
                """
                WITH candidatos AS (
                    SELECT id
                      FROM comprobantes
                     WHERE estado = 'BORRADOR'
                       -- Respeta la espera del backoff: un comprobante que
                       -- falló hace poco no se vuelve a tomar hasta que
                       -- llegue su momento.
                       AND (proximo_intento_en IS NULL
                            OR proximo_intento_en <= now())
                     ORDER BY proximo_intento_en NULLS FIRST, creado_en
                     FOR UPDATE SKIP LOCKED
                     LIMIT @limite
                )
                UPDATE comprobantes c
                   SET estado = 'ENCOLADO'
                  FROM candidatos
                 WHERE c.id = candidatos.id
                RETURNING c.id                AS "Id",
                          c.tenant_id         AS "TenantId",
                          c.tipo_comprobante  AS "TipoComprobante",
                          c.serie             AS "Serie",
                          c.correlativo       AS "Correlativo",
                          c.cpe::text         AS "CpeJson",
                          c.intentos_fallidos AS "IntentosFallidos"
                """,
                new { limite },
                transaccion, cancellationToken: ct));

        await transaccion.CommitAsync(ct);

        return trabajos.ToList();
    }

    /// <summary>
    /// Devuelve a BORRADOR los comprobantes que quedaron encolados demasiado
    /// tiempo.
    ///
    /// POR QUÉ HACE FALTA: si un worker muere a mitad de proceso, sus
    /// comprobantes quedan en ENCOLADO para siempre y nadie los vuelve a
    /// tomar. Este rescate los devuelve a la cola.
    ///
    /// El umbral debe ser holgado: más largo que el peor caso de un envío
    /// lento a SUNAT. Si fuera corto, dos workers procesarían el mismo
    /// comprobante y SUNAT recibiría un duplicado.
    /// </summary>
    public async Task<int> RescatarAbandonadosAsync(
        TimeSpan antiguedad, CancellationToken ct = default)
    {
        await using var conexion = new NpgsqlConnection(_cadenaOperador);
        await conexion.OpenAsync(ct);

        return await conexion.ExecuteAsync(new CommandDefinition(
            """
            UPDATE comprobantes
               SET estado = 'BORRADOR'
             WHERE estado = 'ENCOLADO'
               AND actualizado_en < now() - @antiguedad::interval
            """,
            new { antiguedad = $"{(int)antiguedad.TotalSeconds} seconds" },
            cancellationToken: ct));
    }

    /// <summary>
    /// Programa el siguiente intento de un comprobante que falló por una causa
    /// reintentable, y lo devuelve a la cola.
    /// </summary>
    public async Task ProgramarReintentoAsync(
        Guid comprobanteId, TimeSpan espera, CancellationToken ct = default)
    {
        await using var conexion = new NpgsqlConnection(_cadenaOperador);
        await conexion.OpenAsync(ct);

        await conexion.ExecuteAsync(new CommandDefinition(
            """
            UPDATE comprobantes
               SET estado = 'BORRADOR',
                   intentos_fallidos = intentos_fallidos + 1,
                   proximo_intento_en = now() + @espera::interval
             WHERE id = @comprobanteId
            """,
            new
            {
                comprobanteId,
                espera = $"{(int)espera.TotalSeconds} seconds"
            },
            cancellationToken: ct));
    }

    /// <summary>
    /// Limpia el contador de reintentos de un comprobante que ya se resolvió.
    /// </summary>
    public async Task LimpiarReintentosAsync(
        Guid comprobanteId, CancellationToken ct = default)
    {
        await using var conexion = new NpgsqlConnection(_cadenaOperador);
        await conexion.OpenAsync(ct);

        await conexion.ExecuteAsync(new CommandDefinition(
            """
            UPDATE comprobantes
               SET intentos_fallidos = 0,
                   proximo_intento_en = NULL
             WHERE id = @comprobanteId
            """,
            new { comprobanteId }, cancellationToken: ct));
    }

    /// <summary>Cuántos comprobantes esperan. Sirve para autoescalar workers.</summary>
    public async Task<int> ProfundidadAsync(CancellationToken ct = default)
    {
        await using var conexion = new NpgsqlConnection(_cadenaOperador);
        await conexion.OpenAsync(ct);

        return await conexion.ExecuteScalarAsync<int>(new CommandDefinition(
            "SELECT count(*) FROM comprobantes WHERE estado IN ('BORRADOR','ENCOLADO')",
            cancellationToken: ct));
    }

    /// <summary>Datos del emisor necesarios para enviar, sin pasar por RLS.</summary>
    public async Task<TenantResuelto?> ObtenerTenantAsync(
        Guid tenantId, CancellationToken ct = default)
    {
        await using var conexion = new NpgsqlConnection(_cadenaOperador);
        await conexion.OpenAsync(ct);

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
                 WHERE id = @tenantId
                """,
                new { tenantId }, cancellationToken: ct));
    }
}
