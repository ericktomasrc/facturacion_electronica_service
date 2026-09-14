using System.Globalization;
using System.Xml.Linq;
using static Facturacion.Cpe.NumeroALetras;

namespace Facturacion.Cpe;

/// <summary>
/// Genera el XML UBL 2.1 de una factura.
///
/// ADVERTENCIA SOBRE EL ORDEN: en UBL el orden de los elementos NO es libre.
/// El XSD define una secuencia estricta y cualquier nodo fuera de lugar
/// invalida el documento completo. El orden de este archivo está tomado del
/// esquema y no debe reordenarse "por prolijidad".
///
/// El nodo ext:ExtensionContent se deja VACÍO a propósito: ahí entra la firma
/// en el paso 2. No se toca desde aquí.
/// </summary>
public static class GeneradorFacturaXml
{
    private static readonly CultureInfo Inv = CultureInfo.InvariantCulture;

    public static XDocument Generar(Factura f)
    {
        var totales = CalculadoraTotales.Calcular(f);
        var lineas = CalculadoraTotales.CalcularLineas(f);

        var raiz = new XElement(Ns.Invoice + "Invoice",
            new XAttribute(XNamespace.Xmlns + "cac", Ns.Cac.NamespaceName),
            new XAttribute(XNamespace.Xmlns + "cbc", Ns.Cbc.NamespaceName),
            new XAttribute(XNamespace.Xmlns + "ext", Ns.Ext.NamespaceName),
            new XAttribute(XNamespace.Xmlns + "ds",  Ns.Ds.NamespaceName),

            // 1. Contenedor de la firma. Se deja vacío hasta el paso 2.
            ExtensionesVacias(),

            // 2. Identificación del documento
            new XElement(Ns.Cbc + "UBLVersionID", "2.1"),
            new XElement(Ns.Cbc + "CustomizationID", "2.0"),
            new XElement(Ns.Cbc + "ID", f.NumeroCompleto),
            new XElement(Ns.Cbc + "IssueDate", f.FechaEmision.ToString("yyyy-MM-dd", Inv)),
            new XElement(Ns.Cbc + "IssueTime", f.FechaEmision.ToString("HH:mm:ss", Inv)),

            new XElement(Ns.Cbc + "InvoiceTypeCode",
                new XAttribute("listID", f.TipoOperacion),
                new XAttribute("listAgencyName", "PE:SUNAT"),
                new XAttribute("listName", "Tipo de Documento"),
                new XAttribute("listURI", CatalogoUri.C01_TipoDocumento),
                f.TipoComprobante),

            // Leyenda obligatoria: importe en letras (código 1000)
            new XElement(Ns.Cbc + "Note",
                new XAttribute("languageLocaleID", "1000"),
                new XCData(Leyenda(totales.ImporteTotal, f.Moneda))),

            new XElement(Ns.Cbc + "DocumentCurrencyCode", f.Moneda),

            // 3. Declaración de quién firma
            BloqueSignature(f),

            // 4. Emisor y receptor
            BloqueEmisor(f.Emisor),
            BloqueReceptor(f.Receptor),

            // 5. Forma de pago
            new XElement(Ns.Cac + "PaymentTerms",
                new XElement(Ns.Cbc + "ID", "FormaPago"),
                new XElement(Ns.Cbc + "PaymentMeansID", f.FormaPago)),

            // 6. Totales de impuestos
            BloqueTaxTotal(f, totales),

            // 7. Totales monetarios
            BloqueLegalMonetaryTotal(f, totales)
        );

        // 8. Detalle, una línea por ítem
        foreach (var linea in lineas)
            raiz.Add(BloqueInvoiceLine(f, linea));

        return new XDocument(new XDeclaration("1.0", "UTF-8", null), raiz);
    }

    // ---------------------------------------------------------------- bloques

    private static XElement ExtensionesVacias() =>
        new(Ns.Ext + "UBLExtensions",
            new XElement(Ns.Ext + "UBLExtension",
                new XElement(Ns.Ext + "ExtensionContent")));

    private static XElement BloqueSignature(Factura f) =>
        new(Ns.Cac + "Signature",
            new XElement(Ns.Cbc + "ID", f.NumeroCompleto),
            new XElement(Ns.Cac + "SignatoryParty",
                new XElement(Ns.Cac + "PartyIdentification",
                    new XElement(Ns.Cbc + "ID", f.Emisor.Ruc)),
                new XElement(Ns.Cac + "PartyName",
                    new XElement(Ns.Cbc + "Name", new XCData(f.Emisor.RazonSocial)))),
            new XElement(Ns.Cac + "DigitalSignatureAttachment",
                new XElement(Ns.Cac + "ExternalReference",
                    new XElement(Ns.Cbc + "URI", "#SignatureSP"))));

