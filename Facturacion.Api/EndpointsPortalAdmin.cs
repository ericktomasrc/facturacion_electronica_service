using Facturacion.Persistencia;

namespace Facturacion.Api;

/// <summary>
/// El portal del receptor visto desde el panel: qué correo salió de un
/// comprobante, qué enlaces tiene y anularlos.
///
/// Anular es lo que se hace cuando el correo fue a la dirección equivocada o
/// el cliente lo pide. Se anula, no se borra: queda cuántas veces se usó el
/// enlace y cuándo dejó de servir.
/// </summary>
public static class EndpointsPortalAdmin
{
    public static void MapearPortalAdmin(this WebApplication app)
    {
        var grupo = app.MapGroup("/admin/comprobantes/{id:guid}/portal")
            .AddEndpointFilter<AutenticacionPanel>()
            .WithTags("Administración");

        grupo.MapGet("", async (
            Guid id, RepositorioCorreosPortal portal, CancellationToken ct) =>
        {
            var (correo, accesos) = await portal.ListarAsync(id, ct);

            return Results.Ok(new
            {
                correo,
                accesos = accesos.Select(a => new
                {
                    a.Id,
                    a.Origen,
                    a.CreadoEn,
                    a.ExpiraEn,
                    a.AnuladoEn,
                    a.AnuladoMotivo,
                    a.Usos,
                    a.UltimoUsoEn,
                    vigente = a.AnuladoEn is null && a.ExpiraEn > DateTime.UtcNow
                })
            });
        })
        .AddEndpointFilter(new ExigirPermiso(Permiso.ComprobantesVer))
        .WithSummary("El correo de entrega y los enlaces del portal de un comprobante");

        grupo.MapPost("/anular", async (
            Guid id, AnulacionAccesos peticion,
            RepositorioCorreosPortal portal, CancellationToken ct) =>
        {
            var motivo = (peticion.Motivo ?? "").Trim();

            if (motivo.Length < 3)
                return Results.BadRequest(new RespuestaError(
                    "Escribe el motivo.",
                    "Queda guardado junto al enlace: es lo que se lee después " +
                    "cuando alguien pregunta por qué dejó de abrir."));

            if (motivo.Length > 300) motivo = motivo[..300];

            var anulados = await portal.AnularAccesosAsync(id, motivo, ct);

            return Results.Ok(new
            {
                anulados,
                mensaje = anulados == 0
                    ? "No había enlaces vigentes."
                    : anulados == 1 ? "Se anuló 1 enlace." : $"Se anularon {anulados} enlaces."
            });
        })
        .AddEndpointFilter(new ExigirPermiso(Permiso.ComprobantesReprocesar))
        .WithSummary("Anula los enlaces vigentes del portal de un comprobante");
    }
}

public record AnulacionAccesos(string? Motivo);