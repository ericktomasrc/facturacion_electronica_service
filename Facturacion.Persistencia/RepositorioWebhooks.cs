using System.Security.Cryptography;
using Dapper;
using Npgsql;

namespace Facturacion.Persistencia;

/// <summary>Un webhook configurado por una empresa.</summary>
public record WebhookAdmin(
    Guid Id,
    string Nombre,
    string Url,
    string[] Eventos,
    bool Activo,
    DateTime CreadoEn,
    int Pendientes,
    int Agotados);

/// <summary>Una entrega pendiente de despachar.</summary>
public record EntregaPendiente(
    long Id,
    Guid WebhookId,
    Guid TenantId,
    Guid EventoId,
    string Tipo,
    string Cuerpo,
    string Url,
    string Secreto,
    short Intentos);

/// <summary>Historial de entregas, para el panel.</summary>
public record EntregaHistorial(
    long Id,
    Guid EventoId,
    string Tipo,
    string Estado,
    short Intentos,
    int? UltimoCodigo,
    string? UltimoError,
    DateTime CreadoEn,
    DateTime? EntregadoEn);

/// <summary>
/// Gestiona los webhooks y su bandeja de salida.
///
/// Usa el rol de operador porque el despachador trabaja sobre todas las
/// empresas. La administración desde el panel también, que es donde se
/// configuran.
/// </summary>
public sealed class RepositorioWebhooks
{
    private readonly string _cadenaOperador;

    public RepositorioWebhooks(string cadenaConexionOperador)
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
    /// Genera el secreto con el que se firman los envíos a este webhook.
    ///
    /// El cliente lo usa para comprobar que el aviso viene de nosotros. Sin
    /// firma, cualquiera que descubriera su URL podría enviarle mensajes
    /// falsos diciendo que una factura fue aceptada.
    /// </summary>
    public static string GenerarSecreto() =>
        "whsec_" + Convert.ToBase64String(RandomNumberGenerator.GetBytes(32))
            .Replace("+", "").Replace("/", "").Replace("=", "");

    // ------------------------------------------------------- configuración

    public async Task<IReadOnlyList<WebhookAdmin>> ListarAsync(
        Guid tenantId, CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);

        var filas = await conexion.QueryAsync<WebhookAdmin>(
            new CommandDefinition(
                """
                SELECT w.id        AS "Id",
                       w.nombre    AS "Nombre",
                       w.url       AS "Url",
                       w.eventos   AS "Eventos",
                       w.activo    AS "Activo",
                       w.creado_en AS "CreadoEn",

                       (SELECT count(*)::int FROM webhook_entregas e
                         WHERE e.webhook_id = w.id AND e.estado = 'PENDIENTE')
                                   AS "Pendientes",

                       (SELECT count(*)::int FROM webhook_entregas e
                         WHERE e.webhook_id = w.id AND e.estado = 'AGOTADO')
                                   AS "Agotados"

                  FROM webhooks w
                 WHERE w.tenant_id = @tenantId
                 ORDER BY w.creado_en DESC
                """,
                new { tenantId }, cancellationToken: ct));