    private static XElement BloqueEmisor(Emisor e) =>
        new(Ns.Cac + "AccountingSupplierParty",
            new XElement(Ns.Cac + "Party",
                new XElement(Ns.Cac + "PartyIdentification",
                    new XElement(Ns.Cbc + "ID",
                        new XAttribute("schemeID", TipoDocIdentidad.Ruc),
                        new XAttribute("schemeName", "Documento de Identidad"),
                        new XAttribute("schemeAgencyName", "PE:SUNAT"),
                        new XAttribute("schemeURI", CatalogoUri.C06_TipoDocIdentidad),
                        e.Ruc)),

                new XElement(Ns.Cac + "PartyName",
                    new XElement(Ns.Cbc + "Name",
                        new XCData(string.IsNullOrWhiteSpace(e.NombreComercial)
                            ? e.RazonSocial
                            : e.NombreComercial))),

                new XElement(Ns.Cac + "PartyLegalEntity",
                    new XElement(Ns.Cbc + "RegistrationName", new XCData(e.RazonSocial)),
                    new XElement(Ns.Cac + "RegistrationAddress",
                        new XElement(Ns.Cbc + "ID",
                            new XAttribute("schemeAgencyName", "PE:INEI"),
                            new XAttribute("schemeName", "Ubigeos"),
                            e.Ubigeo),
                        new XElement(Ns.Cbc + "AddressTypeCode",
                            new XAttribute("listAgencyName", "PE:SUNAT"),
                            new XAttribute("listName", "Establecimientos anexos"),
                            e.CodigoEstablecimiento),
                        new XElement(Ns.Cbc + "CityName", e.Provincia),
                        new XElement(Ns.Cbc + "CountrySubentity", e.Departamento),
                        new XElement(Ns.Cbc + "District", e.Distrito),
                        new XElement(Ns.Cac + "AddressLine",
                            new XElement(Ns.Cbc + "Line", new XCData(e.Direccion))),
                        new XElement(Ns.Cac + "Country",
                            new XElement(Ns.Cbc + "IdentificationCode",
                                new XAttribute("listID", "ISO 3166-1"),
                                new XAttribute("listAgencyName", "United Nations Economic Commission for Europe"),
                                new XAttribute("listName", "Country"),
                                e.CodigoPais))))));

    private static XElement BloqueReceptor(Receptor r) =>
        new(Ns.Cac + "AccountingCustomerParty",
            new XElement(Ns.Cac + "Party",
                new XElement(Ns.Cac + "PartyIdentification",
                    new XElement(Ns.Cbc + "ID",
                        new XAttribute("schemeID", r.TipoDocumento),
                        new XAttribute("schemeName", "Documento de Identidad"),
                        new XAttribute("schemeAgencyName", "PE:SUNAT"),
                        new XAttribute("schemeURI", CatalogoUri.C06_TipoDocIdentidad),
                        r.NumeroDocumento)),

                new XElement(Ns.Cac + "PartyLegalEntity",
                    new XElement(Ns.Cbc + "RegistrationName", new XCData(r.RazonSocial)),
                    string.IsNullOrWhiteSpace(r.Direccion)
                        ? null
                        : new XElement(Ns.Cac + "RegistrationAddress",
                            new XElement(Ns.Cac + "AddressLine",
                                new XElement(Ns.Cbc + "Line", new XCData(r.Direccion)))))));

    private static XElement BloqueTaxTotal(Factura f, TotalesFactura t)
    {
        var nodo = new XElement(Ns.Cac + "TaxTotal",
            new XElement(Ns.Cbc + "TaxAmount",
                new XAttribute("currencyID", f.Moneda), F2(t.TotalIgv)));

        if (t.TotalGravado > 0)
            nodo.Add(Subtotal(f.Moneda, t.TotalGravado, t.TotalIgv,
                AfectacionIgv.GravadoOperacionOnerosa));

        if (t.TotalExonerado > 0)
            nodo.Add(Subtotal(f.Moneda, t.TotalExonerado, 0m, AfectacionIgv.Exonerado));

        if (t.TotalInafecto > 0)
            nodo.Add(Subtotal(f.Moneda, t.TotalInafecto, 0m, AfectacionIgv.Inafecto));

        return nodo;
    }

    private static XElement Subtotal(
        string moneda, decimal baseImponible, decimal impuesto, string afectacion)
    {
        var cat = AfectacionIgv.Categoria(afectacion);

        return new XElement(Ns.Cac + "TaxSubtotal",
            new XElement(Ns.Cbc + "TaxableAmount",
                new XAttribute("currencyID", moneda), F2(baseImponible)),
            new XElement(Ns.Cbc + "TaxAmount",
                new XAttribute("currencyID", moneda), F2(impuesto)),
            new XElement(Ns.Cac + "TaxCategory",
                new XElement(Ns.Cac + "TaxScheme",
                    new XElement(Ns.Cbc + "ID",
                        new XAttribute("schemeID", "UN/ECE 5153"),
                        new XAttribute("schemeAgencyID", "6"),
                        cat.Codigo),
                    new XElement(Ns.Cbc + "Name", cat.Nombre),
                    new XElement(Ns.Cbc + "TaxTypeCode", cat.TipoCodigo))));
    }

