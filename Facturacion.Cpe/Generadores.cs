using System.Xml.Linq;
using static Facturacion.Cpe.BloquesComunes;

namespace Facturacion.Cpe;

/// <summary>
/// Genera el XML UBL 2.1 de una factura.
///
/// ADVERTENCIA SOBRE EL ORDEN: en UBL el orden de los elementos NO es libre.
/// El XSD define una secuencia estricta y cualquier nodo fuera de lugar invalida
/// el documento completo. No reordenar "por prolijidad".
/// </summary>
public static class GeneradorFacturaXml
{
    public static XDocument Generar(Factura f)
    {
        var totales = CalculadoraTotales.Calcular(f);
        var lineas = CalculadoraTotales.CalcularLineas(f);

        var raiz = new XElement(Ns.Invoice + "Invoice",
            Namespaces(),

            ExtensionesVacias(),
            UblVersion(),
            CustomizationId(),

            new XElement(Ns.Cbc + "ID", f.NumeroCompleto),
            new XElement(Ns.Cbc + "IssueDate", f.FechaEmision.ToString("yyyy-MM-dd", Inv)),
            new XElement(Ns.Cbc + "IssueTime", f.FechaEmision.ToString("HH:mm:ss", Inv)),

            new XElement(Ns.Cbc + "InvoiceTypeCode",
                new XAttribute("listID", f.TipoOperacion),
                new XAttribute("listAgencyName", "PE:SUNAT"),
                new XAttribute("listName", "Tipo de Documento"),
                new XAttribute("listURI", CatalogoUri.C01_TipoDocumento),
                f.TipoComprobante),

            LeyendaImporte(totales.ImporteTotal, f.Moneda),

            new XElement(Ns.Cbc + "DocumentCurrencyCode", f.Moneda),

            Signature(f),
            Emisor(f.Emisor),
            Receptor(f.Receptor),

            // La forma de pago es obligatoria en facturas.
            new XElement(Ns.Cac + "PaymentTerms",
                new XElement(Ns.Cbc + "ID", "FormaPago"),
                new XElement(Ns.Cbc + "PaymentMeansID", f.FormaPago)),

            TaxTotal(f.Moneda, totales),
            TotalesMonetarios("LegalMonetaryTotal", f.Moneda, totales)
        );

        foreach (var linea in lineas)
            raiz.Add(Linea("InvoiceLine", "InvoicedQuantity", f.Moneda, linea));

        return new XDocument(new XDeclaration("1.0", "UTF-8", null), raiz);
    }
}

/// <summary>
/// Genera el XML de notas de crédito y de débito.
///
/// QUÉ CAMBIA RESPECTO A LA FACTURA, Y NADA MÁS:
///
/// 1. El elemento raíz y su namespace: CreditNote o DebitNote.
/// 2. Aparece cac:DiscrepancyResponse con el motivo (catálogo 09 o 10).
/// 3. Aparece cac:BillingReference apuntando al documento que se modifica.
/// 4. Desaparece InvoiceTypeCode: el tipo ya lo determina el elemento raíz.
/// 5. Las líneas se llaman CreditNoteLine o DebitNoteLine, con su propia
///    etiqueta de cantidad.
/// 6. La nota de débito usa RequestedMonetaryTotal en vez de LegalMonetaryTotal.
///
/// Todo lo demás son los mismos bloques compartidos.
/// </summary>
public static class GeneradorNotaXml
{
    public static XDocument Generar(NotaCredito n) =>
        Construir(
            comprobante: n,
            espacioNombres: Ns.CreditNote,
            nombreRaiz: "CreditNote",
            nombreLinea: "CreditNoteLine",
            nombreCantidad: "CreditedQuantity",
            nombreTotales: "LegalMonetaryTotal",
            codigoMotivo: n.CodigoMotivo,
            descripcionMotivo: ResolverDescripcion(
                n.DescripcionMotivo, MotivoNotaCredito.Descripcion(n.CodigoMotivo)),
            afectado: n.Afectado);

    public static XDocument Generar(NotaDebito n) =>
        Construir(
            comprobante: n,
            espacioNombres: Ns.DebitNote,
            nombreRaiz: "DebitNote",
            nombreLinea: "DebitNoteLine",
            nombreCantidad: "DebitedQuantity",
            nombreTotales: "RequestedMonetaryTotal",
            codigoMotivo: n.CodigoMotivo,
            descripcionMotivo: ResolverDescripcion(
                n.DescripcionMotivo, MotivoNotaDebito.Descripcion(n.CodigoMotivo)),
            afectado: n.Afectado);

    private static string ResolverDescripcion(string propia, string porCatalogo) =>
        string.IsNullOrWhiteSpace(propia) ? porCatalogo : propia;

    private static XDocument Construir(
        ComprobanteBase comprobante,
        XNamespace espacioNombres,
        string nombreRaiz,
        string nombreLinea,
        string nombreCantidad,
        string nombreTotales,
        string codigoMotivo,
        string descripcionMotivo,
        DocumentoAfectado afectado)
    {
        var totales = CalculadoraTotales.Calcular(comprobante);
        var lineas = CalculadoraTotales.CalcularLineas(comprobante);

        var raiz = new XElement(espacioNombres + nombreRaiz,
            Namespaces(),

            ExtensionesVacias(),
            UblVersion(),
            CustomizationId(),

            new XElement(Ns.Cbc + "ID", comprobante.NumeroCompleto),
            new XElement(Ns.Cbc + "IssueDate",
                comprobante.FechaEmision.ToString("yyyy-MM-dd", Inv)),
            new XElement(Ns.Cbc + "IssueTime",
                comprobante.FechaEmision.ToString("HH:mm:ss", Inv)),

            LeyendaImporte(totales.ImporteTotal, comprobante.Moneda),

            new XElement(Ns.Cbc + "DocumentCurrencyCode", comprobante.Moneda),

            // Por qué se emite esta nota.
            new XElement(Ns.Cac + "DiscrepancyResponse",
                new XElement(Ns.Cbc + "ReferenceID", afectado.Numero),
                new XElement(Ns.Cbc + "ResponseCode", codigoMotivo),
                new XElement(Ns.Cbc + "Description", new XCData(descripcionMotivo))),

            // A qué documento afecta.
            new XElement(Ns.Cac + "BillingReference",
                new XElement(Ns.Cac + "InvoiceDocumentReference",
                    new XElement(Ns.Cbc + "ID", afectado.Numero),
                    new XElement(Ns.Cbc + "DocumentTypeCode", afectado.TipoDocumento))),

            Signature(comprobante),
            Emisor(comprobante.Emisor),
            Receptor(comprobante.Receptor),

            TaxTotal(comprobante.Moneda, totales),
            TotalesMonetarios(nombreTotales, comprobante.Moneda, totales)
        );

        foreach (var linea in lineas)
            raiz.Add(Linea(nombreLinea, nombreCantidad, comprobante.Moneda, linea));

        return new XDocument(new XDeclaration("1.0", "UTF-8", null), raiz);
    }
}
