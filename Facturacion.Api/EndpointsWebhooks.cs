using Facturacion.Persistencia;

namespace Facturacion.Api;

/// <summary>
/// Configuración de webhooks por empresa.
///
/// El secreto de firma se muestra UNA sola vez al crearlos, igual que las
/// claves de acceso. Sin él, el cliente no puede verificar que los avisos
/// vienen de nosotros.
///
/// DESDE LA 023 HAY DOS ORÍGENES. Los de aquí son 'panel'. Los 'api' los
/// registra la propia empresa con su clave (EndpointsWebhookApi): aquí se
/// ven, se pueden desactivar y probar, pero su URL y su secreto los mantiene
/// la plataforma al conectar.
///
/// NADA SE BORRA (punto 18): ya no hay DELETE. Se desactiva, y el webhook
/// conserva su historial de entregas y de cambios.
/// </summary>
public static class EndpointsWebhooks
{
    public static void MapearWebhooks(this WebApplication app)
    {
        var grupo = app.MapGroup("/admin/tenants/{id:guid}/webhooks")
            .AddEndpointFilter<AutenticacionPanel>()
            .AddEndpointFilter(new ExigirPermiso(Permiso.WebhooksGestionar))
            .WithTags("Webhooks");

        grupo.MapGet("", async (
            Guid id, RepositorioWebhooks webhooks, CancellationToken ct) =>
            Results.Ok(await webhooks.ListarAsync(id, ct)))
            .WithSummary("Lista los webhooks de una empresa");

        grupo.MapPost("", async (
            Guid id, NuevoWebhook nuevo,
            RepositorioWebhooks webhooks, ReglasDestinoWebhook reglas,
            CancellationToken ct) =>
        {
            // Las mismas reglas que /v1/webhook y que el worker al despachar:
            // https y dirección pública, salvo en desarrollo con
            // FACTURACION_WEBHOOKS_LOCALES. Un webhook del panel que el worker
            // luego no pudiera entregar solo serviría para confundir.
            var problema = await DestinoWebhook.RevisarAsync(
                nuevo.Url, reglas.PermitirLocales, ct);

            if (problema is not null)
                return Results.BadRequest(new RespuestaError("La URL no es válida.", problema));

            var (webhookId, secreto) = await webhooks.CrearAsync(
                id, nuevo.Nombre, nuevo.Url.Trim(), nuevo.Eventos ?? [], ct);

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
            var resultado = await webhooks.CambiarEstadoAsync(
                id, webhookId, cambio.Activo, ct);

            return resultado switch
            {
                null => Results.NotFound(new RespuestaError("No se encontró el webhook.")),

                ResultadoCambioEstado.Conflicto => Results.Conflict(new RespuestaError(
                    "La empresa ya tiene otro webhook de la API activo.",
                    "Solo puede haber uno: con dos, cada factura se avisaría dos " +
                    "veces. Desactiva el otro primero.")),

                _ => Results.Ok(new { mensaje = cambio.Activo
                    ? "Webhook activado." : "Webhook desactivado." })
            };
        })
        .WithSummary("Activa o desactiva un webhook")
        .WithDescription(
            "Sustituye a «Eliminar»: nada se borra. El webhook desactivado deja " +
            "de recibir avisos y conserva su historial.");

        app.MapGet("/admin/tenants/{id:guid}/webhook-cambios", async (
            Guid id, RepositorioWebhooks webhooks, int? limite,
            CancellationToken ct) =>
            Results.Ok(await webhooks.CambiosAsync(
                id, Math.Clamp(limite ?? 30, 1, 200), ct)))
            .AddEndpointFilter<AutenticacionPanel>()
            .AddEndpointFilter(new ExigirPermiso(Permiso.WebhooksGestionar))
            .WithTags("Webhooks")
            .WithSummary("Quién cambió los webhooks de la empresa")
            .WithDescription(
                "Altas y rotaciones hechas por la API (con el prefijo de la " +
                "clave) y activaciones desde el panel. Nunca el secreto.");

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
            .AddEndpointFilter<AutenticacionPanel>()
            .AddEndpointFilter(new ExigirPermiso(Permiso.WebhooksGestionar))
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
        .AddEndpointFilter<AutenticacionPanel>()
        .AddEndpointFilter(new ExigirPermiso(Permiso.WebhooksGestionar))
        .WithTags("Webhooks")
        .WithSummary("Reintenta una entrega agotada")
        .WithDescription(
            "Para después de corregir la causa: la URL estaba mal, el " +
            "servidor del cliente estaba caído.");
    }
}

public record NuevoWebhook(string Nombre, string Url, string[]? Eventos);

public record CambioEstadoWebhook(bool Activo);