    private static XElement BloqueLegalMonetaryTotal(Factura f, TotalesFactura t) =>
        new(Ns.Cac + "LegalMonetaryTotal",
            new XElement(Ns.Cbc + "LineExtensionAmount",
                new XAttribute("currencyID", f.Moneda), F2(t.ValorVenta)),
            new XElement(Ns.Cbc + "TaxInclusiveAmount",
                new XAttribute("currencyID", f.Moneda), F2(t.ImporteTotal)),
            new XElement(Ns.Cbc + "PayableAmount",
                new XAttribute("currencyID", f.Moneda), F2(t.ImporteTotal)));

    private static XElement BloqueInvoiceLine(Factura f, LineaCalculada c)
    {
        var l = c.Linea;
        var cat = AfectacionIgv.Categoria(l.TipoAfectacionIgv);
        var esGratuita = AfectacionIgv.EsGratuita(l.TipoAfectacionIgv);

        return new XElement(Ns.Cac + "InvoiceLine",
            new XElement(Ns.Cbc + "ID", l.Numero),

            new XElement(Ns.Cbc + "InvoicedQuantity",
                new XAttribute("unitCode", l.UnidadMedida),
                new XAttribute("unitCodeListID", "UN/ECE rec 20"),
                new XAttribute("unitCodeListAgencyName",
                    "United Nations Economic Commission for Europe"),
                l.Cantidad.ToString("0.##########", Inv)),

            new XElement(Ns.Cbc + "LineExtensionAmount",
                new XAttribute("currencyID", f.Moneda),
                F2(esGratuita ? 0m : c.ValorVenta)),

            // Precio unitario de referencia, con IGV incluido
            new XElement(Ns.Cac + "PricingReference",
                new XElement(Ns.Cac + "AlternativeConditionPrice",
                    new XElement(Ns.Cbc + "PriceAmount",
                        new XAttribute("currencyID", f.Moneda),
                        F2(esGratuita ? 0m : c.PrecioUnitarioConIgv)),
                    new XElement(Ns.Cbc + "PriceTypeCode",
                        new XAttribute("listName", "Tipo de Precio"),
                        new XAttribute("listAgencyName", "PE:SUNAT"),
                        new XAttribute("listURI", CatalogoUri.C16_TipoPrecio),
                        esGratuita
                            ? TipoPrecio.ValorReferencialGratuito
                            : TipoPrecio.PrecioUnitarioIncluyeIgv))),

            // Impuestos de la línea
            new XElement(Ns.Cac + "TaxTotal",
                new XElement(Ns.Cbc + "TaxAmount",
                    new XAttribute("currencyID", f.Moneda), F2(c.Igv)),
                new XElement(Ns.Cac + "TaxSubtotal",
                    new XElement(Ns.Cbc + "TaxableAmount",
                        new XAttribute("currencyID", f.Moneda), F2(c.ValorVenta)),
                    new XElement(Ns.Cbc + "TaxAmount",
                        new XAttribute("currencyID", f.Moneda), F2(c.Igv)),
                    new XElement(Ns.Cac + "TaxCategory",
                        new XElement(Ns.Cbc + "Percent", F2(l.PorcentajeIgv)),
                        new XElement(Ns.Cbc + "TaxExemptionReasonCode",
                            new XAttribute("listAgencyName", "PE:SUNAT"),
                            new XAttribute("listName", "Afectacion del IGV"),
                            new XAttribute("listURI", CatalogoUri.C07_AfectacionIgv),
                            l.TipoAfectacionIgv),
                        new XElement(Ns.Cac + "TaxScheme",
                            new XElement(Ns.Cbc + "ID",
                                new XAttribute("schemeID", "UN/ECE 5153"),
                                new XAttribute("schemeAgencyID", "6"),
                                cat.Codigo),
                            new XElement(Ns.Cbc + "Name", cat.Nombre),
                            new XElement(Ns.Cbc + "TaxTypeCode", cat.TipoCodigo))))),

            // Descripción del producto
            new XElement(Ns.Cac + "Item",
                new XElement(Ns.Cbc + "Description", new XCData(l.Descripcion)),
                string.IsNullOrWhiteSpace(l.CodigoProducto)
                    ? null
                    : new XElement(Ns.Cac + "SellersItemIdentification",
                        new XElement(Ns.Cbc + "ID", l.CodigoProducto))),

            // Valor unitario sin IGV
            new XElement(Ns.Cac + "Price",
                new XElement(Ns.Cbc + "PriceAmount",
                    new XAttribute("currencyID", f.Moneda),
                    l.ValorUnitario.ToString("F2", Inv))));
    }
}
