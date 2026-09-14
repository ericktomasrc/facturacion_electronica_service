using System.Xml.Linq;

namespace Facturacion.Cpe;

/// <summary>
/// Espacios de nombres XML del estándar UBL 2.1.
/// No cambiar: SUNAT valida contra estas URIs exactas.
/// </summary>
public static class Ns
{
    public static readonly XNamespace Invoice =
        "urn:oasis:names:specification:ubl:schema:xsd:Invoice-2";

    public static readonly XNamespace Cac =
        "urn:oasis:names:specification:ubl:schema:xsd:CommonAggregateComponents-2";

    public static readonly XNamespace Cbc =
        "urn:oasis:names:specification:ubl:schema:xsd:CommonBasicComponents-2";

    public static readonly XNamespace Ext =
        "urn:oasis:names:specification:ubl:schema:xsd:CommonExtensionComponents-2";

    public static readonly XNamespace Ds =
        "http://www.w3.org/2000/09/xmldsig#";
}

/// <summary>
/// URIs de los catálogos de SUNAT, usadas en los atributos listURI/schemeURI.
/// </summary>
public static class CatalogoUri
{
    private const string Base = "urn:pe:gob:sunat:cpe:see:gem:catalogos:catalogo";

    public const string C01_TipoDocumento    = Base + "01";
    public const string C06_TipoDocIdentidad = Base + "06";
    public const string C07_AfectacionIgv    = Base + "07";
    public const string C16_TipoPrecio       = Base + "16";
    public const string C51_TipoOperacion    = Base + "51";
}

/// <summary>Catálogo 01: tipo de comprobante.</summary>
public static class TipoComprobante
{
    public const string Factura        = "01";
    public const string Boleta         = "03";
    public const string NotaCredito    = "07";
    public const string NotaDebito     = "08";
}

/// <summary>Catálogo 06: tipo de documento de identidad.</summary>
public static class TipoDocIdentidad
{
    public const string Dni       = "1";
    public const string Extranjeria = "4";
    public const string Ruc       = "6";
    public const string Pasaporte = "7";
    public const string SinDocumento = "0";
}

/// <summary>
/// Catálogo 07: tipo de afectación del IGV.
/// Solo se incluyen los casos más comunes. Ampliar según se necesiten.
/// </summary>
public static class AfectacionIgv
{
    public const string GravadoOperacionOnerosa = "10";
    public const string Exonerado               = "20";
    public const string Inafecto                = "30";
    public const string GratuitoGravado         = "11";
    public const string GratuitoExonerado       = "21";
    public const string GratuitoInafecto        = "31";
    public const string Exportacion             = "40";

    /// <summary>
    /// Devuelve la categoría tributaria que corresponde a cada afectación.
    /// El código, el nombre y el tipo cambian según el caso, y SUNAT los valida.
    /// </summary>
    public static CategoriaTributaria Categoria(string afectacion) => afectacion switch
    {
        GravadoOperacionOnerosa or Exportacion => new("1000", "IGV",  "VAT"),
        Exonerado                              => new("9997", "EXO",  "VAT"),
        Inafecto                               => new("9998", "INA",  "FRE"),
        GratuitoGravado or GratuitoExonerado
            or GratuitoInafecto                => new("9996", "GRA",  "FRE"),
        _ => throw new ArgumentException(
                $"Tipo de afectación no soportado: {afectacion}", nameof(afectacion))
    };

    /// <summary>Indica si la afectación genera IGV calculable.</summary>
    public static bool GeneraIgv(string afectacion) =>
        afectacion is GravadoOperacionOnerosa or GratuitoGravado;

    /// <summary>Indica si la operación es gratuita (no suma al importe a pagar).</summary>
    public static bool EsGratuita(string afectacion) =>
        afectacion is GratuitoGravado or GratuitoExonerado or GratuitoInafecto;
}

/// <summary>Código, nombre y tipo del tributo, según el catálogo 05 de SUNAT.</summary>
public readonly record struct CategoriaTributaria(string Codigo, string Nombre, string TipoCodigo);

/// <summary>Catálogo 16: tipo de precio unitario.</summary>
public static class TipoPrecio
{
    public const string PrecioUnitarioIncluyeIgv = "01";
    public const string ValorReferencialGratuito = "02";
}
