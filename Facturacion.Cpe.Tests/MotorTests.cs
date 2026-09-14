using System.Text;
using System.Xml.Linq;
using Facturacion.Cpe;

namespace Facturacion.Tests;

/// <summary>
/// Pruebas del XML generado: que tenga lo que SUNAT espera y en el lugar correcto.
/// </summary>
public class GeneradorXmlTests
{
    private static readonly XNamespace Cbc =
        "urn:oasis:names:specification:ubl:schema:xsd:CommonBasicComponents-2";

    private static readonly XNamespace Cac =
        "urn:oasis:names:specification:ubl:schema:xsd:CommonAggregateComponents-2";

    private static readonly XNamespace Ext =
        "urn:oasis:names:specification:ubl:schema:xsd:CommonExtensionComponents-2";

    [Fact]
    public void La_factura_declara_la_version_ubl_correcta()
    {
        var xml = GeneradorFacturaXml.Generar(Datos.Factura());

        Assert.Equal("2.1", Valor(xml, Cbc + "UBLVersionID"));
        Assert.Equal("2.0", Valor(xml, Cbc + "CustomizationID"));
    }

    [Fact]
    public void El_contenedor_de_la_firma_se_genera_vacio()
    {
        // Debe quedar vacío: el firmador lo rellena después. Si el generador
        // pusiera algo ahí, la firma se insertaría en el lugar equivocado.
        var xml = GeneradorFacturaXml.Generar(Datos.Factura());

        var contenedor = xml.Descendants(Ext + "ExtensionContent").Single();

        Assert.Empty(contenedor.Elements());
    }

    [Fact]
    public void Los_totales_del_xml_coinciden_con_los_calculados()
    {
        var factura = Datos.Factura();
        var esperados = CalculadoraTotales.Calcular(factura);

        var xml = GeneradorFacturaXml.Generar(factura);

        var totales = xml.Descendants(Cac + "LegalMonetaryTotal").Single();

        Assert.Equal(
            NumeroALetras.F2(esperados.ImporteTotal),
            totales.Element(Cbc + "PayableAmount")!.Value);
    }

    [Fact]
    public void Incluye_la_leyenda_del_importe_en_letras()
    {
        var xml = GeneradorFacturaXml.Generar(Datos.Factura());

        var nota = xml.Descendants(Cbc + "Note")
            .FirstOrDefault(n => n.Attribute("languageLocaleID")?.Value == "1000");

        Assert.NotNull(nota);
        Assert.Contains("SON CIENTO DIECIOCHO", nota!.Value);
    }

    [Fact]
    public void Genera_una_linea_por_cada_item()
    {
        var factura = Datos.Factura(
            Datos.Linea(numero: 1),
            Datos.Linea(numero: 2),
            Datos.Linea(numero: 3));

        var xml = GeneradorFacturaXml.Generar(factura);

        Assert.Equal(3, xml.Descendants(Cac + "InvoiceLine").Count());
    }

    [Fact]
    public void La_nota_de_credito_referencia_al_documento_que_modifica()
    {
        var nota = Datos.NotaCredito();

        var xml = GeneradorNotaXml.Generar(nota);

        var referencia = xml.Descendants(Cac + "InvoiceDocumentReference").Single();

        Assert.Equal("F001-00000001", referencia.Element(Cbc + "ID")!.Value);
        Assert.Equal("01", referencia.Element(Cbc + "DocumentTypeCode")!.Value);
    }

    [Fact]
    public void La_nota_de_credito_declara_su_motivo()
    {
        var xml = GeneradorNotaXml.Generar(Datos.NotaCredito());

        var motivo = xml.Descendants(Cac + "DiscrepancyResponse").Single();

        Assert.Equal("01", motivo.Element(Cbc + "ResponseCode")!.Value);
    }

    [Fact]
    public void Un_resumen_sin_lineas_falla_antes_de_generar_nada()
    {
        var resumen = new ResumenDiario { Emisor = Datos.Emisor() };

        Assert.Throws<InvalidOperationException>(
            () => GeneradorResumenXml.Generar(resumen));
    }

    private static string Valor(XDocument doc, XName nombre) =>
        doc.Root!.Element(nombre)!.Value;
}

/// <summary>
/// Pruebas de la firma digital.
///
/// El ciclo completo importa: firmar, guardar en disco, releer y verificar.
/// La mayoría de los problemas de firma no aparecen al firmar, sino al guardar,
/// porque cualquier cambio de espacios en blanco o un BOM la invalidan.
/// </summary>
public class FirmadorXmlTests
{
    [Fact]
    public void La_firma_verifica_despues_de_guardar_y_releer()
    {
        using var certificado = Datos.Certificado();

        var xml = GeneradorFacturaXml.Generar(Datos.Factura());
        var firmado = FirmadorXml.Firmar(xml, certificado);

        var ruta = Path.Combine(Path.GetTempPath(), $"{Guid.NewGuid()}.xml");

        try
        {
            FirmadorXml.Guardar(firmado, ruta);

            var releido = new System.Xml.XmlDocument { PreserveWhitespace = true };
            releido.Load(ruta);

            Assert.True(FirmadorXml.VerificarFirma(releido));
        }
        finally
        {
            if (File.Exists(ruta)) File.Delete(ruta);
        }
    }