        return filas.ToList();
    }

    public async Task<(Guid Id, string Secreto)> CrearAsync(
        Guid tenantId, string nombre, string url, string[] eventos,
        CancellationToken ct = default)
    {
        var secreto = GenerarSecreto();

        await using var conexion = await AbrirAsync(ct);

        var id = await conexion.ExecuteScalarAsync<Guid>(new CommandDefinition(
            """
            INSERT INTO webhooks (tenant_id, nombre, url, secreto, eventos)
            VALUES (@tenantId, @nombre, @url, @secreto, @eventos)
            RETURNING id
            """,
            new { tenantId, nombre, url, secreto, eventos },
            cancellationToken: ct));

        return (id, secreto);
    }

    public async Task<bool> CambiarEstadoAsync(
        Guid tenantId, Guid webhookId, bool activo, CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);

        var filas = await conexion.ExecuteAsync(new CommandDefinition(
            "UPDATE webhooks SET activo = @activo WHERE id = @webhookId AND tenant_id = @tenantId",
            new { tenantId, webhookId, activo }, cancellationToken: ct));

        return filas > 0;
    }

    public async Task<bool> EliminarAsync(
        Guid tenantId, Guid webhookId, CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);

        // Las entregas se borran en cascada: sin webhook no tienen a dónde ir.
        var filas = await conexion.ExecuteAsync(new CommandDefinition(
            "DELETE FROM webhooks WHERE id = @webhookId AND tenant_id = @tenantId",
            new { tenantId, webhookId }, cancellationToken: ct));

        return filas > 0;
    }

    public async Task<IReadOnlyList<EntregaHistorial>> HistorialAsync(
        Guid tenantId, int limite = 50, CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);

        var filas = await conexion.QueryAsync<EntregaHistorial>(
            new CommandDefinition(
                """
                SELECT id            AS "Id",
                       evento_id     AS "EventoId",
                       tipo          AS "Tipo",
                       estado        AS "Estado",
                       intentos      AS "Intentos",
                       ultimo_codigo AS "UltimoCodigo",
                       ultimo_error  AS "UltimoError",
                       creado_en     AS "CreadoEn",
                       entregado_en  AS "EntregadoEn"
                  FROM webhook_entregas
                 WHERE tenant_id = @tenantId
                 ORDER BY creado_en DESC
                 LIMIT @limite
                """,
                new { tenantId, limite }, cancellationToken: ct));

        return filas.ToList();
    }

    // ------------------------------------------------------------ despacho

    /// <summary>
    /// Toma entregas pendientes cuyo momento ya llegó.
    ///
    /// Igual que en la cola de comprobantes, FOR UPDATE SKIP LOCKED permite
    /// que varios despachadores trabajen sin pisarse.
    /// </summary>
    public async Task<IReadOnlyList<EntregaPendiente>> ReclamarAsync(
        int limite = 20, CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);
        await using var transaccion = await conexion.BeginTransactionAsync(ct);

        var entregas = await conexion.QueryAsync<EntregaPendiente>(
            new CommandDefinition(
                """
                WITH candidatas AS (
                    SELECT e.id
                      FROM webhook_entregas e
                      JOIN webhooks w ON w.id = e.webhook_id
                     WHERE e.estado = 'PENDIENTE'
                       AND w.activo
                       AND (e.proximo_intento_en IS NULL
                            OR e.proximo_intento_en <= now())
                     ORDER BY e.proximo_intento_en NULLS FIRST, e.creado_en
                     FOR UPDATE OF e SKIP LOCKED
                     LIMIT @limite
                ),
                tomadas AS (
                    UPDATE webhook_entregas e
                       SET intentos = e.intentos + 1
                      FROM candidatas c
                     WHERE e.id = c.id
                    RETURNING e.id, e.webhook_id, e.tenant_id, e.evento_id,
                              e.tipo, e.cuerpo, e.intentos
                )
                SELECT t.id           AS "Id",
                       t.webhook_id   AS "WebhookId",
                       t.tenant_id    AS "TenantId",
                       t.evento_id    AS "EventoId",
                       t.tipo         AS "Tipo",
                       t.cuerpo::text AS "Cuerpo",
                       w.url          AS "Url",
                       w.secreto      AS "Secreto",
                       t.intentos     AS "Intentos"
                  FROM tomadas t
                  JOIN webhooks w ON w.id = t.webhook_id
                """,
                new { limite },
                transaccion, cancellationToken: ct));

        await transaccion.CommitAsync(ct);

        return entregas.ToList();
    }

    public async Task MarcarEntregadaAsync(
        long entregaId, int codigo, CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);

        await conexion.ExecuteAsync(new CommandDefinition(
            """
            UPDATE webhook_entregas
               SET estado = 'ENTREGADO',
                   entregado_en = now(),
                   ultimo_codigo = @codigo,
                   ultimo_error = NULL,
                   proximo_intento_en = NULL
             WHERE id = @entregaId
            """,
            new { entregaId, codigo }, cancellationToken: ct));
    }

    /// <summary>
    /// Registra un fallo y programa el siguiente intento.
    ///
    /// Si se agotaron los intentos, la entrega se marca como AGOTADA y deja
    /// de reintentarse. Seguir insistiendo indefinidamente contra un servidor
    /// que no responde solo consume recursos y esconde el problema: una
    /// entrega agotada es algo que alguien tiene que mirar.
    /// </summary>
    public async Task RegistrarFalloAsync(
        long entregaId, int intentos, int maximoIntentos,
        int? codigo, string error, TimeSpan espera,
        CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);

        var agotada = intentos >= maximoIntentos;

        await conexion.ExecuteAsync(new CommandDefinition(
            """
            UPDATE webhook_entregas
               SET estado = @estado,
                   ultimo_codigo = @codigo,
                   ultimo_error = @error,
                   proximo_intento_en = CASE WHEN @agotada
                       THEN NULL
                       ELSE now() + @espera::interval END
             WHERE id = @entregaId
            """,
            new
            {
                entregaId,
                estado = agotada ? "AGOTADO" : "PENDIENTE",
                codigo,
                error = error.Length > 500 ? error[..500] : error,
                agotada,
                espera = $"{(int)espera.TotalSeconds} seconds"
            },
            cancellationToken: ct));
    }

    /// <summary>Devuelve a la cola una entrega agotada, tras corregir la causa.</summary>
    public async Task<bool> ReintentarAsync(
        long entregaId, CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);

        var filas = await conexion.ExecuteAsync(new CommandDefinition(
            """
            UPDATE webhook_entregas
               SET estado = 'PENDIENTE', intentos = 0, proximo_intento_en = NULL
             WHERE id = @entregaId AND estado = 'AGOTADO'
            """,
            new { entregaId }, cancellationToken: ct));

        return filas > 0;
    }

    /// <summary>Encola un evento de prueba, para verificar la configuración.</summary>
    public async Task<bool> EnviarPruebaAsync(
        Guid tenantId, Guid webhookId, CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);

        var filas = await conexion.ExecuteAsync(new CommandDefinition(
            """
            INSERT INTO webhook_entregas (webhook_id, tenant_id, tipo, cuerpo)
            SELECT id, tenant_id, 'prueba',
                   jsonb_build_object(
                       'tipo', 'prueba',
                       'mensaje', 'Si recibes esto, el webhook está bien configurado.',
                       'ocurridoEn', now())
              FROM webhooks
             WHERE id = @webhookId AND tenant_id = @tenantId AND activo
            """,
            new { tenantId, webhookId }, cancellationToken: ct));

        return filas > 0;
    }
}
