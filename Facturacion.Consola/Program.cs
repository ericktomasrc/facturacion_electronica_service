using System.Security.Cryptography.X509Certificates;
using System.Xml.Linq;
using Facturacion.Cpe;

// ---------------------------------------------------------------------------
// Emite dos boletas y las comunica a SUNAT en un resumen diario.
//
// A diferencia de la factura, aquí NO se envía cada boleta: se agrupan todas
// las del día en un solo documento, y SUNAT responde con un ticket que hay
// que consultar después.
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

// --- 1. Las boletas del día ------------------------------------------------
// Se emitieron ayer. El resumen se genera hoy, que es el caso normal.

var ayer = DateTime.Today.AddDays(-1);

var boleta1 = new Boleta
{
    Serie = "B001",
    Correlativo = 1,
    FechaEmision = ayer,
    Emisor = emisor,
    Receptor = new Receptor
    {
        TipoDocumento = TipoDocIdentidad.Dni,
        NumeroDocumento = "45678912",
        RazonSocial = "JUAN PEREZ"
    },
    Lineas =
    [
        new LineaComprobante
        {
            Numero = 1,
            Descripcion = "PRODUCTO A",
            Cantidad = 1,
            ValorUnitario = 100.00m
        }
    ]
};

var boleta2 = new Boleta
{
    Serie = "B001",
    Correlativo = 2,
    FechaEmision = ayer,
    Emisor = emisor,
    Receptor = new Receptor
    {
        TipoDocumento = TipoDocIdentidad.Dni,
        NumeroDocumento = "10203040",
        RazonSocial = "MARIA GARCIA"
    },
    Lineas =
    [
        new LineaComprobante
        {
            Numero = 1,
            Descripcion = "PRODUCTO B",
            Cantidad = 3,
            ValorUnitario = 25.00m
        }
    ]
};

Console.WriteLine("Boletas emitidas:");
foreach (var b in new[] { boleta1, boleta2 })
{
    var t = CalculadoraTotales.Calcular(b);
    Console.WriteLine($"  {b.NumeroCompleto}  total {NumeroALetras.F2(t.ImporteTotal)}");
}

// --- 2. El resumen diario --------------------------------------------------

var resumen = new ResumenDiario
{
    Emisor = emisor,
    FechaReferencia = ayer,
    FechaGeneracion = DateTime.Today,
    Correlativo = 1,
    Lineas =
    [
        LineaResumen.DesdeBoleta(boleta1, orden: 1),
        LineaResumen.DesdeBoleta(boleta2, orden: 2)
    ]
};

Console.WriteLine();
Console.WriteLine(new string('=', 60));
Console.WriteLine($"RESUMEN DIARIO: {resumen.NombreArchivo}");
Console.WriteLine(new string('=', 60));

// --- 3. Generar, firmar y comprimir ----------------------------------------

var xml = GeneradorResumenXml.Generar(resumen);
var firmado = FirmadorXml.Firmar(xml, certificado);

var rutaXml = Path.Combine(carpetaSalida, $"{resumen.NombreArchivo}.xml");
FirmadorXml.Guardar(firmado, rutaXml);

Console.WriteLine($"XML firmado   : {resumen.NombreArchivo}.xml");

var zip = EmpaquetadorZip.ComprimirDesdeArchivo(rutaXml);
File.WriteAllBytes(Path.Combine(carpetaSalida, $"{resumen.NombreArchivo}.zip"), zip);

// --- 4. Enviar: aquí llega un TICKET, no un CDR ----------------------------

Console.WriteLine("Enviando resumen a SUNAT beta...");

var envio = await enviador.EnviarResumenAsync($"{resumen.NombreArchivo}.zip", zip);

if (!envio.Exitoso)
{
    Console.ForegroundColor = ConsoleColor.Red;
    Console.WriteLine($"No se pudo enviar: {envio.Mensaje}");
    Console.ResetColor();
    return;
}

Console.WriteLine($"Ticket        : {envio.Ticket}");

// --- 5. Consultar el ticket hasta que SUNAT termine ------------------------
// En producción esto NO se hace esperando: el worker encola una consulta
// diferida y libera el hilo. Aquí se espera solo porque es una prueba.

Console.WriteLine("Consultando el ticket...");

var resultado = await enviador.EsperarTicketAsync(
    envio.Ticket,
    intentosMaximos: 10,
    esperaEntreIntentos: TimeSpan.FromSeconds(3));

Console.WriteLine();
Console.ForegroundColor = resultado.Aceptado ? ConsoleColor.Green : ConsoleColor.Red;
Console.WriteLine(resultado.Aceptado ? "ACEPTADO" : "NO ACEPTADO");
Console.ResetColor();

Console.WriteLine($"Código        : {resultado.CodigoRespuesta}");
Console.WriteLine($"Descripción   : {resultado.Descripcion}");

foreach (var obs in resultado.Observaciones)
    Console.WriteLine($"  Observación : {obs}");

// --- 6. Guardar el CDR -----------------------------------------------------

if (resultado.CdrZip is not null)
{
    var nombreCdr = LectorCdr.NombreArchivoCdr(resumen.NombreArchivo);

    File.WriteAllBytes(
        Path.Combine(carpetaSalida, $"{nombreCdr}.zip"), resultado.CdrZip);
    File.WriteAllBytes(
        Path.Combine(carpetaSalida, $"{nombreCdr}.xml"), resultado.CdrXml!);

    Console.WriteLine($"CDR guardado  : {nombreCdr}.xml");
}

Console.WriteLine();
Console.WriteLine($"Todo en: {carpetaSalida}");
