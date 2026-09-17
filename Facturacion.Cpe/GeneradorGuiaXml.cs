using System.Globalization;
using System.Xml.Linq;

namespace Facturacion.Cpe;

/// <summary>
/// Genera el XML de una guía de remisión del remitente.
///
/// USA UN ESQUEMA DISTINTO AL DE LAS FACTURAS.
///
/// Las facturas son Invoice; las guías son DespatchAdvice. Comparten los
/// espacios de nombres comunes de UBL —cac y cbc— pero la raíz, la estructura
/// y casi todos los elementos son otros.
///
/// La diferencia de fondo: una factura describe una VENTA y gira en torno a
/// importes; una guía describe un TRASLADO y gira en torno a un envío, con su
/// origen, destino, vehículo y bienes.
/// </summary>
public static class GeneradorGuiaXml
{
    private static readonly XNamespace Despatch =
        "urn:oasis:names:specification:ubl:schema:xsd:DespatchAdvice-2";

    private static readonly XNamespace Cac = Ns.Cac;
    private static readonly XNamespace Cbc = Ns.Cbc;
    private static readonly XNamespace Ext = Ns.Ext;
    private static readonly XNamespace Ds = "http://www.w3.org/2000/09/xmldsig#";

    public static XDocument Generar(GuiaRemision guia)
    {
        ArgumentNullException.ThrowIfNull(guia);

        var problemas = guia.Revisar();

        if (problemas.Count > 0)
        {
            throw new InvalidOperationException(
                "La guía tiene problemas que SUNAT rechazaría:\n" +
                string.Join("\n", problemas.Select(p => "  - " + p)));
        }

        var raiz = new XElement(Despatch + "DespatchAdvice",
            new XAttribute(XNamespace.Xmlns + "cac", Cac),
            new XAttribute(XNamespace.Xmlns + "cbc", Cbc),
            new XAttribute(XNamespace.Xmlns + "ext", Ext),
            new XAttribute(XNamespace.Xmlns + "ds", Ds),

            // El hueco donde irá la firma. Se deja vacío a propósito: el
            // firmador lo rellena después, igual que en las facturas.
            new XElement(Ext + "UBLExtensions",
                new XElement(Ext + "UBLExtension",
                    new XElement(Ext + "ExtensionContent"))),

            // La GRE usa UBL 2.1 con personalización 2.0. No coincide con la
            // de las facturas, que es 2.0 sobre UBL 2.1: son numeraciones
            // independientes y confundirlas rechaza el documento.
            new XElement(Cbc + "UBLVersionID", "2.1"),
            new XElement(Cbc + "CustomizationID", "2.0"),

            new XElement(Cbc + "ID", guia.Numero),
            new XElement(Cbc + "IssueDate", Fecha(guia.FechaEmision)),
            new XElement(Cbc + "IssueTime", guia.FechaEmision.ToString("HH:mm:ss")),

            new XElement(Cbc + "DespatchAdviceTypeCode", CatalogosGre.TipoGuiaRemitente));

        if (!string.IsNullOrWhiteSpace(guia.Observaciones))
            raiz.Add(new XElement(Cbc + "Note", Recortar(guia.Observaciones, 250)));

        // Documentos que sustentan el traslado: la factura de la venta, la
        // declaración aduanera de una importación.
        foreach (var doc in guia.DocumentosRelacionados)
            raiz.Add(DocumentoRelacionado(doc));

        raiz.Add(FirmaVacia(guia));

        raiz.Add(ParteRemitente(guia.Remitente));
        raiz.Add(ParteDestinatario(guia.Destinatario));

        raiz.Add(Envio(guia));

        var linea = 1;

        foreach (var bien in guia.Bienes)
            raiz.Add(LineaBien(bien, linea++));

        return new XDocument(new XDeclaration("1.0", "UTF-8", null), raiz);
    }

    // ------------------------------------------------------------- partes

