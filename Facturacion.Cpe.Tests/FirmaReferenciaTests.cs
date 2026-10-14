using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Security.Cryptography.Xml;
using System.Text;
using System.Xml.Linq;
using Facturacion.Cpe;
using Xunit.Abstractions;

namespace Facturacion.Tests;

/// <summary>
/// LA FIRMA NO PUEDE CAMBIAR SIN QUE NOS ENTEREMOS (13 de octubre de 2026).
///
/// Para qué: antes de subir el runtime o System.Security.Cryptography.Xml (el
/// paso a .NET 10), se guarda cómo firma HOY el servicio. Después de cambiar,
/// la misma prueba vuelve a firmar exactamente lo mismo y compara BYTE A BYTE.
///
/// POR QUÉ BYTE A BYTE SIRVE: la firma que usamos (RSA PKCS#1 v1.5) es
/// determinista. Mismo XML, misma llave → mismos bytes, siempre. Si algo sale
/// distinto, cambió la canonicalización, el digest, la serialización o la
/// firma misma, y el mensaje de error dice dónde.
///
/// DÓNDE SE GUARDA LA REFERENCIA: FUERA del repositorio, en
/// %LOCALAPPDATA%\reyban\firma-referencia (o en la carpeta que diga la
/// variable REYBAN_FIRMA_REFERENCIA). Ahí va también el certificado de prueba
/// con el que se firma: es autofirmado y no vale nada, pero la regla del
/// proyecto es que ningún certificado entra a git, y se cumple.
///
/// LA PRIMERA VEZ crea el certificado y la referencia, y pasa. Las siguientes,
/// compara. Para empezar de cero, se borra esa carpeta.
/// </summary>
public class FirmaReferenciaTests
{
    private const string ClavePfx = "referencia-firma";

    private readonly ITestOutputHelper salida;

    public FirmaReferenciaTests(ITestOutputHelper salida) => this.salida = salida;

    /// <summary>Los casos que se firman. El nombre es el del archivo de referencia.</summary>
    private static IEnumerable<(string Nombre, Func<XDocument> Xml)> Casos()
    {
        yield return ("factura-una-linea", () => GeneradorFacturaXml.Generar(Datos.Factura()));

        yield return ("factura-tres-lineas", () => GeneradorFacturaXml.Generar(Datos.Factura(
            Datos.Linea(cantidad: 1, valorUnitario: 25.4567m, numero: 1),
            Datos.Linea(cantidad: 1000, valorUnitario: 0.35m, numero: 2),
            Datos.Linea(cantidad: 3, valorUnitario: 1999.99m, numero: 3))));

        yield return ("nota-credito", () => GeneradorNotaXml.Generar(Datos.NotaCredito()));

        // Sin pasar por los generadores: tildes, eñes, «&», comillas y espacios
        // entre etiquetas. Es lo que más castiga a la canonicalización.
        yield return ("xml-con-caracteres-especiales", XmlConCaracteresEspeciales);
    }

    [Fact]
    public void Firmar_dos_veces_lo_mismo_da_los_mismos_bytes()
    {
        // Si esto falla, la comparación con la referencia no tendría sentido:
        // algo del XML cambia solo (una fecha, un id al azar).
        using var certificado = CertificadoDeReferencia(Carpeta());

        foreach (var (nombre, xml) in Casos())
        {
            var a = FirmarYGuardar(xml(), certificado);
            var b = FirmarYGuardar(xml(), certificado);
            Assert.True(a.AsSpan().SequenceEqual(b), $"«{nombre}»: dos firmas seguidas no dieron los mismos bytes.");
        }
    }

    [Fact]
    public void La_firma_es_identica_a_la_referencia_guardada()
    {
        var carpeta = Carpeta();
        using var certificado = CertificadoDeReferencia(carpeta);

        var creados = new List<string>();
        var distintos = new List<string>();

        foreach (var (nombre, xml) in Casos())
        {
            var actual = FirmarYGuardar(xml(), certificado);

            // Además de idéntica, tiene que verificar.
            var releido = new System.Xml.XmlDocument { PreserveWhitespace = true };
            using (var ms = new MemoryStream(actual)) releido.Load(ms);
            Assert.True(FirmadorXml.VerificarFirma(releido), $"«{nombre}»: la firma no verifica.");

            var ruta = Path.Combine(carpeta, nombre + ".xml");
            if (!File.Exists(ruta))
            {
                File.WriteAllBytes(ruta, actual);
                creados.Add(nombre);
                continue;
            }

            var referencia = File.ReadAllBytes(ruta);
            if (referencia.AsSpan().SequenceEqual(actual)) continue;

            File.WriteAllBytes(Path.Combine(carpeta, nombre + ".DISTINTO.xml"), actual);
            distintos.Add(Diferencia(nombre, referencia, actual));
        }

        // La versión del ARCHIVO (8.0.x, 10.0.x), no la del ensamblado (siempre x.0.0.0).
        var xmlDll = typeof(SignedXml).Assembly;
        var entorno = $"{RuntimeInformation.FrameworkDescription} · System.Security.Cryptography.Xml " +
                      $"{System.Diagnostics.FileVersionInfo.GetVersionInfo(xmlDll.Location).FileVersion ?? xmlDll.GetName().Version?.ToString()}";

        if (creados.Count > 0)
        {
            File.AppendAllText(Path.Combine(carpeta, "LEEME.txt"),
                $"{DateTime.Now:yyyy-MM-dd HH:mm} referencia creada con {entorno}: {string.Join(", ", creados)}{Environment.NewLine}",
                new UTF8Encoding(false));
            salida.WriteLine($"Referencia CREADA en {carpeta} ({entorno}): {string.Join(", ", creados)}");
        }

        Assert.True(distintos.Count == 0,
            $"LA FIRMA CAMBIÓ con {entorno}.{Environment.NewLine}{string.Join(Environment.NewLine, distintos)}" +
            $"{Environment.NewLine}Lo nuevo quedó en los archivos *.DISTINTO.xml de {carpeta}.");

        salida.WriteLine($"Firma idéntica a la referencia ({entorno}). Carpeta: {carpeta}");
    }

