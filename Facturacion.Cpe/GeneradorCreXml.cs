using System.Globalization;
using System.Xml.Linq;
using static Facturacion.Cpe.BloquesComunes;

namespace Facturacion.Cpe;

/// <summary>
/// Genera el XML del comprobante de retención (tipo 20) y del de percepción
/// (tipo 40).
///
/// LOS DOS EN LA MISMA CLASE, porque son el mismo documento con los nombres
/// cambiados. Literalmente: donde uno dice Retention el otro dice Perception,
/// donde uno dice Paid el otro dice Cashed, y donde uno resta el otro suma.
/// Nada más.
///
/// ESTOS NO SON DOCUMENTOS UBL. Factura, boleta y notas son tipos que existen
/// en el estándar OASIS; Retention y Perception se los inventó SUNAT, con su
/// propio espacio de nombres. Por eso:
///
///   - La versión de UBL que declaran es "2.0", no "2.1".
///   - La versión de la estructura es "1.0", no "2.0".
///   - Casi todo el contenido cuelga del prefijo sac:, que es de SUNAT.
///
/// Equivocar cualquiera de esas dos versiones son los errores 2110 y 2112, y
/// desconciertan porque el resto del sistema usa los otros números.
/// </summary>
public static class GeneradorCreXml
{
    private static readonly XNamespace Retention =
        "urn:sunat:names:specification:ubl:peru:schema:xsd:Retention-1";

    private static readonly XNamespace Perception =
        "urn:sunat:names:specification:ubl:peru:schema:xsd:Perception-1";

    /// <summary>
    /// El espacio de nombres propio de SUNAT. Aquí no es un añadido: es donde
    /// vive la mitad del documento.
    /// </summary>
    private static readonly XNamespace Sac =
        "urn:sunat:names:specification:ubl:peru:schema:xsd:SunatAggregateComponents-1";

    private static readonly CultureInfo Cultura = CultureInfo.InvariantCulture;

    private static string F2(decimal valor) => valor.ToString("F2", Cultura);
    private static string Fecha(DateTime d) => d.ToString("yyyy-MM-dd", Cultura);

    // ------------------------------------------------------------- retención

    public static XDocument Generar(ComprobanteRetencion r)
    {
        var totales = CalculadoraCre.Calcular(r);

        return Construir(
            espacio: Retention,
            raiz: "Retention",
            comprobante: r,
            contraparte: r.Proveedor,
            codigoRegimen: r.Regimen,
            tasa: r.Tasa,
            observaciones: r.Observaciones,
            totales: totales,

            // Los cuatro nombres que cambian entre un documento y el otro.
            nombreSistema: "SUNATRetentionSystemCode",
            nombrePorcentaje: "SUNATRetentionPercent",
            nombreTotalNeto: "SUNATTotalPaid",
            nombreReferencia: "SUNATRetentionDocumentReference",
            nombreInformacion: "SUNATRetentionInformation",
            nombreMonto: "SUNATRetentionAmount",
            nombreFecha: "SUNATRetentionDate",
            nombreNetoLinea: "SUNATNetTotalPaid");
    }

    // ------------------------------------------------------------ percepción

    public static XDocument Generar(ComprobantePercepcion p)
    {
        var totales = CalculadoraCre.Calcular(p);

        return Construir(
            espacio: Perception,
            raiz: "Perception",
            comprobante: p,
            contraparte: p.Cliente,
            codigoRegimen: p.Regimen,
            tasa: p.Tasa,
            observaciones: p.Observaciones,
            totales: totales,

            nombreSistema: "SUNATPerceptionSystemCode",
            nombrePorcentaje: "SUNATPerceptionPercent",
            nombreTotalNeto: "SUNATTotalCashed",
            nombreReferencia: "SUNATPerceptionDocumentReference",
            nombreInformacion: "SUNATPerceptionInformation",
            nombreMonto: "SUNATPerceptionAmount",
            nombreFecha: "SUNATPerceptionDate",
            nombreNetoLinea: "SUNATNetTotalCashed");
    }

    // ----------------------------------------------------------------- común

