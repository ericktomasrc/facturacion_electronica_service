using Facturacion.Cpe;
using Facturacion.Persistencia;
using Facturacion.Worker;
using Microsoft.Extensions.Logging;

// Los secretos se leen del entorno, no de appsettings.json.
ConfiguracionSecretos.CargarArchivoEnv();

var builder = Host.CreateApplicationBuilder(args);

// --- Configuración ---------------------------------------------------------

var cadenaApp = ConfiguracionSecretos.CadenaPostgres(
    "facturacion_app", "FACTURACION_APP_PASSWORD",
    "procesar cada comprobante dentro de la sesión de su empresa");

// El worker necesita DOS conexiones con roles distintos:
//
//   Operador: para reclamar trabajos de todas las empresas. No está sujeto
//             a Row Level Security, porque el worker no es un tenant.
//
//   App:      para procesar cada comprobante dentro de la sesión de SU
//             empresa, con las políticas activas.
//
// Reclamar y procesar con el mismo rol privilegiado sería más simple y
// mucho peor: un error de código podría escribir en la empresa equivocada
// sin que nada lo impida.
var cadenaOperador = ConfiguracionSecretos.CadenaPostgres(
    "facturacion_operador", "FACTURACION_OPERADOR_PASSWORD",
    "reclamar trabajo de todas las empresas");

// El almacén se construye desde la configuración: disco en desarrollo,
// S3 en cuanto se apunte a MinIO o a una nube. El código es el mismo.
var opcionesAlmacen = new OpcionesAlmacen();
builder.Configuration.GetSection("Almacen").Bind(opcionesAlmacen);

if (opcionesAlmacen.Tipo.Equals("s3", StringComparison.OrdinalIgnoreCase))
{
    opcionesAlmacen.Usuario = ConfiguracionSecretos.Exigir(
        "ALMACEN_USUARIO", "el acceso al almacén de comprobantes");

    opcionesAlmacen.Clave = ConfiguracionSecretos.Exigir(
        "ALMACEN_CLAVE", "el acceso al almacén de comprobantes");
}

// --- Servicios -------------------------------------------------------------

builder.Services.AddSingleton(new FabricaSesiones(cadenaApp));
builder.Services.AddSingleton(new ColaTrabajos(cadenaOperador));
builder.Services.AddSingleton<RepositorioComprobantes>();
builder.Services.AddSingleton<IProtectorDeSecretos>(_ => ProtectorAesGcm.DesdeEntorno());
builder.Services.AddSingleton<AlmacenCertificados>();

// Resuelve las credenciales de SUNAT según el ambiente de cada empresa.
// En beta, las de pruebas; en producción, las del contribuyente descifradas.
builder.Services.AddSingleton(proveedor =>
    new ProveedorCredenciales(
        cadenaOperador,
        proveedor.GetRequiredService<IProtectorDeSecretos>()));
builder.Services.AddSingleton(FabricaAlmacen.Crear(opcionesAlmacen));

builder.Services.AddSingleton(new OpcionesWorker
{
    TamanoLote = builder.Configuration.GetValue("Worker:TamanoLote", 10),
    Concurrencia = builder.Configuration.GetValue("Worker:Concurrencia", 4),
    EsperaSinTrabajo = TimeSpan.FromSeconds(
        builder.Configuration.GetValue("Worker:EsperaSegundos", 5))
});

// El semáforo por empresa es singleton a propósito: su estado debe
// compartirse entre todos los lotes, no reiniciarse en cada vuelta.
builder.Services.AddSingleton(new SemaforoPorTenant(limitePorDefecto: 1));

// ESQUEMAS XSD (migración 033): los que se suben en el panel se copian a la
// carpeta de esquemas cada dos minutos, y los avisos se anotan para la pestaña.
builder.Services.AddSingleton(new RepositorioXsd(cadenaOperador));
builder.Services.AddHostedService<SincronizadorXsd>();

builder.Services.AddSingleton<ProcesadorComprobantes>();
builder.Services.AddHostedService<ServicioWorker>();

// --- Resúmenes diarios de boletas -----------------------------------------
//
// Corre como un servicio aparte del worker de facturas porque su ritmo es
// completamente distinto: las facturas se procesan en segundos y los
// resúmenes una vez al día. Mezclarlos obligaría a que el más lento marcara
// el ritmo del más rápido.
builder.Services.AddSingleton(new RepositorioResumenes(cadenaOperador));
builder.Services.AddSingleton<ProcesadorResumenes>();

builder.Services.AddSingleton(proveedor =>
    new RepositorioBajas(
        proveedor.GetRequiredService<FabricaSesiones>(),
        cadenaOperador));

builder.Services.AddSingleton<ProcesadorBajas>();
builder.Services.AddHostedService<ServicioBajas>();