    // ------------------------------------------------------------------ interno

    private static byte[] FirmarYGuardar(XDocument xml, X509Certificate2 certificado)
    {
        var firmado = FirmadorXml.Firmar(xml, certificado);

        // Por el mismo camino que el servicio: FirmadorXml.Guardar.
        var ruta = Path.Combine(Path.GetTempPath(), $"{Guid.NewGuid()}.xml");
        try
        {
            FirmadorXml.Guardar(firmado, ruta);
            return File.ReadAllBytes(ruta);
        }
        finally
        {
            if (File.Exists(ruta)) File.Delete(ruta);
        }
    }

    private static string Carpeta()
    {
        var carpeta = Environment.GetEnvironmentVariable("REYBAN_FIRMA_REFERENCIA");
        if (string.IsNullOrWhiteSpace(carpeta))
            carpeta = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "reyban", "firma-referencia");
        Directory.CreateDirectory(carpeta);
        return carpeta;
    }

    /// <summary>
    /// El certificado con el que se firma la referencia. Se crea UNA vez y se
    /// guarda en la carpeta de la referencia: con otro certificado los bytes
    /// cambiarían siempre y la comparación no serviría.
    /// </summary>
    private static X509Certificate2 CertificadoDeReferencia(string carpeta)
    {
        var ruta = Path.Combine(carpeta, "certificado-referencia.pfx");

        if (!File.Exists(ruta))
        {
            using var rsa = RSA.Create(2048);
            var peticion = new CertificateRequest(
                "CN=REFERENCIA FIRMA REYBAN", rsa, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
            using var generado = peticion.CreateSelfSigned(
                new DateTimeOffset(2026, 1, 1, 0, 0, 0, TimeSpan.Zero),
                new DateTimeOffset(2036, 1, 1, 0, 0, 0, TimeSpan.Zero));
            File.WriteAllBytes(ruta, generado.Export(X509ContentType.Pfx, ClavePfx));
        }

        return new X509Certificate2(File.ReadAllBytes(ruta), ClavePfx, X509KeyStorageFlags.Exportable);
    }

    private static XDocument XmlConCaracteresEspeciales()
    {
        XNamespace inv = "urn:oasis:names:specification:ubl:schema:xsd:Invoice-2";
        XNamespace ext = "urn:oasis:names:specification:ubl:schema:xsd:CommonExtensionComponents-2";
        XNamespace cbc = "urn:oasis:names:specification:ubl:schema:xsd:CommonBasicComponents-2";

        return new XDocument(
            new XDeclaration("1.0", "UTF-8", "no"),
            new XElement(inv + "Invoice",
                new XAttribute(XNamespace.Xmlns + "ext", ext),
                new XAttribute(XNamespace.Xmlns + "cbc", cbc),
                new XElement(ext + "UBLExtensions",
                    new XElement(ext + "UBLExtension", new XElement(ext + "ExtensionContent"))),
                new XElement(cbc + "ID", "F001-00000001"),
                new XElement(cbc + "Note", new XAttribute("languageLocaleID", "1000"),
                    "CIENTO VEINTE Y 50/100 SOLES"),
                new XElement(cbc + "Note", "Año 2026 · señal «ÁÉÍÓÚ ñ ü» & <cosas> \"entre\" comillas 'simples'"),
                new XElement(cbc + "Description", "  espacios   al inicio y al final  "),
                new XElement(cbc + "PayableAmount", new XAttribute("currencyID", "PEN"), "120.50")));
    }

    /// <summary>Dónde empieza la diferencia, con un poco de contexto de cada lado.</summary>
    private static string Diferencia(string nombre, byte[] referencia, byte[] actual)
    {
        var n = Math.Min(referencia.Length, actual.Length);
        var i = 0;
        while (i < n && referencia[i] == actual[i]) i++;

        static string Trozo(byte[] b, int desde) =>
            Encoding.UTF8.GetString(b, Math.Max(0, desde - 60), Math.Min(b.Length - Math.Max(0, desde - 60), 160));

        return $"  «{nombre}»: distinto desde el byte {i} (referencia {referencia.Length} bytes, ahora {actual.Length}).{Environment.NewLine}" +
               $"    referencia: …{Trozo(referencia, i)}…{Environment.NewLine}" +
               $"    ahora:      …{Trozo(actual, i)}…";
    }
}