using System.Security.Cryptography.X509Certificates;
using System.Xml.Linq;
using Facturacion.Cpe;

// ---------------------------------------------------------------------------
// Emite una factura y, a continuación, una nota de crédito que la anula.
// ---------------------------------------------------------------------------

const string RutaCertificado = "certificado.pfx";
const string ClaveCertificado = "123456";
const string RucEmisor = "20601234567";

var emisor = new Emisor
{
    Ruc = RucEmisor,
    RazonSocial = "MI EMPRESA SAC",
    NombreComercial = "MI EMPRESA",
    Ubigeo = "150101",
    Direccion = "AV. EJEMPLO 123",
    Distrito = "LIMA",
    Provincia = "LIMA",
    Departamento = "LIMA"
};

var receptor = new Receptor
{
    TipoDocumento = TipoDocIdentidad.Ruc,
    NumeroDocumento = "20512345678",
    RazonSocial = "CLIENTE DE PRUEBA SAC",
    Direccion = "JR. CLIENTE 456"
};

List<LineaComprobante> LineasDeEjemplo() =>
[
    new LineaComprobante
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
];

// --- Preparación -----------------------------------------------------------

var carpetaSalida = Path.Combine(AppContext.BaseDirectory, "salida");
Directory.CreateDirectory(carpetaSalida);

var rutaPfx = Path.Combine(AppContext.BaseDirectory, RutaCertificado);

if (!File.Exists(rutaPfx))
{
    Console.WriteLine($"No se encontró el certificado en: {rutaPfx}");
    return;
}

var certificado = new X509Certificate2(
    rutaPfx,
    ClaveCertificado,
    X509KeyStorageFlags.Exportable | X509KeyStorageFlags.MachineKeySet);

var configuracion = ConfiguracionSunat.Beta(RucEmisor);
using var enviador = new EnviadorSunatSoap(configuracion);

// --- 1. La factura ---------------------------------------------------------

var factura = new Factura
{
    Serie = "F001",
    Correlativo = 2,
    FechaEmision = DateTime.Now,
    Emisor = emisor,
    Receptor = receptor,
    Lineas = LineasDeEjemplo()
};

await Emitir(
    titulo: "FACTURA",
    comprobante: factura,
    xml: GeneradorFacturaXml.Generar(factura),
    xsdPrincipal: "UBL-Invoice-2.1.xsd");

// --- 2. La nota de crédito que la anula ------------------------------------
// La serie debe empezar con la misma letra del documento que modifica:
// F para notas sobre facturas, B para notas sobre boletas.

var nota = new NotaCredito
{
    Serie = "FC01",
    Correlativo = 1,
    FechaEmision = DateTime.Now,
    Emisor = emisor,
    Receptor = receptor,

    CodigoMotivo = MotivoNotaCredito.AnulacionDeLaOperacion,
    DescripcionMotivo = "ANULACION POR ERROR EN EL MONTO",

    Afectado = new DocumentoAfectado
    {
        Numero = factura.NumeroCompleto,
        TipoDocumento = TipoComprobante.Factura
    },

    // Una anulación total repite las mismas líneas de la factura original.
    Lineas = LineasDeEjemplo()
};

await Emitir(
    titulo: "NOTA DE CRÉDITO",
    comprobante: nota,
    xml: GeneradorNotaXml.Generar(nota),
    xsdPrincipal: "UBL-CreditNote-2.1.xsd");

Console.WriteLine();
Console.WriteLine($"Todo en: {carpetaSalida}");

// ---------------------------------------------------------------------------

async Task Emitir(
    string titulo,
    ComprobanteBase comprobante,
    XDocument xml,
    string xsdPrincipal)
{
    Console.WriteLine();
    Console.WriteLine(new string('=', 60));
    Console.WriteLine($"{titulo}: {comprobante.NombreArchivo}");
    Console.WriteLine(new string('=', 60));

    var totales = CalculadoraTotales.Calcular(comprobante);
    Console.WriteLine($"Importe total : {NumeroALetras.F2(totales.ImporteTotal)}");

    // Firmar
    var firmado = FirmadorXml.Firmar(xml, certificado);
    var rutaXml = Path.Combine(carpetaSalida, $"{comprobante.NombreArchivo}.xml");
    FirmadorXml.Guardar(firmado, rutaXml);

    // Validar contra el esquema que corresponda a este tipo de documento
    var rutaXsd = Path.Combine(
        AppContext.BaseDirectory, "xsd", "maindoc", xsdPrincipal);

    if (File.Exists(rutaXsd))
    {
        var resultado = new ValidadorXsd(rutaXsd).Validar(XDocument.Load(rutaXml));

        if (!resultado.Valido)
        {
            Console.ForegroundColor = ConsoleColor.Red;
            Console.WriteLine($"XSD: NO válido. {resultado.Errores.Count} problema(s):");
            Console.ResetColor();

            foreach (var error in resultado.Errores)
                Console.WriteLine("  " + error);

            return;   // no tiene sentido enviar algo que ya sabemos que está mal
        }

        Console.WriteLine("XSD           : válido");
    }

    // Comprimir y enviar
    var zip = EmpaquetadorZip.ComprimirDesdeArchivo(rutaXml);
    File.WriteAllBytes(
        Path.Combine(carpetaSalida, $"{comprobante.NombreArchivo}.zip"), zip);

    Console.WriteLine("Enviando a SUNAT beta...");

    var envio = await enviador.EnviarAsync($"{comprobante.NombreArchivo}.zip", zip);

    Console.ForegroundColor = envio.Aceptado ? ConsoleColor.Green : ConsoleColor.Red;
    Console.WriteLine(envio.Aceptado ? "ACEPTADO" : "RECHAZADO");
    Console.ResetColor();

    Console.WriteLine($"Código        : {envio.CodigoRespuesta}");
    Console.WriteLine($"Descripción   : {envio.Descripcion}");

    foreach (var obs in envio.Observaciones)
        Console.WriteLine($"  Observación : {obs}");

    if (envio.CdrZip is not null)
    {
        var nombreCdr = LectorCdr.NombreArchivoCdr(comprobante.NombreArchivo);

        File.WriteAllBytes(
            Path.Combine(carpetaSalida, $"{nombreCdr}.zip"), envio.CdrZip);
        File.WriteAllBytes(
            Path.Combine(carpetaSalida, $"{nombreCdr}.xml"), envio.CdrXml!);

        Console.WriteLine($"CDR guardado  : {nombreCdr}.xml");
    }
}
