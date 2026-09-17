// ===========================================================================
// CICLO COMPLETO DE UNA GUÍA DE REMISIÓN
//
// Junta por primera vez las cinco piezas: modelo, generador, firma,
// compresión y envío por REST con OAuth2.
//
// Si el simulador devuelve un ticket y luego una respuesta, el camino queda
// validado de punta a punta.
//
// NOTA SOBRE EL AMBIENTE: esto NO es SUNAT. Es un simulador de la comunidad
// que imita su API, porque SUNAT no publica un beta de guías tan accesible
// como el de facturas. Sirve para comprobar que el XML, la firma y el flujo
// funcionan; la verificación real llega con el primer cliente que tenga
// credenciales de producción.
// ===========================================================================

using System.Security.Cryptography.X509Certificates;
using System.Text;
using System.Xml;
using Facturacion.Cpe;

// El último dígito debe ser 5: lo exige el simulador, no SUNAT.
const string Ruc = "20601234565";

const string RutaCertificado = "certificado.pfx";
const string ClaveCertificado = "123456";


// ---------------------------------------------------------------- la guía

var guia = new GuiaRemision
{
    Serie = "T001",
    Correlativo = 1,

    FechaEmision = DateTime.Today,

    // El traslado empieza mañana. No puede ser anterior a la emisión: la
    // guía se emite ANTES de mover los bienes.
    FechaTraslado = DateTime.Today.AddDays(1),

    Remitente = new Emisor
    {
        Ruc = Ruc,
        RazonSocial = "MI EMPRESA SAC"
    },

    Destinatario = new Receptor
    {
        TipoDocumento = "6",
        NumeroDocumento = "20512345678",
        RazonSocial = "FERRETERIA EL CLAVO SAC"
    },

    MotivoTraslado = CatalogosGre.MotivoTraslado.Venta,

    // Privado: lo lleva la propia empresa, así que hay que declarar el
    // vehículo y el conductor. En transporte público se declararía al
    // transportista y él tendría que emitir su propia guía tipo 31.
    ModalidadTraslado = CatalogosGre.ModalidadTraslado.Privado,

    PesoBruto = 250.5m,
    NumeroBultos = 12,

    // Los ubigeos son del INEI y SUNAT los valida: uno inventado rechaza
    // la guía entera.
    PuntoPartida = new DireccionTraslado("150101", "AV. ARGENTINA 1234 - LIMA"),
    PuntoLlegada = new DireccionTraslado("150132", "AV. TUPAC AMARU 456 - COMAS"),

    Vehiculo = new Vehiculo("ABC123"),

    Conductor = new Conductor(
        TipoDocumento: "1",
        NumeroDocumento: "45678912",
        Nombres: "JUAN CARLOS",
        Apellidos: "PEREZ LOPEZ",
        Licencia: "Q45678912"),

    Bienes =
    [
        new BienTrasladado("CEMENTO PORTLAND TIPO I BOLSA 42.5KG", 100, "BG"),
        new BienTrasladado("FIERRO CORRUGADO 1/2 X 9M", 50, "NIU")
    ],

    // La factura que origina el traslado.
    DocumentosRelacionados =
    [
        new DocumentoRelacionadoGre("01", "F001-00000053", RucEmisor: Ruc)
    ]
};


// ------------------------------------------------- 1. revisar antes de nada

Console.WriteLine("GUÍA DE REMISIÓN — CICLO COMPLETO");
Console.WriteLine(new string('=', 60));
Console.WriteLine($"Número: {guia.Numero}   Archivo: {guia.NombreArchivo}");
Console.WriteLine();

var problemas = guia.Revisar();

if (problemas.Count > 0)
{
    Console.WriteLine("La guía tiene problemas que SUNAT rechazaría:");

    foreach (var p in problemas)
        Console.WriteLine("  - " + p);

    return;
}

Console.WriteLine("1. Revisión previa: sin problemas");


// ------------------------------------------------------- 2. generar el XML

var xml = GeneradorGuiaXml.Generar(guia);

Console.WriteLine($"2. XML generado ({xml.ToString().Length} caracteres)");


// ------------------------------------------------------------- 3. firmar

if (!File.Exists(RutaCertificado))
{
    Console.WriteLine();
    Console.WriteLine($"No se encontró {RutaCertificado}.");
    Console.WriteLine("Cópialo a la carpeta del proyecto de consola.");
    return;
}

