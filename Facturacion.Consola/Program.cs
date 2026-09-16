// Prueba del canal REST de guías de remisión.
//
// Los tres bytes son basura a propósito: si el error habla del ZIP, es que
// el token, la autenticación y el envío funcionaron. Es lo único que se
// puede comprobar hasta que exista el generador de XML.
//
// El RUC termina en 5 porque lo exige el simulador, no SUNAT.

using Facturacion.Cpe;

var config = ConfiguracionGre.Beta("20601234565");

using var cliente = new ClienteGre(config);

var resultado = await cliente.EnviarAsync(
    "20601234565-09-T001-1.zip", new byte[] { 1, 2, 3 });

Console.WriteLine($"Exitoso : {resultado.Exitoso}");
Console.WriteLine($"HTTP    : {resultado.CodigoHttp}");
Console.WriteLine($"Mensaje : {resultado.Mensaje}");






//using System.Diagnostics;
//using Facturacion.Cpe;
//using Facturacion.Persistencia;

//// ---------------------------------------------------------------------------
//// Prueba el repositorio de comprobantes, con foco en lo que de verdad importa:
////
////   1. Que 50 emisiones SIMULTÁNEAS no produzcan correlativos duplicados
////      ni saltados.
////   2. Que la idempotencia evite duplicados por reintentos.
////   3. Que la bitácora registre cada cambio de estado.
////
//// El primer punto es la razón de ser de este paso. Un duplicado de correlativo
//// no es un bug: es un problema tributario.
//// ---------------------------------------------------------------------------

//// La contraseña sale del entorno, no del código.
////
//// Es un programa de pruebas, pero la regla vale igual: una contraseña
//// escrita aquí queda en el historial de Git para siempre.
//ConfiguracionSecretos.CargarArchivoEnv();

//string CadenaConexion = ConfiguracionSecretos.CadenaPostgres(
//    "facturacion_app", "FACTURACION_APP_PASSWORD",
//    "las pruebas contra la base desde la consola");

//const string RucEmisor = "20601234567";

//var sesiones = new FabricaSesiones(CadenaConexion);
//var repositorio = new RepositorioComprobantes(sesiones);

//// --- Resolver el tenant ----------------------------------------------------

//Guid tenantId;

//await using (var catalogo = await sesiones.AbrirCatalogoAsync())
//{
//    var comando = new Npgsql.NpgsqlCommand(
//        "SELECT id FROM tenants WHERE ruc = @ruc", catalogo);

//    comando.Parameters.AddWithValue("ruc", RucEmisor);

//    var resultado = await comando.ExecuteScalarAsync();

//    if (resultado is null)
//    {
//        Console.WriteLine("No se encontró el tenant. ¿Corriste las migraciones?");
//        return;
//    }

//    tenantId = (Guid)resultado;
//}

//Console.WriteLine($"Tenant: {tenantId}");
//Console.WriteLine();

//// --- Dar de alta la serie --------------------------------------------------

//await repositorio.AsegurarSerieAsync(tenantId, TipoComprobante.Factura, "F001");

//// ===========================================================================
//// PRUEBA 1: 50 emisiones simultáneas
//// ===========================================================================

//Console.WriteLine(new string('=', 60));
//Console.WriteLine("PRUEBA 1: 50 emisiones simultáneas");
//Console.WriteLine(new string('=', 60));

//const int Simultaneas = 50;

//var cronometro = Stopwatch.StartNew();

//var tareas = Enumerable.Range(1, Simultaneas).Select(async i =>
//{
//    try
//    {
//        return await repositorio.CrearAsync(tenantId, NuevaFactura($"ITEM-{i:D3}"));
//    }
//    catch (Exception ex)
//    {
//        Console.WriteLine($"  Falló la emisión {i}: {ex.Message}");
//        return null;
//    }
//});

//var resultados = (await Task.WhenAll(tareas))
//    .Where(r => r is not null)
//    .Select(r => r!)
//    .ToList();

//cronometro.Stop();

//Console.WriteLine($"Emitidas      : {resultados.Count} de {Simultaneas}");
//Console.WriteLine($"Duración      : {cronometro.ElapsedMilliseconds} ms");

//var correlativos = resultados.Select(r => r.Correlativo).OrderBy(c => c).ToList();

//var duplicados = correlativos
//    .GroupBy(c => c)
//    .Where(g => g.Count() > 1)
//    .Select(g => g.Key)
//    .ToList();

//var rangoEsperado = correlativos.Count == 0
//    ? 0
//    : correlativos[^1] - correlativos[0] + 1;

//var huecos = rangoEsperado - correlativos.Count;

//Console.WriteLine($"Rango         : {correlativos.FirstOrDefault()} a {correlativos.LastOrDefault()}");

