using System.Security.Cryptography.X509Certificates;
using System.Security.Cryptography.Xml;
using System.Text;
using System.Xml;
using System.Xml.Linq;

namespace Facturacion.Cpe;

/// <summary>
/// Firma el comprobante con una firma XML digital de tipo "enveloped",
/// insertada dentro de ext:UBLExtensions/ext:UBLExtension/ext:ExtensionContent.
///
/// CÓMO FUNCIONA, EN CUATRO PASOS:
///
/// 1. CANONICALIZAR: el XML se normaliza byte a byte, para que dos documentos
///    equivalentes produzcan siempre los mismos bytes.
/// 2. DIGEST: se calcula un hash de esos bytes.
/// 3. FIRMAR: el hash se cifra con la llave privada del certificado.
/// 4. INSERTAR: el resultado se coloca dentro de ExtensionContent.
///
/// EL DETALLE QUE ARRUINA TODO: la firma cubre el documento completo, incluido
/// el lugar donde ella misma se va a insertar. Por eso existe la transformación
/// "enveloped-signature", que le dice al verificador que ignore el nodo de la
/// firma al recalcular el hash. Si falta, el hash nunca coincide.
///
/// Por eso también la firma se calcula ANTES de insertarla en el documento.
/// </summary>
public static class FirmadorXml
{
    /// <summary>
    /// Debe coincidir con el valor de cac:Signature/cac:DigitalSignatureAttachment/
    /// cac:ExternalReference/cbc:URI que genera GeneradorFacturaXml (ahí va "#SignatureSP").
    /// </summary>
    public const string IdFirma = "SignatureSP";

    /// <summary>
    /// Firma el documento y devuelve un XmlDocument con la firma ya insertada.
    ///
    /// Se devuelve XmlDocument y no XDocument a propósito: el guardado debe hacerse
    /// sobre este mismo objeto, sin volver a serializar por otro camino. Cualquier
    /// reescritura posterior puede alterar espacios en blanco y romper la firma.
    /// </summary>
    public static XmlDocument Firmar(XDocument documento, X509Certificate2 certificado)
    {
        ArgumentNullException.ThrowIfNull(documento);
        ArgumentNullException.ThrowIfNull(certificado);

        if (!certificado.HasPrivateKey)
            throw new InvalidOperationException(
                "El certificado no tiene llave privada. Para firmar hace falta un .pfx " +
                "o .p12 con la llave incluida, no solo el certificado público.");

        var doc = ConvertirAXmlDocument(documento);
        var contenedor = UbicarExtensionContent(doc);

        var firma = CalcularFirma(doc, certificado);

        contenedor.AppendChild(doc.ImportNode(firma, deep: true));

        return doc;
    }

    /// <summary>
    /// Verifica que la firma del documento sea válida y coincida con el contenido.
    ///
    /// Vale la pena llamarlo siempre después de firmar: si algo alteró el documento
    /// entre la firma y el guardado, esto lo detecta en local en vez de esperar un
    /// rechazo de SUNAT con un código poco descriptivo.
    /// </summary>
    public static bool VerificarFirma(XmlDocument doc)
    {
        var nodos = doc.GetElementsByTagName("Signature", SignedXml.XmlDsigNamespaceUrl);
        if (nodos.Count == 0) return false;

        var signedXml = new SignedXml(doc);
        signedXml.LoadXml((XmlElement)nodos[0]!);

        return signedXml.CheckSignature();
    }

    // ------------------------------------------------------------------ interno

    private static XmlElement CalcularFirma(XmlDocument doc, X509Certificate2 certificado)
    {
        using var llavePrivada = certificado.GetRSAPrivateKey()
            ?? throw new InvalidOperationException(
                "No se pudo obtener la llave privada RSA del certificado.");

        var signedXml = new SignedXml(doc)
        {
            SigningKey = llavePrivada
        };

        signedXml.Signature.Id = IdFirma;

        signedXml.SignedInfo!.CanonicalizationMethod = SignedXml.XmlDsigC14NTransformUrl;
        signedXml.SignedInfo.SignatureMethod = SignedXml.XmlDsigRSASHA1Url;

        // URI vacío = el documento completo.
        var referencia = new Reference
        {
            Uri = "",
            DigestMethod = SignedXml.XmlDsigSHA1Url
        };

        // Sin esta transformación, el hash nunca coincidiría.
        referencia.AddTransform(new XmlDsigEnvelopedSignatureTransform());

        signedXml.AddReference(referencia);

        // Los datos del certificado viajan dentro de la firma para que SUNAT
        // pueda verificarla sin tenerlo previamente.
        var infoLlave = new KeyInfo();
        infoLlave.AddClause(new KeyInfoX509Data(certificado));
        signedXml.KeyInfo = infoLlave;

        signedXml.ComputeSignature();

        return signedXml.GetXml();
    }

    private static XmlDocument ConvertirAXmlDocument(XDocument documento)
    {
        // PreserveWhitespace es obligatorio: si .NET normaliza los espacios en
        // blanco, la canonicalización cambia y la firma deja de validar.
        var doc = new XmlDocument { PreserveWhitespace = true };

        using var lector = documento.CreateReader();
        doc.Load(lector);

        return doc;
    }

    private static XmlElement UbicarExtensionContent(XmlDocument doc)
    {
        var espacios = new XmlNamespaceManager(doc.NameTable);
        espacios.AddNamespace("ext", Ns.Ext.NamespaceName);

        var nodo = doc.SelectSingleNode(
            "//ext:UBLExtensions/ext:UBLExtension/ext:ExtensionContent", espacios);

        return nodo as XmlElement
            ?? throw new InvalidOperationException(
                "No se encontró ext:ExtensionContent en el documento. " +
                "El generador debe crearlo vacío antes de firmar.");
    }

    /// <summary>
    /// Guarda el documento firmado en UTF-8 sin BOM.
    ///
    /// No usar XmlWriterSettings con Indent aquí: agregar saltos de línea o
    /// espacios después de firmar invalida la firma.
    /// </summary>
    public static void Guardar(XmlDocument doc, string ruta)
    {
        var directorio = Path.GetDirectoryName(ruta);
        if (!string.IsNullOrEmpty(directorio))
            Directory.CreateDirectory(directorio);

        var configuracion = new XmlWriterSettings
        {
            Encoding = new UTF8Encoding(encoderShouldEmitUTF8Identifier: false),
            Indent = false,
            OmitXmlDeclaration = false,
            NewLineHandling = NewLineHandling.None
        };

        using var writer = XmlWriter.Create(ruta, configuracion);
        doc.Save(writer);
    }
}
