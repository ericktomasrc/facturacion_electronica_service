using Facturacion.Cpe;
using Facturacion.Pdf;
using Facturacion.Persistencia;

namespace Facturacion.Api;

/// <summary>
/// Descarga de los archivos de un comprobante.
///
/// EL XML Y EL CDR SE LEEN DEL ALMACÉN. EL PDF SE GENERA AL PEDIRLO.
///
/// La diferencia no es capricho: el XML firmado y el CDR son documentos con
/// valor legal e irreemplazables. El PDF es solo su representación impresa, y
/// se puede reconstruir desde el mismo cpe que está en la base.
///
/// Guardarlo costaría más de dos terabytes al año con cien mil comprobantes
/// diarios, para algo que se rehace en décimas de segundo.
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
            DescargarArchivo(id, emisor, repositorio, archivos, TipoArchivo.Xml, ct))
            .WithSummary("Descarga el XML firmado")
            .WithDescription(
                "Es el comprobante de verdad. El PDF es solo su representación " +
                "impresa: si ambos difieren, vale el XML.");

        grupo.MapGet("/cdr", (
            Guid id, ContextoEmisor emisor,
            RepositorioComprobantes repositorio, IAlmacenArchivos archivos,
            CancellationToken ct) =>
            DescargarArchivo(id, emisor, repositorio, archivos, TipoArchivo.Cdr, ct))
            .WithSummary("Descarga el CDR")
            .WithDescription(
                "La constancia de recepción de SUNAT. Es la prueba de que el " +
                "comprobante fue recibido, y hay obligación de conservarla.");

        grupo.MapGet("/pdf", GenerarPdf)
            .WithSummary("Genera la representación impresa")
            .WithDescription(
                "El PDF no se almacena: se genera en el momento a partir del " +
                "comprobante guardado. Así el resultado siempre refleja el " +
                "estado actual, y el almacén no crece con archivos que se " +
                "pueden rehacer.");
    }

    // --------------------------------------------------------------- archivos

    private enum TipoArchivo { Xml, Cdr }

    private static async Task<IResult> DescargarArchivo(
        Guid id,
        ContextoEmisor emisor,
        RepositorioComprobantes repositorio,
        IAlmacenArchivos archivos,
        TipoArchivo tipo,
        CancellationToken ct)
    {
        var tenant = emisor.Exigir();

        // Row Level Security hace el trabajo: si el comprobante es de otra
        // empresa, simplemente no existe para esta consulta. El 404 además no
        // revela que ese identificador pertenece a alguien.
        var rutas = await repositorio.ObtenerRutasAsync(tenant.Id, id, ct);

        if (rutas is null)
            return Results.NotFound(new RespuestaError("No se encontró el comprobante."));

        var (ruta, extension, mime) = tipo switch
        {
            TipoArchivo.Xml => (rutas.RutaXml, "xml", "application/xml"),
            _ => (rutas.RutaCdr, "zip", "application/zip")
        };

        if (string.IsNullOrWhiteSpace(ruta))
        {
            // Un mensaje que explica POR QUÉ falta, no solo que falta.
            var motivo = tipo == TipoArchivo.Xml
                ? $"El comprobante está en estado {rutas.Estado} y todavía no se firmó."
                : $"El comprobante está en estado {rutas.Estado}. " +
                  "El CDR solo existe cuando SUNAT ya respondió.";

            return Results.NotFound(new RespuestaError("Archivo no disponible.", motivo));
        }

        var contenido = await archivos.LeerAsync(ruta, ct);

        if (contenido is null)
        {
            // La base dice que existe pero el almacén no lo tiene. Es una
            // inconsistencia real y el mensaje lo dice así, en vez de
            // disfrazarla de "no encontrado".
            return Results.Problem(
                detail:
                    $"El comprobante registra el archivo en '{ruta}' pero el " +
                    "almacén no lo tiene. Revisa que la API y el worker apunten " +
                    "al mismo almacén.",
                statusCode: StatusCodes.Status500InternalServerError,
                title: "Archivo registrado pero ausente");
        }

        return Results.File(contenido, mime, rutas.NombreDescarga(extension));
    }

    // -------------------------------------------------------------------- pdf

    private static async Task<IResult> GenerarPdf(
        Guid id,
        ContextoEmisor emisor,
        RepositorioComprobantes repositorio,
        IAlmacenArchivos archivos,
        string? formato,   // 22 oct: ?formato=ticket80 | ticket58 (por defecto, A4)
        CancellationToken ct)
    {
        var tenant = emisor.Exigir();

        var datos = await repositorio.ObtenerParaPdfAsync(tenant.Id, id, ct);

        if (datos is null)
            return Results.NotFound(new RespuestaError("No se encontró el comprobante."));

        // TODO LO DEMÁS ES IDÉNTICO A LA RUTA DEL PANEL y vive en un solo
        // sitio: qué tipo de documento es, cómo se reconstruye, qué generador
        // le toca y cómo se lee el resumen de la firma.
        //
        // Lo único que cambia entre las dos rutas es cómo se averigua de quién
        // es el comprobante, y eso es justo lo de arriba.
        return await PdfDeComprobante.ResponderAsync(datos, archivos, ct, formato);
    }
}