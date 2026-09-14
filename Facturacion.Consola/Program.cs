using System.Security.Cryptography.X509Certificates;
using System.Xml.Linq;
using Facturacion.Cpe;

// ---------------------------------------------------------------------------
// Emite una factura y después la da de baja.
//
// La baja anula el comprobante como si nunca hubiera existido. Es distinta de
// una nota de crédito, que corrige la operación y deja rastro contable.
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

using var enviador = new EnviadorSunatSoap(ConfiguracionSunat.Beta(RucEmisor));

// --- 1. La factura que después vamos a anular ------------------------------
// Se emite con fecha de ayer, porque la comunicación de baja informa
// comprobantes de una fecha anterior a la de generación.

var ayer = DateTime.Today.AddDays(-1);

var factura = new Factura
{
    Serie = "F001",
    Correlativo = 10,
    FechaEmision = ayer,
    Emisor = emisor,
    Receptor = new Receptor
    {
        TipoDocumento = TipoDocIdentidad.Ruc,
        NumeroDocumento = "20512345678",
        RazonSocial = "CLIENTE DE PRUEBA SAC",
        Direccion = "JR. CLIENTE 456"
    },
    Lineas =
    [
        new LineaComprobante
        {
            Numero = 1,
            CodigoProducto = "P001",
            Descripcion = "PRODUCTO DE PRUEBA",
            Cantidad = 2,
            ValorUnitario = 50.00m
        }
    ]
};

Console.WriteLine(new string('=', 60));
Console.WriteLine($"FACTURA: {factura.NombreArchivo}");
Console.WriteLine(new string('=', 60));

var xmlFactura = GeneradorFacturaXml.Generar(factura);
var facturaFirmada = FirmadorXml.Firmar(xmlFactura, certificado);

var rutaFactura = Path.Combine(carpetaSalida, $"{factura.NombreArchivo}.xml");
FirmadorXml.Guardar(facturaFirmada, rutaFactura);

var zipFactura = EmpaquetadorZip.ComprimirDesdeArchivo(rutaFactura);

Console.WriteLine("Enviando factura...");
var envioFactura = await enviador.EnviarAsync(
    $"{factura.NombreArchivo}.zip", zipFactura);

Console.ForegroundColor = envioFactura.Aceptado ? ConsoleColor.Green : ConsoleColor.Red;
Console.WriteLine(envioFactura.Aceptado ? "ACEPTADA" : "RECHAZADA");
Console.ResetColor();
Console.WriteLine($"Código        : {envioFactura.CodigoRespuesta}");
Console.WriteLine($"Descripción   : {envioFactura.Descripcion}");

if (!envioFactura.Aceptado)
{
    Console.WriteLine();
    Console.WriteLine("No tiene sentido dar de baja algo que SUNAT no aceptó.");
    return;
}

// --- 2. La comunicación de baja --------------------------------------------

var baja = new ComunicacionBaja
{
    Emisor = emisor,
    FechaReferencia = ayer,
    FechaGeneracion = DateTime.Today,
    Correlativo = 1,
    Lineas =
    [
        LineaBaja.Desde(factura, orden: 1, motivo: "ERROR EN LOS DATOS DEL CLIENTE")
    ]
};

Console.WriteLine();
Console.WriteLine(new string('=', 60));
Console.WriteLine($"COMUNICACIÓN DE BAJA: {baja.NombreArchivo}");
Console.WriteLine(new string('=', 60));

var xmlBaja = GeneradorBajaXml.Generar(baja);
var bajaFirmada = FirmadorXml.Firmar(xmlBaja, certificado);

var rutaBaja = Path.Combine(carpetaSalida, $"{baja.NombreArchivo}.xml");
FirmadorXml.Guardar(bajaFirmada, rutaBaja);

Console.WriteLine($"XML firmado   : {baja.NombreArchivo}.xml");

var zipBaja = EmpaquetadorZip.ComprimirDesdeArchivo(rutaBaja);
File.WriteAllBytes(Path.Combine(carpetaSalida, $"{baja.NombreArchivo}.zip"), zipBaja);

// --- 3. Envío asíncrono: el mismo flujo del resumen diario -----------------

Console.WriteLine("Enviando comunicación de baja...");

var envioBaja = await enviador.EnviarResumenAsync($"{baja.NombreArchivo}.zip", zipBaja);

if (!envioBaja.Exitoso)
{
    Console.ForegroundColor = ConsoleColor.Red;
    Console.WriteLine($"No se pudo enviar: {envioBaja.Mensaje}");
    Console.ResetColor();
    return;
}

Console.WriteLine($"Ticket        : {envioBaja.Ticket}");
Console.WriteLine("Consultando el ticket...");

var resultado = await enviador.EsperarTicketAsync(
    envioBaja.Ticket,
    intentosMaximos: 10,
    esperaEntreIntentos: TimeSpan.FromSeconds(3));

Console.WriteLine();
Console.ForegroundColor = resultado.Aceptado ? ConsoleColor.Green : ConsoleColor.Red;
Console.WriteLine(resultado.Aceptado ? "ACEPTADA" : "NO ACEPTADA");
Console.ResetColor();

Console.WriteLine($"Código        : {resultado.CodigoRespuesta}");
Console.WriteLine($"Descripción   : {resultado.Descripcion}");

foreach (var obs in resultado.Observaciones)
    Console.WriteLine($"  Observación : {obs}");

if (resultado.CdrZip is not null)
{
    var nombreCdr = LectorCdr.NombreArchivoCdr(baja.NombreArchivo);

    File.WriteAllBytes(
        Path.Combine(carpetaSalida, $"{nombreCdr}.zip"), resultado.CdrZip);
    File.WriteAllBytes(
        Path.Combine(carpetaSalida, $"{nombreCdr}.xml"), resultado.CdrXml!);

    Console.WriteLine($"CDR guardado  : {nombreCdr}.xml");
}

Console.WriteLine();
Console.WriteLine($"Todo en: {carpetaSalida}");
