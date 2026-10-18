using Dapper;

namespace Facturacion.Persistencia;

/// <summary>Lo que devuelve registrar el webhook de la API.</summary>
public record RegistroWebhookApi(
    Guid Id,
    string Url,
    string Secreto,
    bool Creado,
    string? UrlAnterior);

/// <summary>Cómo está el webhook de la API de una empresa. Nunca el secreto.</summary>
public record EstadoWebhookApi(
    Guid Id,
    string Url,
    DateTime CreadoEn,
    DateTime SecretoCambiadoEn,
    int Pendientes,
    int Agotados);

/// <summary>La última entrega del webhook de la API.</summary>
public record UltimaEntregaApi(
    string Tipo,
    string Estado,
    short Intentos,
    int? UltimoCodigo,
    string? UltimoError,
    DateTime CreadoEn,
    DateTime? EntregadoEn);

/// <summary>El último cambio del webhook de la API (webhook_cambios).</summary>
public record UltimoCambioApi(
    string Accion,
    string HechoDesde,
    string? PrefijoClave,
    DateTime CreadoEn);

/// <summary>
/// El webhook de la API: el que registra la propia empresa con su clave fac_
/// (POST /v1/webhook). Diseño: alta-empresa-diseno.md, parte A.
///
/// A DIFERENCIA DE RepositorioWebhooks, ESTE NO USA EL ROL DE OPERADOR. Todo
/// va por FabricaSesiones, con el rol facturacion_app y la empresa de la
/// clave declarada para Row Level Security. La empresa sale de la clave
/// (ContextoEmisor), nunca de la petición; y aunque un WHERE de aquí se
/// equivocara, la base no dejaría ver ni tocar el webhook de otra empresa.
/// Son dos barreras, a propósito.
///
/// UNO POR EMPRESA, Y SE ACTUALIZA EN LA MISMA FILA (diseño §2.2). Las
/// entregas en cola leen la URL y el secreto al despacharse: actualizando la
/// fila, salen firmadas con el secreto nuevo, que es el que la plataforma ya
/// tiene. Si se creara otro, cada factura se avisaría dos veces.
///
/// Los webhooks del panel (origen 'panel') no se ven ni se tocan desde aquí.
/// </summary>
public sealed class RepositorioWebhookApi
{
    public const string NombreWebhook = "Webhook de la empresa";

    private readonly FabricaSesiones _sesiones;

    public RepositorioWebhookApi(FabricaSesiones sesiones)
    {
        _sesiones = sesiones ?? throw new ArgumentNullException(nameof(sesiones));
    }

