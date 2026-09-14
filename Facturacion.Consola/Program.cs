using Facturacion.Cpe;
using System.Xml.Linq;

// ---------------------------------------------------------------------------
// PASO 1: generar el XML de una factura y validarlo contra el XSD.
// Todavía no hay firma, ni ZIP, ni envío a SUNAT. Solo el XML.
// ---------------------------------------------------------------------------

var factura = new Factura
{
    Serie = "F001",
    Correlativo = 1,
    FechaEmision = DateTime.Now,
    Moneda = "PEN",
    FormaPago = "Contado",

    Emisor = new Emisor
    {
        Ruc = "20601234567",               // cambiar por el RUC de prueba
        RazonSocial = "MI EMPRESA SAC",
        NombreComercial = "MI EMPRESA",
        Ubigeo = "150101",
        Direccion = "AV. EJEMPLO 123",
        Distrito = "LIMA",
        Provincia = "LIMA",
        Departamento = "LIMA"
    },

    Receptor = new Receptor
    {
        TipoDocumento = TipoDocIdentidad.Ruc,
        NumeroDocumento = "20512345678",
        RazonSocial = "CLIENTE DE PRUEBA SAC",
        Direccion = "JR. CLIENTE 456"
    },

    Lineas =
    [
        new LineaFactura
        {
            Numero = 1,
            CodigoProducto = "P001",
            Descripcion = "PRODUCTO DE PRUEBA",
            UnidadMedida = "NIU",
            Cantidad = 2,
            ValorUnitario = 50.00m,
            TipoAfectacionIgv = AfectacionIgv.GravadoOperacionOnerosa,
            PorcentajeIgv = 18m
        }
    ]
};

// --- 1. Calcular y mostrar los totales -------------------------------------

var totales = CalculadoraTotales.Calcular(factura);

Console.WriteLine($"Comprobante   : {factura.NombreArchivo}");
Console.WriteLine($"Gravado       : {NumeroALetras.F2(totales.TotalGravado)}");
Console.WriteLine($"IGV           : {NumeroALetras.F2(totales.TotalIgv)}");
Console.WriteLine($"Importe total : {NumeroALetras.F2(totales.ImporteTotal)}");
Console.WriteLine($"Leyenda       : {NumeroALetras.Leyenda(totales.ImporteTotal, factura.Moneda)}");
Console.WriteLine();

// --- 2. Generar el XML -----------------------------------------------------

var xml = GeneradorFacturaXml.Generar(factura);

// TEMPORAL: relleno para verificar el resto del esquema.
// Quitar cuando el paso 2 inserte la firma real.
// TEMPORAL: firma de mentira, solo para verificar el resto del esquema.
// Quitar cuando el paso 2 inserte la firma real.
var extensionContent = xml.Descendants(Ns.Ext + "ExtensionContent").First();
extensionContent.Add(
    new XElement(Ns.Ds + "Signature",
        new XAttribute("Id", "SignatureSP"),
        new XElement(Ns.Ds + "SignedInfo",
            new XElement(Ns.Ds + "CanonicalizationMethod",
                new XAttribute("Algorithm", "http://www.w3.org/TR/2001/REC-xml-c14n-20010315")),
            new XElement(Ns.Ds + "SignatureMethod",
                new XAttribute("Algorithm", "http://www.w3.org/2000/09/xmldsig#rsa-sha1")),
            new XElement(Ns.Ds + "Reference",
                new XAttribute("URI", ""),
                new XElement(Ns.Ds + "Transforms",
                    new XElement(Ns.Ds + "Transform",
                        new XAttribute("Algorithm", "http://www.w3.org/2000/09/xmldsig#enveloped-signature"))),
                new XElement(Ns.Ds + "DigestMethod",
                    new XAttribute("Algorithm", "http://www.w3.org/2000/09/xmldsig#sha1")),
                new XElement(Ns.Ds + "DigestValue", ""))),
        new XElement(Ns.Ds + "SignatureValue", "")));

var carpetaSalida = Path.Combine(AppContext.BaseDirectory, "salida");
var rutaXml = Path.Combine(carpetaSalida, $"{factura.NombreArchivo}.xml");

ValidadorXsd.Guardar(xml, rutaXml);
Console.WriteLine($"XML generado  : {rutaXml}");

// --- 3. Validar contra el XSD ----------------------------------------------
// Descarga los esquemas de SUNAT y ajusta esta ruta.

var rutaXsd = Path.Combine(
    AppContext.BaseDirectory, "xsd", "maindoc", "UBL-Invoice-2.1.xsd");

if (!File.Exists(rutaXsd))
{
    Console.WriteLine();
    Console.WriteLine("Los XSD no están en la carpeta 'xsd'.");
    Console.WriteLine("Descárgalos del portal de SUNAT y colócalos ahí para validar.");
    Console.WriteLine("Ruta esperada: " + rutaXsd);
    return;
}

var validador = new ValidadorXsd(rutaXsd);
var resultado = validador.Validar(xml);

Console.WriteLine();

if (resultado.Valido)
{
    Console.ForegroundColor = ConsoleColor.Green;
    Console.WriteLine("El XML es válido según el XSD. Listo para el paso 2: la firma.");
    Console.ResetColor();
}
else
{
    Console.ForegroundColor = ConsoleColor.Red;
    Console.WriteLine($"El XML NO es válido. {resultado.Errores.Count} problema(s):");
    Console.ResetColor();

    foreach (var error in resultado.Errores)
        Console.WriteLine("  " + error);
}
