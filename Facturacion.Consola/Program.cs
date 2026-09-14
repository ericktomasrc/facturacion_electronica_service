using System.Security.Cryptography.X509Certificates;
using Facturacion.Cpe;

// ---------------------------------------------------------------------------
// Emite una factura, la envía, y después CONSULTA su estado a SUNAT.
//
// El caso real que esto resuelve: el envío llega pero la respuesta se pierde
// por un corte de red. Sin consultar, no sabes si el comprobante existe.
// Reenviarlo crearía un duplicado; no reenviarlo dejaría la venta sin facturar.
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
    rutaPfx, ClaveCertificado,
    X509KeyStorageFlags.Exportable | X509KeyStorageFlags.MachineKeySet);

var configuracion = ConfiguracionSunat.Beta(RucEmisor);

// --- 1. Emitir una factura -------------------------------------------------

var factura = new Factura
{
    Serie = "F001",
    Correlativo = 30,
    FechaEmision = DateTime.Now,
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
Console.WriteLine($"EMISIÓN: {factura.NombreArchivo}");
Console.WriteLine(new string('=', 60));

var firmado = FirmadorXml.Firmar(
    GeneradorFacturaXml.Generar(factura), certificado);

var rutaXml = Path.Combine(carpetaSalida, $"{factura.NombreArchivo}.xml");
FirmadorXml.Guardar(firmado, rutaXml);

var zip = EmpaquetadorZip.ComprimirDesdeArchivo(rutaXml);

using (var enviador = new EnviadorSunatSoap(configuracion))
{
    var envio = await enviador.EnviarAsync($"{factura.NombreArchivo}.zip", zip);

    Console.ForegroundColor = envio.Aceptado ? ConsoleColor.Green : ConsoleColor.Red;
    Console.WriteLine(envio.Aceptado ? "ACEPTADA" : "RECHAZADA");
    Console.ResetColor();

    Console.WriteLine($"Código        : {envio.CodigoRespuesta}");
    Console.WriteLine($"Descripción   : {envio.Descripcion}");
}

// --- 2. Consultar el comprobante recién emitido ----------------------------
// Se simula que el CDR se perdió: se pregunta a SUNAT si tiene el documento
// y se recupera la constancia desde cero.

Console.WriteLine();
Console.WriteLine(new string('=', 60));
Console.WriteLine("CONSULTA DE ESTADO");
Console.WriteLine(new string('=', 60));
Console.WriteLine($"Preguntando por {factura.Serie}-{factura.Correlativo}...");
Console.WriteLine();

using var consultor = new ConsultorCpeSunat(configuracion);

var estado = await consultor.ConsultarAsync(
    ruc: RucEmisor,
    tipoComprobante: factura.TipoComprobante,
    serie: factura.Serie,
    numero: factura.Correlativo);

Console.WriteLine($"Código        : {estado.Codigo}");
Console.WriteLine($"Mensaje       : {estado.Mensaje}");
Console.WriteLine($"Existe        : {(estado.Existe ? "sí" : "no")}");
Console.WriteLine($"Aceptado      : {(estado.Aceptado ? "sí" : "no")}");

if (estado.CdrZip is not null)
{
    var nombre = $"RECUPERADO-{LectorCdr.NombreArchivoCdr(factura.NombreArchivo)}";

    File.WriteAllBytes(
        Path.Combine(carpetaSalida, $"{nombre}.zip"), estado.CdrZip);
    File.WriteAllBytes(
        Path.Combine(carpetaSalida, $"{nombre}.xml"), estado.CdrXml!);

    Console.ForegroundColor = ConsoleColor.Green;
    Console.WriteLine($"CDR recuperado: {nombre}.xml");
    Console.ResetColor();
}
else
{
    Console.WriteLine("SUNAT no devolvió el CDR en la consulta.");
}

// --- 3. Consultar un comprobante que no existe -----------------------------
// Para ver cómo responde SUNAT en el caso negativo, que es justo el que
// necesitas distinguir bien antes de decidir si reenviar.

Console.WriteLine();
Console.WriteLine("Preguntando por un comprobante inexistente (F999-99999)...");
Console.WriteLine();

var inexistente = await consultor.ConsultarAsync(
    ruc: RucEmisor,
    tipoComprobante: TipoComprobante.Factura,
    serie: "F999",
    numero: 99999);

Console.WriteLine($"Código        : {inexistente.Codigo}");
Console.WriteLine($"Mensaje       : {inexistente.Mensaje}");
Console.WriteLine($"Existe        : {(inexistente.Existe ? "sí" : "no")}");

Console.WriteLine();
Console.WriteLine($"Todo en: {carpetaSalida}");
