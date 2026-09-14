using System.Security.Cryptography.X509Certificates;
using System.Xml.Linq;
using Facturacion.Cpe;

// ---------------------------------------------------------------------------
// Prueba dos casos nuevos contra SUNAT:
//   1. Factura con descuento por línea
//   2. Factura en dólares con tipo de cambio
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

var carpetaSalida = Path.Combine(AppContext.BaseDirectory, "salida");
Directory.CreateDirectory(carpetaSalida);

var rutaPfx = Path.Combine(AppContext.BaseDirectory, RutaCertificado);

if (!File.Exists(rutaPfx))
{
    Console.WriteLine($"No se encontró el certificado en: {rutaPfx}");
    return;
}

var certificado = new X509Certificate2(
    rutaPfx, ClaveCertificado,
    X509KeyStorageFlags.Exportable | X509KeyStorageFlags.MachineKeySet);

using var enviador = new EnviadorSunatSoap(ConfiguracionSunat.Beta(RucEmisor));

// --- Caso 1: factura con descuento por línea -------------------------------

var conDescuento = new Factura
{
    Serie = "F001",
    Correlativo = 20,
    FechaEmision = DateTime.Now,
    Emisor = emisor,
    Receptor = receptor,
    Lineas =
    [
        new LineaComprobante
        {
            Numero = 1,
            CodigoProducto = "P001",
            Descripcion = "PRODUCTO CON DESCUENTO",
            Cantidad = 2,
            ValorUnitario = 50.00m,
            DescuentoPorcentaje = 10m
        },
        new LineaComprobante
        {
            Numero = 2,
            CodigoProducto = "P002",
            Descripcion = "PRODUCTO SIN DESCUENTO",
            Cantidad = 1,
            ValorUnitario = 30.00m
        }
    ]
};

await Emitir("FACTURA CON DESCUENTO", conDescuento);

// --- Caso 2: factura con descuento global ----------------------------------

var conDescuentoGlobal = new Factura
{
    Serie = "F001",
    Correlativo = 22,
    FechaEmision = DateTime.Now,
    DescuentoGlobalPorcentaje = 5m,
    Emisor = emisor,
    Receptor = receptor,
    Lineas =
    [
        new LineaComprobante
        {
            Numero = 1,
            CodigoProducto = "P001",
            Descripcion = "PRODUCTO A",
            Cantidad = 1,
            ValorUnitario = 100.00m
        },
        new LineaComprobante
        {
            Numero = 2,
            CodigoProducto = "P002",
            Descripcion = "PRODUCTO B",
            Cantidad = 1,
            ValorUnitario = 20.00m
        }
    ]
};

await Emitir("FACTURA CON DESCUENTO GLOBAL", conDescuentoGlobal);

// --- Caso 3: descuento de linea mas descuento global -----------------------

var conAmbos = new Factura
{
    Serie = "F001",
    Correlativo = 23,
    FechaEmision = DateTime.Now,
    DescuentoGlobalPorcentaje = 10m,
    Emisor = emisor,
    Receptor = receptor,
    Lineas =
    [
        new LineaComprobante
        {
            Numero = 1,
            CodigoProducto = "P001",
            Descripcion = "PRODUCTO CON AMBOS DESCUENTOS",
            Cantidad = 2,
            ValorUnitario = 50.00m,
            DescuentoPorcentaje = 10m
        }
    ]
};

await Emitir("DESCUENTO DE LINEA MAS GLOBAL", conAmbos);

// --- Caso 4: factura en dólares --------------------------------------------

var enDolares = new Factura
{
    Serie = "F001",
    Correlativo = 24,
    FechaEmision = DateTime.Now,
    Moneda = "USD",
    TipoCambio = new TipoCambio
    {
        MonedaOrigen = "USD",
        MonedaDestino = "PEN",
        Tasa = 3.752m,
        Fecha = DateTime.Today
    },
    Emisor = emisor,
    Receptor = receptor,
    Lineas =
    [
        new LineaComprobante
        {
            Numero = 1,
            CodigoProducto = "P003",
            Descripcion = "SERVICIO DE CONSULTORIA",
            UnidadMedida = "ZZ",
            Cantidad = 1,
            ValorUnitario = 500.00m
        }
    ]
};

