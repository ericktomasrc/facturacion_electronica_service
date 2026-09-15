using Facturacion.Persistencia;

namespace Facturacion.Api;

/// <summary>
/// Descarga de los archivos de un comprobante.
///
/// POR QUÉ EXISTEN ESTOS ENDPOINTS:
///
/// El XML firmado y el CDR son documentos con valor legal, y el emisor tiene
/// obligación de conservarlos y de poder entregárselos a su cliente. Si el
/// servicio los genera pero no los devuelve, la empresa que te contrata sigue
/// sin poder cumplir esa obligación.
///
/// El PDF es lo que se le entrega al comprador.
/// </summary>
public static class EndpointsDescarga
{
    public static void MapearDescargas(this WebApplication app)
    {
        var grupo = app.MapGroup("/v1/comprobantes/{id:guid}")
            .WithTags("Descargas");

        grupo.MapGet("/xml", (
            Guid id, ContextoEmisor emisor,
            RepositorioComprobantes repositorio, IAlmacenArchivos archivos,
            CancellationToken ct) =>
            Descargar(id, emisor, repositorio, archivos, TipoArchivo.Xml, ct))
            .WithSummary("Descarga el XML firmado")
            .WithDescription(
                "Es el comprobante de verdad. El PDF es solo su representación " +
                "impresa: si ambos difieren, vale el XML.");

        grupo.MapGet("/cdr", (
            Guid id, ContextoEmisor emisor,
            RepositorioComprobantes repositorio, IAlmacenArchivos archivos,
            CancellationToken ct) =>
            Descargar(id, emisor, repositorio, archivos, TipoArchivo.Cdr, ct))
            .WithSummary("Descarga el CDR")
            .WithDescription(
                "La constancia de recepción de SUNAT. Es la prueba de que el " +
                "comprobante fue recibido, y hay obligación de conservarla.");

        grupo.MapGet("/pdf", (
            Guid id, ContextoEmisor emisor,
            RepositorioComprobantes repositorio, IAlmacenArchivos archivos,
            CancellationToken ct) =>
            Descargar(id, emisor, repositorio, archivos, TipoArchivo.Pdf, ct))
            .WithSummary("Descarga la representación impresa")
            .WithDescription("El documento que se entrega al comprador.");
    }

    private enum TipoArchivo { Xml, Cdr, Pdf }

    private static async Task<IResult> Descargar(
        Guid id,
        ContextoEmisor emisor,
        RepositorioComprobantes repositorio,
        IAlmacenArchivos archivos,
        TipoArchivo tipo,
        CancellationToken ct)
    {
        var tenant = emisor.Exigir();

        // Row Level Security hace el trabajo: si el comprobante es de otra
        // empresa, simplemente no existe para esta consulta. El 404 además
        // no revela que el identificador pertenece a alguien más.
        var rutas = await repositorio.ObtenerRutasAsync(tenant.Id, id, ct);

        if (rutas is null)
            return Results.NotFound(new RespuestaError("No se encontró el comprobante."));

        var (ruta, extension, mime) = tipo switch
        {
            TipoArchivo.Xml => (rutas.RutaXml, "xml", "application/xml"),
            TipoArchivo.Cdr => (rutas.RutaCdr, "zip", "application/zip"),
            TipoArchivo.Pdf => (rutas.RutaPdf, "pdf", "application/pdf"),
            _ => (null, "", "")
        };

        if (string.IsNullOrWhiteSpace(ruta))
        {
            // Un mensaje que explica POR QUÉ falta, no solo que falta.
            // "No disponible" obliga a adivinar; esto dirige a la causa.
            var motivo = tipo switch
            {
                TipoArchivo.Xml =>
                    $"El comprobante está en estado {rutas.Estado} y todavía no se firmó.",

                TipoArchivo.Cdr =>
                    $"El comprobante está en estado {rutas.Estado}. " +
                    "El CDR solo existe cuando SUNAT ya respondió.",

                _ =>
                    $"El comprobante está en estado {rutas.Estado}. " +
                    "El PDF se genera después de la respuesta de SUNAT."
            };

            return Results.NotFound(new RespuestaError("Archivo no disponible.", motivo));
        }

        var contenido = await archivos.LeerAsync(ruta, ct);

        if (contenido is null)
        {
            // La base dice que existe pero el almacén no lo tiene. Eso es una
            // inconsistencia real y conviene que el mensaje lo diga así, en
            // vez de disfrazarlo de "no encontrado".
            return Results.Problem(
                detail:
                    $"El comprobante registra el archivo en '{ruta}' pero el " +
                    "almacén no lo tiene. Revisa que la API y el worker apunten " +
                    "a la misma carpeta.",
                statusCode: StatusCodes.Status500InternalServerError,
                title: "Archivo registrado pero ausente");
        }

        return Results.File(contenido, mime, rutas.NombreDescarga(extension));
    }
}
