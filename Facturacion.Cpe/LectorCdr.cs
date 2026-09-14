using System.Text;
using System.Xml.Linq;

namespace Facturacion.Cpe;

/// <summary>
/// Interpreta la Constancia de Recepción (CDR) que devuelve SUNAT.
///
/// El CDR es un XML de tipo ApplicationResponse, comprimido en ZIP, cuyo archivo
/// interno se llama igual que el comprobante pero con el prefijo "R-":
///
///   Enviado:  20601234567-01-F001-00000001.zip
///   CDR:      R-20601234567-01-F001-00000001.xml
///
/// SIGNIFICADO DEL CÓDIGO DE RESPUESTA:
///
///   0            Aceptado.
///   0100 - 1999  Excepción: el comprobante no se procesó. NO reintentar,
///                hay que corregir el XML.
///   2000 - 3999  Error que impide la emisión. Tampoco se reintenta.
///   4000 +       Observación: el comprobante SE ACEPTA, pero con avisos.
///                Conviene corregirlos, no bloquean la operación.
///
/// EL CDR HAY QUE CONSERVARLO TAL CUAL LLEGÓ, en binario. Es la prueba legal
/// de que el comprobante fue recibido, y existe obligación de guardarlo.
/// </summary>
public static class LectorCdr
{
    public static ResultadoEnvio Interpretar(byte[] cdrZip, byte[] cdrXml)
    {
        var doc = XDocument.Parse(Encoding.UTF8.GetString(cdrXml));

        var codigo = BuscarValor(doc, "ResponseCode") ?? "";
        var descripcion = BuscarValor(doc, "Description")
            ?? "SUNAT no devolvió descripción.";

        var observaciones = doc.Descendants()
            .Where(e => e.Name.LocalName == "Note")
            .Select(e => e.Value)
            .Where(v => !string.IsNullOrWhiteSpace(v))
            .ToList();

        var aceptado = codigo == "0";

        // Las observaciones (4000+) también significan aceptación.
        if (!aceptado && int.TryParse(codigo, out var numero) && numero >= 4000)
            aceptado = true;

        return new ResultadoEnvio(
            Aceptado: aceptado,
            CodigoRespuesta: codigo,
            Descripcion: descripcion,
            Observaciones: observaciones,
            CdrZip: cdrZip,
            CdrXml: cdrXml)
        {
            EsReintentable = false
        };
    }

    private static string? BuscarValor(XDocument doc, string nombreLocal) =>
        doc.Descendants()
           .FirstOrDefault(e => e.Name.LocalName == nombreLocal)
           ?.Value;

    /// <summary>
    /// Nombre con el que debe guardarse el CDR, siguiendo la convención de SUNAT.
    /// </summary>
    public static string NombreArchivoCdr(string nombreBaseComprobante) =>
        $"R-{nombreBaseComprobante}";
}
