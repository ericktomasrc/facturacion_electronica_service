using System.Xml.Linq;

namespace Facturacion.Cpe;

/// <summary>
/// EL CÓDIGO DE PRODUCTO SUNAT (catálogo 25, UNSPSC v14) — 14 de octubre de 2026.
///
/// Dice QUÉ ES lo que se vende según una lista oficial: 50161509 «Azúcares
/// naturales», 30111601 «Cemento». No es el código propio de la empresa (ese
/// es <c>CodigoProducto</c> y va en SellersItemIdentification).
///
/// ══════════════════════════════════════════════════════════════════════════
/// EN EL XML
///
///   &lt;cac:Item&gt;
///     &lt;cbc:Description&gt;…
///     &lt;cac:SellersItemIdentification&gt;…          el código propio
///     &lt;cac:CommodityClassification&gt;
///       &lt;cbc:ItemClassificationCode listID="UNSPSC"
///           listAgencyName="GS1 US" listName="Item Classification"&gt;50161509&lt;/…&gt;
///     &lt;/cac:CommodityClassification&gt;
///     &lt;cac:AdditionalItemProperty&gt;…              catálogo 55, si hay
///
/// EL ORDEN NO ES LIBRE: UBL fija que CommodityClassification va después de
/// las identificaciones del ítem y antes de las propiedades adicionales.
///
/// LAS REGLAS
///   · Ocho dígitos. Desde el nivel CLASE hacia abajo: 50161500 vale,
///     50160000 (familia) y 50000000 (segmento) no (OBS-4337).
///   · 00000000 y 99999999 se admiten (son los genéricos de SUNAT).
///   · Hoy es opcional en factura, boleta y notas; si se manda y no es válido,
///     hasta 2026 es una observación y DESDE 2027 UN RECHAZO (ERR-3496).
///   · En la LIQUIDACIÓN DE COMPRA es obligatorio desde 2027 (ERR-3506).
///
/// Aquí solo se comprueba la FORMA. Que el código exista en la lista lo
/// comprueba la plataforma, que tiene el catálogo entero y un buscador.
/// ══════════════════════════════════════════════════════════════════════════
/// </summary>
public static class CodigoProductoSunat
{
    public const string ListId = "UNSPSC";
    public const string ListAgencyName = "GS1 US";
    public const string ListName = "Item Classification";

    /// <summary>
    /// Qué tiene de malo un código, o null si la forma vale.
    /// Vacío vale: es opcional (salvo en la liquidación desde 2027, que se
    /// comprueba aparte).
    /// </summary>
    public static string? Problema(string? codigo)
    {
        if (string.IsNullOrWhiteSpace(codigo)) return null;

        var c = codigo.Trim();

        if (c.Length != 8 || !c.All(char.IsAsciiDigit))
            return $"'{codigo}' no es un codigo de producto SUNAT: son 8 digitos del " +
                   "catalogo 25 (UNSPSC), por ejemplo 50161509. No es el codigo propio " +
                   "del producto: ese va en codigoProducto.";

        if (c is "00000000" or "99999999") return null;

        if (c.EndsWith("0000", StringComparison.Ordinal))
            return $"'{c}' es un segmento o una familia del catalogo 25. SUNAT pide " +
                   "por lo menos el nivel de clase: los digitos 5 y 6 no pueden " +
                   "ser 00 (por ejemplo 50161500 en vez de 50160000).";

        return null;
    }

    /// <summary>
    /// Los problemas de todas las líneas, con su número. Vacío si están bien.
    ///
    /// LOS MENSAJES VAN SIN TILDES, como los demás del motor: acaban también
    /// en el log de la consola de Windows.
    /// </summary>
    public static IReadOnlyList<string> Problemas(IEnumerable<string?> codigosPorLinea) =>
        codigosPorLinea
            .Select((c, i) => Problema(c) is { } p ? $"Linea {i + 1}: {p}" : null)
            .OfType<string>()
            .ToList();

    /// <summary>
    /// El bloque del XML, o null si la línea no lleva código (y entonces no se
    /// escribe nada: XElement ignora los null).
    /// </summary>
    public static XElement? Bloque(string? codigo) =>
        string.IsNullOrWhiteSpace(codigo)
            ? null
            : new XElement(Ns.Cac + "CommodityClassification",
                new XElement(Ns.Cbc + "ItemClassificationCode",
                    new XAttribute("listID", ListId),
                    new XAttribute("listAgencyName", ListAgencyName),
                    new XAttribute("listName", ListName),
                    codigo.Trim()));
}