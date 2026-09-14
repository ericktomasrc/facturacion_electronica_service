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
/// Eso explica dos rarezas que vas a notar:
///
/// 1. El emisor no usa el bloque cac:Party completo de la factura, sino
///    cbc:CustomerAssignedAccountID con el RUC directo. Es una forma más
///    antigua de declarar partes.
///
/// 2. Cada línea representa un COMPROBANTE ENTERO, no un ítem. Solo lleva
///    totales consolidados, receptor y estado.
/// </summary>
public static class GeneradorResumenXml
{
    private static readonly XNamespace Resumen =
        "urn:sunat:names:specification:ubl:peru:schema:xsd:SummaryDocuments-1";

    private static readonly XNamespace Sac =
        "urn:sunat:names:specification:ubl:peru:schema:xsd:SunatAggregateComponents-1";

    public static XDocument Generar(ResumenDiario r)
    {
        if (r.Lineas.Count == 0)
            throw new InvalidOperationException(
                "El resumen no tiene líneas. No tiene sentido enviarlo vacío.");

        var raiz = new XElement(Resumen + "SummaryDocuments",
            new XAttribute(XNamespace.Xmlns + "cac", Ns.Cac.NamespaceName),
            new XAttribute(XNamespace.Xmlns + "cbc", Ns.Cbc.NamespaceName),
            new XAttribute(XNamespace.Xmlns + "ds",  Ns.Ds.NamespaceName),
            new XAttribute(XNamespace.Xmlns + "ext", Ns.Ext.NamespaceName),
            new XAttribute(XNamespace.Xmlns + "sac", Sac.NamespaceName),

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

            BloqueFirmante(r.Emisor),
            BloqueEmisor(r.Emisor)
        );

        foreach (var linea in r.Lineas.OrderBy(l => l.Orden))
            raiz.Add(BloqueLinea(linea));

        return new XDocument(new XDeclaration("1.0", "UTF-8", null), raiz);
    }

    // ------------------------------------------------------------------ bloques

    private static XElement BloqueFirmante(Emisor e) =>
        new(Ns.Cac + "Signature",
            new XElement(Ns.Cbc + "ID", e.Ruc),
            new XElement(Ns.Cac + "SignatoryParty",
                new XElement(Ns.Cac + "PartyIdentification",
                    new XElement(Ns.Cbc + "ID", e.Ruc)),
                new XElement(Ns.Cac + "PartyName",
                    new XElement(Ns.Cbc + "Name", new XCData(e.RazonSocial)))),
            new XElement(Ns.Cac + "DigitalSignatureAttachment",
                new XElement(Ns.Cac + "ExternalReference",
                    new XElement(Ns.Cbc + "URI", "#SignatureSP"))));

    /// <summary>
    /// Emisor en formato antiguo: el RUC va directo en CustomerAssignedAccountID.
    /// No confundir con el bloque cac:Party de la factura.
    /// </summary>
    private static XElement BloqueEmisor(Emisor e) =>
        new(Ns.Cac + "AccountingSupplierParty",
            new XElement(Ns.Cbc + "CustomerAssignedAccountID", e.Ruc),
            new XElement(Ns.Cbc + "AdditionalAccountID", TipoDocIdentidad.Ruc),
            new XElement(Ns.Cac + "Party",
                new XElement(Ns.Cac + "PartyLegalEntity",
                    new XElement(Ns.Cbc + "RegistrationName",
                        new XCData(e.RazonSocial)))));

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
