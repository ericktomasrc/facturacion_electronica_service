using System.Globalization;
using System.Xml.Linq;
using Facturacion.Cpe;
using QRCoder;

namespace Facturacion.Pdf;

/// <summary>
/// Genera el código QR de la representación impresa.
///
/// QUÉ CONTIENE Y POR QUÉ IMPORTA:
///
/// El QR no es decoración. Permite que cualquiera —el comprador, un
/// fiscalizador— verifique el comprobante contra SUNAT sin teclear nada.
/// Por eso su contenido está normado: campos separados por barras, en un
/// orden fijo.
///
///     RUC | Tipo | Serie | Correlativo | IGV | Total | Fecha |
///     TipoDocReceptor | NumDocReceptor | Digest |
///
/// El último campo es el resumen de la firma digital, que se extrae del XML
/// ya firmado. Es lo que ata el QR a ESE comprobante concreto: sin él, dos
/// facturas con los mismos importes tendrían el mismo código.
///
/// ADVERTENCIA: el formato ha cambiado con los años y puede volver a hacerlo.
/// Conviene contrastarlo con la guía vigente de representación impresa antes
/// de dar por buena una implementación.
/// </summary>
public static class CodigoQr
{
    private static readonly CultureInfo Inv = CultureInfo.InvariantCulture;

    /// <summary>
    /// Arma el texto que va dentro del QR.
    /// </summary>
    public static string Contenido(
        ComprobanteBase comprobante,
        TotalesComprobante totales,
        string? digestFirma)
    {
        var campos = new[]
        {
            comprobante.Emisor.Ruc,
            comprobante.TipoComprobante,
            comprobante.Serie,
            comprobante.Correlativo.ToString(Inv),
            totales.TotalIgv.ToString("F2", Inv),
            totales.ImporteTotal.ToString("F2", Inv),
            comprobante.FechaEmision.ToString("yyyy-MM-dd", Inv),
            comprobante.Receptor.TipoDocumento,
            comprobante.Receptor.NumeroDocumento,
            digestFirma ?? ""
        };

        // Termina en barra: forma parte del formato, no es un descuido.
        return string.Join("|", campos) + "|";
    }

    /// <summary>
    /// Extrae el resumen de la firma del XML ya firmado.
    ///
    /// Se lee del documento en vez de recalcularlo a propósito: el QR debe
    /// declarar exactamente lo que se firmó. Recalcularlo por separado abriría
    /// la puerta a que ambos valores se separen sin que nadie lo note.
    /// </summary>
    public static string? LeerDigest(System.Xml.XmlDocument documentoFirmado)
    {
        var espacios = new System.Xml.XmlNamespaceManager(documentoFirmado.NameTable);
        espacios.AddNamespace("ds", "http://www.w3.org/2000/09/xmldsig#");

        return documentoFirmado
            .SelectSingleNode("//ds:Signature//ds:DigestValue", espacios)
            ?.InnerText;
    }

    /// <summary>Variante que lee el digest desde un XDocument.</summary>
    public static string? LeerDigest(XDocument documentoFirmado)
    {
        XNamespace ds = "http://www.w3.org/2000/09/xmldsig#";

        return documentoFirmado
            .Descendants(ds + "DigestValue")
            .FirstOrDefault()
            ?.Value;
    }

    /// <summary>
    /// Genera la imagen PNG del código.
    /// </summary>
    /// <param name="pixelesPorModulo">
    /// Tamaño de cada cuadrito. Con menos de 4 el código deja de leerse en
    /// impresiones de baja calidad, que son la mayoría de los tickets.
    /// </param>
    public static byte[] GenerarPng(string contenido, int pixelesPorModulo = 6)
    {
        using var generador = new QRCodeGenerator();

        // Nivel de corrección M: tolera hasta un 15% de daño. Un ticket
        // arrugado o con tinta corrida sigue siendo legible.
        using var datos = generador.CreateQrCode(
            contenido, QRCodeGenerator.ECCLevel.M);

        using var png = new PngByteQRCode(datos);

        return png.GetGraphic(pixelesPorModulo);
    }
}