    private static XDocument Construir(
        XNamespace espacio,
        string raiz,
        ComprobanteBase comprobante,
        ContraparteCre contraparte,
        string codigoRegimen,
        decimal tasa,
        string observaciones,
        TotalesCre totales,
        string nombreSistema,
        string nombrePorcentaje,
        string nombreTotalNeto,
        string nombreReferencia,
        string nombreInformacion,
        string nombreMonto,
        string nombreFecha,
        string nombreNetoLinea)
    {
        var elemento = new XElement(espacio + raiz,
            new XAttribute(XNamespace.Xmlns + "cac", Ns.Cac.NamespaceName),
            new XAttribute(XNamespace.Xmlns + "cbc", Ns.Cbc.NamespaceName),
            new XAttribute(XNamespace.Xmlns + "ext", Ns.Ext.NamespaceName),
            new XAttribute(XNamespace.Xmlns + "sac", Sac.NamespaceName),
            new XAttribute(XNamespace.Xmlns + "ds", Ns.Ds.NamespaceName),

            ExtensionesVacias(),

            // OJO CON ESTOS DOS NÚMEROS. No son los de la factura.
            //
            //   UBLVersionID     "2.0"  (la factura usa "2.1")
            //   CustomizationID  "1.0"  (la factura usa "2.0")
            //
            // Errores 2110 y 2112. Se equivocan constantemente porque el resto
            // del sistema usa los otros.
            new XElement(Ns.Cbc + "UBLVersionID", "2.0"),
            new XElement(Ns.Cbc + "CustomizationID", "1.0"),

            // LA FIRMA VA AQUÍ, ANTES DEL NÚMERO DEL COMPROBANTE.
            //
            // Esto es lo que costó tres rechazos 0306. En la factura,
            // cac:Signature va mucho más abajo, después del tipo de moneda; en
            // estos dos documentos va tercera, entre CustomizationID y el ID.
            //
            // Las reglas de SUNAT lo decían —la firma es el dato 3 y la
            // numeración el 4— y yo lo leí como un número de orden de la
            // documentación en vez de como el orden del esquema. Era el orden
            // del esquema.
            //
            // EL 0306 NO DICE QUÉ ELEMENTO ESTÁ MAL. Solo dice que el XML no
            // valida. Cuando aparezca otra vez en este archivo, el orden de
            // estos primeros elementos es lo primero que hay que mirar.
            Signature(comprobante),

            new XElement(Ns.Cbc + "ID", comprobante.NumeroCompleto),
            new XElement(Ns.Cbc + "IssueDate", Fecha(comprobante.FechaEmision)),
            new XElement(Ns.Cbc + "IssueTime",
                comprobante.FechaEmision.ToString("HH:mm:ss", Cultura)),

            // El emisor es el AGENTE. SUNAT lo llama así y no "supplier",
            // porque aquí no está vendiendo nada: actúa por cuenta del fisco.
            Parte("AgentParty",
                comprobante.Emisor.Ruc,
                comprobante.Emisor.RazonSocial,
                comprobante.Emisor.NombreComercial,
                comprobante.Emisor.Ubigeo,
                comprobante.Emisor.Direccion,
                urbanizacion: "",
                comprobante.Emisor.Provincia,
                comprobante.Emisor.Departamento,
                comprobante.Emisor.Distrito,
                comprobante.Emisor.CodigoPais),

            // La contraparte: el proveedor al que se le retuvo, o el cliente
            // al que se le percibió.
            Parte("ReceiverParty",
                contraparte.Ruc,
                contraparte.RazonSocial,
                contraparte.NombreComercial,
                contraparte.Ubigeo,
                contraparte.Direccion,
                contraparte.Urbanizacion,
                contraparte.Provincia,
                contraparte.Departamento,
                contraparte.Distrito,
                contraparte.CodigoPais),

            new XElement(Sac + nombreSistema, codigoRegimen),

            // La tasa. SUNAT la recalcula contra el catálogo (errores 2619 y
            // 2603), así que sale del régimen y no de lo que alguien escriba.
            new XElement(Sac + nombrePorcentaje, F2(tasa)),

            // Las observaciones, si las hay. Van después del porcentaje y
            // antes de los importes.
            string.IsNullOrWhiteSpace(observaciones)
                ? null
                : new XElement(Ns.Cbc + "Note", new XCData(observaciones)),

            // EL TOTAL DEL DOCUMENTO ES LO RETENIDO O PERCIBIDO, no lo pagado.
            //
            // Se llama TotalInvoiceAmount, que suena a "total de la factura",
            // y no lo es: es la suma de las retenciones. Reglas 2628 y 2669.
            new XElement(Ns.Cbc + "TotalInvoiceAmount",
                new XAttribute("currencyID", "PEN"),
                F2(totales.Total)),

            // Y este es el dinero que de verdad cambió de manos: la suma de
            // los netos de cada documento. Reglas 2629 y 2687.
            new XElement(Sac + nombreTotalNeto,
                new XAttribute("currencyID", "PEN"),
                F2(totales.Neto))
        );

        foreach (var linea in totales.Lineas)
        {
            elemento.Add(Referencia(
                linea, nombreReferencia, nombreInformacion,
                nombreMonto, nombreFecha, nombreNetoLinea));
        }

        return new XDocument(new XDeclaration("1.0", "UTF-8", null), elemento);
    }

