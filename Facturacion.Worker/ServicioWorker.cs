using Facturacion.Persistencia;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;

namespace Facturacion.Worker;

/// <summary>Ajustes del worker.</summary>
public sealed class OpcionesWorker
{
    /// <summary>Cuántos comprobantes reclama en cada vuelta.</summary>
    public int TamanoLote { get; set; } = 10;

    /// <summary>
    /// Cuántos procesa a la vez en total, sumando todas las empresas.
    ///
    /// Este es el tope GLOBAL, y protege los recursos de la máquina. El tope
    /// POR EMPRESA es otra cosa y vive en tenants.max_concurrencia, porque
    /// SUNAT limita por RUC, no por servidor.
    /// </summary>
    public int Concurrencia { get; set; } = 8;

    /// <summary>Espera cuando no hay trabajo.</summary>
    public TimeSpan EsperaSinTrabajo { get; set; } = TimeSpan.FromSeconds(5);

    /// <summary>
    /// A partir de cuánto tiempo se considera abandonado un comprobante
    /// encolado. Debe ser holgado: más largo que el peor envío lento a SUNAT.
    /// Si fuera corto, dos workers procesarían el mismo y SUNAT recibiría
    /// un duplicado.
    /// </summary>
    public TimeSpan UmbralAbandono { get; set; } = TimeSpan.FromMinutes(10);
}

/// <summary>
/// Toma comprobantes de la cola y los procesa, en bucle.
///
/// POR QUÉ ESTÁ SEPARADO DE LA API: la API acepta peticiones en milisegundos
/// y responde; el worker se pasa segundos esperando a SUNAT. Mezclarlos haría
/// que un SUNAT lento dejara sin hilos a la API y el sistema entero se
/// volviera irresponsivo justo cuando más carga tiene.
///
/// Separados, se escalan por distinto criterio: la API por peticiones por
/// segundo, el worker por profundidad de la cola.
/// </summary>
public sealed class ServicioWorker : BackgroundService
{
    private readonly ColaTrabajos _cola;
    private readonly ProcesadorComprobantes _procesador;
    private readonly SemaforoPorTenant _semaforoTenant;
    private readonly OpcionesWorker _opciones;
    private readonly ILogger<ServicioWorker> _log;

    private DateTime _ultimoRescate = DateTime.MinValue;

    private readonly System.Collections.Concurrent.ConcurrentDictionary<Guid, int> _limites = new();

    public ServicioWorker(
        ColaTrabajos cola,
        ProcesadorComprobantes procesador,
        SemaforoPorTenant semaforoTenant,
        OpcionesWorker opciones,
        ILogger<ServicioWorker> log)
    {
        _cola = cola;
        _procesador = procesador;
        _semaforoTenant = semaforoTenant;
        _opciones = opciones;
        _log = log;
    }

    protected override async Task ExecuteAsync(CancellationToken ct)
    {
        _log.LogInformation(
            "Worker iniciado en {Maquina}. Lote {Lote}, concurrencia global {Concurrencia}. " +
            "El límite por empresa lo define tenants.max_concurrencia.",
            Environment.MachineName, _opciones.TamanoLote, _opciones.Concurrencia);

        while (!ct.IsCancellationRequested)
        {
            try
            {
                await RescatarSiTocaAsync(ct);

                var trabajos = await _cola.ReclamarAsync(_opciones.TamanoLote, ct);

                if (trabajos.Count == 0)
                {
                    // Sin trabajo: esperar antes de volver a preguntar.
                    // Consultar en bucle cerrado castigaría la base sin motivo.
                    await Task.Delay(_opciones.EsperaSinTrabajo, ct);
                    continue;
                }

                _log.LogInformation("Reclamados {Cantidad} comprobantes.", trabajos.Count);

                await ProcesarLoteAsync(trabajos, ct);
            }
            catch (OperationCanceledException) when (ct.IsCancellationRequested)
            {
                break;
            }
            catch (Exception ex)
            {
                // El bucle NUNCA debe morir por un error. Si muere, los
                // comprobantes dejan de procesarse en silencio y nadie se
                // entera hasta que un cliente reclama.
                _log.LogError(ex, "Error en el ciclo del worker. Se reintenta.");

                await Task.Delay(TimeSpan.FromSeconds(10), ct);
            }
        }

        _log.LogInformation("Worker detenido.");
    }

    private async Task ProcesarLoteAsync(
        IReadOnlyList<TrabajoComprobante> trabajos, CancellationToken ct)
    {
        // DOS LÍMITES A LA VEZ, y cada uno protege algo distinto:
        //
        //   Global (este semáforo): protege los recursos de la máquina.
        //                           Sin él, un lote grande abriría cien
        //                           conexiones simultáneas.
        //
        //   Por empresa: protege la relación con SUNAT, que rechaza envíos
        //                simultáneos del mismo RUC, y evita que un cliente
        //                ruidoso deje esperando a los demás.
        using var semaforoGlobal = new SemaphoreSlim(_opciones.Concurrencia);

        var tareas = trabajos.Select(async trabajo =>
        {
            await semaforoGlobal.WaitAsync(ct);

            try
            {
                var limite = await ResolverLimiteAsync(trabajo.TenantId, ct);

                using var turno = await _semaforoTenant.TomarTurnoAsync(
                    trabajo.TenantId, limite, ct);

                await _procesador.ProcesarAsync(trabajo, ct);
            }
            finally
            {
                semaforoGlobal.Release();
            }
        });

        await Task.WhenAll(tareas);
    }

    /// <summary>
    /// Cuántos envíos simultáneos admite esta empresa.
    ///
    /// Se guarda en caché porque se consulta en cada trabajo y cambia muy
    /// rara vez: es un ajuste que hace el operador desde el panel, no algo
    /// que varíe solo.
    /// </summary>
    private async Task<int> ResolverLimiteAsync(Guid tenantId, CancellationToken ct)
    {
        if (_limites.TryGetValue(tenantId, out var limite))
            return limite;

        var tenant = await _cola.ObtenerTenantAsync(tenantId, ct);

        limite = tenant?.MaxConcurrencia ?? 1;

        _limites[tenantId] = limite;

        return limite;
    }

    private async Task RescatarSiTocaAsync(CancellationToken ct)
    {
        if (DateTime.UtcNow - _ultimoRescate < TimeSpan.FromMinutes(1)) return;

        _ultimoRescate = DateTime.UtcNow;

        var rescatados = await _cola.RescatarAbandonadosAsync(
            _opciones.UmbralAbandono, ct);

        if (rescatados > 0)
            _log.LogWarning(
                "Rescatados {Cantidad} comprobantes abandonados. " +
                "Suele indicar que un worker murió a mitad de proceso.",
                rescatados);
    }
}
