using Facturacion.Cpe;
using Facturacion.Persistencia;

// ---------------------------------------------------------------------------
// Demuestra el ciclo completo del almacén de certificados:
//
//   1. Carga el .pfx del disco
//   2. Lo cifra y lo guarda en la base
//   3. Lo recupera descifrado
//   4. Firma una factura con él y verifica la firma
//
// El certificado nunca queda en claro en la base ni se vuelve a escribir
// al disco.
// ---------------------------------------------------------------------------

const string RutaCertificado = "certificado.pfx";
const string ClaveCertificado = "123456";

// El puerto es 5433 porque el 5432 ya lo ocupa otro contenedor.
const string CadenaConexion =
    "Host=localhost;Port=5433;Database=facturacion;" +
    "Username=facturacion_app;Password=cambiame_en_produccion";

// --- 1. La llave maestra ---------------------------------------------------

if (string.IsNullOrWhiteSpace(
        Environment.GetEnvironmentVariable(ProtectorAesGcm.VariableLlaveMaestra)))
{
    Console.ForegroundColor = ConsoleColor.Yellow;
    Console.WriteLine($"Falta la variable {ProtectorAesGcm.VariableLlaveMaestra}.");
    Console.ResetColor();
    Console.WriteLine();
    Console.WriteLine("Genera una y guárdala FUERA del repositorio. En PowerShell:");
    Console.WriteLine();
    Console.WriteLine($"  $env:{ProtectorAesGcm.VariableLlaveMaestra} = \"{ProtectorAesGcm.GenerarLlaveBase64()}\"");
    Console.WriteLine();
    Console.WriteLine("Esa línea la define solo para la sesión actual de PowerShell.");
    Console.WriteLine("Para que Visual Studio la vea, defínela a nivel de usuario:");
    Console.WriteLine();
    Console.WriteLine($"  [Environment]::SetEnvironmentVariable(\"{ProtectorAesGcm.VariableLlaveMaestra}\", \"<la llave>\", \"User\")");
    Console.WriteLine();
    Console.WriteLine("Y reinicia Visual Studio para que tome el cambio.");
    Console.WriteLine();
    Console.WriteLine("SI PIERDES ESTA LLAVE, los certificados guardados quedan");
    Console.WriteLine("irrecuperables. No hay puerta trasera: de eso se trata.");
    return;
}

var protector = ProtectorAesGcm.DesdeEntorno();
var sesiones = new FabricaSesiones(CadenaConexion);
var almacen = new AlmacenCertificados(sesiones, protector);

Console.WriteLine("Llave maestra   : cargada");

// --- 2. Resolver el tenant -------------------------------------------------

Guid tenantId;

await using (var catalogo = await sesiones.AbrirCatalogoAsync())
{
    var comando = new Npgsql.NpgsqlCommand(
        "SELECT id FROM tenants WHERE ruc = @ruc", catalogo);

    comando.Parameters.AddWithValue("ruc", "20601234567");

    var resultado = await comando.ExecuteScalarAsync();

    if (resultado is null)
    {
        Console.WriteLine("No se encontró el tenant. ¿Corriste las migraciones?");
        return;
    }

    tenantId = (Guid)resultado;
}

Console.WriteLine($"Tenant          : {tenantId}");
Console.WriteLine();

// --- 3. Guardar el certificado cifrado -------------------------------------

var rutaPfx = Path.Combine(AppContext.BaseDirectory, RutaCertificado);

if (!File.Exists(rutaPfx))
{
    Console.WriteLine($"No se encontró el certificado en: {rutaPfx}");
    return;
}

var contenidoPfx = await File.ReadAllBytesAsync(rutaPfx);

Console.WriteLine("Guardando el certificado cifrado...");

var certificadoId = await almacen.GuardarAsync(
    tenantId, contenidoPfx, ClaveCertificado);

Console.WriteLine($"Guardado con id : {certificadoId}");
Console.WriteLine();

// --- 4. Verificar que en la base NO está en claro --------------------------

await using (var sesion = await sesiones.AbrirAsync(tenantId))
{
    var comando = new Npgsql.NpgsqlCommand(
        "SELECT pfx_cifrado FROM certificados WHERE id = @id",
        sesion.Conexion, sesion.Transaccion);

    comando.Parameters.AddWithValue("id", certificadoId);

    var cifrado = (byte[])(await comando.ExecuteScalarAsync())!;

    // Un PFX real empieza con la secuencia DER 0x30 0x82.
    // Si lo guardado empezara así, no estaría cifrado.
    var pareceUnPfxEnClaro = cifrado.Length > 2 && cifrado[0] == 0x30 && cifrado[1] == 0x82;

    Console.ForegroundColor = pareceUnPfxEnClaro ? ConsoleColor.Red : ConsoleColor.Green;
    Console.WriteLine(pareceUnPfxEnClaro
        ? "PROBLEMA: el certificado parece estar guardado EN CLARO."
        : "En la base : cifrado, no se reconoce como PFX");
    Console.ResetColor();

    Console.WriteLine($"Original   : {contenidoPfx.Length:N0} bytes");
    Console.WriteLine($"Cifrado    : {cifrado.Length:N0} bytes (28 más: nonce y tag)");

    await sesion.ConfirmarAsync();
}

Console.WriteLine();

// --- 5. Recuperarlo y firmar con él ----------------------------------------

Console.WriteLine("Recuperando el certificado desde la base...");

using var certificado = await almacen.ObtenerActivoAsync(tenantId);

if (certificado is null)
{
    Console.WriteLine("No hay certificado activo para este tenant.");
    return;
}

Console.WriteLine($"Subject         : {certificado.Subject}");
Console.WriteLine($"Llave privada   : {(certificado.HasPrivateKey ? "sí" : "NO")}");
Console.WriteLine();

var factura = new Factura
{
    Serie = "F001",
    Correlativo = 40,
    FechaEmision = DateTime.Now,
    Emisor = new Emisor
    {
        Ruc = "20601234567",
        RazonSocial = "MI EMPRESA SAC",
        Direccion = "AV. EJEMPLO 123",
        Distrito = "LIMA",
        Provincia = "LIMA",
        Departamento = "LIMA"
    },
    Receptor = new Receptor
    {
        TipoDocumento = TipoDocIdentidad.Ruc,
        NumeroDocumento = "20512345678",
        RazonSocial = "CLIENTE DE PRUEBA SAC"
    },
    Lineas =
    [
        new LineaComprobante
        {
            Numero = 1,
            Descripcion = "PRODUCTO DE PRUEBA",
            Cantidad = 2,
            ValorUnitario = 50.00m
        }
    ]
};

var firmado = FirmadorXml.Firmar(
    GeneradorFacturaXml.Generar(factura), certificado);

Console.ForegroundColor = ConsoleColor.Green;
Console.WriteLine("Factura firmada con el certificado recuperado de la base.");
Console.ResetColor();

// --- 6. Listar los certificados del tenant ---------------------------------

Console.WriteLine();
Console.WriteLine("Certificados del tenant:");

foreach (var info in await almacen.ListarAsync(tenantId))
{
    var marca = info.Activo ? "activo " : "inactivo";
    Console.WriteLine(
        $"  [{marca}] {info.Subject}  vence {info.ValidoHasta:yyyy-MM-dd}  " +
        $"({info.DiasParaVencer} días)");

    if (info.RequiereAlerta())
    {
        Console.ForegroundColor = ConsoleColor.Yellow;
        Console.WriteLine("            ATENCIÓN: vence pronto. Hay que renovarlo.");
        Console.ResetColor();
    }
}
