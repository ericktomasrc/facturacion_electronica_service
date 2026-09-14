using System.Globalization;
using System.Xml.Linq;
using static Facturacion.Cpe.NumeroALetras;

namespace Facturacion.Cpe;

/// <summary>
/// Bloques XML que comparten factura, boleta, nota de crédito y nota de débito.
///
/// POR QUÉ EXISTE ESTA CLASE: los cuatro documentos coinciden en cerca del 80%
/// de su contenido (emisor, receptor, impuestos, líneas de detalle). Mantener
/// cuatro copias de esos bloques significa que cada cambio de SUNAT hay que
/// aplicarlo cuatro veces, y que tarde o temprano se desincronizan.
///
/// Este refactor es lo que hace que agregar el quinto y el sexto documento
/// cueste casi nada.
/// </summary>
internal static class BloquesComunes
{
    internal static readonly CultureInfo Inv = CultureInfo.InvariantCulture;

    /// <summary>Contenedor donde el firmador insertará la firma. Se deja vacío.</summary>
    internal static XElement ExtensionesVacias() =>
        new(Ns.Ext + "UBLExtensions",
            new XElement(Ns.Ext + "UBLExtension",
                new XElement(Ns.Ext + "ExtensionContent")));

    internal static XElement UblVersion() =>
        new(Ns.Cbc + "UBLVersionID", "2.1");

    internal static XElement CustomizationId() =>
        new(Ns.Cbc + "CustomizationID", "2.0");

    /// <summary>Leyenda obligatoria con el importe en letras (código 1000).</summary>
    internal static XElement LeyendaImporte(decimal importeTotal, string moneda) =>
        new(Ns.Cbc + "Note",
            new XAttribute("languageLocaleID", "1000"),
            new XCData(Leyenda(importeTotal, moneda)));

    /// <summary>Declaración de quién firma el documento.</summary>
    internal static XElement Signature(ComprobanteBase c) =>
        new(Ns.Cac + "Signature",
            new XElement(Ns.Cbc + "ID", c.NumeroCompleto),
            new XElement(Ns.Cac + "SignatoryParty",
                new XElement(Ns.Cac + "PartyIdentification",
                    new XElement(Ns.Cbc + "ID", c.Emisor.Ruc)),
                new XElement(Ns.Cac + "PartyName",
                    new XElement(Ns.Cbc + "Name", new XCData(c.Emisor.RazonSocial)))),
            new XElement(Ns.Cac + "DigitalSignatureAttachment",
                new XElement(Ns.Cac + "ExternalReference",
                    new XElement(Ns.Cbc + "URI", "#SignatureSP"))));

