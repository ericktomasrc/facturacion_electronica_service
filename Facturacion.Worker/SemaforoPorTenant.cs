using System.Collections.Concurrent;

namespace Facturacion.Worker;

/// <summary>
/// Limita cuántos envíos simultáneos puede tener cada empresa.
///
/// RESUELVE DOS PROBLEMAS DISTINTOS CON EL MISMO MECANISMO:
///
/// 1. SUNAT NO ACEPTA PETICIONES SIMULTÁNEAS DEL MISMO RUC.
///    Si se le envían dos a la vez, acepta una y a la otra le devuelve un
///    401 que parece un problema de credenciales pero es una limitación de
///    tasa. Descubrimos esto en pruebas, y sin un mensaje de error honesto
///    habría parecido que el servicio estaba caído.
///
/// 2. UNA EMPRESA NO DEBE AHOGAR A LAS DEMÁS.
///    Si un cliente descarga cuarenta mil boletas de golpe, sin este límite
///    se comería todos los workers y las otras empresas quedarían esperando
///    detrás. Con el tope, avanza a su ritmo sin bloquear a nadie.
///
/// El límite es POR EMPRESA, no global: veinte empresas pueden enviar a la
/// vez, pero cada una de a uno. Así el sistema escala con el número de
/// clientes sin pelearse con SUNAT.
/// </summary>
public sealed class SemaforoPorTenant : IDisposable
{
    private readonly ConcurrentDictionary<Guid, SemaphoreSlim> _semaforos = new();
    private readonly int _porDefecto;

    public SemaforoPorTenant(int limitePorDefecto = 1)
    {
        _porDefecto = Math.Max(1, limitePorDefecto);
    }

    /// <summary>
    /// Espera turno para esta empresa y devuelve un objeto que lo libera
    /// al desecharse.
    /// </summary>
    public async Task<IDisposable> TomarTurnoAsync(
        Guid tenantId, int limite, CancellationToken ct)
    {
        var semaforo = _semaforos.GetOrAdd(
            tenantId,
            _ => new SemaphoreSlim(limite > 0 ? limite : _porDefecto));

        await semaforo.WaitAsync(ct);

        return new Turno(semaforo);
    }

    private sealed class Turno : IDisposable
    {
        private readonly SemaphoreSlim _semaforo;
        private bool _liberado;

        public Turno(SemaphoreSlim semaforo) => _semaforo = semaforo;

        public void Dispose()
        {
            // Liberar dos veces desbalancearía el semáforo y dejaría pasar
            // más trabajos de los permitidos.
            if (_liberado) return;

            _liberado = true;
            _semaforo.Release();
        }
    }

    public void Dispose()
    {
        foreach (var semaforo in _semaforos.Values)
            semaforo.Dispose();

        _semaforos.Clear();
    }
}
