using Facturacion.Persistencia;

namespace Facturacion.Api;

/// <summary>Cuerpo de POST /v1/comprobantes/{id}/enlace-portal. Todo opcional.</summary>
public sealed record PeticionEnlacePortal(int? Dias);

/// <summary>
/// 22 OCT — UN ENLACE AL PORTAL PARA MANDARLO POR WHATSAPP.
///
/// La plataforma (o quien integre) pide el enlace y lo manda por donde quiera.
/// Es el mismo acceso que lleva el correo de entrega: abre SOLO ese
/// comprobante, caduca (30 días por defecto, 90 como mucho) y se guarda su
/// hash, nunca el enlace.
///
/// A DIFERENCIA DEL CORREO, se puede pedir apenas se emite: una boleta viaja a
/// SUNAT en el resumen del día siguiente, y el cliente no puede esperar al
/// otro día para recibirla. El portal la enseña «en camino a SUNAT» hasta que
/// SUNAT conteste. Uno RECHAZADO no tiene enlace: no es un comprobante.
/// </summary>
public static class EndpointsEnlacePortal
{
    public const int DiasPorDefecto = 30;

    public static void MapearEnlacePortal(this WebApplication app)
    {
        app.MapPost("/v1/comprobantes/{id:guid}/enlace-portal", async (
            Guid id, PeticionEnlacePortal? p, ContextoEmisor emisor, RepositorioPortal portal,
            OpcionesCorreo correo, CancellationToken ct) =>
        {
            var tenant = emisor.Exigir();

            var identificador = await portal.IdentificadorAsync(tenant.Id, ct);
            if (identificador is null)
                return Results.Conflict(new RespuestaError(
                    "La empresa no tiene dirección en el portal de comprobantes.",
                    "Sin ella no hay enlace que mandar. Se configura en el panel del servicio (Empresas › Portal)."));

            var c = await portal.ObtenerAsync(tenant.Id, id, ct);
            if (c is null)
                return Results.NotFound(new RespuestaError(
                    "No se encontró el comprobante, o SUNAT lo rechazó.",
                    "Solo tienen enlace las facturas, boletas y notas que SUNAT aceptó o que están en camino."));

            var dias = Math.Clamp(p?.Dias ?? DiasPorDefecto, 1, 90);
            var acceso = AccesoPortal.Nuevo();
            await portal.CrearAccesoAsync(
                tenant.Id, id, AccesoPortal.Hash(acceso), "whatsapp", TimeSpan.FromDays(dias), ct);

            return Results.Ok(new
            {
                url = $"{correo.UrlPortalEfectiva}/{identificador}/e/{acceso}",
                expiraEn = DateTime.UtcNow.AddDays(dias),
                numero = c.Numero
            });
        })
        .WithTags("Comprobantes")
        .WithSummary("Un enlace al portal del receptor para este comprobante (para WhatsApp)")
        .WithDescription("Abre solo este comprobante y caduca (30 días por defecto). Sirve también " +
                         "mientras el comprobante está en camino a SUNAT.");
    }
}