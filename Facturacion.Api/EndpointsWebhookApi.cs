using Facturacion.Persistencia;

namespace Facturacion.Api;

/// <summary>
/// El webhook de la propia empresa, gestionado con su clave fac_.
///
/// Diseño: alta-empresa-diseno.md, parte A. Lo usa la plataforma al
/// «Conectar» una empresa: registra su propio webhook y se queda el secreto
/// sin que nadie lo copie a mano.
///
///   POST /v1/webhook             lo crea, o le cambia la URL y el secreto
///   GET  /v1/webhook             cómo está (nunca el secreto)
///   POST /v1/webhook/reintentar  devuelve a la cola sus entregas agotadas
///
/// LA EMPRESA SALE DE LA CLAVE, NUNCA DE LA PETICIÓN. Ninguna de estas rutas
/// lleva un id de empresa ni de webhook: solo existe «el webhook de la API de
/// quien llama». Y todo va con el rol facturacion_app y RLS
/// (RepositorioWebhookApi), no con el de operador.
///
/// LO QUE ESTO ABRE, Y CÓMO SE CIERRA (diseño §2.4): desde ahora una clave
/// decide a dónde manda el servicio sus avisos. Por eso la URL pasa por
/// DestinoWebhook aquí, y otra vez en el worker al despachar: solo https y
/// solo direcciones públicas. Y cada cambio queda en webhook_cambios con el
/// prefijo de la clave que lo hizo.
/// </summary>
public static class EndpointsWebhookApi
{
    private const string DescripcionFirma =
        "Cada aviso llega por POST con las cabeceras X-Facturacion-Timestamp, " +
        "X-Facturacion-Firma, X-Facturacion-Evento y X-Facturacion-Tipo. La firma " +
        "es el HMAC-SHA256 de 'timestamp.cuerpo' con el secreto, en hexadecimal " +
        "minúsculo. Suscrito a todos los eventos.";

    public static void MapearWebhookApi(this WebApplication app)
    {
        var grupo = app.MapGroup("/v1/webhook").WithTags("Webhook de la empresa");

        grupo.MapPost("", async (
            PeticionWebhookApi peticion,
            ContextoEmisor emisor,
            RepositorioWebhookApi repositorio,
            ReglasDestinoWebhook reglas,
            ILoggerFactory registro,
            CancellationToken ct) =>
        {
            var tenant = emisor.Exigir();
            var url = peticion.Url?.Trim();

            var problema = await DestinoWebhook.RevisarAsync(url, reglas.PermitirLocales, ct);

            if (problema is not null)
                return Results.BadRequest(new RespuestaError("La URL no es válida.", problema));

            var r = await repositorio.RegistrarAsync(tenant.Id, url!, emisor.PrefijoClave, ct);

            // Al registro va QUÉ pasó, nunca el secreto.
            registro.CreateLogger("Facturacion.Api.WebhookApi").LogInformation(
                "Webhook de la API {Accion} para la empresa {Ruc} con la clave {Prefijo}…: {Url}",
                r.Creado ? "creado" : "rotado", tenant.Ruc, emisor.PrefijoClave, r.Url);

            return Results.Ok(new
            {
                id = r.Id,
                url = r.Url,
                secreto = r.Secreto,
                creado = r.Creado,
                urlAnterior = r.UrlAnterior,
                aviso = r.Creado
                    ? "Guarda el secreto ahora: no se vuelve a mostrar."
                    : "El secreto anterior dejó de valer ahora mismo. Las entregas en " +
                      "cola saldrán firmadas con este."
            });
        })
        .WithSummary("Registra el webhook de la empresa, o le cambia la URL y el secreto")
        .WithDescription(
            "La empresa es la de la clave. Si ya tiene webhook de la API, se " +
            "actualiza en la misma fila y se genera un secreto NUEVO: el anterior " +
            "deja de valer en ese momento. El secreto se devuelve solo aquí. " +
            "La URL tiene que ser https:// y pública. " + DescripcionFirma);

        grupo.MapGet("", async (
            ContextoEmisor emisor, RepositorioWebhookApi repositorio, CancellationToken ct) =>
        {
            var tenant = emisor.Exigir();

            var (w, ultima, cambio, otros) = await repositorio.ObtenerAsync(tenant.Id, ct);

            if (w is null)
                return Results.Ok(new { registrado = false, otrosWebhooksActivos = otros });

            return Results.Ok(new
            {
                registrado = true,
                id = w.Id,
                url = w.Url,
                eventos = "todos",
                creadoEn = w.CreadoEn,
                secretoCambiadoEn = w.SecretoCambiadoEn,
                pendientes = w.Pendientes,
                agotados = w.Agotados,
                ultimaEntrega = ultima is null ? null : new
                {
                    tipo = ultima.Tipo,
                    estado = ultima.Estado,
                    intentos = ultima.Intentos,
                    codigo = ultima.UltimoCodigo,
                    error = ultima.UltimoError,
                    creadoEn = ultima.CreadoEn,
                    entregadoEn = ultima.EntregadoEn
                },
                ultimoCambio = cambio is null ? null : new
                {
                    accion = cambio.Accion,
                    hechoDesde = cambio.HechoDesde,
                    prefijoClave = cambio.PrefijoClave,
                    en = cambio.CreadoEn
                },
                otrosWebhooksActivos = otros
            });
        })
        .WithSummary("Cómo está el webhook de la empresa")
        .WithDescription(
            "URL, entregas pendientes y agotadas, la última entrega y el último " +
            "cambio. Nunca el secreto. otrosWebhooksActivos cuenta los registrados " +
            "a mano en el panel del servicio, que no se ven desde aquí.");

        grupo.MapPost("/reintentar", async (
            int? dias,
            ContextoEmisor emisor, RepositorioWebhookApi repositorio, CancellationToken ct) =>
        {
            var tenant = emisor.Exigir();
            var plazo = Math.Clamp(dias ?? 7, 1, 30);

            var reencoladas = await repositorio.ReintentarAgotadasAsync(tenant.Id, plazo, ct);

            return Results.Ok(new
            {
                reencoladas,
                dias = plazo,
                mensaje = reencoladas == 0
                    ? "No había entregas agotadas."
                    : $"{reencoladas} entregas devueltas a la cola. Saldrán en los próximos segundos."
            });
        })
        .WithSummary("Devuelve a la cola las entregas agotadas del webhook de la empresa")
        .WithDescription(
            "Solo las del webhook de la API de la empresa de la clave, de los " +
            "últimos 'dias' días (7 si no se dice; de 1 a 30). Para después de " +
            "rotar el secreto: los avisos que se rechazaron mientras tanto vuelven " +
            "a salir con el mismo evento.");
    }
}

/// <summary>Cuerpo de POST /v1/webhook. Ni empresa ni secreto: salen de la clave.</summary>
public record PeticionWebhookApi(string? Url);