    [Fact]
    public void El_archivo_guardado_no_lleva_BOM()
    {
        // El BOM son tres bytes invisibles al inicio del archivo. Windows los
        // agrega por defecto, el XML se ve perfecto en cualquier editor, y la
        // firma no valida. Es el error más difícil de diagnosticar del motor.
        using var certificado = Datos.Certificado();

        var firmado = FirmadorXml.Firmar(
            GeneradorFacturaXml.Generar(Datos.Factura()), certificado);

        var ruta = Path.Combine(Path.GetTempPath(), $"{Guid.NewGuid()}.xml");

        try
        {
            FirmadorXml.Guardar(firmado, ruta);

            var primeros = File.ReadAllBytes(ruta).Take(3).ToArray();

            Assert.False(
                primeros is [0xEF, 0xBB, 0xBF],
                "El archivo empieza con BOM. La firma no va a validar.");
        }
        finally
        {
            if (File.Exists(ruta)) File.Delete(ruta);
        }
    }

    [Fact]
    public void La_firma_queda_dentro_de_ExtensionContent()
    {
        using var certificado = Datos.Certificado();

        var firmado = FirmadorXml.Firmar(
            GeneradorFacturaXml.Generar(Datos.Factura()), certificado);

        var espacios = new System.Xml.XmlNamespaceManager(firmado.NameTable);
        espacios.AddNamespace("ext",
            "urn:oasis:names:specification:ubl:schema:xsd:CommonExtensionComponents-2");
        espacios.AddNamespace("ds", "http://www.w3.org/2000/09/xmldsig#");

        var firma = firmado.SelectSingleNode(
            "//ext:ExtensionContent/ds:Signature", espacios);

        Assert.NotNull(firma);
    }

    [Fact]
    public void Firmar_sin_llave_privada_falla_con_un_mensaje_claro()
    {
        using var completo = Datos.Certificado();

        // Un certificado exportado sin llave privada: solo la parte pública.
        using var soloPublico = new System.Security.Cryptography.X509Certificates
            .X509Certificate2(completo.Export(
                System.Security.Cryptography.X509Certificates.X509ContentType.Cert));

        var xml = GeneradorFacturaXml.Generar(Datos.Factura());

        var error = Assert.Throws<InvalidOperationException>(
            () => FirmadorXml.Firmar(xml, soloPublico));

        Assert.Contains("llave privada", error.Message);
    }
}

/// <summary>Pruebas del empaquetado ZIP.</summary>
public class EmpaquetadorZipTests
{
    [Fact]
    public void El_xml_queda_en_la_raiz_del_zip_con_el_nombre_correcto()
    {
        var contenido = Encoding.UTF8.GetBytes("<Invoice/>");

        var zip = EmpaquetadorZip.Comprimir("20601234567-01-F001-00000001", contenido);

        var (nombre, extraido) = EmpaquetadorZip.ExtraerPrimerXml(zip);

        Assert.Equal("20601234567-01-F001-00000001.xml", nombre);
        Assert.Equal(contenido, extraido);
    }

    [Fact]
    public void Un_zip_sin_xml_dentro_falla_con_un_mensaje_claro()
    {
        using var memoria = new MemoryStream();

        using (var zip = new System.IO.Compression.ZipArchive(
            memoria, System.IO.Compression.ZipArchiveMode.Create, leaveOpen: true))
        {
            zip.CreateEntry("cualquier-cosa.txt");
        }

        var error = Assert.Throws<InvalidOperationException>(
            () => EmpaquetadorZip.ExtraerPrimerXml(memoria.ToArray()));

        Assert.Contains("XML", error.Message);
    }
}

/// <summary>
/// Validación contra los esquemas oficiales de UBL 2.1.
///
/// Estas pruebas se saltan solas si los XSD no están descargados, para que el
/// proyecto siga compilando en una máquina recién clonada.
/// </summary>
public class ValidacionXsdTests
{
    [Fact]
    public void La_factura_firmada_valida_contra_el_esquema()
    {
        var rutaXsd = Datos.RutaXsd("UBL-Invoice-2.1.xsd");
        if (rutaXsd is null) return;   // esquemas no descargados

        using var certificado = Datos.Certificado();

        var firmado = FirmadorXml.Firmar(
            GeneradorFacturaXml.Generar(Datos.Factura()), certificado);

        var resultado = new ValidadorXsd(rutaXsd)
            .Validar(XDocument.Parse(firmado.OuterXml));

        Assert.True(resultado.Valido, Detalle(resultado));
    }

    [Fact]
    public void La_nota_de_credito_firmada_valida_contra_el_esquema()
    {
        var rutaXsd = Datos.RutaXsd("UBL-CreditNote-2.1.xsd");
        if (rutaXsd is null) return;

        using var certificado = Datos.Certificado();

        var firmado = FirmadorXml.Firmar(
            GeneradorNotaXml.Generar(Datos.NotaCredito()), certificado);

        var resultado = new ValidadorXsd(rutaXsd)
            .Validar(XDocument.Parse(firmado.OuterXml));

        Assert.True(resultado.Valido, Detalle(resultado));
    }

    [Fact]
    public void Una_factura_sin_firmar_no_valida_todavia()
    {
        // Confirma que la validación es real y no un sello de goma:
        // el esquema exige contenido dentro de ExtensionContent.
        var rutaXsd = Datos.RutaXsd("UBL-Invoice-2.1.xsd");
        if (rutaXsd is null) return;

        var sinFirma = GeneradorFacturaXml.Generar(Datos.Factura());

        var resultado = new ValidadorXsd(rutaXsd).Validar(sinFirma);

        Assert.False(resultado.Valido);
    }

    private static string Detalle(ResultadoValidacion r) =>
        string.Join(Environment.NewLine, r.Errores.Select(e => e.ToString()));
}
