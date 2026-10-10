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
/// </summary>
internal static class BloquesComunes
{
    internal static readonly CultureInfo Inv = CultureInfo.InvariantCulture;

    /// <summary>
    /// Formato de un valor unitario: dos decimales como mínimo, hasta diez
    /// como máximo.
    ///
    /// POR QUÉ NO VALE F2 AQUÍ. SUNAT recalcula el valor de venta de la
    /// línea multiplicando el unitario por la cantidad, con una tolerancia
    /// de un sol. Un precio de 25.4567 declarado como 25.46 cuadra si se
    /// venden diez unidades y NO cuadra si se venden mil: 25460.00 contra
    /// 25456.70 son tres soles y medio de diferencia, y el comprobante se
    /// rechaza con el 3271.
    ///
    /// El campo admite n(12,10), así que la precisión cabe. Los precios
    /// redondos siguen saliendo como "25.00".
    /// </summary>
    internal static string Unitario(decimal valor) =>
        valor.ToString("0.00##########", Inv);

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
            new XAttribute("languageLocaleID", CodigoLeyenda.MontoEnLetras),
            new XCData(Leyenda(importeTotal, moneda)));

    /// <summary>
    /// Una leyenda cualquiera del catálogo 52. Devuelve null si no hay que
    /// ponerla, y XElement descarta los nulos, así que el nodo desaparece.
    /// </summary>
    internal static XElement? LeyendaSuelta(bool corresponde, string codigo, string texto) =>
        !corresponde ? null : new XElement(Ns.Cbc + "Note",
            new XAttribute("languageLocaleID", codigo),
            new XCData(texto));

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

    /// <summary>
    /// País donde se usa, explota o aprovecha el servicio exportado.
    ///
    /// SUNAT lo pide dentro de cac:Delivery, que en UBL es el bloque de
    /// entrega. Suena raro para un servicio, pero es el sitio que el
    /// estándar ofrece y el que la validación 3098 mira.
    ///
    /// DÓNDE VA EN LA SECUENCIA: después del receptor y antes de
    /// cac:PaymentMeans. El XSD no admite otro orden.
    /// </summary>
    internal static XElement? PaisDeUsoDelServicio(string? pais)
    {
        if (string.IsNullOrWhiteSpace(pais)) return null;

        return new XElement(Ns.Cac + "Delivery",
            new XElement(Ns.Cac + "DeliveryLocation",
                new XElement(Ns.Cac + "Address",
                    new XElement(Ns.Cac + "Country",
                        new XElement(Ns.Cbc + "IdentificationCode",
                            new XAttribute("listID", "ISO 3166-1"),
                            new XAttribute("listAgencyName",
                                "United Nations Economic Commission for Europe"),
                            new XAttribute("listName", "Country"),
                            pais.Trim().ToUpperInvariant())))));
    }

    // ----------------------------------------------------------- anticipos

    /// <summary>
    /// Las referencias a los comprobantes donde se facturó cada anticipo.
    ///
    /// DÓNDE VAN: antes de cac:Signature. En UBL todas las referencias a
    /// otros documentos viven en ese tramo, y ponerlas más abajo —donde
    /// intuitivamente parecería que van, junto a los montos— invalida el
    /// documento contra el XSD.
    /// </summary>
    internal static IEnumerable<XElement> ReferenciasDeAnticipos(
        IEnumerable<Anticipo> anticipos) =>
        anticipos.Select(a => new XElement(Ns.Cac + "AdditionalDocumentReference",

            new XElement(Ns.Cbc + "ID", a.Numero),

            new XElement(Ns.Cbc + "DocumentTypeCode",
                new XAttribute("listName", "Documento Relacionado"),
                new XAttribute("listAgencyName", "PE:SUNAT"),
                new XAttribute("listURI",
                    "urn:pe:gob:sunat:cpe:see:gem:catalogos:catalogo12"),
                a.TipoComprobante),

            // El enlace con el monto. Tiene que coincidir con el ID del
            // PrepaidPayment de más abajo, o SUNAT devuelve el 3214.
            new XElement(Ns.Cbc + "DocumentStatusCode",
                new XAttribute("listName", "Anticipo"),
                new XAttribute("listAgencyName", "PE:SUNAT"),
                a.IdentificadorPago.ToString(Inv)),

            new XElement(Ns.Cac + "IssuerParty",
                new XElement(Ns.Cac + "PartyIdentification",
                    new XElement(Ns.Cbc + "ID",
                        new XAttribute("schemeID", TipoDocIdentidad.Ruc),
                        new XAttribute("schemeName", "Documento de Identidad"),
                        new XAttribute("schemeAgencyName", "PE:SUNAT"),
                        new XAttribute("schemeURI",
                            CatalogoUri.C06_TipoDocIdentidad),
                        a.RucEmisor)))));

    /// <summary>
    /// Los montos anticipados. Van después de cac:PaymentTerms y antes de
    /// los cargos y descuentos globales.
    /// </summary>
    internal static IEnumerable<XElement> MontosAnticipados(
        IEnumerable<Anticipo> anticipos, string moneda) =>
        anticipos.Select(a => new XElement(Ns.Cac + "PrepaidPayment",

            new XElement(Ns.Cbc + "ID",
                new XAttribute("schemeName", "Anticipo"),
                new XAttribute("schemeAgencyName", "PE:SUNAT"),
                a.IdentificadorPago.ToString(Inv)),

            // CON IGV: es lo que el cliente pagó de verdad.
            new XElement(Ns.Cbc + "PaidAmount",
                new XAttribute("currencyID", moneda), F2(a.MontoTotal)),

            a.FechaPago is null
                ? null
                : new XElement(Ns.Cbc + "PaidDate",
                    a.FechaPago.Value.ToString("yyyy-MM-dd", Inv))));

    /// <summary>
    /// Los descuentos globales por anticipo: códigos 04, 05 y 06 del
    /// catálogo 53, uno por cada base imponible afectada.
    ///
    /// SIN IGV, al revés que el PrepaidPayment de arriba. No es un despiste
    /// del estándar: este monto se resta de la base imponible, y la base
    /// imponible nunca lleva impuesto dentro.
    ///
    /// Se agrupan por tipo de afectación en vez de emitir uno por anticipo,
    /// porque SUNAT suma por código y tres anticipos gravados dan lo mismo
    /// sumados que por separado — pero un solo nodo deja el XML más limpio
    /// y evita problemas de redondeo al comparar contra la base.
    /// </summary>
    internal static IEnumerable<XElement> DescuentosPorAnticipo(
        string moneda, TotalesComprobante t)
    {
        if (t.AnticipoGravado > 0)
            yield return DescuentoGlobalPorAnticipo(moneda, CodigoAnticipo.Gravado, t.AnticipoGravado);

        if (t.AnticipoExonerado > 0)
            yield return DescuentoGlobalPorAnticipo(moneda, CodigoAnticipo.Exonerado, t.AnticipoExonerado);

        if (t.AnticipoInafecto > 0)
            yield return DescuentoGlobalPorAnticipo(moneda, CodigoAnticipo.Inafecto, t.AnticipoInafecto);
    }

    // SE LLAMABA CargoGlobal, Y HUBO QUE RENOMBRARLO.
    //
    // Ahora existe una clase CargoGlobal en este mismo espacio de nombres,
    // y un método con el nombre de un tipo es justo lo que produjo el bug
    // silencioso de AfectacionIgv.EsExportacion: el compilador elige uno de
    // los dos según el contexto, y no siempre el que uno cree.
    //
    // Además el nombre mentía: estos bloques son DESCUENTOS por anticipo,
    // con ChargeIndicator en false.
    private static XElement DescuentoGlobalPorAnticipo(
        string moneda, string codigo, decimal monto) =>
        new(Ns.Cac + "AllowanceCharge",

            // false = descuento. Para los códigos 04, 05 y 06 SUNAT no
            // admite otra cosa (regla 3114).
            new XElement(Ns.Cbc + "ChargeIndicator", "false"),

            new XElement(Ns.Cbc + "AllowanceChargeReasonCode",
                new XAttribute("listAgencyName", "PE:SUNAT"),
                new XAttribute("listName", "Cargo/descuento"),
                new XAttribute("listURI", CatalogoUri.C53_CargoDescuento),
                codigo),

            new XElement(Ns.Cbc + "Amount",
                new XAttribute("currencyID", moneda), F2(monto)));

    // ------------------------------------------------------------- totales

    /// <summary>
    /// Totales de impuestos del comprobante completo.
    ///
    /// LAS BASES QUE VAN AQUÍ SON LAS NETAS, ya con los anticipos
    /// descontados. Lo exigen las reglas 346 y 350.
    ///
    /// CADA BASE VA CON SU TRIBUTO Y SOLO SI TIENE IMPORTE. Declarar un
    /// subtotal en cero no es inocuo: la regla 3107 rechaza el comprobante
    /// de exportación que traiga el tributo 1000 a nivel global, aunque
    /// venga con importe cero.
    /// </summary>
    internal static XElement TaxTotal(string moneda, TotalesComprobante t)
    {
        // ImpuestosDeclarados, NO TotalIgv: la regla 3294 dice que este tag
        // es la suma de los tributos 1000, 1016, 2000, 7152 y 9999, y el
        // 7152 es el ICBPER. Sin bolsas los dos valen lo mismo.
        var nodo = new XElement(Ns.Cac + "TaxTotal",
            new XElement(Ns.Cbc + "TaxAmount",
                new XAttribute("currencyID", moneda), F2(t.ImpuestosDeclarados)));

        // AQUÍ HAY DOS NÚMEROS DISTINTOS Y NO ES UN DESCUIDO.
        //
        //   TaxableAmount → ValorVentaGravado (1 000.00)
        //   TaxAmount     → TotalIgv            (201.60)
        //
        // Con ISC, 201.60 no es el 18% de 1 000.00, y parece un error. No lo
        // es: SUNAT valida cada uno contra una cosa distinta.
        //
        //   Regla 3277: el monto base global es la suma de los
        //               cbc:LineExtensionAmount de las líneas gravadas, es
        //               decir el VALOR DE VENTA, sin ISC.
        //
        //   Regla 3291: el impuesto global es la suma de los MONTOS BASE DE
        //               LAS LÍNEAS por la tasa, y esos sí llevan el ISC
        //               dentro (regla 3272).
        //
        // Antes aquí iba TotalGravado —la base del IGV, con ISC— y la factura
        // de la gaseosa se rechazaba con el 3277 señalando 1120.00. Sin ISC
        // los dos valores coinciden, y por eso el error no apareció hasta que
        // hubo una línea con ISC.
        if (t.TotalGravado > 0)
            nodo.Add(TaxSubtotal(moneda, t.ValorVentaGravado, t.TotalIgv,
                AfectacionIgv.GravadoOperacionOnerosa));

        // Arroz pilado: tributo 1016 en vez del 1000 (reglas 3293 y 3295).
        // Por la regla 2644 nunca coexiste con el subtotal de arriba.
        if (t.TotalGravadoIvap > 0)
            nodo.Add(TaxSubtotal(moneda, t.TotalGravadoIvap, t.TotalIvap,
                AfectacionIgv.GravadoIvap));

        // Total valor de venta - exportación (tributo 9995, impuesto 0).
        if (t.TotalExportacion > 0)
            nodo.Add(TaxSubtotal(moneda, t.TotalExportacion, 0m,
                AfectacionIgv.Exportacion));

        if (t.TotalExonerado > 0)
            nodo.Add(TaxSubtotal(moneda, t.TotalExonerado, 0m, AfectacionIgv.Exonerado));

        if (t.TotalInafecto > 0)
            nodo.Add(TaxSubtotal(moneda, t.TotalInafecto, 0m, AfectacionIgv.Inafecto));

        // Total valor de venta - operaciones gratuitas (tributo 9996 - GRA).
        //
        // FALTABA, Y SIN ÉL NINGUNA LÍNEA GRATUITA PASABA. La regla 2638 dice
        // que si alguna línea trae un tributo con monto base mayor que cero,
        // el documento tiene que traer el total de ese mismo tributo.
        //
        // Aquí el impuesto NO es cero, al revés que en exportación, exonerado
        // e inafecto: es el IGV de las gratuitas gravadas, que se declara
        // aunque no se cobre (regla 3302).
        if (t.TotalGratuito > 0)
            nodo.Add(TaxSubtotal(moneda, t.TotalGratuito, t.IgvGratuito,
                AfectacionIgv.GratuitoGravado));

        // ISC: tributo 2000 (reglas 3296 y 3298).
        //
        // SU MONTO BASE NO ES EL VALOR DE VENTA DEL DOCUMENTO sino la suma
        // de las bases sobre las que se calculó el impuesto, que solo
        // incluye las líneas afectas y excluye las gratuitas.
        if (t.TotalIsc > 0)
        {
            nodo.Add(new XElement(Ns.Cac + "TaxSubtotal",
                new XElement(Ns.Cbc + "TaxableAmount",
                    new XAttribute("currencyID", moneda), F2(t.TotalBaseIsc)),
                new XElement(Ns.Cbc + "TaxAmount",
                    new XAttribute("currencyID", moneda), F2(t.TotalIsc)),
                new XElement(Ns.Cac + "TaxCategory",
                    new XElement(Ns.Cac + "TaxScheme",
                        new XElement(Ns.Cbc + "ID",
                            new XAttribute("schemeID", "UN/ECE 5153"),
                            new XAttribute("schemeAgencyID", "6"),
                            Isc.Codigo),
                        new XElement(Ns.Cbc + "Name", Isc.Nombre),
                        new XElement(Ns.Cbc + "TaxTypeCode", Isc.TipoCodigo)))));
        }

        // ICBPER: el impuesto a las bolsas de plástico (regla 3306).
        //
        // VA SIN TaxableAmount, y es el único subtotal del documento que lo
        // omite. No hay base imponible que declarar: el impuesto sale de
        // contar bolsas, no de aplicar un porcentaje. Por eso la regla 3003,
        // que exige el monto base en los demás tributos, dice expresamente
        // "si el código de tributo es DIFERENTE de 7152".
        if (t.TotalIcbper > 0)
        {
            nodo.Add(new XElement(Ns.Cac + "TaxSubtotal",
                new XElement(Ns.Cbc + "TaxAmount",
                    new XAttribute("currencyID", moneda), F2(t.TotalIcbper)),
                new XElement(Ns.Cac + "TaxCategory",
                    new XElement(Ns.Cac + "TaxScheme",
                        new XElement(Ns.Cbc + "ID",
                            new XAttribute("schemeID", "UN/ECE 5153"),
                            new XAttribute("schemeAgencyID", "6"),
                            Icbper.Codigo),
                        new XElement(Ns.Cbc + "Name", Icbper.Nombre),
                        new XElement(Ns.Cbc + "TaxTypeCode", Icbper.TipoCodigo)))));
        }

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
    ///
    /// TODO EL DOCUMENTO SE RESUME EN ESTOS CINCO NÚMEROS:
    ///
    ///   LineExtensionAmount  → la operación completa sin IGV
    ///   TaxInclusiveAmount   → la operación completa con IGV
    ///   AllowanceTotalAmount → descuentos que NO tocaron la base (01, 03, 63)
    ///   ChargeTotalAmount    → cargos que NO tocaron la base (45, 46, 48, 50)
    ///   PrepaidAmount        → lo ya adelantado, con IGV
    ///   PayableAmount        → precio de venta + cargos - descuentos - anticipos
    ///
    /// Los cuatro del medio desaparecen cuando no hay nada que poner en
    /// ellos, y entonces el precio de venta y el importe a pagar coinciden.
    ///
    /// EL ORDEN LO FIJA EL XSD Y NO ES NEGOCIABLE. Es exactamente el de
    /// arriba: los descuentos antes que los cargos, y PrepaidAmount justo
    /// antes de PayableAmount. Un elemento fuera de sitio invalida el
    /// documento con un error que habla de estructura y no dice cuál.
    /// </summary>
    internal static XElement TotalesMonetarios(
        string nombreElemento, string moneda, TotalesComprobante t) =>
        new(Ns.Cac + nombreElemento,
            new XElement(Ns.Cbc + "LineExtensionAmount",
                new XAttribute("currencyID", moneda), F2(t.ValorVenta)),
            new XElement(Ns.Cbc + "TaxInclusiveAmount",
                new XAttribute("currencyID", moneda), F2(t.PrecioVentaEfectivo)),

            // Los dos van solo si tienen contenido: la regla 2065 y la 2064
            // exigen que, si el tag existe, su valor sea distinto de cero.
            // Un cero declarado aquí es un rechazo, no un cero inocente.
            t.TotalOtrosDescuentos <= 0
                ? null
                : new XElement(Ns.Cbc + "AllowanceTotalAmount",
                    new XAttribute("currencyID", moneda), F2(t.TotalOtrosDescuentos)),

            t.TotalOtrosCargos <= 0
                ? null
                : new XElement(Ns.Cbc + "ChargeTotalAmount",
                    new XAttribute("currencyID", moneda), F2(t.TotalOtrosCargos)),

            t.TotalAnticipos <= 0
                ? null
                : new XElement(Ns.Cbc + "PrepaidAmount",
                    new XAttribute("currencyID", moneda), F2(t.TotalAnticipos)),

            new XElement(Ns.Cbc + "PayableAmount",
                new XAttribute("currencyID", moneda), F2(t.ImporteTotal)));

    /// <summary>
    /// Los bloques cac:AllowanceCharge de los cargos y descuentos globales.
    ///
    /// EL INDICADOR SALE DEL CÓDIGO, NO DEL USUARIO. La regla 3114 comprueba
    /// que los dos concuerden, así que dejar que se declaren por separado
    /// solo abriría la puerta a que se contradigan.
    ///
    /// DÓNDE VAN: junto a los descuentos por anticipo y al cargo de la
    /// percepción, después de cac:PaymentTerms y antes del tipo de cambio.
    /// </summary>
    internal static IEnumerable<XElement> CargosYDescuentosGlobales(
        IEnumerable<CargoGlobal> cargos, string moneda) =>
        cargos.Select(cg => new XElement(Ns.Cac + "AllowanceCharge",

            new XElement(Ns.Cbc + "ChargeIndicator",
                cg.EsCargo ? "true" : "false"),

            new XElement(Ns.Cbc + "AllowanceChargeReasonCode",
                new XAttribute("listAgencyName", "PE:SUNAT"),
                new XAttribute("listName", "Cargo/descuento"),
                new XAttribute("listURI", CatalogoUri.C53_CargoDescuento),
                cg.Codigo),

            // El factor y la base son opcionales, pero van juntos: SUNAT
            // recalcula monto = base x factor, y con uno solo no hay nada
            // que recalcular.
            cg.Factor is null
                ? null
                : new XElement(Ns.Cbc + "MultiplierFactorNumeric",
                    cg.Factor.Value.ToString("0.#####", Inv)),

            new XElement(Ns.Cbc + "Amount",
                new XAttribute("currencyID", moneda), F2(cg.Monto)),

            cg.BaseImponible is null
                ? null
                : new XElement(Ns.Cbc + "BaseAmount",
                    new XAttribute("currencyID", moneda),
                    F2(cg.BaseImponible.Value))));

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

            // EL VALOR DE VENTA DE LA LÍNEA, TAMBIÉN SI ES GRATUITA.
            //
            // Antes aquí iba un cero para las gratuitas, y era un rechazo
            // seguro por partida doble: la regla 3271 exige que este importe
            // sea el valor referencial por la cantidad menos descuentos, y la
            // 3276 suma precisamente estos importes para cuadrar el total de
            // gratuitas del documento. Con cero, ese total salía cero y caía
            // también el 2641.
            //
            // Que no se cobre no significa que no valga nada: SUNAT quiere
            // saber cuánto valía lo que se regaló.
            new XElement(Ns.Cbc + "LineExtensionAmount",
                new XAttribute("currencyID", moneda),
                F2(c.ValorVenta)),

            new XElement(Ns.Cac + "PricingReference",
                new XElement(Ns.Cac + "AlternativeConditionPrice",

                    // EN UNA LÍNEA GRATUITA ESTE CAMPO Y cac:Price SE INVIERTEN.
                    //
                    // Normal:   aquí el precio con IGV, abajo el valor unitario.
                    // Gratuita: aquí el valor referencial, abajo un cero.
                    //
                    // Y el valor referencial tiene que ser mayor que cero
                    // (error 2367). Poner cero "porque no se cobra" es el
                    // error más común de todo este bloque.
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

            // El descuento por línea va aquí: después de PricingReference y
            // antes de TaxTotal. El esquema no admite otro orden.
            DescuentoDeLinea(moneda, c),

            new XElement(Ns.Cac + "TaxTotal",

                // El total de tributos de la línea: IGV, ICBPER e ISC.
                // Regla 3292, que suma 1000, 1016, 2000, 7152 y 9999.
                new XElement(Ns.Cbc + "TaxAmount",
                    new XAttribute("currencyID", moneda),
                    F2(c.Igv + c.Icbper + c.Isc)),

                // EL SUBTOTAL DEL ISC VA PRIMERO, y su orden importa poco
                // para SUNAT pero mucho para leerlo: el ISC se calcula antes
                // y su importe entra en la base del bloque siguiente.
                SubtotalIsc(moneda, c),

                new XElement(Ns.Cac + "TaxSubtotal",

                    // BaseIgv y NO ValorVenta: con ISC, la base del tributo
                    // 1000 es el valor de venta más el ISC de esta misma
                    // línea. Lo comprueba la regla 3272. Sin ISC los dos
                    // valen lo mismo.
                    new XElement(Ns.Cbc + "TaxableAmount",
                        new XAttribute("currencyID", moneda), F2(c.BaseIgv)),
                    new XElement(Ns.Cbc + "TaxAmount",
                        new XAttribute("currencyID", moneda), F2(c.Igv)),
                    new XElement(Ns.Cac + "TaxCategory",

                        // TasaDeclarada, no PorcentajeIgv: en exportación el
                        // tributo es 9995 y el impuesto 0, así que declarar
                        // aquí un 18% sería decir dos cosas contrarias dentro
                        // del mismo bloque.
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
                            new XElement(Ns.Cbc + "TaxTypeCode", cat.TipoCodigo)))),

                // El segundo subtotal, cuando la línea son bolsas.
                SubtotalIcbper(moneda, c)),

            new XElement(Ns.Cac + "Item",
                new XElement(Ns.Cbc + "Description", new XCData(l.Descripcion)),
                string.IsNullOrWhiteSpace(l.CodigoProducto)
                    ? null
                    : new XElement(Ns.Cac + "SellersItemIdentification",
                        new XElement(Ns.Cbc + "ID", l.CodigoProducto)),

                // Los datos del catálogo 55, si los hay.
                PropiedadesDelItem(l.Propiedades)),

            // El valor unitario. CERO SI LA LÍNEA ES GRATUITA: la regla 2640
            // dice que en una operación gratuita solo se consigna el monto
            // referencial, el de arriba. Declarar aquí lo que valía sería
            // decir que se cobró.
            new XElement(Ns.Cac + "Price",
                new XElement(Ns.Cbc + "PriceAmount",
                    new XAttribute("currencyID", moneda),
                    esGratuita ? "0.00" : Unitario(l.ValorUnitario))));
    }

    /// <summary>
    /// Las propiedades del ítem: los datos del catálogo 55.
    ///
    /// SON LA VÍA QUE SUNAT USA PARA LO QUE NO CABE EN UBL. Una detracción
    /// de pesca necesita declarar la matrícula del barco y la fecha de
    /// descarga, y el estándar no tiene dónde ponerlas: van aquí, cada una
    /// con su código.
    ///
    /// EL VALOR VIAJA EN UN TAG U OTRO SEGÚN LO QUE SEA: un texto en
    /// cbc:Value, una cantidad en cbc:ValueQuantity con su unidad. El XSD
    /// los define en ese orden y no admite otro.
    /// </summary>
    internal static IEnumerable<XElement> PropiedadesDelItem(
        IEnumerable<PropiedadItem> propiedades) =>
        propiedades.Select(p => new XElement(Ns.Cac + "AdditionalItemProperty",

            new XElement(Ns.Cbc + "Name", ConceptoItem.Nombre(p.Codigo)),

            new XElement(Ns.Cbc + "NameCode",
                new XAttribute("listName", "Propiedad del item"),
                new XAttribute("listAgencyName", "PE:SUNAT"),
                // CatalogoUri y NO la cadena a mano: hay DOS formatos de URI
                // dando vueltas por internet y solo uno es el bueno.
                //
                // El corto —urn:pe:gob:catalogo:cpe:codigo:catalogoNN— sale
                // en ejemplos antiguos y SUNAT lo acepta con la observacion
                // 4253 colgando del CDR. El que vale es el largo, el que
                // usan todos los demas atributos de este archivo.
                new XAttribute("listURI", CatalogoUri.C55_ConceptoItem),
                p.Codigo),

            // TRES FORMAS DE LLEVAR EL DATO, Y SUNAT MIRA UNA CONCRETA SEGÚN
            // EL CONCEPTO:
            //
            //   texto     → cbc:Value
            //   cantidad  → cbc:ValueQuantity, con su unidad
            //   fecha     → cac:UsabilityPeriod/cbc:StartDate
            //
            // La fecha es la que sorprende: cabe perfectamente en cbc:Value
            // y aun así SUNAT devuelve el error 3065 si no está en ese
            // periodo. El estándar define ese nodo para decir cuándo es
            // válida una propiedad, y SUNAT lo reaprovecha como "el día en
            // que ocurrió esto".
            p.Fecha is not null
                ? new XElement(Ns.Cac + "UsabilityPeriod",
                    new XElement(Ns.Cbc + "StartDate",
                        p.Fecha.Value.ToString("yyyy-MM-dd", Inv)))
                : p.Cantidad is null
                    ? new XElement(Ns.Cbc + "Value", p.Valor)
                    : new XElement(Ns.Cbc + "ValueQuantity",
                        new XAttribute("unitCode", p.UnidadMedida),
                        p.Cantidad.Value.ToString("0.##########", Inv))));

    /// <summary>
    /// El subtotal del ISC dentro de la línea. Null si no lleva.
    ///
    /// DOS COSAS QUE NO TIENE NINGÚN OTRO SUBTOTAL:
    ///
    ///   cbc:TierRange  →  el sistema de cálculo del catálogo 08. Es
    ///                     obligatorio (regla 2373) y no existe en los demás
    ///                     tributos.
    ///   sin TaxExemptionReasonCode  →  la regla 2371 exime al 2000 y al
    ///                     9999 de declarar la afectación del IGV, porque no
    ///                     son tributos de IGV.
    ///
    /// El Percent no puede ser cero (regla 3104) y el importe tiene que ser
    /// la tasa por la base (regla 3108).
    /// </summary>
    private static XElement? SubtotalIsc(string moneda, LineaCalculada c)
    {
        if (!c.TieneIsc) return null;

        return new XElement(Ns.Cac + "TaxSubtotal",

            // La base del ISC es el valor de venta, sin el propio ISC.
            new XElement(Ns.Cbc + "TaxableAmount",
                new XAttribute("currencyID", moneda), F2(c.ValorVenta)),

            new XElement(Ns.Cbc + "TaxAmount",
                new XAttribute("currencyID", moneda), F2(c.Isc)),

            new XElement(Ns.Cac + "TaxCategory",

                new XElement(Ns.Cbc + "Percent", F2(c.Linea.TasaIsc)),

                // TierRange VA DESNUDO, SIN NINGUN ATRIBUTO.
                //
                // Su tipo en el XSD es TierRangeType, que no define
                // listAgencyName ni listName ni listURI. Ponerlos devuelve
                // el rechazo 0306 — "no se puede parsear el XML" — con un
                // mensaje que habla de un atributo indefinido y no dice que
                // el problema sea el ISC.
                //
                // Es exactamente lo mismo que nos paso con PaymentMeansID
                // en la detraccion. Que un elemento lleve un codigo de
                // catalogo NO significa que admita los atributos del
                // catalogo.
                new XElement(Ns.Cbc + "TierRange", c.Linea.SistemaIsc),

                new XElement(Ns.Cac + "TaxScheme",
                    new XElement(Ns.Cbc + "ID",
                        new XAttribute("schemeID", "UN/ECE 5153"),
                        new XAttribute("schemeAgencyID", "6"),
                        Isc.Codigo),
                    new XElement(Ns.Cbc + "Name", Isc.Nombre),
                    new XElement(Ns.Cbc + "TaxTypeCode", Isc.TipoCodigo))));
    }

    /// <summary>
    /// El subtotal del ICBPER dentro de la línea. Null si no hay bolsas.
    ///
    /// ES EL ÚNICO TRIBUTO QUE NO SE DECLARA COMO PORCENTAJE, y por eso su
    /// bloque no se parece a los demás:
    ///
    ///   cbc:TaxableAmount    →  0.00, porque no hay base imponible
    ///   cbc:BaseUnitMeasure  →  cuántas bolsas (entero, unitCode "NIU")
    ///   cbc:PerUnitAmount    →  cuánto por bolsa
    ///   cbc:Percent          →  NO VA. No existe un porcentaje que poner, y
    ///                           la regla 2992 exime al 7152 de declararlo.
    ///
    /// La cantidad de bolsas tiene que ser la cantidad de la línea (regla
    /// 3236), así que se toma de ahí en vez de pedirla aparte: dos números
    /// para la misma cosa terminan discrepando.
    /// </summary>
    private static XElement? SubtotalIcbper(string moneda, LineaCalculada c)
    {
        if (!c.TieneIcbper) return null;

        return new XElement(Ns.Cac + "TaxSubtotal",

            new XElement(Ns.Cbc + "TaxableAmount",
                new XAttribute("currencyID", moneda), "0.00"),

            new XElement(Ns.Cbc + "TaxAmount",
                new XAttribute("currencyID", moneda), F2(c.Icbper)),

            // Entero sin decimales: el campo es n5 y media bolsa no existe.
            new XElement(Ns.Cbc + "BaseUnitMeasure",
                new XAttribute("unitCode", "NIU"),
                ((int)Math.Truncate(c.Linea.Cantidad)).ToString(Inv)),

            new XElement(Ns.Cac + "TaxCategory",

                new XElement(Ns.Cbc + "PerUnitAmount",
                    new XAttribute("currencyID", moneda),
                    F2(c.TasaIcbper)),

                new XElement(Ns.Cac + "TaxScheme",
                    new XElement(Ns.Cbc + "ID",
                        new XAttribute("schemeID", "UN/ECE 5153"),
                        new XAttribute("schemeAgencyID", "6"),
                        Icbper.Codigo),
                    new XElement(Ns.Cbc + "Name", Icbper.Nombre),
                    new XElement(Ns.Cbc + "TaxTypeCode", Icbper.TipoCodigo))));
    }

    /// <summary>
    /// Descuento aplicado a una línea. Devuelve null si no hay, y XElement
    /// ignora los nulos, así que el nodo simplemente no aparece.
    ///
    /// BaseAmount debe ser el valor ANTES del descuento: SUNAT recalcula
    /// Amount = BaseAmount x MultiplierFactorNumeric y compara.
    /// </summary>
    internal static XElement? DescuentoDeLinea(string moneda, LineaCalculada c)
    {
        if (!c.TieneDescuento) return null;

        return new XElement(Ns.Cac + "AllowanceCharge",
            new XElement(Ns.Cbc + "ChargeIndicator", "false"),
            new XElement(Ns.Cbc + "AllowanceChargeReasonCode",
                CodigoDescuento.PorItem),
            new XElement(Ns.Cbc + "MultiplierFactorNumeric",
                c.FactorDescuento.ToString("0.#####", Inv)),
            new XElement(Ns.Cbc + "Amount",
                new XAttribute("currencyID", moneda), F2(c.Descuento)),
            new XElement(Ns.Cbc + "BaseAmount",
                new XAttribute("currencyID", moneda), F2(c.ValorBruto)));
    }

    /// <summary>
    /// Tipo de cambio. Solo se declara cuando el comprobante no está en soles.
    /// Va después de los descuentos globales y antes de TaxTotal.
    /// </summary>
    internal static XElement? TipoDeCambio(TipoCambio? tc)
    {
        if (tc is null) return null;

        return new XElement(Ns.Cac + "PaymentExchangeRate",
            new XElement(Ns.Cbc + "SourceCurrencyCode", tc.MonedaOrigen),
            new XElement(Ns.Cbc + "TargetCurrencyCode", tc.MonedaDestino),
            new XElement(Ns.Cbc + "CalculationRate",
                tc.Tasa.ToString("F3", Inv)),
            new XElement(Ns.Cbc + "Date", tc.Fecha.ToString("yyyy-MM-dd", Inv)));
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