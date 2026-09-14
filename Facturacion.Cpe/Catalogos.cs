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

    public static readonly XNamespace CreditNote =
        "urn:oasis:names:specification:ubl:schema:xsd:CreditNote-2";

    public static readonly XNamespace DebitNote =
        "urn:oasis:names:specification:ubl:schema:xsd:DebitNote-2";

    public static readonly XNamespace Cac =
        "urn:oasis:names:specification:ubl:schema:xsd:CommonAggregateComponents-2";

    public static readonly XNamespace Cbc =
        "urn:oasis:names:specification:ubl:schema:xsd:CommonBasicComponents-2";

    public static readonly XNamespace Ext =
        "urn:oasis:names:specification:ubl:schema:xsd:CommonExtensionComponents-2";

    public static readonly XNamespace Ds =
        "http://www.w3.org/2000/09/xmldsig#";
}

/// <summary>URIs de los catálogos de SUNAT, para los atributos listURI/schemeURI.</summary>
public static class CatalogoUri
{
    private const string Base = "urn:pe:gob:sunat:cpe:see:gem:catalogos:catalogo";

    public const string C01_TipoDocumento    = Base + "01";
    public const string C06_TipoDocIdentidad = Base + "06";
    public const string C07_AfectacionIgv    = Base + "07";
    public const string C09_NotaCredito      = Base + "09";
    public const string C10_NotaDebito       = Base + "10";
    public const string C16_TipoPrecio       = Base + "16";
    public const string C51_TipoOperacion    = Base + "51";
}

/// <summary>Catálogo 01: tipo de comprobante.</summary>
public static class TipoComprobante
{
    public const string Factura     = "01";
    public const string Boleta      = "03";
    public const string NotaCredito = "07";
    public const string NotaDebito  = "08";
}

/// <summary>Catálogo 06: tipo de documento de identidad.</summary>
public static class TipoDocIdentidad
{
    public const string SinDocumento = "0";
    public const string Dni          = "1";
    public const string Extranjeria  = "4";
    public const string Ruc          = "6";
    public const string Pasaporte    = "7";
}

/// <summary>
/// Catálogo 09: motivos de nota de crédito.
/// Solo los más usados. La lista completa está en el Anexo 8 de SUNAT.
/// </summary>
public static class MotivoNotaCredito
{
    public const string AnulacionDeLaOperacion       = "01";
    public const string AnulacionPorErrorEnElRuc     = "02";
    public const string CorreccionPorErrorEnDescripcion = "03";
    public const string DescuentoGlobal              = "04";
    public const string DescuentoPorItem             = "05";
    public const string DevolucionTotal              = "06";
    public const string DevolucionPorItem            = "07";
    public const string BonificacionOtros            = "08";
    public const string DisminucionEnElValor         = "09";
    public const string OtrosConceptos               = "10";

    public static string Descripcion(string codigo) => codigo switch
    {
        AnulacionDeLaOperacion          => "ANULACION DE LA OPERACION",
        AnulacionPorErrorEnElRuc        => "ANULACION POR ERROR EN EL RUC",
        CorreccionPorErrorEnDescripcion => "CORRECCION POR ERROR EN LA DESCRIPCION",
        DescuentoGlobal                 => "DESCUENTO GLOBAL",
        DescuentoPorItem                => "DESCUENTO POR ITEM",
        DevolucionTotal                 => "DEVOLUCION TOTAL",
        DevolucionPorItem               => "DEVOLUCION POR ITEM",
        BonificacionOtros               => "BONIFICACION",
        DisminucionEnElValor            => "DISMINUCION EN EL VALOR",
        OtrosConceptos                  => "OTROS CONCEPTOS",
        _                               => "OTROS CONCEPTOS"
    };
}

/// <summary>Catálogo 10: motivos de nota de débito.</summary>
public static class MotivoNotaDebito
{
    public const string InteresPorMora      = "01";
    public const string AumentoEnElValor    = "02";
    public const string PenalidadesOtros    = "03";

    public static string Descripcion(string codigo) => codigo switch
    {
        InteresPorMora   => "INTERES POR MORA",
        AumentoEnElValor => "AUMENTO EN EL VALOR",
        PenalidadesOtros => "PENALIDADES U OTROS CONCEPTOS",
        _                => "OTROS CONCEPTOS"
    };
}

/// <summary>Catálogo 07: tipo de afectación del IGV.</summary>
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
    /// Categoría tributaria que corresponde a cada afectación.
    /// El código, el nombre y el tipo cambian según el caso, y SUNAT los valida.
    /// </summary>
    public static CategoriaTributaria Categoria(string afectacion) => afectacion switch
    {
        GravadoOperacionOnerosa or Exportacion => new("1000", "IGV", "VAT"),
        Exonerado                              => new("9997", "EXO", "VAT"),
        Inafecto                               => new("9998", "INA", "FRE"),
        GratuitoGravado or GratuitoExonerado
            or GratuitoInafecto                => new("9996", "GRA", "FRE"),
        _ => throw new ArgumentException(
                $"Tipo de afectación no soportado: {afectacion}", nameof(afectacion))
    };

    public static bool GeneraIgv(string afectacion) =>
        afectacion is GravadoOperacionOnerosa or GratuitoGravado;

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
