using Facturacion.Persistencia;
using Facturacion.Worker;
using Microsoft.Extensions.Logging;

var builder = Host.CreateApplicationBuilder(args);

// --- Configuración ---------------------------------------------------------

var cadenaApp = builder.Configuration.GetConnectionString("Facturacion")
    ?? throw new InvalidOperationException("Falta la cadena 'Facturacion'.");

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
var cadenaOperador = builder.Configuration.GetConnectionString("FacturacionOperador")
    ?? throw new InvalidOperationException("Falta la cadena 'FacturacionOperador'.");

var carpetaAlmacen = builder.Configuration["Almacen:Carpeta"] ?? "almacen";

// --- Servicios -------------------------------------------------------------

builder.Services.AddSingleton(new FabricaSesiones(cadenaApp));
builder.Services.AddSingleton(new ColaTrabajos(cadenaOperador));
builder.Services.AddSingleton<RepositorioComprobantes>();
builder.Services.AddSingleton<IProtectorDeSecretos>(_ => ProtectorAesGcm.DesdeEntorno());
builder.Services.AddSingleton<AlmacenCertificados>();
builder.Services.AddSingleton<IAlmacenArchivos>(
    _ => new AlmacenArchivosDisco(carpetaAlmacen));

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

builder.Services.AddSingleton<IHostedService>(proveedor =>
    new ServicioResumenes(
        proveedor.GetRequiredService<ProcesadorResumenes>(),
        proveedor.GetRequiredService<ILogger<ServicioResumenes>>(),
        TimeSpan.FromSeconds(
            builder.Configuration.GetValue("Resumenes:IntervaloSegundos", 60))));

var host = builder.Build();
host.Run();
