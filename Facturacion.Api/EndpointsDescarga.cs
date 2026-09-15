using System.Text.Json;
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
    private static readonly JsonSerializerOptions OpcionesJson = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        PropertyNameCaseInsensitive = true
    };

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
        CancellationToken ct)
    {
        var tenant = emisor.Exigir();

        var datos = await repositorio.ObtenerParaPdfAsync(tenant.Id, id, ct);

        if (datos is null)
            return Results.NotFound(new RespuestaError("No se encontró el comprobante."));

        if (datos.Estado == "BORRADOR")
        {
            return Results.NotFound(new RespuestaError(
                "Todavía no se puede generar el PDF.",
                "El comprobante está en BORRADOR: aún no se firmó ni se envió " +
                "a SUNAT. Un PDF de algo que puede terminar rechazado induciría " +
                "a error a quien lo reciba."));
        }

        ComprobanteBase comprobante;

        try
        {
            comprobante = Deserializar(datos);
        }
        catch (Exception ex)
        {
            return Results.Problem(
                detail: $"No se pudo reconstruir el comprobante: {ex.Message}",
                statusCode: StatusCodes.Status500InternalServerError,
                title: "Comprobante ilegible");
        }

        // El resumen de la firma se LEE del XML guardado, no se recalcula.
        //
        // El QR debe declarar exactamente lo que se firmó. Recalcularlo por
        // separado abriría la puerta a que ambos valores se separen sin que
        // nadie lo note.
        string? digest = null;

        if (!string.IsNullOrWhiteSpace(datos.RutaXml))
        {
            var xml = await archivos.LeerAsync(datos.RutaXml, ct);

            if (xml is not null)
            {
                try
                {
                    var documento = System.Xml.Linq.XDocument.Parse(
                        System.Text.Encoding.UTF8.GetString(xml));

                    digest = CodigoQr.LeerDigest(documento);
                }
                catch (Exception)
                {
                    // Sin digest el PDF se genera igual, solo que su QR no
                    // podrá verificarse contra la firma. Es mejor entregar un
                    // documento incompleto que ninguno.
                }
            }
        }

        var opciones = new OpcionesImpresion(
            EstadoSunat: TextoEstado(datos.Estado),
            MensajeSunat: datos.MensajeSunat);

        var pdf = GeneradorPdf.Generar(comprobante, digest, opciones);

        return Results.File(pdf, "application/pdf", $"{datos.Numero}.pdf");
    }

    private static string TextoEstado(string estado) => estado switch
    {
        "ACEPTADO" => "Aceptado por SUNAT",
        "ACEPTADO_CON_OBSERVACIONES" => "Aceptado con observaciones",
        "RECHAZADO" => "Rechazado por SUNAT",
        "ANULADO" => "Dado de baja",
        _ => "Pendiente de envío"
    };

    private static ComprobanteBase Deserializar(DatosParaPdf datos) =>
        datos.TipoComprobante switch
        {
            TipoComprobante.Factura =>
                JsonSerializer.Deserialize<Factura>(datos.CpeJson, OpcionesJson)!,

            TipoComprobante.Boleta =>
                JsonSerializer.Deserialize<Boleta>(datos.CpeJson, OpcionesJson)!,

            TipoComprobante.NotaCredito =>
                JsonSerializer.Deserialize<NotaCredito>(datos.CpeJson, OpcionesJson)!,

            TipoComprobante.NotaDebito =>
                JsonSerializer.Deserialize<NotaDebito>(datos.CpeJson, OpcionesJson)!,

            _ => throw new InvalidOperationException(
                $"Tipo de comprobante no soportado: {datos.TipoComprobante}")
        };
}