await Emitir("FACTURA EN DOLARES", enDolares);

Console.WriteLine();
Console.WriteLine($"Todo en: {carpetaSalida}");

// ---------------------------------------------------------------------------

async Task Emitir(string titulo, Factura factura)
{
    Console.WriteLine();
    Console.WriteLine(new string('=', 60));
    Console.WriteLine($"{titulo}: {factura.NombreArchivo}");
    Console.WriteLine(new string('=', 60));

    var t = CalculadoraTotales.Calcular(factura);

    Console.WriteLine($"Valor venta   : {NumeroALetras.F2(t.ValorVenta)}");

    if (t.TotalDescuentos > 0)
        Console.WriteLine($"Descuentos    : {NumeroALetras.F2(t.TotalDescuentos)}");

    Console.WriteLine($"Base IGV      : {NumeroALetras.F2(t.TotalGravado)}");
    Console.WriteLine($"IGV           : {NumeroALetras.F2(t.TotalIgv)}");
    Console.WriteLine($"Total         : {NumeroALetras.F2(t.ImporteTotal)} {factura.Moneda}");
    Console.WriteLine($"Leyenda       : {NumeroALetras.Leyenda(t.ImporteTotal, factura.Moneda)}");

    var firmado = FirmadorXml.Firmar(
        GeneradorFacturaXml.Generar(factura), certificado);

    var rutaXml = Path.Combine(carpetaSalida, $"{factura.NombreArchivo}.xml");
    FirmadorXml.Guardar(firmado, rutaXml);

    // Validar en local antes de enviar: es gratis y el mensaje es más claro.
    var rutaXsd = Path.Combine(
        AppContext.BaseDirectory, "xsd", "maindoc", "UBL-Invoice-2.1.xsd");

    if (File.Exists(rutaXsd))
    {
        var validacion = new ValidadorXsd(rutaXsd).Validar(XDocument.Load(rutaXml));

        if (!validacion.Valido)
        {
            Console.ForegroundColor = ConsoleColor.Red;
            Console.WriteLine($"XSD: NO válido. {validacion.Errores.Count} problema(s):");
            Console.ResetColor();

            foreach (var error in validacion.Errores)
                Console.WriteLine("  " + error);

            return;
        }

        Console.WriteLine("XSD           : válido");
    }

    var zip = EmpaquetadorZip.ComprimirDesdeArchivo(rutaXml);
    File.WriteAllBytes(
        Path.Combine(carpetaSalida, $"{factura.NombreArchivo}.zip"), zip);

    Console.WriteLine("Enviando a SUNAT beta...");

    var envio = await enviador.EnviarAsync($"{factura.NombreArchivo}.zip", zip);

    Console.ForegroundColor = envio.Aceptado ? ConsoleColor.Green : ConsoleColor.Red;
    Console.WriteLine(envio.Aceptado ? "ACEPTADA" : "RECHAZADA");
    Console.ResetColor();

    Console.WriteLine($"Código        : {envio.CodigoRespuesta}");
    Console.WriteLine($"Descripción   : {envio.Descripcion}");

    foreach (var obs in envio.Observaciones)
        Console.WriteLine($"  Observación : {obs}");

    if (envio.CdrZip is not null)
    {
        var nombreCdr = LectorCdr.NombreArchivoCdr(factura.NombreArchivo);

        File.WriteAllBytes(
            Path.Combine(carpetaSalida, $"{nombreCdr}.zip"), envio.CdrZip);
        File.WriteAllBytes(
            Path.Combine(carpetaSalida, $"{nombreCdr}.xml"), envio.CdrXml!);
    }
}