    internal static XElement Emisor(Emisor e) =>
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
                                new XAttribute("listAgencyName",
                                    "United Nations Economic Commission for Europe"),
                                new XAttribute("listName", "Country"),
                                e.CodigoPais))))));

    internal static XElement Receptor(Receptor r) =>
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

    /// <summary>Totales de impuestos del comprobante completo.</summary>
    internal static XElement TaxTotal(string moneda, TotalesComprobante t)
    {
        var nodo = new XElement(Ns.Cac + "TaxTotal",
            new XElement(Ns.Cbc + "TaxAmount",
                new XAttribute("currencyID", moneda), F2(t.TotalIgv)));

        if (t.TotalGravado > 0)
            nodo.Add(TaxSubtotal(moneda, t.TotalGravado, t.TotalIgv,
                AfectacionIgv.GravadoOperacionOnerosa));

        if (t.TotalExonerado > 0)
            nodo.Add(TaxSubtotal(moneda, t.TotalExonerado, 0m, AfectacionIgv.Exonerado));

        if (t.TotalInafecto > 0)
            nodo.Add(TaxSubtotal(moneda, t.TotalInafecto, 0m, AfectacionIgv.Inafecto));

        return nodo;
    }

    private static XElement TaxSubtotal(
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

    /// <summary>
    /// Totales monetarios. El nombre del elemento cambia según el documento:
    /// "LegalMonetaryTotal" en factura y nota de crédito,
    /// "RequestedMonetaryTotal" en nota de débito.
    /// </summary>
    internal static XElement TotalesMonetarios(
        string nombreElemento, string moneda, TotalesComprobante t) =>
        new(Ns.Cac + nombreElemento,
            new XElement(Ns.Cbc + "LineExtensionAmount",
                new XAttribute("currencyID", moneda), F2(t.ValorVenta)),
            new XElement(Ns.Cbc + "TaxInclusiveAmount",
                new XAttribute("currencyID", moneda), F2(t.ImporteTotal)),
            new XElement(Ns.Cbc + "PayableAmount",
                new XAttribute("currencyID", moneda), F2(t.ImporteTotal)));

    /// <summary>
    /// Línea de detalle. Los nombres cambian por documento:
    ///   Factura      → InvoiceLine    / InvoicedQuantity
    ///   NotaCrédito  → CreditNoteLine / CreditedQuantity
    ///   NotaDébito   → DebitNoteLine  / DebitedQuantity
    /// El contenido interno es idéntico en los tres.
    /// </summary>
    internal static XElement Linea(
        string nombreLinea,
        string nombreCantidad,
        string moneda,
        LineaCalculada c)
    {
        var l = c.Linea;
        var cat = AfectacionIgv.Categoria(l.TipoAfectacionIgv);
        var esGratuita = AfectacionIgv.EsGratuita(l.TipoAfectacionIgv);

        return new XElement(Ns.Cac + nombreLinea,
            new XElement(Ns.Cbc + "ID", l.Numero),

            new XElement(Ns.Cbc + nombreCantidad,
                new XAttribute("unitCode", l.UnidadMedida),
                new XAttribute("unitCodeListID", "UN/ECE rec 20"),
                new XAttribute("unitCodeListAgencyName",
                    "United Nations Economic Commission for Europe"),
                l.Cantidad.ToString("0.##########", Inv)),

            new XElement(Ns.Cbc + "LineExtensionAmount",
                new XAttribute("currencyID", moneda),
                F2(esGratuita ? 0m : c.ValorVenta)),

            new XElement(Ns.Cac + "PricingReference",
                new XElement(Ns.Cac + "AlternativeConditionPrice",
                    new XElement(Ns.Cbc + "PriceAmount",
                        new XAttribute("currencyID", moneda),
                        F2(esGratuita ? 0m : c.PrecioUnitarioConIgv)),
                    new XElement(Ns.Cbc + "PriceTypeCode",
                        new XAttribute("listName", "Tipo de Precio"),
                        new XAttribute("listAgencyName", "PE:SUNAT"),
                        new XAttribute("listURI", CatalogoUri.C16_TipoPrecio),
                        esGratuita
                            ? TipoPrecio.ValorReferencialGratuito
                            : TipoPrecio.PrecioUnitarioIncluyeIgv))),

            new XElement(Ns.Cac + "TaxTotal",
                new XElement(Ns.Cbc + "TaxAmount",
                    new XAttribute("currencyID", moneda), F2(c.Igv)),
                new XElement(Ns.Cac + "TaxSubtotal",
                    new XElement(Ns.Cbc + "TaxableAmount",
                        new XAttribute("currencyID", moneda), F2(c.ValorVenta)),
                    new XElement(Ns.Cbc + "TaxAmount",
                        new XAttribute("currencyID", moneda), F2(c.Igv)),
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

            new XElement(Ns.Cac + "Item",
                new XElement(Ns.Cbc + "Description", new XCData(l.Descripcion)),
                string.IsNullOrWhiteSpace(l.CodigoProducto)
                    ? null
                    : new XElement(Ns.Cac + "SellersItemIdentification",
                        new XElement(Ns.Cbc + "ID", l.CodigoProducto))),

            new XElement(Ns.Cac + "Price",
                new XElement(Ns.Cbc + "PriceAmount",
                    new XAttribute("currencyID", moneda),
                    l.ValorUnitario.ToString("F2", Inv))));
    }

    /// <summary>Atributos de namespace comunes a todos los documentos.</summary>
    internal static XAttribute[] Namespaces() =>
    [
        new XAttribute(XNamespace.Xmlns + "cac", Ns.Cac.NamespaceName),
        new XAttribute(XNamespace.Xmlns + "cbc", Ns.Cbc.NamespaceName),
        new XAttribute(XNamespace.Xmlns + "ext", Ns.Ext.NamespaceName),
        new XAttribute(XNamespace.Xmlns + "ds",  Ns.Ds.NamespaceName)
    ];
}
