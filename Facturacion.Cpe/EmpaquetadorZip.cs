using System.IO.Compression;

namespace Facturacion.Cpe;

/// <summary>
/// Empaqueta el XML firmado en un ZIP, tal como lo exige SUNAT.
///
/// LA CONVENCIÓN DE NOMBRES ES PARTE DE LA VALIDACIÓN, no una formalidad:
///
///   Archivo XML dentro del ZIP:  20601234567-01-F001-00000001.xml
///   Archivo ZIP:                 20601234567-01-F001-00000001.zip
///
///   RUC del emisor - tipo de comprobante - serie - correlativo
///
/// Si el nombre no calza exactamente con lo que declara el XML por dentro,
/// SUNAT rechaza el envío aunque el contenido esté perfecto. Y el mensaje de
/// error no suele decir que el problema es el nombre.
///
/// El XML va en la raíz del ZIP, sin carpetas intermedias.
/// </summary>
public static class EmpaquetadorZip
{
    /// <summary>
    /// Crea el ZIP en memoria a partir del XML firmado.
    /// </summary>
    /// <param name="nombreBase">Sin extensión. Ej: 20601234567-01-F001-00000001</param>
    /// <param name="contenidoXml">Bytes del XML firmado, tal cual se guardó en disco.</param>
    public static byte[] Comprimir(string nombreBase, byte[] contenidoXml)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(nombreBase);
        ArgumentNullException.ThrowIfNull(contenidoXml);

        using var memoria = new MemoryStream();

        // El bloque se cierra antes de leer el stream: el ZIP no queda completo
        // hasta que se libera el archivo, porque ahí se escribe el índice final.
        using (var zip = new ZipArchive(memoria, ZipArchiveMode.Create, leaveOpen: true))
        {
            var entrada = zip.CreateEntry($"{nombreBase}.xml", CompressionLevel.Optimal);

            using var flujo = entrada.Open();
            flujo.Write(contenidoXml, 0, contenidoXml.Length);
        }

        return memoria.ToArray();
    }

    /// <summary>Variante que lee el XML desde disco.</summary>
    public static byte[] ComprimirDesdeArchivo(string rutaXml)
    {
        if (!File.Exists(rutaXml))
            throw new FileNotFoundException($"No se encontró el XML: {rutaXml}", rutaXml);

        var nombreBase = Path.GetFileNameWithoutExtension(rutaXml);
        var contenido = File.ReadAllBytes(rutaXml);

        return Comprimir(nombreBase, contenido);
    }

    /// <summary>
    /// Extrae el primer archivo XML de un ZIP. Se usa para leer el CDR,
    /// que SUNAT devuelve comprimido.
    /// </summary>
    public static (string Nombre, byte[] Contenido) ExtraerPrimerXml(byte[] zipBytes)
    {
        using var memoria = new MemoryStream(zipBytes);
        using var zip = new ZipArchive(memoria, ZipArchiveMode.Read);

        var entrada = zip.Entries.FirstOrDefault(e =>
            e.Name.EndsWith(".xml", StringComparison.OrdinalIgnoreCase))
            ?? throw new InvalidOperationException(
                "El ZIP no contiene ningún archivo XML.");

        using var flujo = entrada.Open();
        using var destino = new MemoryStream();
        flujo.CopyTo(destino);

        return (entrada.Name, destino.ToArray());
    }
}