// --- Webhooks --------------------------------------------------------------
//
// Van en su propio servicio porque su fallo NO debe afectar a la facturación:
// que el servidor de un cliente esté caído no puede impedir que las facturas
// de los demás lleguen a SUNAT.
//
// El cliente HTTP de los webhooks NO es uno cualquiera (DestinoWebhook): no
// sigue redirecciones, no usa proxy y solo se conecta a IPs públicas que
// comprueba él mismo al conectar. Desde que una clave fac_ puede registrar su
// webhook, esto es lo que impide que el servicio haga peticiones hacia dentro.
var reglasWebhook = ReglasDestinoWebhook.Resolver(builder.Environment.IsDevelopment());

builder.Services.AddSingleton(reglasWebhook);

builder.Services.AddHttpClient("webhooks")
    .ConfigurePrimaryHttpMessageHandler(() =>
        DestinoWebhook.CrearManejador(reglasWebhook.PermitirLocales));

builder.Services.AddSingleton(new RepositorioWebhooks(cadenaOperador));
builder.Services.AddSingleton<DespachadorWebhooks>();

builder.Services.AddSingleton<IHostedService>(proveedor =>
    new ServicioWebhooks(
        proveedor.GetRequiredService<DespachadorWebhooks>(),
        proveedor.GetRequiredService<ILogger<ServicioWebhooks>>(),
        TimeSpan.FromSeconds(
            builder.Configuration.GetValue("Webhooks:IntervaloSegundos", 10))));

builder.Services.AddSingleton<IHostedService>(proveedor =>
    new ServicioResumenes(
        proveedor.GetRequiredService<ProcesadorResumenes>(),
        proveedor.GetRequiredService<ILogger<ServicioResumenes>>(),
        TimeSpan.FromSeconds(
            builder.Configuration.GetValue("Resumenes:IntervaloSegundos", 60))));

builder.Services.AddSingleton(proveedor =>
    new RepositorioGuias(
        proveedor.GetRequiredService<FabricaSesiones>(),
        cadenaOperador));

builder.Services.AddSingleton<ProcesadorGuias>();
builder.Services.AddHostedService<ServicioGuias>();

// LA RUTA POR DEFECTO ES LA CARPETA DEL PROPIO EJECUTABLE, y así no hay que
// configurarla en ningún ambiente: los esquemas se copian al compilar y
// están donde corre el proceso, sea tu máquina o un contenedor.
//
// La variable de entorno queda solo por si algún día hace falta apuntar a
// otro sitio.
ValidacionPrevia.Ruta = ConfiguracionSecretos.Opcional(
    "FACTURACION_XSD_RUTA",
    Path.Combine(AppContext.BaseDirectory, "xsd"));

ValidacionPrevia.Bloquea = ConfiguracionSecretos
    .Opcional("FACTURACION_XSD_BLOQUEA", "false")
    .Equals("true", StringComparison.OrdinalIgnoreCase);

// REGLAS DE SUNAT DE 2027 (14 oct 2026): desde qué fecha se generan los
// documentos con ellas. La oficial es el 2027-01-01; SUNAT ya la postergó una
// vez, así que se puede cambiar aquí sin tocar el código. Ver VigenciaSunat.
if (DateTime.TryParseExact(
        ConfiguracionSecretos.Opcional("SUNAT_REGLAS_2027_DESDE", ""),
        "yyyy-MM-dd", System.Globalization.CultureInfo.InvariantCulture,
        System.Globalization.DateTimeStyles.None, out var reglas2027))
{
    VigenciaSunat.Reglas2027Desde = reglas2027;
}

var host = builder.Build();

// SE DICE AL ARRANCAR QUÉ SE VA A COMPROBAR Y QUÉ NO. El modo de fallo de
// esto es el silencio: si la ruta está mal, no valida nada y nadie se entera.
host.Services.GetRequiredService<ILoggerFactory>()
    .CreateLogger("ValidacionPrevia")
    .LogInformation("{Diagnostico}", ValidacionPrevia.Diagnostico());

host.Services.GetRequiredService<ILoggerFactory>()
    .CreateLogger("ReglasSunat")
    .LogInformation("{Diagnostico}", VigenciaSunat.Diagnostico());

// Lo mismo con los destinos de webhook: si el worker no está en Development,
// el webhook de la plataforma en http://localhost se bloquea, y conviene
// verlo aquí y no adivinarlo en las entregas agotadas.
host.Services.GetRequiredService<ILoggerFactory>()
    .CreateLogger("Webhooks")
    .LogInformation("{Diagnostico} Entorno: {Entorno}.",
        ReglasDestinoWebhook.Diagnostico(builder.Environment.IsDevelopment()),
        builder.Environment.EnvironmentName);

host.Run();