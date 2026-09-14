using System.Xml.Linq;
using static Facturacion.Cpe.BloquesComunes;

namespace Facturacion.Cpe;

/// <summary>
/// Comunicación de baja: anula comprobantes ya aceptados por SUNAT.
///
/// DIFERENCIA CON UNA NOTA DE CRÉDITO, que se confunde siempre:
///
///   Nota de crédito → corrige o revierte la operación, y deja rastro contable.
///                     Se usa cuando hubo una venta real que después cambió.
///
///   Comunicación de baja → el comprobante queda como si nunca hubiera existido.
///                     Se usa cuando se emitió por error.
///
/// QUÉ SE PUEDE DAR DE BAJA POR AQUÍ: facturas y sus notas.
/// LAS BOLETAS NO. Las boletas se anulan dentro del resumen diario, informándolas
/// con el estado 3 (Anular), que es el mecanismo que ya tienes implementado.
///
/// Hay plazos legales para comunicar una baja. Conviene verificarlos contra la
/// resolución vigente, porque han cambiado varias veces.
///
/// Nomenclatura:  RA-YYYYMMDD-#####
/// Envío:         sendSummary → ticket → getStatus. El mismo flujo del resumen.
/// </summary>
public class ComunicacionBaja
{
    public Emisor Emisor { get; set; } = new();

    /// <summary>Fecha en que se emitieron los comprobantes que se anulan.</summary>
    public DateTime FechaReferencia { get; set; } = DateTime.Today.AddDays(-1);

    /// <summary>Fecha en que se genera esta comunicación. Normalmente hoy.</summary>
    public DateTime FechaGeneracion { get; set; } = DateTime.Today;

    /// <summary>Correlativo de la comunicación dentro del día. Hasta 5 dígitos.</summary>
    public int Correlativo { get; set; } = 1;

    public List<LineaBaja> Lineas { get; set; } = [];

    /// <summary>Identificador: RA-20260914-1</summary>
    public string Identificador => $"RA-{FechaGeneracion:yyyyMMdd}-{Correlativo}";

    /// <summary>Nombre del archivo, sin extensión.</summary>
    public string NombreArchivo => $"{Emisor.Ruc}-{Identificador}";
}

/// <summary>Un comprobante que se da de baja.</summary>
public class LineaBaja
{
    /// <summary>Número secuencial dentro de la comunicación, empezando en 1.</summary>
    public int Orden { get; set; }

    /// <summary>Catálogo 01. "01" factura, "07" nota de crédito, "08" nota de débito.</summary>
    public string TipoComprobante { get; set; } = Cpe.TipoComprobante.Factura;

    /// <summary>Serie del comprobante. Ej: F001</summary>
    public string Serie { get; set; } = "";

    /// <summary>Correlativo del comprobante, sin ceros a la izquierda.</summary>
    public int Numero { get; set; }

    /// <summary>Por qué se anula. Texto libre, lo lee una persona en SUNAT.</summary>
    public string Motivo { get; set; } = "";

    /// <summary>Construye la línea a partir de un comprobante ya emitido.</summary>
    public static LineaBaja Desde(ComprobanteBase comprobante, int orden, string motivo) =>
        new()
        {
            Orden = orden,
            TipoComprobante = comprobante.TipoComprobante,
            Serie = comprobante.Serie,
            Numero = comprobante.Correlativo,
            Motivo = motivo
        };
}

/// <summary>
/// Genera el XML de la comunicación de baja.
///
/// Usa los esquemas propios de SUNAT, igual que el resumen diario:
/// VoidedDocuments-1 y SunatAggregateComponents-1, con UBL 2.0.
///
/// Fíjate en un detalle: aquí la serie y el número van en elementos SEPARADOS
/// (DocumentSerialID y DocumentNumberID), no juntos como "F001-00000002".
/// Y el número va sin ceros a la izquierda.
/// </summary>
public static class GeneradorBajaXml
{
    private static readonly XNamespace Baja =
        "urn:sunat:names:specification:ubl:peru:schema:xsd:VoidedDocuments-1";

    public static XDocument Generar(ComunicacionBaja b)
    {
        if (b.Lineas.Count == 0)
            throw new InvalidOperationException(
                "La comunicación de baja no tiene líneas. No tiene sentido enviarla vacía.");

        var raiz = new XElement(Baja + "VoidedDocuments",
            BloquesSunat.Namespaces(),

            ExtensionesVacias(),

            new XElement(Ns.Cbc + "UBLVersionID", "2.0"),
            new XElement(Ns.Cbc + "CustomizationID", "1.0"),

            new XElement(Ns.Cbc + "ID", b.Identificador),

            // ReferenceDate = cuándo se emitieron los comprobantes que se anulan
            // IssueDate     = cuándo se genera esta comunicación
            new XElement(Ns.Cbc + "ReferenceDate",
                b.FechaReferencia.ToString("yyyy-MM-dd", Inv)),
            new XElement(Ns.Cbc + "IssueDate",
                b.FechaGeneracion.ToString("yyyy-MM-dd", Inv)),

            BloquesSunat.Firmante(b.Emisor),
            BloquesSunat.Emisor(b.Emisor)
        );

        foreach (var linea in b.Lineas.OrderBy(l => l.Orden))
            raiz.Add(BloqueLinea(linea));

        return new XDocument(new XDeclaration("1.0", "UTF-8", null), raiz);
    }

    private static XElement BloqueLinea(LineaBaja l) =>
        new(BloquesSunat.Sac + "VoidedDocumentsLine",
            new XElement(Ns.Cbc + "LineID", l.Orden),
            new XElement(Ns.Cbc + "DocumentTypeCode", l.TipoComprobante),

            // Serie y número por separado, y el número sin ceros a la izquierda.
            new XElement(BloquesSunat.Sac + "DocumentSerialID", l.Serie),
            new XElement(BloquesSunat.Sac + "DocumentNumberID", l.Numero),

            new XElement(BloquesSunat.Sac + "VoidReasonDescription",
                new XCData(l.Motivo)));
}
