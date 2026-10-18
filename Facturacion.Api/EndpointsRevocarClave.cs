using Facturacion.Persistencia;

namespace Facturacion.Api;

/// <summary>
/// PUNTO 21: QUE UNA CLAVE fac_ SE PUEDA REVOCAR A SÍ MISMA.
///
///     POST /v1/clave/revocar        con la clave que se quiere revocar
///
/// Para la plataforma: al rotar, se queda con la clave nueva y le pide al
/// servicio que dé de baja la anterior, llamando CON LA ANTERIOR. Así no hace
/// falta ninguna clave especial: quien tiene una clave puede matarla, y nada
/// más. No puede revocar otra, ni ver cuáles hay.
///
/// UNA CONDICIÓN: tiene que quedar otra clave activa de la misma empresa. Si
/// fuera la única, la empresa se quedaría sin poder emitir y solo el panel lo
/// arreglaría; eso responde 409 y no toca nada. (Una clave filtrada que es la
/// única se revoca desde el panel, después de emitir otra.)
///
/// Funciona también con la empresa EN PAUSA: revocar no emite nada, y es
/// justo lo que conviene poder hacer siempre.
///
/// Respuestas: 200 revocada · 409 es la única activa · 401 la clave ya no vale.
/// </summary>
public static class EndpointsRevocarClave
{
    public static void MapearRevocarClave(this WebApplication app)
    {
        app.MapPost("/v1/clave/revocar", async (
            HttpContext http, ContextoEmisor emisor, RepositorioRevocacionClaves repo,
            ILoggerFactory logs, CancellationToken ct) =>
        {
            var tenant = emisor.Exigir();

            // La clave en claro solo está en la cabecera: el contexto guarda su
            // prefijo, no la clave. Se lee igual que la lee el middleware.
            var clave = LeerClave(http.Request);
            if (string.IsNullOrWhiteSpace(clave))
                return Results.Json(new RespuestaError("Falta la clave de acceso."),
                    statusCode: StatusCodes.Status401Unauthorized);

            var r = await repo.RevocarAsync(tenant.Id, RepositorioTenants.CalcularHash(clave), ct);

            var log = logs.CreateLogger("Claves");

            switch (r)
            {
                case ResultadoRevocacion.Revocada:
                    log.LogWarning("Clave {Prefijo}… de {Ruc} revocada por sí misma (POST /v1/clave/revocar).",
                                   emisor.PrefijoClave, tenant.Ruc);
                    return Results.Ok(new
                    {
                        revocada = true,
                        prefijo = emisor.PrefijoClave,
                        mensaje = "Clave revocada. Desde ahora el servicio la rechaza."
                    });

                case ResultadoRevocacion.EsLaUnica:
                    return Results.Conflict(new RespuestaError(
                        "Es la única clave activa de esta empresa: no se revoca.",
                        "Sin ella la empresa no podría emitir. Emite otra en el panel del servicio " +
                        "(Claves de acceso) y revoca esta desde allí o con la nueva ya en uso."));

                default:
                    // Revocada entre la autenticación y aquí: ya no vale.
                    return Results.Json(new RespuestaError("Clave de acceso no válida."),
                        statusCode: StatusCodes.Status401Unauthorized);
            }
        })
        .WithName("RevocarEstaClave")
        .WithTags("Emisor")
        .WithSummary("Revoca la clave con la que se llama (punto 21)")
        .WithDescription(
            "Da de baja **la clave con la que se hace la llamada**. Sirve para rotar: con la " +
            "clave nueva ya en uso, se llama aquí con la ANTERIOR.\n\n" +
            "No revoca la única clave activa de la empresa (409). No se puede deshacer: " +
            "una clave revocada no vuelve.")
        .Produces(StatusCodes.Status200OK)
        .Produces<RespuestaError>(StatusCodes.Status409Conflict)
        .Produces<RespuestaError>(StatusCodes.Status401Unauthorized);
    }

    private static string? LeerClave(HttpRequest peticion)
    {
        var autorizacion = peticion.Headers.Authorization.ToString();

        if (autorizacion.StartsWith("Bearer ", StringComparison.OrdinalIgnoreCase))
            return autorizacion["Bearer ".Length..].Trim();

        var cabecera = peticion.Headers["X-Api-Key"].ToString();

        return string.IsNullOrWhiteSpace(cabecera) ? null : cabecera.Trim();
    }
}