using System.Xml.Linq;

namespace Facturacion.Cpe;

/// <summary>
/// Bloques comunes a los documentos que usan esquemas PROPIOS de SUNAT:
/// el resumen diario (RC) y la comunicación de baja (RA).
///
/// POR QUÉ ESTÁN SEPARADOS DE BloquesComunes: estos documentos no siguen el
/// estándar de OASIS. Declaran UBL 2.0, usan el prefijo sac: para los elementos
/// que SUNAT inventó, y declaran al emisor con una estructura más antigua
/// (CustomerAssignedAccountID en vez del bloque cac:Party completo).
///
/// Mezclarlos con los bloques de factura haría que ninguno de los dos se
/// entienda bien.
/// </summary>
internal static class BloquesSunat
{
    /// <summary>Elementos propios de SUNAT, prefijo sac:</summary>
    internal static readonly XNamespace Sac =
        "urn:sunat:names:specification:ubl:peru:schema:xsd:SunatAggregateComponents-1";

    /// <summary>Quién firma el documento.</summary>
    internal static XElement Firmante(Emisor e) =>
        new(Ns.Cac + "Signature",
            new XElement(Ns.Cbc + "ID", e.Ruc),
            new XElement(Ns.Cac + "SignatoryParty",
                new XElement(Ns.Cac + "PartyIdentification",
                    new XElement(Ns.Cbc + "ID", e.Ruc)),
                new XElement(Ns.Cac + "PartyName",
                    new XElement(Ns.Cbc + "Name", new XCData(e.RazonSocial)))),
            new XElement(Ns.Cac + "DigitalSignatureAttachment",
                new XElement(Ns.Cac + "ExternalReference",
                    new XElement(Ns.Cbc + "URI", "#SignatureSP"))));

    /// <summary>
    /// Emisor en formato antiguo: el RUC va directo en CustomerAssignedAccountID.
    /// No confundir con el bloque cac:Party de la factura, que es mucho más rico.
    /// </summary>
    internal static XElement Emisor(Emisor e) =>
        new(Ns.Cac + "AccountingSupplierParty",
            new XElement(Ns.Cbc + "CustomerAssignedAccountID", e.Ruc),
            new XElement(Ns.Cbc + "AdditionalAccountID", TipoDocIdentidad.Ruc),
            new XElement(Ns.Cac + "Party",
                new XElement(Ns.Cac + "PartyLegalEntity",
                    new XElement(Ns.Cbc + "RegistrationName",
                        new XCData(e.RazonSocial)))));

    /// <summary>Atributos de namespace comunes a RC y RA.</summary>
    internal static XAttribute[] Namespaces() =>
    [
        new XAttribute(XNamespace.Xmlns + "cac", Ns.Cac.NamespaceName),
        new XAttribute(XNamespace.Xmlns + "cbc", Ns.Cbc.NamespaceName),
        new XAttribute(XNamespace.Xmlns + "ds",  Ns.Ds.NamespaceName),
        new XAttribute(XNamespace.Xmlns + "ext", Ns.Ext.NamespaceName),
        new XAttribute(XNamespace.Xmlns + "sac", Sac.NamespaceName)
    ];
}