    /// <summary>
    /// Crea el webhook de la API de la empresa o, si ya tiene uno activo, le
    /// cambia la URL y el secreto. Siempre devuelve un secreto NUEVO: el
    /// anterior deja de valer en ese instante.
    ///
    /// La URL tiene que venir ya revisada por DestinoWebhook.
    /// </summary>
    public async Task<RegistroWebhookApi> RegistrarAsync(
        Guid tenantId, string url, string? prefijoClave, CancellationToken ct = default)
    {
        var secreto = RepositorioWebhooks.GenerarSecreto();

        await using var sesion = await _sesiones.AbrirAsync(tenantId, ct);

        // DOS PETICIONES A LA VEZ de la misma empresa (dos pestañas pulsando
        // «Conectar») no pueden crear dos. El índice único ya lo impediría
        // con un error; el candado hace que la segunda espere y actualice.
        await sesion.Conexion.ExecuteAsync(new CommandDefinition(
            "SELECT pg_advisory_xact_lock(hashtextextended('webhook_api:' || @tenantId::text, 0))",
            new { tenantId }, sesion.Transaccion, cancellationToken: ct));

        var actual = await sesion.Conexion.QuerySingleOrDefaultAsync<IdYUrl>(
            new CommandDefinition(
                """
                SELECT id AS "Id", url AS "Url"
                  FROM webhooks
                 WHERE tenant_id = @tenantId
                   AND origen = 'api'
                   AND activo
                 FOR UPDATE
                """,
                new { tenantId }, sesion.Transaccion, cancellationToken: ct));

        Guid id;

        if (actual is null)
        {
            // Eventos vacío = todos (decisión del 10 de octubre): el día que
            // aparezca uno nuevo, llega solo, sin tocar cada empresa.
            id = await sesion.Conexion.ExecuteScalarAsync<Guid>(new CommandDefinition(
                """
                INSERT INTO webhooks
                       (tenant_id, nombre, url, secreto_cifrado, eventos, origen, secreto_cambiado_en)
                VALUES (@tenantId, @nombre, @url, @secretoCifrado, '{}', 'api', now())
                RETURNING id
                """,
                // CIFRADO (migración 032): en la base no queda en claro.
                new { tenantId, nombre = NombreWebhook, url, secretoCifrado = SecretosWebhook.Cifrar(secreto) },
                sesion.Transaccion, cancellationToken: ct));
        }
        else
        {
            id = actual.Id;

            await sesion.Conexion.ExecuteAsync(new CommandDefinition(
                """
                UPDATE webhooks
                   SET url = @url,
                       secreto = NULL,
                       secreto_cifrado = @secretoCifrado,
                       secreto_cambiado_en = now()
                 WHERE id = @id
                   AND tenant_id = @tenantId
                """,
                // El secreto NUEVO, cifrado (032). El viejo deja de valer, y si
                // quedaba en claro de antes de la 032, se va con él.
                new { id, tenantId, url, secretoCifrado = SecretosWebhook.Cifrar(secreto) },
                sesion.Transaccion, cancellationToken: ct));
        }

        // La bitácora del cambio: URL de antes y de después, y quién (el
        // prefijo de la clave, el mismo que enseña el panel). EL SECRETO NO VA AQUÍ, ni en ningún registro.
        await sesion.Conexion.ExecuteAsync(new CommandDefinition(
            """
            INSERT INTO webhook_cambios
                   (webhook_id, tenant_id, accion, url_antes, url_despues,
                    hecho_desde, prefijo_clave)
            VALUES (@id, @tenantId, @accion, @urlAntes, @url, 'api', @prefijoClave)
            """,
            new
            {
                id, tenantId, url, prefijoClave,
                accion = actual is null ? "alta" : "rotacion",
                urlAntes = actual?.Url
            },
            sesion.Transaccion, cancellationToken: ct));

        await sesion.ConfirmarAsync(ct);

        return new RegistroWebhookApi(id, url, secreto, actual is null, actual?.Url);
    }