    /// <summary>
    /// El agente o la contraparte.
    /// </summary>
    private static XElement Parte(
        string nombre,
        string ruc,
        string razonSocial,
        string nombreComercial,
        string ubigeo,
        string direccion,
        string urbanizacion,
        string provincia,
        string departamento,
        string distrito,
        string codigoPais)
    {
        var parte = new XElement(Ns.Cac + nombre,
            new XElement(Ns.Cac + "PartyIdentification",
                new XElement(Ns.Cbc + "ID",
                    new XAttribute("schemeID", TipoDocIdentidad.Ruc),
                    ruc)));

        if (!string.IsNullOrWhiteSpace(nombreComercial))
        {
            parte.Add(new XElement(Ns.Cac + "PartyName",
                new XElement(Ns.Cbc + "Name", new XCData(nombreComercial))));
        }

        // EL ORDEN DENTRO DE cac:Party NO ES EL QUE LA INTUICIÓN SUGIERE.
        //
        // La secuencia de PartyType en UBL es:
        //
        //   PartyIdentification → PartyName → PostalAddress → PartyLegalEntity
        //
        // Es decir, LA DIRECCIÓN VA ANTES QUE LA RAZÓN SOCIAL. Ponerla después,
        // que es donde cualquiera la pondría —primero quién es, luego dónde
        // vive—, invalida el documento entero.
        //
        // Y SUNAT lo reporta con un 0306 a secas, sin decir qué elemento está
        // fuera de sitio. Por eso esto se comenta: la próxima vez que aparezca
        // un 0306 en este archivo, el orden es lo primero que hay que mirar.

        var hayDireccion =
            !string.IsNullOrWhiteSpace(direccion) || !string.IsNullOrWhiteSpace(ubigeo);

        if (hayDireccion)
        {
            parte.Add(DireccionPostal(
                ubigeo, direccion, urbanizacion, provincia,
                departamento, distrito, codigoPais));
        }

        parte.Add(new XElement(Ns.Cac + "PartyLegalEntity",
            new XElement(Ns.Cbc + "RegistrationName", new XCData(razonSocial))));

        return parte;
    }