    private static XElement ParteRemitente(Emisor emisor) =>
        new(Cac + "DespatchSupplierParty",
            new XElement(Cac + "Party",
                new XElement(Cac + "PartyIdentification",
                    new XElement(Cbc + "ID",
                        new XAttribute("schemeID", "6"),
                        emisor.Ruc)),
                new XElement(Cac + "PartyLegalEntity",
                    new XElement(Cbc + "RegistrationName",
                        new XCData(emisor.RazonSocial)))));

    private static XElement ParteDestinatario(Receptor receptor) =>
        new(Cac + "DeliveryCustomerParty",
            new XElement(Cac + "Party",
                new XElement(Cac + "PartyIdentification",
                    new XElement(Cbc + "ID",
                        new XAttribute("schemeID", receptor.TipoDocumento),
                        receptor.NumeroDocumento)),
                new XElement(Cac + "PartyLegalEntity",
                    new XElement(Cbc + "RegistrationName",
                        new XCData(receptor.RazonSocial)))));

    // -------------------------------------------------------------- envío

    /// <summary>
    /// El bloque Shipment: todo lo que describe el traslado.
    ///
    /// Es el corazón de la guía. Agrupa el motivo, el peso, el trayecto y el
    /// vehículo.
    /// </summary>
    private static XElement Envio(GuiaRemision guia)
    {
        var envio = new XElement(Cac + "Shipment",

            // SUNAT exige literalmente este identificador. No es un número
            // nuestro: es una constante del esquema.
            new XElement(Cbc + "ID", "SUNAT_Envio"),

            new XElement(Cbc + "HandlingCode",
                new XAttribute("listAgencyName", "PE:SUNAT"),
                new XAttribute("listName", "Motivo de traslado"),
                new XAttribute("listURI", "urn:pe:gob:sunat:cpe:see:gem:catalogos:catalogo20"),
                guia.MotivoTraslado),

            new XElement(Cbc + "HandlingInstructions",
                new XCData(guia.DescripcionMotivo ??
                    CatalogosGre.MotivoTraslado.Descripciones[guia.MotivoTraslado])),

            new XElement(Cbc + "GrossWeightMeasure",
                new XAttribute("unitCode", "KGM"),
                Decimal3(guia.PesoBruto)));

        if (guia.NumeroBultos is > 0)
            envio.Add(new XElement(Cbc + "TotalTransportHandlingUnitQuantity",
                guia.NumeroBultos.Value));

        // Indica si el traslado se hace en varios viajes. Se declara siempre
        // en falso salvo casos muy concretos.
        envio.Add(new XElement(Cbc + "SplitConsignmentIndicator", "false"));

        envio.Add(Etapa(guia));
        envio.Add(Entrega(guia));

        // El vehículo, como unidad de transporte.
        //
        // Va después de Delivery y es hermano de ShipmentStage. El orden
        // importa: el esquema XSD define una secuencia, y colocarlo antes
        // hace que el documento no valide.
        var vehiculo = UnidadDeTransporte(guia);

        if (vehiculo is not null) envio.Add(vehiculo);

        return envio;
    }

