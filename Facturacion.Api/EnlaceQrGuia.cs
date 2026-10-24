using System.IO.Compression;
using System.Text;
using System.Text.RegularExpressions;

namespace Facturacion.Api;

/// <summary>
/// 24 oct: el enlace de consulta que SUNAT pone en la constancia de una guía
/// aceptada (cbc:DocumentDescription, «.../gre/comprobantes/descargaqr?hashqr=...»).
/// Es el que va en el QR de la hoja impresa.
///
/// La constancia llega como ZIP con el XML dentro; también se acepta el XML
/// suelto. Si no hay enlace, devuelve null y el PDF sale sin QR.
/// </summary>
public static class EnlaceQrGuia
{
    private static readonly Regex Patron = new(
        @"https://[^\s<""']*descargaqr[^\s<""']*",
        RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);

    public static string? DesdeCdr(byte[] cdr)
    {
        var texto = TextoDelCdr(cdr);
        if (texto is null) return null;

        var m = Patron.Match(texto);
        return m.Success ? System.Net.WebUtility.HtmlDecode(m.Value) : null;
    }

    private static string? TextoDelCdr(byte[] cdr)
    {
        // ZIP: empieza por "PK".
        if (cdr.Length > 4 && cdr[0] == (byte)'P' && cdr[1] == (byte)'K')
        {
            using var zip = new ZipArchive(new MemoryStream(cdr), ZipArchiveMode.Read);
            foreach (var entrada in zip.Entries)
            {
                if (!entrada.Name.EndsWith(".xml", StringComparison.OrdinalIgnoreCase)) continue;
                using var lector = new StreamReader(entrada.Open(), Encoding.UTF8);
                return lector.ReadToEnd();
            }
            return null;
        }

        return Encoding.UTF8.GetString(cdr);
    }
}