X509Certificate2 certificado;

try
{
    // EphemeralKeySet primero: evita que Windows intente escribir la llave
    // en el almacén del usuario, que es donde fallaba de forma intermitente.
    certificado = new X509Certificate2(
        RutaCertificado, ClaveCertificado,
        X509KeyStorageFlags.EphemeralKeySet | X509KeyStorageFlags.Exportable);
}
catch (Exception ex)
{
    Console.WriteLine();
    Console.WriteLine("No se pudo abrir el certificado: " + ex.Message);
    return;
}

var firmado = FirmadorXml.Firmar(xml, certificado);

Console.WriteLine($"3. Firmado. Verifica: {FirmadorXml.VerificarFirma(firmado)}");


// ---------------------------------------------------------- 4. comprimir

// UTF-8 SIN BOM, y esto importa.
//
// Los tres bytes de marca al inicio del archivo invalidan la firma, porque
// no formaban parte de lo que se firmó. Ya nos costó tiempo descubrirlo con
// las facturas.
var sinBom = new UTF8Encoding(false);

using var memoria = new MemoryStream();

using (var escritor = new XmlTextWriter(memoria, sinBom))
{
    firmado.Save(escritor);
}

var bytesXml = memoria.ToArray();

var zip = EmpaquetadorZip.Comprimir(guia.NombreArchivo, bytesXml);

Console.WriteLine($"4. Comprimido ({zip.Length} bytes)");

// Se guarda para poder inspeccionarlo si SUNAT rechaza algo.
File.WriteAllBytes($"{guia.NombreArchivo}.xml", bytesXml);
Console.WriteLine($"   XML guardado en {guia.NombreArchivo}.xml");


// -------------------------------------------------------------- 5. enviar

using var cliente = new ClienteGre(ConfiguracionGre.Beta(Ruc));

var envio = await cliente.EnviarAsync($"{guia.NombreArchivo}.zip", zip);

Console.WriteLine();
Console.WriteLine("5. Envío");
Console.WriteLine($"   Exitoso : {envio.Exitoso}");
Console.WriteLine($"   HTTP    : {envio.CodigoHttp}");
Console.WriteLine($"   Ticket  : {envio.Ticket ?? "(ninguno)"}");
Console.WriteLine($"   Mensaje : {envio.Mensaje}");

if (!envio.Exitoso) return;


// --------------------------------------------------- 6. consultar el ticket

// El envío devuelve un ticket, no una respuesta.
//
// Y aquí está la regla que distingue a las guías: LA CONSTANCIA ACEPTADA
// DEBE EXISTIR ANTES DE QUE EL VEHÍCULO SALGA. Por eso se consulta cada
// pocos segundos y no cada minuto como los resúmenes: el camión espera.

Console.WriteLine();
Console.WriteLine("6. Consultando el ticket");

for (var intento = 1; intento <= 10; intento++)
{
    await Task.Delay(3000);

    var estado = await cliente.ConsultarAsync(envio.Ticket!);

    Console.WriteLine($"   Intento {intento}: {estado.Descripcion}");

    if (!estado.Terminado) continue;

    Console.WriteLine();
    Console.WriteLine($"   Aceptada : {estado.Aceptado}");
    Console.WriteLine($"   Código   : {estado.CodigoRespuesta}");

    foreach (var obs in estado.Observaciones)
        Console.WriteLine($"   Observación: {obs}");
    // El código 99 no explica nada. El motivo está en el CDR.
    if (estado.CdrZip is not null)
    {
        File.WriteAllBytes($"R-{guia.NombreArchivo}.zip", estado.CdrZip);

        var (nombre, contenido) = EmpaquetadorZip.ExtraerPrimerXml(estado.CdrZip);

        Console.WriteLine();
        Console.WriteLine("--- CDR ---");
        Console.WriteLine(Encoding.UTF8.GetString(contenido));
        Console.WriteLine();
        Console.WriteLine("--- Respuesta cruda ---");
        Console.WriteLine(estado.RespuestaCruda);
    }
    else
    {
        Console.WriteLine("   (sin CDR: el motivo debería venir en la respuesta)");
    }

    return;
}

Console.WriteLine();
Console.WriteLine("   SUNAT no terminó de procesar en 30 segundos.");
Console.WriteLine("   El ticket sigue vivo: se puede consultar más tarde.");