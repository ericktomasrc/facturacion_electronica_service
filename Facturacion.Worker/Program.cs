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

// --- Webhooks --------------------------------------------------------------
//
// Van en su propio servicio porque su fallo NO debe afectar a la facturación:
// que el servidor de un cliente esté caído no puede impedir que las facturas
// de los demás lleguen a SUNAT.
builder.Services.AddHttpClient("webhooks");
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

var host = builder.Build();
host.Run();
