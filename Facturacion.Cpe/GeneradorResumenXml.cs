using System.Xml.Linq;
using static Facturacion.Cpe.BloquesComunes;
using static Facturacion.Cpe.NumeroALetras;

namespace Facturacion.Cpe;

/// <summary>
/// Genera el XML del resumen diario de boletas.
///
/// ESTE DOCUMENTO NO USA LOS ESQUEMAS DE OASIS. SUNAT definió los suyos:
///
///   SummaryDocuments-1          el documento en sí
///   SunatAggregateComponents-1  los elementos propios (prefijo sac:)
///
/// Y declara UBLVersionID 2.0 con CustomizationID 1.1. No existe una versión
/// 2.1 de este documento: SUNAT lo dejó en el estándar anterior.
///
/// Cada línea representa un COMPROBANTE ENTERO, no un ítem: solo lleva totales
/// consolidados, receptor y estado.
/// </summary>
public static class GeneradorResumenXml
{
    private static readonly XNamespace Resumen =
        "urn:sunat:names:specification:ubl:peru:schema:xsd:SummaryDocuments-1";

    private static XNamespace Sac => BloquesSunat.Sac;

    public static XDocument Generar(ResumenDiario r)
    {
        if (r.Lineas.Count == 0)
            throw new InvalidOperationException(
                "El resumen no tiene líneas. No tiene sentido enviarlo vacío.");

        var raiz = new XElement(Resumen + "SummaryDocuments",
            BloquesSunat.Namespaces(),

            ExtensionesVacias(),

            // Versión 2.0, no 2.1: este documento se quedó en el estándar anterior.
            new XElement(Ns.Cbc + "UBLVersionID", "2.0"),
            new XElement(Ns.Cbc + "CustomizationID", "1.1"),

            new XElement(Ns.Cbc + "ID", r.Identificador),

            // Cuidado con no confundir estas dos fechas:
            //   ReferenceDate = cuándo se emitieron las boletas
            //   IssueDate     = cuándo se genera este resumen
            new XElement(Ns.Cbc + "ReferenceDate",
                r.FechaReferencia.ToString("yyyy-MM-dd", Inv)),
            new XElement(Ns.Cbc + "IssueDate",
                r.FechaGeneracion.ToString("yyyy-MM-dd", Inv)),

            BloquesSunat.Firmante(r.Emisor),
            BloquesSunat.Emisor(r.Emisor)
        );

        foreach (var linea in r.Lineas.OrderBy(l => l.Orden))
            raiz.Add(BloqueLinea(linea));

        return new XDocument(new XDeclaration("1.0", "UTF-8", null), raiz);
    }

    private static XElement BloqueLinea(LineaResumen l)
    {
        var nodo = new XElement(Sac + "SummaryDocumentsLine",
            new XElement(Ns.Cbc + "LineID", l.Orden),
            new XElement(Ns.Cbc + "DocumentTypeCode", l.TipoComprobante),
            new XElement(Ns.Cbc + "ID", l.Numero),

            new XElement(Ns.Cac + "AccountingCustomerParty",
                new XElement(Ns.Cbc + "CustomerAssignedAccountID",
                    l.Receptor.NumeroDocumento),
                new XElement(Ns.Cbc + "AdditionalAccountID",
                    l.Receptor.TipoDocumento)));

        // Solo las notas llevan referencia al documento que modifican.
        if (l.Afectado is not null)
        {
            nodo.Add(new XElement(Ns.Cac + "BillingReference",
                new XElement(Ns.Cac + "InvoiceDocumentReference",
                    new XElement(Ns.Cbc + "ID", l.Afectado.Numero),
                    new XElement(Ns.Cbc + "DocumentTypeCode",
                        l.Afectado.TipoDocumento))));
        }

        nodo.Add(new XElement(Ns.Cac + "Status",
            new XElement(Ns.Cbc + "ConditionCode", (int)l.Estado)));

        nodo.Add(new XElement(Sac + "TotalAmount",
            new XAttribute("currencyID", l.Moneda), F2(l.ImporteTotal)));

        // Un BillingPayment por cada tipo de monto que exista.
        // Solo se incluyen los que tienen valor: declarar ceros genera observaciones.
        if (l.TotalGravado > 0)
            nodo.Add(Monto(l.Moneda, l.TotalGravado, TipoMontoResumen.Gravado));

        if (l.TotalExonerado > 0)
            nodo.Add(Monto(l.Moneda, l.TotalExonerado, TipoMontoResumen.Exonerado));

        if (l.TotalInafecto > 0)
            nodo.Add(Monto(l.Moneda, l.TotalInafecto, TipoMontoResumen.Inafecto));

        nodo.Add(BloqueIgv(l.Moneda, l.TotalIgv));

        return nodo;
    }

    private static XElement Monto(string moneda, decimal importe, string tipo) =>
        new(Sac + "BillingPayment",
            new XElement(Ns.Cbc + "PaidAmount",
                new XAttribute("currencyID", moneda), F2(importe)),
            new XElement(Ns.Cbc + "InstructionID", tipo));

    private static XElement BloqueIgv(string moneda, decimal igv) =>
        new(Ns.Cac + "TaxTotal",
            new XElement(Ns.Cbc + "TaxAmount",
                new XAttribute("currencyID", moneda), F2(igv)),
            new XElement(Ns.Cac + "TaxSubtotal",
                new XElement(Ns.Cbc + "TaxAmount",
                    new XAttribute("currencyID", moneda), F2(igv)),
                new XElement(Ns.Cac + "TaxCategory",
                    new XElement(Ns.Cac + "TaxScheme",
                        // En el resumen estos códigos van sin los atributos
                        // de catálogo que sí lleva la factura.
                        new XElement(Ns.Cbc + "ID", "1000"),
                        new XElement(Ns.Cbc + "Name", "IGV"),
                        new XElement(Ns.Cbc + "TaxTypeCode", "VAT")))));
}
