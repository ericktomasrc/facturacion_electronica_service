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

            // EL TIPO DE OPERACIÓN VA COMO ATRIBUTO listID.
            //
            // Es lo que le dice a SUNAT que esta factura está sujeta a
            // detracción. Sin él, los bloques de detracción se ignoran y la
            // factura sale como una venta normal, sin que nadie lo note hasta
            // que el cliente reclame el depósito que nunca llegó.
            new XElement(Ns.Cbc + "InvoiceTypeCode",
                new XAttribute("listID", f.TipoOperacionEfectivo),
                new XAttribute("listAgencyName", "PE:SUNAT"),
                new XAttribute("listName", "Tipo de Documento"),
                new XAttribute("listURI", CatalogoUri.C01_TipoDocumento),
                f.TipoComprobante),

            LeyendaImporte(totales.ImporteTotal, f.Moneda),

            // La leyenda que SUNAT exige en toda factura con detracción.
            //
            // El texto debe ser exactamente el del catálogo 15: sin ella, la
            // factura se rechaza.
            LeyendaDetraccion(f.Detraccion),

            new XElement(Ns.Cbc + "DocumentCurrencyCode", f.Moneda),

            Signature(f),
            Emisor(f.Emisor),
            Receptor(f.Receptor),

            // La cuenta donde se deposita la detracción.
            //
            // EL ORDEN IMPORTA: PaymentMeans antes que PaymentTerms. El XSD
            // define una secuencia, y al revés el documento no valida con un
            // error que habla de estructura y no menciona la detracción.
            MediosDePagoDetraccion(f.Detraccion),

            // La forma de pago es obligatoria en facturas.
            new XElement(Ns.Cac + "PaymentTerms",
                new XElement(Ns.Cbc + "ID", "FormaPago"),
                new XElement(Ns.Cbc + "PaymentMeansID", f.FormaPago)),

            // Cuánto se detrae y por qué concepto.
            CondicionesDetraccion(f.Detraccion),

            // Solo aparece si la factura no está en soles.
            TipoDeCambio(f.TipoCambio),

            TaxTotal(f.Moneda, totales),
            TotalesMonetarios("LegalMonetaryTotal", f.Moneda, totales)
        );

        foreach (var linea in lineas)
            raiz.Add(Linea("InvoiceLine", "InvoicedQuantity", f.Moneda, linea));

        return new XDocument(new XDeclaration("1.0", "UTF-8", null), raiz);
    }

    private static XElement? LeyendaDetraccion(Detraccion? d) =>
        d is null ? null : new XElement(Ns.Cbc + "Note",
            new XAttribute("languageLocaleID", Detraccion.CodigoLeyenda),
            new XCData(Detraccion.TextoLeyenda));

    // --------------------------------------------------------- detracción

    /// <summary>
    /// El bloque con la cuenta del Banco de la Nación.
    ///
    /// Devuelve null cuando no hay detracción, y XElement admite nulos sin
    /// añadir nada: así el bloque desaparece del documento en vez de quedar
    /// vacío, que SUNAT rechazaría.
    /// </summary>
    private static XElement? MediosDePagoDetraccion(Detraccion? d)
    {
        if (d is null) return null;

        return new XElement(Ns.Cac + "PaymentMeans",

            // El identificador literal "Detraccion" es lo que SUNAT busca
            // para reconocer el bloque. No es un nombre nuestro.
            new XElement(Ns.Cbc + "ID", "Detraccion"),

            new XElement(Ns.Cbc + "PaymentMeansCode",
                new XAttribute("listName", "Medio de pago"),
                new XAttribute("listAgencyName", "PE:SUNAT"),
                new XAttribute("listURI",
                    "urn:pe:gob:catalogo:cpe:codigo:catalogo59"),
                d.MedioDePago),

            new XElement(Ns.Cac + "PayeeFinancialAccount",
                new XElement(Ns.Cbc + "ID", d.CuentaBancoNacion)));
    }

    /// <summary>El bloque con el código, el porcentaje y el monto.</summary>
    private static XElement? CondicionesDetraccion(Detraccion? d)
    {
        if (d is null) return null;

        return new XElement(Ns.Cac + "PaymentTerms",
            new XElement(Ns.Cbc + "ID", "Detraccion"),

            // PaymentMeansID NO ADMITE listName, listAgencyName ni listURI.
            //
            // Se los puse por analogía con otros elementos del documento, que
            // sí los llevan, y el XSD los rechazó con un error que nombra el
            // atributo exacto.
            //
            // En UBL cada elemento tiene su propio conjunto de atributos
            // permitidos: las analogías no valen.
            new XElement(Ns.Cbc + "PaymentMeansID", d.CodigoBienServicio),

            new XElement(Ns.Cbc + "PaymentPercent",
                d.Porcentaje.ToString("0.00", Inv)),

            // SIEMPRE EN SOLES, aunque la factura esté en dólares.
            //
            // Lo exige la regla 3208, y tiene sentido: la cuenta del Banco de
            // la Nación es en soles y ahí se deposita.
            new XElement(Ns.Cbc + "Amount",
                new XAttribute("currencyID", "PEN"),
                d.Monto.ToString("0.00", Inv)));
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

            TipoDeCambio(comprobante.TipoCambio),

            TaxTotal(comprobante.Moneda, totales),
            TotalesMonetarios(nombreTotales, comprobante.Moneda, totales)
        );

        foreach (var linea in lineas)
            raiz.Add(Linea(nombreLinea, nombreCantidad, comprobante.Moneda, linea));

        return new XDocument(new XDeclaration("1.0", "UTF-8", null), raiz);
    }
}
