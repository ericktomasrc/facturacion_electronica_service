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

            // EL TIPO SALE DE LA GUÍA, no de una constante: el mismo
            // generador produce la 09 del remitente y la 31 del
            // transportista. Son el mismo XML con las partes cambiadas de
            // sitio, y tenerlas en dos archivos habría garantizado que un
            // arreglo entrara en uno y no en el otro.
            new XElement(Cbc + "DespatchAdviceTypeCode",
                new XAttribute("listAgencyName", "PE:SUNAT"),
                new XAttribute("listName", "Tipo de Documento"),
                new XAttribute("listURI", CatalogoUri.C01_TipoDocumento),
                guia.TipoGuia));

        if (!string.IsNullOrWhiteSpace(guia.Observaciones))
            raiz.Add(new XElement(Cbc + "Note", Recortar(guia.Observaciones, 250)));

        // Documentos que sustentan el traslado: la factura de la venta, la
        // declaración aduanera de una importación.
        foreach (var doc in guia.DocumentosRelacionados)
            raiz.Add(DocumentoRelacionado(doc));

        raiz.Add(FirmaVacia(guia));

        raiz.Add(ParteRemitente(guia.Remitente));
        raiz.Add(ParteDestinatario(guia.Destinatario));

        // QUIEN PAGA EL FLETE, cuando es un tercero.
        //
        // OriginatorCustomerParty NO es el remitente, aunque el nombre lo
        // sugiera: es el pagador del servicio, y solo se declara junto al
        // indicador SUNAT_Envio_IndicadorPagadorFlete_Tercero.
        //
        // El remitente va en otro sitio — dentro del punto de partida — y
        // confundirlos cuesta un rechazo 3383 que dice "nodo /" y no ayuda
        // en absoluto.
        if (guia.PagadorFlete is not null)
            raiz.Add(PagadorDelFlete(guia.PagadorFlete));

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

    private static XElement PagadorDelFlete(RemitenteContratante c) =>
        new(Cac + "OriginatorCustomerParty",
            new XElement(Cac + "Party",
                new XElement(Cac + "PartyIdentification",
                    new XElement(Cbc + "ID",
                        new XAttribute("schemeID", c.TipoDocumento),
                        new XAttribute("schemeName", "Documento de Identidad"),
                        new XAttribute("schemeAgencyName", "PE:SUNAT"),
                        new XAttribute("schemeURI", CatalogoUri.C06_TipoDocIdentidad),
                        c.NumeroDocumento)),
                new XElement(Cac + "PartyLegalEntity",
                    new XElement(Cbc + "RegistrationName",
                        new XCData(c.RazonSocial)))));

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

        // LOS INDICADORES VAN AQUÍ, antes del SplitConsignmentIndicator.
        //
        // El XSD de ShipmentType define la secuencia y cbc:SpecialInstructions
        // va justo delante. Ponerlos después invalida el documento con un
        // error de estructura que no menciona los indicadores.
        foreach (var indicador in guia.Indicadores)
            envio.Add(new XElement(Cbc + "SpecialInstructions", indicador));

        // Indica si el traslado se hace en varios viajes. Se declara siempre
        // en falso salvo casos muy concretos.
        envio.Add(new XElement(Cbc + "SplitConsignmentIndicator", "false"));

        // El transportista subcontratado, cuando lo hay. Va en Consignment,
        // que en el esquema precede a ShipmentStage.
        if (guia.OperadorSubcontratado is not null)
            envio.Add(Subcontratado(guia.OperadorSubcontratado));

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
    /// El transportista al que se subcontrató el traslado.
    ///
    /// Va acompañado del indicador de transporte subcontratado: uno sin el
    /// otro es un rechazo (errores 3390 y 4424).
    /// </summary>
    private static XElement Subcontratado(Transportista t) =>
        new(Cac + "Consignment",
            new XElement(Cbc + "ID", "SUNAT_Envio"),
            new XElement(Cac + "LogisticsOperatorParty",
                new XElement(Cac + "PartyIdentification",
                    new XElement(Cbc + "ID",
                        new XAttribute("schemeID", t.TipoDocumento),
                        new XAttribute("schemeName", "Documento de Identidad"),
                        new XAttribute("schemeAgencyName", "PE:SUNAT"),
                        new XAttribute("schemeURI", CatalogoUri.C06_TipoDocIdentidad),
                        t.NumeroDocumento)),
                new XElement(Cac + "PartyLegalEntity",
                    new XElement(Cbc + "RegistrationName",
                        new XCData(t.RazonSocial)))));

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

        // --- LA GUÍA DEL TRANSPORTISTA ----------------------------------------
        //
        // Aquí el emisor ES el que lleva la carga, así que no hay un tercero
        // que nombrar: lo que SUNAT quiere en CarrierParty es su número de
        // registro del MTC (error 3353).
        //
        // Y los conductores nunca son opcionales: el principal más los de
        // relevo, cada uno con su licencia.
        if (guia.EsTransportista)
        {
            etapa.Add(new XElement(Cac + "CarrierParty",
                new XElement(Cac + "PartyIdentification",
                    new XElement(Cbc + "ID",
                        new XAttribute("schemeID", "6"),
                        guia.Remitente.Ruc)),
                new XElement(Cac + "PartyLegalEntity",
                    new XElement(Cbc + "RegistrationName",
                        new XCData(guia.Remitente.RazonSocial)),
                    new XElement(Cbc + "CompanyID", guia.NumeroMtc ?? ""))));

            if (guia.Conductor is not null)
                etapa.Add(Chofer(guia.Conductor, "Principal"));

            foreach (var secundario in guia.ConductoresSecundarios)
                etapa.Add(Chofer(secundario, "Secundario"));

            return etapa;
        }

        if (guia.ModalidadTraslado == CatalogosGre.ModalidadTraslado.Publico)
        {
            var t = guia.Transportista!;

            // EL CompanyID VA DENTRO DEL MISMO PartyLegalEntity, no en uno
            // aparte. Antes se añadía un segundo bloque hermano y el
            // documento no validaba en cuanto el transportista traía número
            // de MTC — que es siempre que el traslado es de carga.
            var identidad = new XElement(Cac + "PartyLegalEntity",
                new XElement(Cbc + "RegistrationName", new XCData(t.RazonSocial)));

            if (!string.IsNullOrWhiteSpace(t.NumeroMtc))
                identidad.Add(new XElement(Cbc + "CompanyID", t.NumeroMtc));

            etapa.Add(new XElement(Cac + "CarrierParty",
                new XElement(Cac + "PartyIdentification",
                    new XElement(Cbc + "ID",
                        new XAttribute("schemeID", t.TipoDocumento),
                        t.NumeroDocumento)),
                identidad));

            // CUÁNDO SE LE ENTREGÓ LA CARGA AL TRANSPORTISTA.
            //
            // Obligatorio en transporte público (error 3617) y no existe en el
            // privado, donde no hay entrega: la misma empresa carga y lleva.
            //
            // Va entre CarrierParty y los conductores. El nombre del elemento
            // —LoadingTransportEvent— habla de carga, no de entrega, y es otro
            // hueco de UBL que SUNAT reutilizó para lo suyo.
            etapa.Add(new XElement(Cac + "LoadingTransportEvent",
                new XElement(Cbc + "OccurrenceDate",
                    Fecha(guia.FechaEntregaEfectiva))));
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
                etapa.Add(Chofer(guia.Conductor, "Principal"));

                foreach (var secundario in guia.ConductoresSecundarios)
                    etapa.Add(Chofer(secundario, "Secundario"));
            }
        }

        return etapa;
    }

    /// <summary>
    /// Un conductor.
    ///
    /// EL JobTitle NO ES DECORATIVO: SUNAT distingue "Principal" de
    /// "Secundario" y exige licencia en los dos (errores 2570 y 2573). Los
    /// dos textos se comparan literalmente, con esa mayúscula y sin tilde.
    /// </summary>
    private static XElement Chofer(Conductor c, string rol) =>
        new(Cac + "DriverPerson",
            new XElement(Cbc + "ID",
                new XAttribute("schemeID", c.TipoDocumento),
                new XAttribute("schemeName", "Documento de Identidad"),
                new XAttribute("schemeAgencyName", "PE:SUNAT"),
                new XAttribute("schemeURI", CatalogoUri.C06_TipoDocIdentidad),
                c.NumeroDocumento),
            new XElement(Cbc + "FirstName", new XCData(c.Nombres)),
            new XElement(Cbc + "FamilyName", new XCData(c.Apellidos)),
            new XElement(Cbc + "JobTitle", rol),
            new XElement(Cac + "IdentityDocumentReference",
                new XElement(Cbc + "ID", c.Licencia)));

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
        // LA EXENCIÓN POR VEHÍCULO MENOR ES DEL REMITENTE, no del
        // transportista. Una empresa de transporte declara siempre su placa.
        if (guia.VehiculoMenor && !guia.EsTransportista) return null;

        if (guia.Vehiculo is null) return null;
        if (string.IsNullOrWhiteSpace(guia.Vehiculo.Placa)) return null;

        var equipo = new XElement(Cac + "TransportEquipment",
            new XElement(Cbc + "ID", guia.Vehiculo.Placa));

        // El certificado de habilitación vehicular.
        //
        // EL NOMBRE DEL TAG ENGAÑA: RegistrationNationalityID suena a
        // nacionalidad de matrícula y no lo es. SUNAT reutilizó el hueco que
        // le ofrecía UBL, y aquí dentro va el número del certificado.
        if (!string.IsNullOrWhiteSpace(guia.Vehiculo.Tuc))
        {
            equipo.Add(new XElement(Cac + "ApplicableTransportMeans",
                new XElement(Cbc + "RegistrationNationalityID", guia.Vehiculo.Tuc)));
        }

        // La autorización especial: mercancía peligrosa, carga
        // sobredimensionada, residuos sólidos. Lleva la entidad que la dio.
        if (!string.IsNullOrWhiteSpace(guia.Vehiculo.NumeroAutorizacion))
        {
            equipo.Add(new XElement(Cac + "ShipmentDocumentReference",
                new XElement(Cbc + "ID",
                    new XAttribute("schemeID", guia.Vehiculo.EntidadAutorizadora ?? ""),
                    new XAttribute("schemeName", "Entidad Autorizadora"),
                    new XAttribute("schemeAgencyName", "PE:SUNAT"),
                    guia.Vehiculo.NumeroAutorizacion)));
        }

        return new XElement(Cac + "TransportHandlingUnit", equipo);
    }

    /// <summary>
    /// De dónde sale y a dónde llega.
    ///
    /// Los dos puntos se declaran con ubigeo y dirección. SUNAT valida el
    /// ubigeo contra el listado del INEI: uno inventado rechaza la guía.
    /// </summary>
    private static XElement Entrega(GuiaRemision guia)
    {
        var despacho = new XElement(Cac + "Despatch",
            new XElement(Cac + "DespatchAddress",
                Direccion(guia.PuntoPartida)));

        // EL REMITENTE VA AQUÍ, y este es el hallazgo que más cuesta.
        //
        // En la guía del transportista hay que decir de quién son los bienes,
        // y SUNAT lo pide DENTRO del punto de partida —quien despacha desde
        // ahí— y no en un bloque de partes como cualquiera supondría.
        //
        // Sin esto, el rechazo es un 3383 cuyo detalle dice literalmente
        // (nodo: "/" valor: ""). No nombra el elemento que falta.
        //
        // El orden dentro de cac:Despatch tampoco es libre: la dirección va
        // antes que la parte.
        if (guia.EsTransportista && guia.Contratante is not null)
        {
            var c = guia.Contratante;

            despacho.Add(new XElement(Cac + "DespatchParty",
                new XElement(Cac + "PartyIdentification",
                    new XElement(Cbc + "ID",
                        new XAttribute("schemeID", c.TipoDocumento),
                        new XAttribute("schemeName", "Documento de Identidad"),
                        new XAttribute("schemeAgencyName", "PE:SUNAT"),
                        new XAttribute("schemeURI", CatalogoUri.C06_TipoDocIdentidad),
                        c.NumeroDocumento)),
                new XElement(Cac + "PartyLegalEntity",
                    new XElement(Cbc + "RegistrationName",
                        new XCData(c.RazonSocial)))));
        }

        return new XElement(Cac + "Delivery",
            new XElement(Cac + "DeliveryAddress",
                Direccion(guia.PuntoLlegada)),
            despacho);
    }

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

            // EL CATÁLOGO ES EL 61, no el 01.
            //
            // Es el de "documentos relacionados al transporte de mercancías",
            // y comparte códigos con el 01 —01 factura, 09 guía— pero no es
            // el mismo listado. Sin estos atributos SUNAT acepta el documento
            // y lo devuelve con observaciones 4251 a 4253 colgando del CDR.
            new XElement(Cbc + "DocumentTypeCode",
                new XAttribute("listAgencyName", "PE:SUNAT"),
                new XAttribute("listName", "Documento relacionado al transporte"),
                new XAttribute("listURI",
                    "urn:pe:gob:sunat:cpe:see:gem:catalogos:catalogo61"),
                doc.TipoDocumento));

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