using System.IO.Compression;
using System.Security.Cryptography;
using System.Text;

namespace Facturacion.Cpe;

/// <summary>
/// EL CATÁLOGO DE CÓDIGOS DE PRODUCTO DE SUNAT QUE USA LA PLATAFORMA, y con qué
/// compararlo (14 de octubre de 2026).
///
/// ══════════════════════════════════════════════════════════════════════════
/// POR QUÉ ESTÁ AQUÍ. La plataforma lleva su propia copia del catálogo 25
/// (CatalogoSunatDatos.cs, con descripciones, para el buscador). Si SUNAT
/// quita un código de su lista y la copia sigue teniéndolo, un producto puede
/// guardarse con él y, desde 2027, sus comprobantes se rechazan (ERR-3496).
///
/// La Vigilancia SUNAT descarga una vez al día el Excel oficial y lo compara
/// con ESTA lista: solo los códigos, sin descripciones (una descripción
/// cambiada no rechaza nada; un código quitado, sí). Si no coinciden, avisa
/// por correo con los códigos agregados y quitados.
///
/// AL REGENERAR EL CATÁLOGO DE LA PLATAFORMA HAY QUE REGENERAR ESTA LISTA
/// TAMBIÉN, del mismo Excel. Si no, la vigilancia seguiría avisando.
///
/// La lista va comprimida: los 52 840 códigos ordenados, cada uno como la
/// diferencia con el anterior, en gzip y base64.
/// ══════════════════════════════════════════════════════════════════════════
/// </summary>
public static class CatalogoProductosSunat
{
    /// <summary>Dónde publica SUNAT el Excel (página «Código de producto»).</summary>
    public const string UrlArchivo =
        "https://cpe.sunat.gob.pe/sites/default/files/inline-files/CCNU_MOD_2.xlsm";

    public const string UrlPagina =
        "https://cpe.sunat.gob.pe/informacion_general/codigoproducto";

    /// <summary>Qué versión lleva la plataforma. Cambia al regenerar.</summary>
    public const string VersionEnUso = "UNSPSC v14 (CCNU_MOD_2.xlsm), cargado el 14/10/2026";

    /// <summary>Cuántos códigos tiene (clases y productos). Para comprobar la lista.</summary>
    public const int CantidadEnUso = 52840;

    /// <summary>La huella de la lista: SHA-256 de los códigos ordenados, uno por línea.</summary>
    public const string HuellaEnUso = "c3ed2acd0ebbf63b5f1130eb253117ee6eb2984091f7cce1301f739c9e3040ee";

    private static readonly Lazy<IReadOnlySet<string>> Lista = new(Descomprimir);

    /// <summary>Los códigos que usa la plataforma.</summary>
    public static IReadOnlySet<string> EnUso => Lista.Value;

    /// <summary>La huella de cualquier lista de códigos, calculada igual que <see cref="HuellaEnUso"/>.</summary>
    public static string Huella(IEnumerable<string> codigos) =>
        Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(
            string.Join("\n", codigos.Distinct().Order(StringComparer.Ordinal))))).ToLowerInvariant();

    /// <summary>Qué tiene SUNAT que no tenemos, y qué tenemos que SUNAT ya no tiene.</summary>
    public static DiferenciaCatalogo Comparar(IReadOnlySet<string> deSunat) => new(
        deSunat.Where(c => !EnUso.Contains(c)).Order(StringComparer.Ordinal).ToList(),
        EnUso.Where(c => !deSunat.Contains(c)).Order(StringComparer.Ordinal).ToList());

    private const string CodigosGzipBase64 = """
        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
        """;

    private static IReadOnlySet<string> Descomprimir()
    {
        using var entrada = new MemoryStream(Convert.FromBase64String(CodigosGzipBase64));
        using var gzip = new GZipStream(entrada, CompressionMode.Decompress);
        using var lector = new StreamReader(gzip, Encoding.UTF8);

        var codigos = new HashSet<string>(StringComparer.Ordinal);
        long anterior = 0;
        string? linea;

        while ((linea = lector.ReadLine()) is not null)
        {
            if (linea.Length == 0) continue;
            anterior += long.Parse(linea, System.Globalization.CultureInfo.InvariantCulture);
            codigos.Add(anterior.ToString("D8", System.Globalization.CultureInfo.InvariantCulture));
        }

        return codigos;
    }
}

/// <summary>Lo que cambió entre la lista de SUNAT y la de la plataforma.</summary>
public sealed record DiferenciaCatalogo(IReadOnlyList<string> Agregados, IReadOnlyList<string> Quitados)
{
    public bool Igual => Agregados.Count == 0 && Quitados.Count == 0;
}