    /// <summary>
    /// La etapa del transporte: cómo y con qué se lleva.
    ///
    /// Lo que va aquí depende de la modalidad, y es la parte donde más se
    /// equivoca quien empieza:
    ///
    ///   Público   se declara el TRANSPORTISTA, y además él debe emitir su
    ///             propia guía de tipo 31
    ///   Privado   se declaran el VEHÍCULO y el CONDUCTOR, porque no hay un
    ///             tercero que responda
    /// </summary>
    private static XElement Etapa(GuiaRemision guia)
    {
        var etapa = new XElement(Cac + "ShipmentStage",

            new XElement(Cbc + "TransportModeCode",
                new XAttribute("listName", "Modalidad de traslado"),
                new XAttribute("listAgencyName", "PE:SUNAT"),
                new XAttribute("listURI", "urn:pe:gob:sunat:cpe:see:gem:catalogos:catalogo18"),
                guia.ModalidadTraslado),

            new XElement(Cac + "TransitPeriod",
                new XElement(Cbc + "StartDate", Fecha(guia.FechaTraslado))));

        if (guia.ModalidadTraslado == CatalogosGre.ModalidadTraslado.Publico)
        {
            var t = guia.Transportista!;

            var parte = new XElement(Cac + "CarrierParty",
                new XElement(Cac + "PartyIdentification",
                    new XElement(Cbc + "ID",
                        new XAttribute("schemeID", t.TipoDocumento),
                        t.NumeroDocumento)),
                new XElement(Cac + "PartyLegalEntity",
                    new XElement(Cbc + "RegistrationName",
                        new XCData(t.RazonSocial))));

            if (!string.IsNullOrWhiteSpace(t.NumeroMtc))
            {
                parte.Add(new XElement(Cac + "PartyLegalEntity",
                    new XElement(Cbc + "CompanyID", t.NumeroMtc)));
            }

            etapa.Add(parte);
        }
        else
        {
            // Transporte privado.
            //
            // LA PLACA NO VA AQUÍ. Va en TransportHandlingUnit, que es un
            // bloque hermano de ShipmentStage, no uno anidado dentro.
            //
            // UBL estándar la coloca en TransportMeans/RoadTransport, y por
            // analogía es donde se pone al principio. SUNAT la busca en otro
            // sitio, y el rechazo (error 2566) dice que falta la placa sin
            // mencionar que el problema es dónde está.
            //
            // Con vehículo menor (categorías M1 y L) SUNAT exime de declarar
            // placa y licencia: son motos y vehículos de reparto urbano.
            if (!guia.VehiculoMenor && guia.Conductor is not null)
            {
                var c = guia.Conductor;

                etapa.Add(new XElement(Cac + "DriverPerson",
                    new XElement(Cbc + "ID",
                        new XAttribute("schemeID", c.TipoDocumento),
                        c.NumeroDocumento),
                    new XElement(Cbc + "FirstName", new XCData(c.Nombres)),
                    new XElement(Cbc + "FamilyName", new XCData(c.Apellidos)),

                    // "Principal" distingue al conductor titular de los
                    // secundarios, cuando el viaje lleva relevo.
                    new XElement(Cbc + "JobTitle", "Principal"),

                    new XElement(Cac + "IdentityDocumentReference",
                        new XElement(Cbc + "ID", c.Licencia))));
            }
        }

        return etapa;
    }

    /// <summary>
    /// El vehículo que hace el traslado.
    ///
    /// SUNAT lo espera aquí, en TransportHandlingUnit/TransportEquipment/ID,
    /// y no dentro de la etapa del transporte como haría UBL estándar.
    ///
    /// Se declara cuando el traslado es privado, y también cuando es público
    /// pero el transportista registró sus vehículos.
    /// </summary>
    private static XElement? UnidadDeTransporte(GuiaRemision guia)
    {
        if (guia.VehiculoMenor) return null;
        if (guia.Vehiculo is null) return null;
        if (string.IsNullOrWhiteSpace(guia.Vehiculo.Placa)) return null;

        var equipo = new XElement(Cac + "TransportEquipment",
            new XElement(Cbc + "ID", guia.Vehiculo.Placa));

        // La tarjeta única de circulación, cuando se declara.
        if (!string.IsNullOrWhiteSpace(guia.Vehiculo.Tuc))
        {
            equipo.Add(new XElement(Cac + "ApplicableTransportMeans",
                new XElement(Cbc + "RegistrationNationalityID", guia.Vehiculo.Tuc)));
        }

        return new XElement(Cac + "TransportHandlingUnit", equipo);
    }

    /// <summary>
    /// De dónde sale y a dónde llega.
    ///
    /// Los dos puntos se declaran con ubigeo y dirección. SUNAT valida el
    /// ubigeo contra el listado del INEI: uno inventado rechaza la guía.
    /// </summary>
    private static XElement Entrega(GuiaRemision guia) =>
        new(Cac + "Delivery",

            new XElement(Cac + "DeliveryAddress",
                Direccion(guia.PuntoLlegada)),

            new XElement(Cac + "Despatch",
                new XElement(Cac + "DespatchAddress",
                    Direccion(guia.PuntoPartida))));

