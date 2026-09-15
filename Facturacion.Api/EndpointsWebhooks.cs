using Facturacion.Persistencia;

namespace Facturacion.Api;

/// <summary>
/// Configuración de webhooks por empresa.
///
/// El secreto de firma se muestra UNA sola vez al crearlos, igual que las
/// claves de acceso. Sin él, el cliente no puede verificar que los avisos
/// vienen de nosotros.
/// </summary>
public static class EndpointsWebhooks
{
    public static void MapearWebhooks(this WebApplication app)
    {
        var grupo = app.MapGroup("/admin/tenants/{id:guid}/webhooks")
            .AddEndpointFilter<FiltroClaveOperador>()
            .WithTags("Webhooks");

        grupo.MapGet("", async (
            Guid id, RepositorioWebhooks webhooks, CancellationToken ct) =>
            Results.Ok(await webhooks.ListarAsync(id, ct)))
            .WithSummary("Lista los webhooks de una empresa");

        grupo.MapPost("", async (
            Guid id, NuevoWebhook nuevo,
            RepositorioWebhooks webhooks, CancellationToken ct) =>
        {
            if (!Uri.TryCreate(nuevo.Url, UriKind.Absolute, out var uri) ||
                (uri.Scheme != Uri.UriSchemeHttp && uri.Scheme != Uri.UriSchemeHttps))
            {
                return Results.BadRequest(new RespuestaError(
                    "La URL no es válida.",
                    "Debe ser una dirección completa que empiece con https://"));
            }

            if (uri.Scheme == Uri.UriSchemeHttp)
            {
                // Se permite http en desarrollo, pero conviene decirlo: por ahí
                // viajan datos de facturación de un cliente.
                // No se bloquea para no impedir las pruebas locales.
            }

            var (webhookId, secreto) = await webhooks.CrearAsync(
                id, nuevo.Nombre, nuevo.Url, nuevo.Eventos ?? [], ct);

            return Results.Ok(new
            {
                id = webhookId,
                secreto,
                aviso =
                    "Este secreto se muestra una sola vez. El cliente lo necesita " +
                    "para verificar que los avisos vienen de nosotros: con él " +
                    "recalcula la firma de cada mensaje y descarta los que no " +
                    "coincidan."
            });
        })
        .WithSummary("Registra un webhook")
        .WithDescription(
            "Devuelve el secreto de firma UNA sola vez. " +
            "Cada aviso llega con las cabeceras X-Facturacion-Timestamp y " +
            "X-Facturacion-Firma. La firma es el HMAC-SHA256 de " +
            "'timestamp.cuerpo' usando el secreto, en hexadecimal minúsculo.");

        grupo.MapPatch("/{webhookId:guid}", async (
            Guid id, Guid webhookId, CambioEstadoWebhook cambio,
            RepositorioWebhooks webhooks, CancellationToken ct) =>
        {
            var cambiado = await webhooks.CambiarEstadoAsync(
                id, webhookId, cambio.Activo, ct);

            return cambiado
                ? Results.Ok(new { mensaje = cambio.Activo
                    ? "Webhook activado." : "Webhook desactivado." })
                : Results.NotFound(new RespuestaError("No se encontró el webhook."));
        })
        .WithSummary("Activa o desactiva un webhook");

        grupo.MapDelete("/{webhookId:guid}", async (
            Guid id, Guid webhookId,
            RepositorioWebhooks webhooks, CancellationToken ct) =>
        {
            var eliminado = await webhooks.EliminarAsync(id, webhookId, ct);

            return eliminado
                ? Results.Ok(new { mensaje = "Webhook eliminado." })
                : Results.NotFound(new RespuestaError("No se encontró el webhook."));
        })
        .WithSummary("Elimina un webhook")
        .WithDescription("También elimina su historial de entregas.");

        grupo.MapPost("/{webhookId:guid}/prueba", async (
            Guid id, Guid webhookId,
            RepositorioWebhooks webhooks, CancellationToken ct) =>
        {
            var encolado = await webhooks.EnviarPruebaAsync(id, webhookId, ct);

            return encolado
                ? Results.Ok(new { mensaje =
                    "Aviso de prueba encolado. Llegará en los próximos segundos." })
                : Results.NotFound(new RespuestaError(
                    "No se encontró el webhook, o está desactivado."));
        })
        .WithSummary("Envía un aviso de prueba")
        .WithDescription(
            "Sirve para comprobar la configuración sin esperar a que haya " +
            "un comprobante real.");

        // El historial no cuelga de un webhook concreto: interesa ver todas
        // las entregas del emisor juntas.
        app.MapGet("/admin/tenants/{id:guid}/webhook-entregas", async (
            Guid id, RepositorioWebhooks webhooks, int? limite,
            CancellationToken ct) =>
            Results.Ok(await webhooks.HistorialAsync(
                id, Math.Clamp(limite ?? 50, 1, 200), ct)))
            .AddEndpointFilter<FiltroClaveOperador>()
            .WithTags("Webhooks")
            .WithSummary("Historial de entregas");

        app.MapPost("/admin/webhook-entregas/{entregaId:long}/reintentar", async (
            long entregaId, RepositorioWebhooks webhooks, CancellationToken ct) =>
        {
            var reintentada = await webhooks.ReintentarAsync(entregaId, ct);

            return reintentada
                ? Results.Ok(new { mensaje = "Devuelta a la cola." })
                : Results.NotFound(new RespuestaError(
                    "No se pudo reintentar.",
                    "O no existe, o no está agotada. Solo se reintentan las " +
                    "entregas que agotaron sus intentos."));
        })
        .AddEndpointFilter<FiltroClaveOperador>()
        .WithTags("Webhooks")
        .WithSummary("Reintenta una entrega agotada")
        .WithDescription(
            "Para después de corregir la causa: la URL estaba mal, el " +
            "servidor del cliente estaba caído.");
    }
}

public record NuevoWebhook(string Nombre, string Url, string[]? Eventos);

public record CambioEstadoWebhook(bool Activo);
