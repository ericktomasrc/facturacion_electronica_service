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
///
/// ---------------------------------------------------------------------------
///
/// TRES COSAS QUE AQUÍ SE HACEN AL REVÉS QUE EN LA FACTURA, y que son el
/// motivo de que este archivo no pueda reutilizar sus bloques:
///
/// 1. CADA TRIBUTO VA EN SU PROPIO cac:TaxTotal. En la factura un TaxTotal
///    agrupa todos los subtotales; aquí la regla 2355 prohíbe dos TaxTotal
///    con el mismo código de tributo, y el XSD espera bloques hermanos: uno
///    para el IGV, otro para el ICBPER, otro para las gratuitas.
///
/// 2. LAS GRATUITAS: hasta que rigen las reglas de 2027 van todas juntas, en
///    el código 05 del catálogo 11 (mandar 06–09 antes era el error 2256).
///    Desde entonces SUNAT desactiva el 05 y pide cada clase con su código:
///    06 gravadas, 07 exoneradas, 08 inafectas, 09 exportación. Ver
///    VigenciaSunat y TipoMontoResumen.
///
/// 3. LA PERCEPCIÓN NO ES UN AllowanceCharge sino un nodo propio de SUNAT,
///    con otros nombres y siempre en soles.
/// </summary>
public static class GeneradorResumenXml
{
    private static readonly XNamespace Resumen =
        "urn:sunat:names:specification:ubl:peru:schema:xsd:SummaryDocuments-1";

    private static XNamespace Sac => BloquesSunat.Sac;

    public static XDocument Generar(ResumenDiario r)
    {
        // Las reglas primero: es mejor no generar un XML que sabemos que
        // declara un total que no cuadra.
        var problemas = ReglasResumen.Errores(r);

        if (problemas.Count > 0)
            throw new InvalidOperationException(string.Join(" ", problemas));

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
            raiz.Add(BloqueLinea(linea, r.FechaGeneracion));

        return new XDocument(new XDeclaration("1.0", "UTF-8", null), raiz);
    }

    /// <summary>
    /// Una línea del resumen: un comprobante entero.
    ///
    /// EL ORDEN DE LOS ELEMENTOS LO FIJA EL XSD y no admite variación:
    ///
    ///   LineID · DocumentTypeCode · ID · AccountingCustomerParty ·
    ///   BillingReference · SUNATPerceptionSummaryDocumentReference ·
    ///   Status · TotalAmount · BillingPayment* · AllowanceCharge* · TaxTotal*
    ///
    /// La percepción va ANTES del estado, que es donde menos se la espera.
    /// </summary>
    private static XElement BloqueLinea(LineaResumen l, DateTime fechaGeneracion)
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

        // La percepción, en su nodo propio y antes del estado.
        if (l.Percepcion is not null)
            nodo.Add(BloquePercepcion(l.Percepcion));

        nodo.Add(new XElement(Ns.Cac + "Status",
            new XElement(Ns.Cbc + "ConditionCode", (int)l.Estado)));

        // TotalDeclarado y no ImporteTotal: SUNAT recalcula este importe con
        // su propia fórmula y compara. Los dos coinciden en una boleta
        // normal, y cuando no lo hacen es porque el comprobante lleva algo
        // que el resumen no puede declarar — eso lo ataja ReglasResumen
        // antes de llegar aquí.
        nodo.Add(new XElement(Sac + "TotalAmount",
            new XAttribute("currencyID", l.Moneda), F2(l.TotalDeclarado)));

        // --- Los valores de venta, uno por código del catálogo 11 -----------
        //
        // Solo los que tienen importe: la regla 2357 prohíbe repetir un
        // InstructionID, y declarar ceros genera observaciones.

        // La base del IVAP comparte el código "01" con la gravada, porque
        // nunca coexisten: la regla 2644 obliga a que un comprobante de
        // arroz pilado no tenga ninguna otra clase de línea.
        var gravado = l.TotalGravado + l.TotalGravadoIvap;