    /// <summary>
    /// La dirección de una parte.
    ///
    /// VA EN cac:PostalAddress, no en el cac:RegistrationAddress que usan las
    /// facturas, y la calle va en cbc:StreetName en vez de en AddressLine. Es
    /// otro esquema: lo que se parece engaña.
    ///
    /// El orden interno también es el del XSD de AddressType y no el que
    /// parecería natural: ubigeo, calle, urbanización, provincia,
    /// departamento, distrito, país.
    /// </summary>
    private static XElement DireccionPostal(
        string ubigeo,
        string direccion,
        string urbanizacion,
        string provincia,
        string departamento,
        string distrito,
        string codigoPais)
    {
        return new XElement(Ns.Cac + "PostalAddress",
            string.IsNullOrWhiteSpace(ubigeo)
                ? null
                : new XElement(Ns.Cbc + "ID", ubigeo),
            string.IsNullOrWhiteSpace(direccion)
                ? null
                : new XElement(Ns.Cbc + "StreetName", new XCData(direccion)),
            string.IsNullOrWhiteSpace(urbanizacion)
                ? null
                : new XElement(Ns.Cbc + "CitySubdivisionName", urbanizacion),
            string.IsNullOrWhiteSpace(provincia)
                ? null
                : new XElement(Ns.Cbc + "CityName", provincia),
            string.IsNullOrWhiteSpace(departamento)
                ? null
                : new XElement(Ns.Cbc + "CountrySubentity", departamento),
            string.IsNullOrWhiteSpace(distrito)
                ? null
                : new XElement(Ns.Cbc + "District", distrito),
            new XElement(Ns.Cac + "Country",
                new XElement(Ns.Cbc + "IdentificationCode", codigoPais)));
    }

    /// <summary>
    /// Un documento del detalle: la factura, el pago y la retención.
    ///
    /// SON TRES NIVELES Y CADA UNO DICE UNA COSA DISTINTA:
    ///
    ///   el documento      cuánto decía la factura
    ///   cac:Payment       cuánto se pagó de ella, y cuándo
    ///   ...Information    cuánto se retuvo de ese pago, y qué queda
    ///
    /// Mezclarlos es el error de bulto de este documento: el importe de la
    /// factura y el importe del pago son distintos en cuanto alguien paga a
    /// plazos, que es lo normal.
    /// </summary>
    private static XElement Referencia(
        LineaCre linea,
        string nombreReferencia,
        string nombreInformacion,
        string nombreMonto,
        string nombreFecha,
        string nombreNetoLinea)
    {
        var d = linea.Documento;

        var informacion = new XElement(Sac + nombreInformacion,

            // Siempre en soles, aunque la factura esté en dólares.
            // Errores 2742 y 2707.
            new XElement(Sac + nombreMonto,
                new XAttribute("currencyID", "PEN"),
                F2(linea.Monto)),

            new XElement(Sac + nombreFecha, Fecha(d.FechaPago)),

            new XElement(Sac + nombreNetoLinea,
                new XAttribute("currencyID", "PEN"),
                F2(linea.Neto)));

        // El tipo de cambio va AL FINAL del bloque de información, después
        // del neto, y solo cuando la factura no está en soles.
        if (d.EsMonedaExtranjera && d.TipoCambio is not null)
        {
            informacion.Add(new XElement(Ns.Cac + "ExchangeRate",
                new XElement(Ns.Cbc + "SourceCurrencyCode", d.Moneda),
                new XElement(Ns.Cbc + "TargetCurrencyCode", "PEN"),
                new XElement(Ns.Cbc + "CalculationRate",
                    d.TipoCambio.Tasa.ToString("0.000", Cultura)),
                new XElement(Ns.Cbc + "Date", Fecha(d.TipoCambio.Fecha))));
        }

        return new XElement(Sac + nombreReferencia,

            // El tipo de documento viaja como ATRIBUTO del número, no como
            // elemento propio. Es lo que más despista de este bloque.
            new XElement(Ns.Cbc + "ID",
                new XAttribute("schemeID", d.TipoDocumento),
                d.Numero),

            new XElement(Ns.Cbc + "IssueDate", Fecha(d.FechaEmision)),

            // Lo que decía la factura, en SU moneda.
            new XElement(Ns.Cbc + "TotalInvoiceAmount",
                new XAttribute("currencyID", d.Moneda),
                F2(d.ImporteTotal)),

            new XElement(Ns.Cac + "Payment",
                new XElement(Ns.Cbc + "ID", d.NumeroPago),
                new XElement(Ns.Cbc + "PaidAmount",
                    new XAttribute("currencyID", d.Moneda),
                    F2(d.ImportePago)),
                new XElement(Ns.Cbc + "PaidDate", Fecha(d.FechaPago))),

            informacion);
    }
}