    private static IEnumerable<XElement> Direccion(DireccionTraslado d)
    {
        yield return new XElement(Cbc + "ID", d.Ubigeo);

        // El código de establecimiento solo aplica cuando el traslado es
        // entre locales de la misma empresa.
        if (!string.IsNullOrWhiteSpace(d.CodigoEstablecimiento))
            yield return new XElement(Cbc + "AddressTypeCode", d.CodigoEstablecimiento);

        yield return new XElement(Cac + "AddressLine",
            new XElement(Cbc + "Line", new XCData(d.Direccion)));
    }

    // -------------------------------------------------------------- líneas

    private static XElement LineaBien(BienTrasladado bien, int numero)
    {
        // DESCRIPTION, NO NAME.
        //
        // Las facturas usan cbc:Name para el nombre del producto; la guía usa
        // cbc:Description. Es el mismo dato con otro tag, y el rechazo (error
        // 2781) dice que falta la descripción sin aclarar que el problema es
        // el nombre del elemento.
        var item = new XElement(Cac + "Item",
            new XElement(Cbc + "Description",
                new XCData(Recortar(bien.Descripcion, 500))));

        if (!string.IsNullOrWhiteSpace(bien.CodigoProducto))
        {
            item.Add(new XElement(Cac + "SellersItemIdentification",
                new XElement(Cbc + "ID", bien.CodigoProducto)));
        }

        // El código de producto SUNAT es obligatorio para bienes
        // normalizados, como combustibles o alcohol.
        if (!string.IsNullOrWhiteSpace(bien.CodigoSunat))
        {
            item.Add(new XElement(Cac + "CommodityClassification",
                new XElement(Cbc + "ItemClassificationCode", bien.CodigoSunat)));
        }

        return new XElement(Cac + "DespatchLine",
            new XElement(Cbc + "ID", numero),

            new XElement(Cbc + "DeliveredQuantity",
                new XAttribute("unitCode", bien.UnidadMedida),
                Decimal10(bien.Cantidad)),

            new XElement(Cac + "OrderLineReference",
                new XElement(Cbc + "LineID", numero)),

            item);
    }

    private static XElement DocumentoRelacionado(DocumentoRelacionadoGre doc)
    {
        var referencia = new XElement(Cac + "AdditionalDocumentReference",
            new XElement(Cbc + "ID", doc.NumeroDocumento),
            new XElement(Cbc + "DocumentTypeCode", doc.TipoDocumento));

        if (!string.IsNullOrWhiteSpace(doc.RucEmisor))
        {
            referencia.Add(new XElement(Cac + "IssuerParty",
                new XElement(Cac + "PartyIdentification",
                    new XElement(Cbc + "ID",
                        new XAttribute("schemeID", "6"),
                        doc.RucEmisor))));
        }

        return referencia;
    }

    // --------------------------------------------------------------- apoyo

    /// <summary>
    /// El bloque de firma, con el emisor declarado y el contenido vacío.
    ///
    /// Igual que en las facturas: el firmador rellena el hueco después. Si se
    /// firmara antes de tener el documento completo, la firma no cubriría
    /// todo el contenido.
    /// </summary>
    private static XElement FirmaVacia(GuiaRemision guia) =>
        new(Cac + "Signature",
            new XElement(Cbc + "ID", guia.Remitente.Ruc),
            new XElement(Cac + "SignatoryParty",
                new XElement(Cac + "PartyIdentification",
                    new XElement(Cbc + "ID", guia.Remitente.Ruc)),
                new XElement(Cac + "PartyName",
                    new XElement(Cbc + "Name", new XCData(guia.Remitente.RazonSocial)))),
            new XElement(Cac + "DigitalSignatureAttachment",
                new XElement(Cac + "ExternalReference",
                    new XElement(Cbc + "URI", "#SignatureSP"))));

    private static string Fecha(DateTime f) =>
        f.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);

    private static string Decimal3(decimal v) =>
        v.ToString("0.000", CultureInfo.InvariantCulture);

    private static string Decimal10(decimal v) =>
        v.ToString("0.##########", CultureInfo.InvariantCulture);

    private static string Recortar(string texto, int largo) =>
        texto.Length <= largo ? texto : texto[..largo];
}
