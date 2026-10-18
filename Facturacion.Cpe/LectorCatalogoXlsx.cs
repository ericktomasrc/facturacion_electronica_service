using System.IO.Compression;
using System.Xml;
using System.Xml.Linq;

namespace Facturacion.Cpe;

/// <summary>
/// Lee los códigos del Excel oficial del catálogo 25 de SUNAT (CCNU_MOD_2.xlsm).
///
/// SIN LIBRERÍAS: un .xlsm es un .zip con XML dentro. Se busca la hoja
/// «Bienes y Servicios», se ubica la fila de títulos por su texto («ID CLASE»
/// e «ID PRODUCTO») y se leen esas dos columnas. Así, si SUNAT agrega una
/// columna o mueve la tabla, se sigue leyendo bien.
///
/// SI EL ARCHIVO CAMBIA DE FORMA —otra hoja, otros títulos, casi ningún
/// código—, lanza <see cref="FormatException"/> con un mensaje que lo dice.
/// La vigilancia lo convierte en un aviso: mejor saber que ya no se puede
/// leer que creer que todo sigue igual.
/// </summary>
public static class LectorCatalogoXlsx
{
    private static readonly XNamespace Main = "http://schemas.openxmlformats.org/spreadsheetml/2006/main";
    private static readonly XNamespace Rel = "http://schemas.openxmlformats.org/officeDocument/2006/relationships";
    private static readonly XNamespace Pkg = "http://schemas.openxmlformats.org/package/2006/relationships";

    /// <summary>Por debajo de esto no es el catálogo: hoy tiene más de 52 000.</summary>
    public const int MinimoRazonable = 10_000;

    public static IReadOnlySet<string> Leer(byte[] archivo)
    {
        ZipArchive zip;
        try { zip = new ZipArchive(new MemoryStream(archivo), ZipArchiveMode.Read); }
        catch (InvalidDataException)
        {
            throw new FormatException(
                "Lo que se descargo no es un Excel (.xlsm). SUNAT pudo haber cambiado la pagina " +
                "o el archivo.");
        }

        using (zip)
        {
            var hoja = RutaDeLaHoja(zip);
            var compartidos = TextosCompartidos(zip);

            var entrada = zip.GetEntry(hoja)
                ?? throw new FormatException($"El Excel no tiene la hoja que dice tener ({hoja}).");

            using var flujo = entrada.Open();
            using var lector = XmlReader.Create(flujo, new XmlReaderSettings { IgnoreWhitespace = true });

            var codigos = new HashSet<string>(StringComparer.Ordinal);
            string? colClase = null, colProducto = null;

            lector.MoveToContent();
            while (!lector.EOF)
            {
                if (lector.NodeType != XmlNodeType.Element || lector.LocalName != "row")
                {
                    lector.Read();
                    continue;
                }

                var fila = (XElement)XNode.ReadFrom(lector);
                var celdas = Celdas(fila, compartidos);

                if (colProducto is null)
                {
                    foreach (var (col, valor) in celdas)
                    {
                        var t = valor.Trim().ToUpperInvariant();
                        if (t == "ID PRODUCTO") colProducto = col;
                        else if (t == "ID CLASE") colClase = col;
                    }
                    continue;
                }

                foreach (var col in new[] { colClase, colProducto })
                {
                    if (col is not null && celdas.TryGetValue(col, out var v))
                    {
                        var c = v.Trim();
                        if (c.Length == 8 && c.All(char.IsAsciiDigit)) codigos.Add(c);
                    }
                }
            }

            if (colProducto is null)
                throw new FormatException(
                    "La hoja de bienes y servicios ya no tiene la columna «ID PRODUCTO». SUNAT " +
                    "cambio la forma del Excel.");

            if (codigos.Count < MinimoRazonable)
                throw new FormatException(
                    $"El Excel solo trae {codigos.Count} codigos; el catalogo tiene mas de 50 000. " +
                    "SUNAT cambio la forma del archivo.");

            return codigos;
        }
    }

    /// <summary>La hoja cuyo nombre dice «Bienes» (hoy, «Bienes y Servicios»).</summary>
    private static string RutaDeLaHoja(ZipArchive zip)
    {
        var libro = Xml(zip, "xl/workbook.xml")
            ?? throw new FormatException("El Excel no tiene xl/workbook.xml.");
        var relaciones = Xml(zip, "xl/_rels/workbook.xml.rels")
            ?? throw new FormatException("El Excel no tiene la lista de sus hojas.");

        var hoja = libro.Descendants(Main + "sheet")
            .FirstOrDefault(h => ((string?)h.Attribute("name") ?? "")
                .Contains("bienes", StringComparison.OrdinalIgnoreCase))
            ?? throw new FormatException(
                "El Excel ya no tiene la hoja «Bienes y Servicios». SUNAT cambio la forma del archivo.");

        var id = (string?)hoja.Attribute(Rel + "id");
        var destino = relaciones.Descendants(Pkg + "Relationship")
            .FirstOrDefault(r => (string?)r.Attribute("Id") == id)?.Attribute("Target")?.Value
            ?? throw new FormatException("No se encuentra el archivo de la hoja «Bienes y Servicios».");

        return destino.StartsWith('/') ? destino.TrimStart('/') : "xl/" + destino;
    }

    private static List<string> TextosCompartidos(ZipArchive zip)
    {
        var textos = new List<string>();
        var entrada = zip.GetEntry("xl/sharedStrings.xml");
        if (entrada is null) return textos;

        using var flujo = entrada.Open();
        using var lector = XmlReader.Create(flujo, new XmlReaderSettings { IgnoreWhitespace = true });

        lector.MoveToContent();
        while (!lector.EOF)
        {
            if (lector.NodeType == XmlNodeType.Element && lector.LocalName == "si")
            {
                var si = (XElement)XNode.ReadFrom(lector);
                // Un texto puede venir en trozos con formato (<r><t>…</t></r>);
                // los fonéticos (<rPh>) no son parte del texto.
                textos.Add(string.Concat(si.Descendants(Main + "t")
                    .Where(t => t.Parent?.Name != Main + "rPh")
                    .Select(t => t.Value)));
            }
            else lector.Read();
        }

        return textos;
    }

    private static Dictionary<string, string> Celdas(XElement fila, List<string> compartidos)
    {
        var celdas = new Dictionary<string, string>(StringComparer.Ordinal);

        foreach (var c in fila.Elements(Main + "c"))
        {
            var referencia = (string?)c.Attribute("r");
            if (referencia is null) continue;

            var columna = new string(referencia.TakeWhile(char.IsAsciiLetter).ToArray());
            var tipo = (string?)c.Attribute("t");
            var v = c.Element(Main + "v")?.Value;

            var valor = tipo switch
            {
                "s" when int.TryParse(v, out var i) && i >= 0 && i < compartidos.Count => compartidos[i],
                "inlineStr" => string.Concat(c.Descendants(Main + "t").Select(t => t.Value)),
                _ => v
            };

            if (valor is not null) celdas[columna] = valor;
        }

        return celdas;
    }

    private static XDocument? Xml(ZipArchive zip, string ruta)
    {
        var e = zip.GetEntry(ruta);
        if (e is null) return null;
        using var flujo = e.Open();
        return XDocument.Load(flujo);
    }
}