using System.Globalization;
using System.Xml.Linq;
using static Facturacion.Cpe.BloquesComunes;

namespace Facturacion.Cpe;

/// <summary>
/// Genera el XML UBL 2.1 de una liquidación de compra electrónica.
///
/// POR QUÉ NO REUTILIZA LOS BLOQUES DE LA FACTURA: porque casi ninguno sirve.
/// El emisor y el receptor están intercambiados, el vendedor lleva dirección
/// completa que un receptor no lleva, y la línea declara un tributo —la
/// retención de renta— que no existe en ningún otro documento.
///
/// Se reutiliza lo que de verdad es común: las extensiones vacías, la versión,
/// la firma y la leyenda del importe en letras.
///
/// EL ORDEN DE LOS ELEMENTOS NO ES LIBRE. El XSD del SelfBilledInvoice define
/// una secuencia estricta, y la única diferencia visible con la del Invoice es
/// justamente la que define el documento: AccountingCustomerParty —el
/// comprador, que es quien emite— va ANTES que AccountingSupplierParty.
/// </summary>
public static class GeneradorLiquidacionXml
{
    /// <summary>
    /// El espacio de nombres de la raíz.
    ///
    /// Se declara aquí y no en Ns para no tocar Catalogos.cs por un solo
    /// valor que solo usa este documento.
    /// </summary>
    private static readonly XNamespace SelfBilled =
        "urn:oasis:names:specification:ubl:schema:xsd:SelfBilledInvoice-2";

    private static readonly CultureInfo Cultura = CultureInfo.InvariantCulture;

    /// <summary>Importe con dos decimales exactos, que es lo que SUNAT compara.</summary>
    private static string F2(decimal valor) => valor.ToString("F2", Cultura);

    public static XDocument Generar(LiquidacionCompra lc)
    {
        var totales = CalculadoraLiquidacion.Calcular(lc);
        var lineas = CalculadoraLiquidacion.CalcularLineas(lc);

        var raiz = new XElement(SelfBilled + "SelfBilledInvoice",
            new XAttribute(XNamespace.Xmlns + "cac", Ns.Cac.NamespaceName),
            new XAttribute(XNamespace.Xmlns + "cbc", Ns.Cbc.NamespaceName),
            new XAttribute(XNamespace.Xmlns + "ext", Ns.Ext.NamespaceName),
            new XAttribute(XNamespace.Xmlns + "ds", Ns.Ds.NamespaceName),

            ExtensionesVacias(),
            UblVersion(),
            CustomizationId(),

            new XElement(Ns.Cbc + "ID", lc.NumeroCompleto),
            new XElement(Ns.Cbc + "IssueDate",
                lc.FechaEmision.ToString("yyyy-MM-dd", Cultura)),
            new XElement(Ns.Cbc + "IssueTime",
                lc.FechaEmision.ToString("HH:mm:ss", Cultura)),

            // El tipo de operación va como listID, igual que en la factura,
            // pero aquí solo admite 0501, 0502 y 0503 (error 3206).
            new XElement(Ns.Cbc + "InvoiceTypeCode",
                new XAttribute("listID", lc.TipoOperacion),
                new XAttribute("listAgencyName", "PE:SUNAT"),
                new XAttribute("listName", "Tipo de Documento"),
                new XAttribute("listURI", CatalogoUri.C01_TipoDocumento),
                lc.TipoComprobante),

            // El importe en letras es el que el vendedor cobra —el neto— y no
            // el subtotal. Es el número que la persona va a mirar.
            LeyendaImporte(totales.ImporteAPagar, lc.Moneda),

            LeyendaSuelta(totales.HayGratuitas,
                CodigoLeyenda.TransferenciaGratuita, Gratuitas.TextoLeyenda),

            new XElement(Ns.Cbc + "DocumentCurrencyCode", lc.Moneda),

            Signature(lc),

            // AQUÍ ESTÁ TODO EL DOCUMENTO, EN DOS LÍNEAS.
            //
            // El comprador es el CustomerParty y va primero; el vendedor es el
            // SupplierParty y va después. Al revés de una factura, y al revés
            // de lo que cualquiera escribiría sin leer el XSD.
            Comprador(lc.Emisor),
            VendedorParty(lc.Vendedor),

            // El lugar donde se hizo la compra. Obligatorio, y distinto del
            // domicilio del vendedor.
            LugarDeLaOperacion(lc.Lugar),

            TipoDeCambio(lc.TipoCambio),

            TaxTotalGlobal(lc.Moneda, totales, lc),
            TotalesMonetariosLc(lc.Moneda, totales)
        );

        foreach (var linea in lineas)
            raiz.Add(Linea(lc, linea));

        return new XDocument(new XDeclaration("1.0", "UTF-8", null), raiz);
    }

    // ------------------------------------------------------------- las partes

