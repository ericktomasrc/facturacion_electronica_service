namespace Facturacion.Api;

/// <summary>
/// 22 oct — LA PESTAÑA «PADRÓN RUC» DE VIGILANCIA SUNAT: SOLO VER.
///
/// El padrón de SUNAT lo baja y lo usa la PLATAFORMA (para las consultas de
/// RUC); allí se configura y se sube a mano. Aquí solo se enseña su estado,
/// pidiéndoselo a la plataforma por la red interna: cuándo se cargó, cuántos
/// RUC, y si falló, el motivo.
///
/// PLATAFORMA_URL_INTERNA: por defecto http://plataforma:8080 (el nombre del
/// contenedor en compose.aplicacion.yml). En el PC, la dirección de la API de
/// la plataforma.
/// </summary>
public static class EndpointsPadronPlataforma
{
    public const string NombreCliente = "plataforma-interna";

    public static string UrlBase() =>
        (Environment.GetEnvironmentVariable("PLATAFORMA_URL_INTERNA") is { Length: > 0 } u ? u : "http://plataforma:8080")
        .Trim().TrimEnd('/');

    public static void MapearVigilanciaPadron(this WebApplication app)
    {
        app.MapGet("/admin/vigilancia/padron", async (IHttpClientFactory fabrica, CancellationToken ct) =>
        {
            var url = UrlBase() + "/api/publico/padron-estado";
            try
            {
                var http = fabrica.CreateClient(NombreCliente);
                using var resp = await http.GetAsync(url, ct);
                var cuerpo = await resp.Content.ReadAsStringAsync(ct);

                if (!resp.IsSuccessStatusCode)
                    return Results.Json(new RespuestaError(
                        "La plataforma no dio el estado del padrón.",
                        $"Respondió {(int)resp.StatusCode}. ¿Tiene ya la migración 042?"),
                        statusCode: StatusCodes.Status502BadGateway);

                return Results.Content(cuerpo, "application/json");
            }
            catch (Exception e) when (!ct.IsCancellationRequested)
            {
                return Results.Json(new RespuestaError(
                    "No se pudo hablar con la plataforma.",
                    $"{url}: {e.Message}. Revisa PLATAFORMA_URL_INTERNA en el .env del servicio."),
                    statusCode: StatusCodes.Status502BadGateway);
            }
        })
        .AddEndpointFilter<AutenticacionPanel>()
        .WithTags("Vigilancia SUNAT")
        .WithSummary("Estado del padrón de SUNAT de la plataforma (solo ver)");
    }
}