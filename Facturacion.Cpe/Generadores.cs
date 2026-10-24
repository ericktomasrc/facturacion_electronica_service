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
            // Es lo que le dice a SUNAT qué clase de operación es esta: venta
            // interna, sujeta a detracción o exportación. De ese único
            // atributo dependen validaciones que no se parecen en nada entre
            // sí, y equivocarlo no produce un error de formato sino una
            // factura que declara algo distinto de lo que pasó.
            new XElement(Ns.Cbc + "InvoiceTypeCode",
                new XAttribute("listID", f.TipoOperacionEfectivo),
                new XAttribute("listAgencyName", "PE:SUNAT"),
                new XAttribute("listName", "Tipo de Documento"),
                new XAttribute("listURI", CatalogoUri.C01_TipoDocumento),
                f.TipoComprobante),

            LeyendaImporte(totales.ImporteTotal, f.Moneda),

            // La leyenda obligatoria en cuanto hay una sola línea gratuita.
            //
            // El texto lo fija SUNAT palabra por palabra, y va atado al total
            // de gratuitas: si la leyenda aparece y ese total es cero, el
            // comprobante se rechaza con el 2416.
            LeyendaSuelta(totales.HayGratuitas,
                CodigoLeyenda.TransferenciaGratuita, Gratuitas.TextoLeyenda),

            // Arroz pilado. Sin esta leyenda el comprobante se acepta,
            // pero con la observación 4264 colgando del CDR.
            LeyendaSuelta(Ivap.Aplica(f), CodigoLeyenda.Ivap, Ivap.TextoLeyenda),

            // La leyenda que SUNAT exige en toda factura con detracción.
            LeyendaDetraccion(f.Detraccion),

            // Drawback: opcional, y solo la pone quien se acoge a la
            // restitución simplificada de derechos arancelarios.
            LeyendaSuelta(f.Drawback && f.EsExportacion,
                CodigoLeyenda.Drawback, Exportacion.TextoDrawback),

            // Exportación de servicios: informativa, no obligatoria.
            LeyendaSuelta(
                f.EsExportacion && f.TipoOperacion != TipoOperacion.ExportacionDeBienes,
                CodigoLeyenda.ExportacionServicios,
                Exportacion.TextoExportacionServicios),

            new XElement(Ns.Cbc + "DocumentCurrencyCode", f.Moneda),

            // Las facturas donde se cobraron los anticipos.
            //
            // VAN AQUÍ, ANTES DE LA FIRMA. En UBL todas las referencias a
            // otros documentos viven en este tramo. Ponerlas junto a los
            // montos, que es donde la intuición las pondría, rompe el XSD.
            ReferenciasDeAnticipos(f.Anticipos),

            Signature(f),
            Emisor(f.Emisor),
            Receptor(f.Receptor),

            // País donde se aprovecha el servicio exportado. Solo 0201 y 0208.
            PaisDeUsoDelServicio(
                TipoOperacion.ExigePaisDeUso(f.TipoOperacionEfectivo)
                    ? f.PaisDeUso
                    : null),

            // La cuenta donde se deposita la detracción.
            //
            // EL ORDEN IMPORTA: PaymentMeans antes que PaymentTerms. El XSD
            // define una secuencia, y al revés el documento no valida con un
            // error que habla de estructura y no menciona la detracción.
            MediosDePagoDetraccion(f.Detraccion),

            // La forma de pago y, si es a crédito, el monto pendiente y
            // las cuotas. Desde 2022 lo segundo no es opcional.
            FormaDePago(f),

            // Cuánto se detrae y por qué concepto.
            CondicionesDetraccion(f.Detraccion),

            // El total que el cliente paga de verdad, percepción incluida.
            //
            // VA AQUÍ Y NO EN LOS TOTALES porque la percepción no forma
            // parte del precio de la operación: es un cobro por cuenta de
            // SUNAT. El LegalMonetaryTotal de abajo sale sin ella.
            CondicionesPercepcion(f.Percepcion),

            // Cuánto se adelantó, con IGV incluido.
            MontosAnticipados(f.Anticipos, f.Moneda),

            // Y el mismo anticipo otra vez, ahora SIN IGV, como descuento
            // sobre la base imponible. Son dos cifras distintas del mismo
            // hecho, y cada una va donde SUNAT la busca.
            DescuentosPorAnticipo(f.Moneda, totales),

            // Cargos y descuentos del comprobante entero que no mueven la
            // base imponible: recargo al consumo, FISE, un descuento
            // comercial pactado fuera del precio.
            CargosYDescuentosGlobales(f.CargosGlobales, f.Moneda),

            // El cargo de la percepción. Es lo único del documento que va
            // en soles aunque la factura esté en otra moneda.
            CargoPorPercepcion(f.Percepcion),

            // Solo aparece si la factura no está en soles.
            TipoDeCambio(f.TipoCambio),

            TaxTotal(f.Moneda, totales),
            TotalesMonetarios("LegalMonetaryTotal", f.Moneda, totales)
        );

        foreach (var linea in lineas)
            raiz.Add(Linea("InvoiceLine", "InvoicedQuantity", f.Moneda, linea));

        return new XDocument(new XDeclaration("1.0", "UTF-8", null), raiz);
    }

    // ------------------------------------------------------------- crédito

    /// <summary>
    /// La forma de pago, con sus cuotas si las hay.
    ///
    /// SON VARIOS cac:PaymentTerms HERMANOS, no uno anidado: el bloque
    /// "Credito" lleva el monto pendiente, y cada cuota va en su propio
    /// bloque con el mismo identificador "FormaPago".
    ///
    /// Al contado es un solo bloque sin monto, como siempre.
    /// </summary>
    private static IEnumerable<XElement> FormaDePago(Factura f)
    {
        var esCredito = ReglasCredito.EsCredito(f.FormaPago);

        var cabecera = new XElement(Ns.Cac + "PaymentTerms",
            new XElement(Ns.Cbc + "ID", "FormaPago"),
            new XElement(Ns.Cbc + "PaymentMeansID", f.FormaPago));

        // El monto neto pendiente solo existe a crédito. Ponerlo al contado
        // sería declarar una deuda que no hay.
        if (esCredito && f.Cuotas.Count > 0)
        {
            cabecera.Add(new XElement(Ns.Cbc + "Amount",
                new XAttribute("currencyID", f.Moneda),
                f.MontoPendiente.ToString("0.00", Inv)));
        }

        yield return cabecera;

        if (!esCredito) yield break;

        foreach (var cuota in f.Cuotas.OrderBy(c => c.Numero))
        {
            yield return new XElement(Ns.Cac + "PaymentTerms",
                new XElement(Ns.Cbc + "ID", "FormaPago"),

                // "Cuota001", con tres dígitos siempre. "Cuota1" es el
                // error 3246.
                new XElement(Ns.Cbc + "PaymentMeansID", cuota.Identificador),

                new XElement(Ns.Cbc + "Amount",
                    new XAttribute("currencyID", f.Moneda),
                    cuota.Monto.ToString("0.00", Inv)),

                new XElement(Ns.Cbc + "PaymentDueDate",
                    cuota.FechaVencimiento.ToString("yyyy-MM-dd", Inv)));
        }
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
                // ESTA CADENA LLEVABA MAL DESDE EL PASO DE LA DETRACCION.
                //
                // Es el formato corto, que SUNAT acepta pero observa con el
                // 4253. Nunca lo vimos porque el CDR de la detraccion salia
                // "ACEPTADO" y nadie leyo las observaciones.
                new XAttribute("listURI", CatalogoUri.C59_MedioPago),
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
            // Ponerlos devuelve el rechazo 0306, que habla de un "atributo no
            // definido" sin decir cuál.
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

    // --------------------------------------------------------- percepción

    /// <summary>
    /// El cargo de la percepción: cuánto se percibe y sobre qué base.
    ///
    /// TRES DETALLES QUE SUNAT COMPRUEBA UNO POR UNO:
    ///
    /// 1. ChargeIndicator es "true". Es un CARGO, no un descuento: suma al
    ///    precio en vez de restarlo. Ponerlo en false devuelve el 3114.
    ///
    /// 2. El factor va como 0.02, no como 2. SUNAT recalcula
    ///    Amount = BaseAmount x MultiplierFactorNumeric y compara (2798).
    ///
    /// 3. Las dos cifras van en PEN aunque la factura esté en dólares
    ///    (errores 2792 y 2788). Es la única excepción del documento.
    /// </summary>
    private static XElement? CargoPorPercepcion(Percepcion? p)
    {
        if (p is null) return null;

        return new XElement(Ns.Cac + "AllowanceCharge",

            new XElement(Ns.Cbc + "ChargeIndicator", "true"),

            new XElement(Ns.Cbc + "AllowanceChargeReasonCode",
                new XAttribute("listAgencyName", "PE:SUNAT"),
                new XAttribute("listName", "Cargo/descuento"),
                new XAttribute("listURI", CatalogoUri.C53_CargoDescuento),
                p.CodigoCargo),

            new XElement(Ns.Cbc + "MultiplierFactorNumeric",
                p.Factor.ToString("0.#####", Inv)),

            new XElement(Ns.Cbc + "Amount",
                new XAttribute("currencyID", "PEN"),
                p.Monto.ToString("0.00", Inv)),

            new XElement(Ns.Cbc + "BaseAmount",
                new XAttribute("currencyID", "PEN"),
                p.BaseEnSoles.ToString("0.00", Inv)));
    }

    /// <summary>
    /// El total que el cliente paga con la percepción incluida.
    ///
    /// El identificador literal "Percepcion" es lo que SUNAT busca para
    /// reconocer el bloque (regla 3309), igual que "Detraccion" más arriba.
    /// No es un nombre nuestro y no admite variantes con tilde.
    /// </summary>
    private static XElement? CondicionesPercepcion(Percepcion? p)
    {
        if (p is null) return null;

        return new XElement(Ns.Cac + "PaymentTerms",
            new XElement(Ns.Cbc + "ID", "Percepcion"),
            new XElement(Ns.Cbc + "Amount",
                new XAttribute("currencyID", "PEN"),
                p.TotalConPercepcion.ToString("0.00", Inv)));
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
/// Todo lo demás son los mismos bloques compartidos. Por eso una nota de
/// crédito sobre una factura de exportación funciona sin tocar nada.
///
/// LAS NOTAS NO LLEVAN ANTICIPOS. Una nota modifica un comprobante que ya
/// declaró los suyos; volver a declararlos aquí los contaría dos veces.
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

    /// <summary>
    /// 24 oct: la forma de pago de una nota de crédito con motivo 13: el
    /// bloque «Credito» con el monto neto pendiente y un bloque por cuota.
    /// Las demás notas no llevan forma de pago.
    /// </summary>
    private static IEnumerable<XElement> PagoDeNota(ComprobanteBase c)
    {
        if (c is not NotaCredito { CodigoMotivo: MotivoNotaCredito.AjusteMontosYFechasDePago } n || n.Cuotas.Count == 0)
            yield break;

        yield return new XElement(Ns.Cac + "PaymentTerms",
            new XElement(Ns.Cbc + "ID", "FormaPago"),
            new XElement(Ns.Cbc + "PaymentMeansID", ReglasCredito.Credito),
            new XElement(Ns.Cbc + "Amount",
                new XAttribute("currencyID", n.Moneda),
                n.MontoPendiente.ToString("0.00", Inv)));

        foreach (var cuota in n.Cuotas.OrderBy(x => x.Numero))
        {
            yield return new XElement(Ns.Cac + "PaymentTerms",
                new XElement(Ns.Cbc + "ID", "FormaPago"),
                new XElement(Ns.Cbc + "PaymentMeansID", cuota.Identificador),
                new XElement(Ns.Cbc + "Amount",
                    new XAttribute("currencyID", n.Moneda),
                    cuota.Monto.ToString("0.00", Inv)),
                new XElement(Ns.Cbc + "PaymentDueDate",
                    cuota.FechaVencimiento.ToString("yyyy-MM-dd", Inv)));
        }
    }

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

            // Una nota también puede llevar líneas gratuitas: por ejemplo la
            // que corrige una bonificación mal declarada.
            LeyendaSuelta(totales.HayGratuitas,
                CodigoLeyenda.TransferenciaGratuita, Gratuitas.TextoLeyenda),

            // Y una nota sobre una factura de arroz pilado sigue siendo de
            // arroz pilado.
            LeyendaSuelta(Ivap.Aplica(comprobante),
                CodigoLeyenda.Ivap, Ivap.TextoLeyenda),

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

            // Una nota puede llevarlos igual que la factura: por ejemplo la
            // que devuelve el recargo al consumo de un servicio anulado.
            // 24 oct: motivo 13, las cuotas nuevas (UBL: PaymentTerms va
            // antes de AllowanceCharge).
            PagoDeNota(comprobante),

            CargosYDescuentosGlobales(
                comprobante.CargosGlobales, comprobante.Moneda),

            TipoDeCambio(comprobante.TipoCambio),

            TaxTotal(comprobante.Moneda, totales),
            TotalesMonetarios(nombreTotales, comprobante.Moneda, totales)
        );

        foreach (var linea in lineas)
            raiz.Add(Linea(nombreLinea, nombreCantidad, comprobante.Moneda, linea));

        return new XDocument(new XDeclaration("1.0", "UTF-8", null), raiz);
    }
}