    /// <summary>
    /// El comprador, que es el emisor del documento.
    ///
    /// Va en cac:AccountingCustomerParty, que en una factura es el cliente.
    /// Lleva RUC obligatorio con schemeID "6" (error 1007).
    /// </summary>
    private static XElement Comprador(Emisor e) =>
        new(Ns.Cac + "AccountingCustomerParty",
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

    /// <summary>
    /// El vendedor, que va en cac:AccountingSupplierParty.
    ///
    /// LA DIRECCIÓN ES OBLIGATORIA, con ubigeo (error 2453) y con
    /// AddressTypeCode del catálogo 60 (error 2456). Un receptor de factura
    /// no lleva nada de esto, y es la razón de que este bloque no se pueda
    /// reutilizar.
    /// </summary>
    private static XElement VendedorParty(Vendedor v) =>
        new(Ns.Cac + "AccountingSupplierParty",
            new XElement(Ns.Cac + "Party",
                new XElement(Ns.Cac + "PartyIdentification",
                    new XElement(Ns.Cbc + "ID",
                        new XAttribute("schemeID", v.TipoDocumento),
                        new XAttribute("schemeName", "Documento de Identidad"),
                        new XAttribute("schemeAgencyName", "PE:SUNAT"),
                        new XAttribute("schemeURI", CatalogoUri.C06_TipoDocIdentidad),
                        v.NumeroDocumento)),

                new XElement(Ns.Cac + "PartyLegalEntity",
                    new XElement(Ns.Cbc + "RegistrationName", new XCData(v.Nombres)),
                    new XElement(Ns.Cac + "RegistrationAddress",
                        new XElement(Ns.Cbc + "ID",
                            new XAttribute("schemeAgencyName", "PE:INEI"),
                            new XAttribute("schemeName", "Ubigeos"),
                            v.Ubigeo),

                        // Qué es este sitio: chacra, mina, punto de venta.
                        // Catálogo 60.
                        new XElement(Ns.Cbc + "AddressTypeCode",
                            new XAttribute("listAgencyName", "PE:SUNAT"),
                            new XAttribute("listName", "Establecimientos anexos"),
                            v.CondicionDomicilio),

                        new XElement(Ns.Cbc + "CityName", v.Provincia),
                        new XElement(Ns.Cbc + "CountrySubentity", v.Departamento),
                        new XElement(Ns.Cbc + "District", v.Distrito),
                        new XElement(Ns.Cac + "AddressLine",
                            new XElement(Ns.Cbc + "Line", new XCData(v.Direccion))),
                        new XElement(Ns.Cac + "Country",
                            new XElement(Ns.Cbc + "IdentificationCode",
                                new XAttribute("listID", "ISO 3166-1"),
                                new XAttribute("listAgencyName",
                                    "United Nations Economic Commission for Europe"),
                                new XAttribute("listName", "Country"),
                                v.CodigoPais))))));

    /// <summary>
    /// Dónde se hizo la compra.
    ///
    /// SUNAT lo mete en cac:DeliveryTerms, que en UBL son las condiciones de
    /// entrega. Suena forzado, pero es el hueco que el estándar ofrece y el
    /// que miran las validaciones 2454, 2455 y 2458.
    ///
    /// DÓNDE VA EN LA SECUENCIA: después de las dos partes y antes de
    /// cac:TaxTotal.
    /// </summary>
    private static XElement LugarDeLaOperacion(LugarOperacion l) =>
        new(Ns.Cac + "DeliveryTerms",
            new XElement(Ns.Cac + "DeliveryLocation",

                // El tipo de sitio va en LocationTypeCode, no en
                // AddressTypeCode: el mismo dato del catálogo 60 con otro
                // nombre, porque aquí cuelga del Location y no del Address.
                new XElement(Ns.Cbc + "LocationTypeCode", l.Condicion),

                new XElement(Ns.Cac + "Address",
                    new XElement(Ns.Cbc + "ID",
                        new XAttribute("schemeAgencyName", "PE:INEI"),
                        new XAttribute("schemeName", "Ubigeos"),
                        l.Ubigeo),
                    new XElement(Ns.Cbc + "CityName", l.Provincia),
                    new XElement(Ns.Cbc + "CountrySubentity", l.Departamento),
                    new XElement(Ns.Cbc + "District", l.Distrito),
                    new XElement(Ns.Cac + "AddressLine",
                        new XElement(Ns.Cbc + "Line", new XCData(l.Direccion))),
                    new XElement(Ns.Cac + "Country",
                        new XElement(Ns.Cbc + "IdentificationCode",
                            new XAttribute("listID", "ISO 3166-1"),
                            new XAttribute("listAgencyName",
                                "United Nations Economic Commission for Europe"),
                            new XAttribute("listName", "Country"),
                            l.CodigoPais)))));

    // ------------------------------------------------------------- impuestos

    /// <summary>
    /// El bloque de impuestos del documento.
    ///
    /// EL TAXAMOUNT DE ARRIBA SOLO LLEVA EL IGV. La retención de renta tiene
    /// su propio TaxSubtotal —es obligatorio, error 3003— pero no suma en el
    /// total: la regla 4301 solo cuenta los tributos 1000 y 9999.
    ///
    /// Es coherente con lo que pasa de verdad: el IGV es un impuesto de la
    /// operación, la retención es un adelanto del impuesto de otra persona.
    /// </summary>
    private static XElement TaxTotalGlobal(
        string moneda, TotalesLiquidacion t, LiquidacionCompra lc)
    {
        var bloque = new XElement(Ns.Cac + "TaxTotal",
            new XElement(Ns.Cbc + "TaxAmount",
                new XAttribute("currencyID", moneda), F2(t.TotalTributos)));

        // El subtotal del IGV siempre va, aunque no haya gravadas: es
        // obligatorio (error 3003).
        bloque.Add(Subtotal(moneda, "1000", "IGV", "VAT",
            t.ValorVentaGravado, t.Igv));

        if (t.HayExoneradas)
            bloque.Add(Subtotal(moneda, "9997", "EXO", "VAT", t.ValorVentaExonerado, 0m));

        if (t.HayInafectas)
            bloque.Add(Subtotal(moneda, "9998", "INA", "FRE", t.ValorVentaInafecto, 0m));

        if (t.HayGratuitas)
            bloque.Add(Subtotal(moneda, "9996", "GRA", "FRE", t.ValorVentaGratuito, 0m));

        // La retención de renta. Va siempre que se haya retenido algo.
        if (lc.RetieneRenta && t.Retencion > 0)
        {
            bloque.Add(Subtotal(moneda,
                RetencionRenta.Codigo, RetencionRenta.Nombre, RetencionRenta.TipoCodigo,
                t.BaseRetencion, t.Retencion));
        }

        return bloque;
    }

    /// <summary>Un cac:TaxSubtotal global, sin afectación al IGV.</summary>
    private static XElement Subtotal(
        string moneda, string codigo, string nombre, string tipoCodigo,
        decimal baseImponible, decimal impuesto) =>
        new(Ns.Cac + "TaxSubtotal",
            new XElement(Ns.Cbc + "TaxableAmount",
                new XAttribute("currencyID", moneda), F2(baseImponible)),
            new XElement(Ns.Cbc + "TaxAmount",
                new XAttribute("currencyID", moneda), F2(impuesto)),
            new XElement(Ns.Cac + "TaxCategory",
                new XElement(Ns.Cac + "TaxScheme",
                    new XElement(Ns.Cbc + "ID",
                        new XAttribute("schemeID", "UN/ECE 5153"),
                        new XAttribute("schemeAgencyID", "6"),
                        codigo),
                    new XElement(Ns.Cbc + "Name", nombre),
                    new XElement(Ns.Cbc + "TaxTypeCode", tipoCodigo))));

    /// <summary>
    /// Los totales.
    ///
    /// AQUÍ ESTÁ LA RESTA QUE HACE RARO A ESTE DOCUMENTO:
    ///
    ///   LineExtensionAmount   valor de compra
    ///   TaxInclusiveAmount    valor de compra + IGV
    ///   PayableAmount         lo anterior menos el IGV menos la retención
    ///
    /// El PayableAmount es el MENOR de los tres, al revés que en una factura.
    /// Es lo que el vendedor cobra de verdad: el IGV se lo queda el comprador
    /// como crédito fiscal y la retención se deposita a SUNAT.
    /// </summary>
    private static XElement TotalesMonetariosLc(string moneda, TotalesLiquidacion t) =>
        new(Ns.Cac + "LegalMonetaryTotal",
            new XElement(Ns.Cbc + "LineExtensionAmount",
                new XAttribute("currencyID", moneda), F2(t.ValorVenta)),
            new XElement(Ns.Cbc + "TaxInclusiveAmount",
                new XAttribute("currencyID", moneda), F2(t.Subtotal)),
            new XElement(Ns.Cbc + "PayableAmount",
                new XAttribute("currencyID", moneda), F2(t.ImporteAPagar)));

    // ---------------------------------------------------------------- líneas

    /// <summary>
    /// Una línea de la liquidación.
    ///
    /// Lo que la distingue de una línea de factura es el SEGUNDO TaxSubtotal,
    /// el de la retención de renta, que:
    ///
    ///   - lleva Percent como cualquier otro,
    ///   - NO lleva TaxExemptionReasonCode (error 3050): no es un tributo de
    ///     IGV y no tiene afectación que declarar,
    ///   - y NO suma en el TaxAmount de la línea (regla 4293), igual que a
    ///     nivel global.
    /// </summary>
    private static XElement Linea(LiquidacionCompra lc, LineaLiquidacion c)
    {
        var l = c.Origen;
        var cat = AfectacionIgv.Categoria(l.TipoAfectacionIgv);
        var esGratuita = AfectacionIgv.EsGratuita(l.TipoAfectacionIgv);
        var moneda = lc.Moneda;

        var impuestos = new XElement(Ns.Cac + "TaxTotal",

            // Solo el IGV. La retención va debajo pero no suma aquí.
            new XElement(Ns.Cbc + "TaxAmount",
                new XAttribute("currencyID", moneda), F2(c.Igv)),

            new XElement(Ns.Cac + "TaxSubtotal",
                new XElement(Ns.Cbc + "TaxableAmount",
                    new XAttribute("currencyID", moneda), F2(c.ValorVenta)),
                new XElement(Ns.Cbc + "TaxAmount",
                    new XAttribute("currencyID", moneda), F2(c.Igv)),
                new XElement(Ns.Cac + "TaxCategory",
                    new XElement(Ns.Cbc + "Percent", F2(l.TasaDeclarada)),
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
                        new XElement(Ns.Cbc + "TaxTypeCode", cat.TipoCodigo)))));

        if (c.Retencion > 0)
        {
            impuestos.Add(new XElement(Ns.Cac + "TaxSubtotal",
                new XElement(Ns.Cbc + "TaxableAmount",
                    new XAttribute("currencyID", moneda), F2(c.ValorVenta)),
                new XElement(Ns.Cbc + "TaxAmount",
                    new XAttribute("currencyID", moneda), F2(c.Retencion)),
                new XElement(Ns.Cac + "TaxCategory",
                    new XElement(Ns.Cbc + "Percent", F2(lc.TasaRetencionRenta)),

                    // Sin TaxExemptionReasonCode, a propósito. Error 3050.
                    new XElement(Ns.Cac + "TaxScheme",
                        new XElement(Ns.Cbc + "ID",
                            new XAttribute("schemeID", "UN/ECE 5153"),
                            new XAttribute("schemeAgencyID", "6"),
                            RetencionRenta.Codigo),
                        new XElement(Ns.Cbc + "Name", RetencionRenta.Nombre),
                        new XElement(Ns.Cbc + "TaxTypeCode", RetencionRenta.TipoCodigo)))));
        }

        return new XElement(Ns.Cac + "InvoiceLine",
            new XElement(Ns.Cbc + "ID", c.Numero),

            new XElement(Ns.Cbc + "InvoicedQuantity",
                new XAttribute("unitCode", l.UnidadMedida),
                new XAttribute("unitCodeListID", "UN/ECE rec 20"),
                new XAttribute("unitCodeListAgencyName",
                    "United Nations Economic Commission for Europe"),
                l.Cantidad.ToString("0.##########", Inv)),

            new XElement(Ns.Cbc + "LineExtensionAmount",
                new XAttribute("currencyID", moneda), F2(c.ValorVenta)),

            // El precio de compra unitario. En una línea gratuita se invierte
            // con cac:Price, exactamente igual que en una factura.
            new XElement(Ns.Cac + "PricingReference",
                new XElement(Ns.Cac + "AlternativeConditionPrice",
                    new XElement(Ns.Cbc + "PriceAmount",
                        new XAttribute("currencyID", moneda),
                        esGratuita
                            ? Unitario(l.ValorUnitario)
                            : F2(c.PrecioUnitarioConIgv)),
                    new XElement(Ns.Cbc + "PriceTypeCode",
                        new XAttribute("listName", "Tipo de Precio"),
                        new XAttribute("listAgencyName", "PE:SUNAT"),
                        new XAttribute("listURI", CatalogoUri.C16_TipoPrecio),
                        esGratuita
                            ? TipoPrecio.ValorReferencialGratuito
                            : TipoPrecio.PrecioUnitarioIncluyeIgv))),

            impuestos,

            new XElement(Ns.Cac + "Item",
                new XElement(Ns.Cbc + "Description", new XCData(l.Descripcion)),
                string.IsNullOrWhiteSpace(l.CodigoProducto)
                    ? null
                    : new XElement(Ns.Cac + "SellersItemIdentification",
                        new XElement(Ns.Cbc + "ID", l.CodigoProducto)),

                // El código de producto SUNAT: obligatorio aquí desde 2027
                // (ReglasLiquidacion lo exige). Mismo sitio que en la factura.
                CodigoProductoSunat.Bloque(l.CodigoProductoSunat),

                PropiedadesDelItem(l.Propiedades)),

            new XElement(Ns.Cac + "Price",
                new XElement(Ns.Cbc + "PriceAmount",
                    new XAttribute("currencyID", moneda),
                    esGratuita ? "0.00" : Unitario(l.ValorUnitario))));
    }
}