    /// <summary>El webhook de la API activo, o null si la empresa no tiene.</summary>
    public async Task<(EstadoWebhookApi? Webhook, UltimaEntregaApi? UltimaEntrega,
        UltimoCambioApi? UltimoCambio, int OtrosActivos)> ObtenerAsync(
        Guid tenantId, CancellationToken ct = default)
    {
        await using var sesion = await _sesiones.AbrirAsync(tenantId, ct);

        var webhook = await sesion.Conexion.QuerySingleOrDefaultAsync<EstadoWebhookApi>(
            new CommandDefinition(
                """
                SELECT w.id                  AS "Id",
                       w.url                 AS "Url",
                       w.creado_en           AS "CreadoEn",
                       w.secreto_cambiado_en AS "SecretoCambiadoEn",
                       (SELECT count(*)::int FROM webhook_entregas e
                         WHERE e.webhook_id = w.id AND e.estado = 'PENDIENTE') AS "Pendientes",
                       (SELECT count(*)::int FROM webhook_entregas e
                         WHERE e.webhook_id = w.id AND e.estado = 'AGOTADO')   AS "Agotados"
                  FROM webhooks w
                 WHERE w.tenant_id = @tenantId
                   AND w.origen = 'api'
                   AND w.activo
                """,
                new { tenantId }, sesion.Transaccion, cancellationToken: ct));

        // Los del panel no se enseñan, solo se cuentan: si hay alguno activo,
        // los avisos de esta empresa también van a otro sitio (el ERP de un
        // cliente, por ejemplo). La plataforma lo sabrá; la URL, no.
        var otros = await sesion.Conexion.ExecuteScalarAsync<int>(new CommandDefinition(
            """
            SELECT count(*)::int FROM webhooks
             WHERE tenant_id = @tenantId AND origen = 'panel' AND activo
            """,
            new { tenantId }, sesion.Transaccion, cancellationToken: ct));

        if (webhook is null) return (null, null, null, otros);

        var ultima = await sesion.Conexion.QuerySingleOrDefaultAsync<UltimaEntregaApi>(
            new CommandDefinition(
                """
                SELECT tipo          AS "Tipo",
                       estado        AS "Estado",
                       intentos      AS "Intentos",
                       ultimo_codigo AS "UltimoCodigo",
                       ultimo_error  AS "UltimoError",
                       creado_en     AS "CreadoEn",
                       entregado_en  AS "EntregadoEn"
                  FROM webhook_entregas
                 WHERE webhook_id = @id AND tenant_id = @tenantId
                 ORDER BY creado_en DESC, id DESC
                 LIMIT 1
                """,
                new { id = webhook.Id, tenantId }, sesion.Transaccion, cancellationToken: ct));

        var cambio = await sesion.Conexion.QuerySingleOrDefaultAsync<UltimoCambioApi>(
            new CommandDefinition(
                """
                SELECT accion      AS "Accion",
                       hecho_desde AS "HechoDesde",
                       prefijo_clave AS "PrefijoClave",
                       creado_en   AS "CreadoEn"
                  FROM webhook_cambios
                 WHERE webhook_id = @id AND tenant_id = @tenantId
                 ORDER BY creado_en DESC, id DESC
                 LIMIT 1
                """,
                new { id = webhook.Id, tenantId }, sesion.Transaccion, cancellationToken: ct));

        return (webhook, ultima, cambio, otros);
    }

    /// <summary>
    /// Devuelve a la cola las entregas AGOTADAS del webhook de la API de esta
    /// empresa, de los últimos <paramref name="dias"/> días. Devuelve cuántas.
    ///
    /// Para después de «Conectar» (diseño §10.5): mientras el servicio tenía
    /// un secreto que la plataforma no había guardado, los avisos se
    /// rechazaron con 401, y un 4xx no se reintenta: quedan agotados al primer
    /// intento. Reenviarlos es seguro: llevan el mismo evento_id y la
    /// plataforma descarta lo que ya tenía.
    ///
    /// Solo el webhook de la API de la propia empresa; nunca las del panel.
    /// </summary>
    public async Task<int> ReintentarAgotadasAsync(
        Guid tenantId, int dias, CancellationToken ct = default)
    {
        await using var sesion = await _sesiones.AbrirAsync(tenantId, ct);

        var filas = await sesion.Conexion.ExecuteAsync(new CommandDefinition(
            """
            UPDATE webhook_entregas e
               SET estado = 'PENDIENTE',
                   intentos = 0,
                   proximo_intento_en = NULL
              FROM webhooks w
             WHERE w.id = e.webhook_id
               AND w.tenant_id = @tenantId
               AND w.origen = 'api'
               AND w.activo
               AND e.tenant_id = @tenantId
               AND e.estado = 'AGOTADO'
               AND e.creado_en >= now() - make_interval(days => @dias)
            """,
            new { tenantId, dias }, sesion.Transaccion, cancellationToken: ct));

        await sesion.ConfirmarAsync(ct);

        return filas;
    }

    private sealed record IdYUrl(Guid Id, string Url);
}