        if (gravado > 0)
            nodo.Add(Monto(l.Moneda, gravado, TipoMontoResumen.Gravado));

        if (l.TotalExonerado > 0)
            nodo.Add(Monto(l.Moneda, l.TotalExonerado, TipoMontoResumen.Exonerado));

        if (l.TotalInafecto > 0)
            nodo.Add(Monto(l.Moneda, l.TotalInafecto, TipoMontoResumen.Inafecto));

        if (l.TotalExportacion > 0)
            nodo.Add(Monto(l.Moneda, l.TotalExportacion, TipoMontoResumen.Exportacion));

        // LAS GRATUITAS: UN SOLO IMPORTE HASTA 2027, DESGLOSADAS DESDE 2027.
        //
        // Hasta que rigen las reglas de 2027, el catálogo 11 solo tiene el 05:
        // se suman las cuatro clases y se declara una cifra. Desde entonces
        // SUNAT desactiva el 05 y pide cada clase con su código (06 gravadas,
        // 07 exoneradas, 08 inafectas, 09 exportación). El desglose ya lo
        // hacía LineaResumen; ahora también se declara.
        //
        // Lo decide la fecha de GENERACIÓN del resumen, que es la que SUNAT
        // ve al recibirlo: un resumen generado el 2 de enero con boletas del
        // 31 de diciembre ya va con las reglas nuevas.
        if (VigenciaSunat.Rigen2027(fechaGeneracion))
        {
            if (l.TotalGratuitoGravado > 0)
                nodo.Add(Monto(l.Moneda, l.TotalGratuitoGravado, TipoMontoResumen.GratuitasGravadas));

            if (l.TotalGratuitoExonerado > 0)
                nodo.Add(Monto(l.Moneda, l.TotalGratuitoExonerado, TipoMontoResumen.GratuitasExoneradas));

            if (l.TotalGratuitoInafecto > 0)
                nodo.Add(Monto(l.Moneda, l.TotalGratuitoInafecto, TipoMontoResumen.GratuitasInafectas));

            if (l.TotalGratuitoExportacion > 0)
                nodo.Add(Monto(l.Moneda, l.TotalGratuitoExportacion, TipoMontoResumen.GratuitasExportacion));
        }
        else
        {
            var gratuitas =
                l.TotalGratuitoGravado + l.TotalGratuitoExonerado +
                l.TotalGratuitoInafecto + l.TotalGratuitoExportacion;

            if (gratuitas > 0)
                nodo.Add(Monto(l.Moneda, gratuitas, TipoMontoResumen.Gratuitas));
        }

        // --- Otros cargos -----------------------------------------------------

        if (l.OtrosCargos > 0)
        {
            nodo.Add(new XElement(Ns.Cac + "AllowanceCharge",
                new XElement(Ns.Cbc + "ChargeIndicator", "true"),
                new XElement(Ns.Cbc + "Amount",
                    new XAttribute("currencyID", l.Moneda), F2(l.OtrosCargos))));
        }

        // --- Los tributos, cada uno en su propio TaxTotal ---------------------
        //
        // El del IGV/IVAP es obligatorio siempre, incluso en cero: la regla
        // 2278 exige que exista un TaxTotal con el tributo 1000 o el 1016.

        if (l.TotalIvap > 0)
        {
            nodo.Add(BloqueTributo(l.Moneda, l.TotalIvap, Ivap.Tasa,
                Ivap.Codigo, Ivap.Nombre, Ivap.TipoCodigo));
        }
        else
        {
            nodo.Add(BloqueTributo(l.Moneda, l.TotalIgv, l.TasaIgv,
                "1000", "IGV", "VAT"));
        }

