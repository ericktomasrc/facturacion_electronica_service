using System.Text.Json;
using Facturacion.Cpe;
using Facturacion.Pdf;
using Facturacion.Persistencia;

namespace Facturacion.Api;

/// <summary>
/// Reconstruye un comprobante guardado y genera su PDF.
///
/// POR QUÉ ESTO ES UNA CLASE Y NO DOS TROZOS DE CÓDIGO REPETIDOS:
///
/// Hay dos rutas que generan PDF y no se pueden juntar, porque resuelven de
/// quién es el comprobante de formas distintas:
///
///   /v1/comprobantes/{id}/pdf     lo pide el emisor con su clave
///   /admin/comprobantes/{id}/pdf  lo pide el operador desde el panel, que
///                                 primero averigua a qué empresa pertenece
///
/// Lo que sí es idéntico es TODO lo que viene después: saber qué tipo de
/// documento es, reconstruirlo desde el JSON, elegir el generador que le
/// toca y traducir el estado.
///
/// Eso estaba escrito dos veces, y pasó lo que siempre pasa: al aparecer la
/// liquidación de compra, la retención y la percepción, se arregló una ruta
/// y se olvidó la otra. /v1 devolvía el PDF y /admin devolvía "tipo de
/// comprobante no soportado: 04".
///
/// Ahora las dos llaman aquí. Un documento nuevo se añade en un solo sitio.
/// </summary>
public static class PdfDeComprobante
{
    private static readonly JsonSerializerOptions OpcionesJson = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        PropertyNameCaseInsensitive = true
    };

    /// <summary>
    /// Reconstruye el comprobante desde el JSON guardado.
    ///
    /// AQUÍ SE AÑADE UN DOCUMENTO NUEVO, y en ningún otro sitio de la API.
    /// </summary>
    public static ComprobanteBase Deserializar(DatosParaPdf datos) =>
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

            LiquidacionCompra.Tipo =>
                JsonSerializer.Deserialize<LiquidacionCompra>(datos.CpeJson, OpcionesJson)!,

            ComprobanteRetencion.Tipo =>
                JsonSerializer.Deserialize<ComprobanteRetencion>(datos.CpeJson, OpcionesJson)!,

            ComprobantePercepcion.Tipo =>
                JsonSerializer.Deserialize<ComprobantePercepcion>(datos.CpeJson, OpcionesJson)!,

            _ => throw new InvalidOperationException(
                $"Tipo de comprobante no soportado: {datos.TipoComprobante}")
        };

    /// <summary>
    /// Elige el generador y produce el PDF.
    ///
    /// GeneradorPdf imprime una VENTA: detalle de productos, IGV que el
    /// cliente paga y un total que es el número más grande de la hoja. Los
    /// tres documentos de abajo no cumplen ninguna de las tres cosas, y por
    /// eso tienen el suyo.
    /// </summary>
    public static byte[] Generar(
        ComprobanteBase comprobante, string? digest, OpcionesImpresion opciones) =>
        comprobante switch
        {
            LiquidacionCompra lc =>
                GeneradorPdfEspeciales.Generar(lc, digest, opciones),

            ComprobanteRetencion r =>
                GeneradorPdfEspeciales.Generar(r, digest, opciones),

            ComprobantePercepcion p =>
                GeneradorPdfEspeciales.Generar(p, digest, opciones),

            _ => GeneradorPdf.Generar(comprobante, digest, opciones)
        };

    /// <summary>
    /// Cómo se imprime el estado en el pie del documento.
    ///
    /// Es lo que lee quien recibe el papel, así que dice qué pasó, no cómo se
    /// llama la constante en la base.
    /// </summary>
    public static string TextoEstado(string estado) => estado switch
    {
        "ACEPTADO" => "Aceptado por SUNAT",
        "ACEPTADO_CON_OBSERVACIONES" => "Aceptado con observaciones",
        "RECHAZADO" => "Rechazado por SUNAT",
        "ANULADO" => "Dado de baja",
        _ => "Pendiente de envío"
    };

    /// <summary>
    /// Convierte el `extra` guardado del comprobante en pares listos para
    /// imprimir.
    ///
    /// ESTO NO VIAJA A SUNAT Y NO DEBE VIAJAR. Son campos propios de la
    /// empresa: la orden de compra, un centro de costo, el nombre del
    /// vendedor. El XML no tiene sitio para ellos y el papel sí.
    ///
    /// UN JSON ILEGIBLE NO PUEDE IMPEDIR QUE SE ENTREGUE EL COMPROBANTE. Si
    /// algo no cuadra, devuelve null y el PDF sale exactamente como antes.
    /// Un dato de adorno no vale una factura que no se puede imprimir.
    ///
    /// Los objetos y los arreglos se descartan: no hay forma de ponerlos en
    /// una línea, y escribir su JSON crudo en una factura sería peor que no
    /// escribir nada.
    /// </summary>
    private static IReadOnlyDictionary<string, string>? LeerExtra(string? extraJson)
    {
        if (string.IsNullOrWhiteSpace(extraJson)) return null;

        try
        {
            using var doc = JsonDocument.Parse(extraJson);

            if (doc.RootElement.ValueKind != JsonValueKind.Object) return null;

            var pares = new Dictionary<string, string>();

            foreach (var campo in doc.RootElement.EnumerateObject())
            {
                var texto = campo.Value.ValueKind switch
                {
                    JsonValueKind.String => campo.Value.GetString(),
                    JsonValueKind.Number => campo.Value.GetRawText(),
                    JsonValueKind.True   => "Sí",
                    JsonValueKind.False  => "No",
                    _                    => null
                };

                if (!string.IsNullOrWhiteSpace(texto))
                    pares[campo.Name] = texto!;
            }

            return pares.Count > 0 ? pares : null;
        }
        catch (JsonException)
        {
            return null;
        }
    }

    /// <summary>
    /// El logo de la empresa, o null si no tiene o no se puede leer.
    ///
    /// Que el almacén falle al leer el logo tampoco impide el PDF: se
    /// entrega sin él.
    /// </summary>
    private static async Task<byte[]?> LeerLogoAsync(
        string? ruta, IAlmacenArchivos archivos, CancellationToken ct)
    {
        if (string.IsNullOrWhiteSpace(ruta)) return null;

        try
        {
            return await archivos.LeerAsync(ruta, ct);
        }
        catch (Exception) when (!ct.IsCancellationRequested)
        {
            return null;
        }
    }

    /// <summary>
    /// Todo el camino de una vez: comprobar el estado, reconstruir, leer el
    /// resumen de la firma y generar.
    ///
    /// Devuelve el PDF, o un IResult con el problema si algo impide hacerlo.
    /// Las dos rutas entran aquí con lo que cada una supo averiguar por su
    /// cuenta.
    /// </summary>
    public static async Task<IResult> ResponderAsync(
        DatosParaPdf datos, IAlmacenArchivos archivos, CancellationToken ct)
    {
        // UN PDF DE UN BORRADOR INDUCE A ERROR y por eso no se genera.
        //
        // El comprobante todavía no se firmó ni se envió: puede terminar
        // rechazado, y quien reciba ese papel creería que tiene algo válido.
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

        var pdf = await GenerarBytesAsync(comprobante, datos, archivos, ct);

        return Results.File(pdf, "application/pdf", $"{datos.Numero}.pdf");
    }

    /// <summary>
    /// El PDF de un comprobante ya reconstruido, en bytes.
    ///
    /// Es lo mismo que sirve ResponderAsync, separado para que el correo de
    /// entrega adjunte EXACTAMENTE el mismo PDF que se descarga del panel y
    /// del portal. Dos caminos para hacer el PDF acabarían dando dos PDF.
    /// </summary>
    public static async Task<byte[]> GenerarBytesAsync(
        ComprobanteBase comprobante, DatosParaPdf datos,
        IAlmacenArchivos archivos, CancellationToken ct)
    {
        // EL RESUMEN DE LA FIRMA SE LEE DEL XML, no se recalcula.
        //
        // El QR debe declarar exactamente lo que se firmó. Calcularlo por
        // separado abriría la puerta a que los dos valores se separen sin que
        // nadie lo note, y un QR que no cuadra con la firma es peor que no
        // tener QR.
        string? digest = null;

        if (!string.IsNullOrWhiteSpace(datos.RutaXml))
        {
            var xml = await archivos.LeerAsync(datos.RutaXml, ct);

            if (xml is not null)
            {
                try
                {
                    digest = CodigoQr.LeerDigest(System.Xml.Linq.XDocument.Parse(
                        System.Text.Encoding.UTF8.GetString(xml)));
                }
                catch (Exception)
                {
                    // Sin resumen el PDF se genera igual, solo que su QR no
                    // podrá verificarse contra la firma. Entregar un documento
                    // incompleto es mejor que no entregar ninguno.
                }
            }
        }

        var logo = await LeerLogoAsync(datos.LogoRuta, archivos, ct);

        var opciones = new OpcionesImpresion(
            EstadoSunat: TextoEstado(datos.Estado),
            MensajeSunat: datos.MensajeSunat,
            Logo: logo,
            Extra: LeerExtra(datos.ExtraJson));

        byte[] pdf;

        try
        {
            pdf = Generar(comprobante, digest, opciones);
        }
        catch (Exception) when (logo is not null)
        {
            // UN LOGO QUE NO SE PUEDE DIBUJAR NO DEJA SIN COMPROBANTE A NADIE.
            //
            // Al subirlo se prueba a dibujarlo (Marca.ProblemaAlDibujar), así
            // que esto no debería pasar. Si pasa, el PDF sale sin logo: es el
            // mismo criterio que con `extra`. Un adorno no vale una factura
            // que no se puede entregar.
            pdf = Generar(comprobante, digest, opciones with { Logo = null });
        }

        return pdf;
    }
}