//Console.ForegroundColor = duplicados.Count == 0 ? ConsoleColor.Green : ConsoleColor.Red;
//Console.WriteLine(duplicados.Count == 0
//    ? "Duplicados    : ninguno"
//    : $"DUPLICADOS    : {string.Join(", ", duplicados)}");
//Console.ResetColor();

//Console.ForegroundColor = huecos == 0 ? ConsoleColor.Green : ConsoleColor.Yellow;
//Console.WriteLine(huecos == 0
//    ? "Huecos        : ninguno"
//    : $"Huecos        : {huecos} (correlativos quemados por fallos)");
//Console.ResetColor();

//// ===========================================================================
//// PRUEBA 2: idempotencia
//// ===========================================================================

//Console.WriteLine();
//Console.WriteLine(new string('=', 60));
//Console.WriteLine("PRUEBA 2: idempotencia");
//Console.WriteLine(new string('=', 60));

//var clave = $"prueba-{Guid.NewGuid()}";

//var primera = await repositorio.CrearAsync(
//    tenantId, NuevaFactura("IDEMPOTENTE"), idempotencyKey: clave);

//Console.WriteLine($"Primera vez   : {primera.NumeroCompleto}  (nueva: {!primera.YaExistia})");

//// Mismo envío otra vez, como si el cliente hubiera reintentado tras un timeout.
//var segunda = await repositorio.CrearAsync(
//    tenantId, NuevaFactura("IDEMPOTENTE"), idempotencyKey: clave);

//Console.WriteLine($"Reintento     : {segunda.NumeroCompleto}  (nueva: {!segunda.YaExistia})");

//var mismoComprobante = primera.Id == segunda.Id;

//Console.ForegroundColor = mismoComprobante ? ConsoleColor.Green : ConsoleColor.Red;
//Console.WriteLine(mismoComprobante
//    ? "El reintento devolvió el mismo comprobante. Sin duplicado."
//    : "PROBLEMA: el reintento creó un comprobante nuevo.");
//Console.ResetColor();

//// ===========================================================================
//// PRUEBA 3: bitácora
//// ===========================================================================

//Console.WriteLine();
//Console.WriteLine(new string('=', 60));
//Console.WriteLine("PRUEBA 3: bitácora de estados");
//Console.WriteLine(new string('=', 60));

//var seguimiento = resultados.First();

//await repositorio.RegistrarCambioAsync(tenantId, seguimiento.Id,
//    new CambioEstado(EstadoCpe.Firmado, Mensaje: "XML firmado."));

//await repositorio.RegistrarCambioAsync(tenantId, seguimiento.Id,
//    new CambioEstado(EstadoCpe.Enviado, Mensaje: "Enviado a SUNAT.",
//        DuracionMs: 2840));

//await repositorio.RegistrarCambioAsync(tenantId, seguimiento.Id,
//    new CambioEstado(EstadoCpe.Aceptado,
//        CodigoSunat: "0",
//        Mensaje: "La Factura ha sido aceptada",
//        DuracionMs: 120));

//Console.WriteLine($"Comprobante   : {seguimiento.NumeroCompleto}");
//Console.WriteLine();

//foreach (var intento in await repositorio.HistorialAsync(tenantId, seguimiento.Id))
//{
//    var duracion = intento.DuracionMs is null ? "" : $"  ({intento.DuracionMs} ms)";

//    Console.WriteLine(
//        $"  {intento.IntentoNro}. {intento.EstadoAnterior ?? "—"} → " +
//        $"{intento.EstadoNuevo}{duracion}");
//    Console.WriteLine($"     {intento.Mensaje}");
//}

//// --- Estado final ----------------------------------------------------------

//Console.WriteLine();
//Console.WriteLine("Últimos comprobantes:");

//foreach (var r in await repositorio.ListarAsync(tenantId, limite: 5))
//    Console.WriteLine($"  {r.NumeroCompleto}  {r.Estado,-28}  {r.ImporteTotal:N2} {r.Moneda}");

//// ---------------------------------------------------------------------------

//static Factura NuevaFactura(string descripcion) => new()
//{
//    Serie = "F001",
//    // Sin correlativo: lo asigna la base.
//    FechaEmision = DateTime.Now,
//    Emisor = new Emisor
//    {
//        Ruc = RucEmisor,
//        RazonSocial = "MI EMPRESA SAC",
//        Direccion = "AV. EJEMPLO 123",
//        Distrito = "LIMA",
//        Provincia = "LIMA",
//        Departamento = "LIMA"
//    },
//    Receptor = new Receptor
//    {
//        TipoDocumento = TipoDocIdentidad.Ruc,
//        NumeroDocumento = "20512345678",
//        RazonSocial = "CLIENTE DE PRUEBA SAC"
//    },
//    Lineas =
//    [
//        new LineaComprobante
//        {
//            Numero = 1,
//            Descripcion = descripcion,
//            Cantidad = 2,
//            ValorUnitario = 50.00m
//        }
//    ]
//};