        // El IGV de las gratuitas. También lleva Percent: la regla 2992 lo
        // exige para el 1000 y para el 9996.
        if (l.TotalIgvGratuitas > 0)
        {
            nodo.Add(BloqueTributo(l.Moneda, l.TotalIgvGratuitas, l.TasaIgv,
                "9996", "GRA", "FRE"));
        }

        // El ICBPER no lleva Percent: no hay porcentaje que declarar.
        if (l.TotalIcbper > 0)
        {
            nodo.Add(BloqueTributo(l.Moneda, l.TotalIcbper, null,
                Icbper.Codigo, Icbper.Nombre, Icbper.TipoCodigo));
        }

        return nodo;
    }

    private static XElement Monto(string moneda, decimal importe, string tipo) =>
        new(Sac + "BillingPayment",
            new XElement(Ns.Cbc + "PaidAmount",
                new XAttribute("currencyID", moneda), F2(importe)),
            new XElement(Ns.Cbc + "InstructionID", tipo));

    /// <summary>
    /// Un tributo del resumen, con su propio cac:TaxTotal.
    ///
    /// EL Percent FALTABA Y ERA UN RECHAZO SEGURO. La regla 2992 lo exige
    /// cuando el tributo es 1000 o 9996, con código de ERROR. Solo el 7152
    /// —el ICBPER— está exento, porque no se calcula como porcentaje: por
    /// eso el parámetro admite null.
    ///
    /// El importe se repite en cbc:TaxAmount y en el del subtotal, y tienen
    /// que ser idénticos (regla 2344). Van del mismo valor para que no haya
    /// forma de que se separen.
    /// </summary>
    private static XElement BloqueTributo(
        string moneda,
        decimal importe,
        decimal? tasa,
        string codigo,
        string nombre,
        string tipoCodigo)
    {
        var categoria = new XElement(Ns.Cac + "TaxCategory");

        if (tasa is not null)
            categoria.Add(new XElement(Ns.Cbc + "Percent", F2(tasa.Value)));

        categoria.Add(new XElement(Ns.Cac + "TaxScheme",
            // En el resumen estos códigos van sin los atributos de catálogo
            // que sí lleva la factura.
            new XElement(Ns.Cbc + "ID", codigo),
            new XElement(Ns.Cbc + "Name", nombre),
            new XElement(Ns.Cbc + "TaxTypeCode", tipoCodigo)));

        return new XElement(Ns.Cac + "TaxTotal",
            new XElement(Ns.Cbc + "TaxAmount",
                new XAttribute("currencyID", moneda), F2(importe)),
            new XElement(Ns.Cac + "TaxSubtotal",
                new XElement(Ns.Cbc + "TaxAmount",
                    new XAttribute("currencyID", moneda), F2(importe)),
                categoria));
    }

    /// <summary>
    /// La percepción de una boleta.
    ///
    /// LOS TRES IMPORTES VAN EN PEN, no en la moneda del comprobante:
    /// errores 2685 y 2690. Es la misma excepción que en la factura, y el
    /// único sitio del documento donde la regla "una sola moneda" no aplica.
    /// </summary>
    private static XElement BloquePercepcion(PercepcionResumen p) =>
        new(Sac + "SUNATPerceptionSummaryDocumentReference",

            new XElement(Sac + "SUNATPerceptionSystemCode", p.Regimen),

            // La tasa como número, no como factor: aquí va 2.00, no 0.02.
            // Al revés que en el AllowanceCharge de la factura.
            new XElement(Sac + "SUNATPerceptionPercent",
                p.Porcentaje.ToString("0.00", Inv)),

            new XElement(Ns.Cbc + "TotalInvoiceAmount",
                new XAttribute("currencyID", "PEN"), F2(p.Monto)),

            new XElement(Sac + "SUNATTotalCashed",
                new XAttribute("currencyID", "PEN"), F2(p.TotalCobrado)),

            new XElement(Ns.Cbc + "TaxableAmount",
                new XAttribute("currencyID", "PEN"), F2(p.BaseEnSoles)));
}