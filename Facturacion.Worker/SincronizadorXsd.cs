using System.Text.Json;
using Facturacion.Cpe;
using Facturacion.Persistencia;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;

namespace Facturacion.Worker;

/// <summary>
/// LOS ESQUEMAS XSD SUBIDOS DESDE EL PANEL, EN LA CARPETA DEL WORKER
/// (migración 033).
///
/// Cada dos minutos mira si cambió lo subido (una huella de la tabla). Si
/// cambió, copia los archivos a la carpeta de esquemas (ValidacionPrevia.Ruta)
/// y olvida los validadores ya compilados: el siguiente comprobante usa los
/// moldes nuevos, sin reiniciar. Al arrancar copia siempre, por si la carpeta
/// se limpió al compilar.
///
/// Y CUENTA LO QUE TIENE DE VERDAD (xsd_estado): qué moldes encontró en su
/// carpeta. La pestaña enseña eso, no lo que se supone que se subió.
/// </summary>
public sealed class SincronizadorXsd(RepositorioXsd repo, ILogger<SincronizadorXsd> log) : BackgroundService
{
    private static readonly TimeSpan Ciclo = TimeSpan.FromMinutes(2);
    private static readonly TimeSpan InformarCada = TimeSpan.FromHours(1);

    private static readonly JsonSerializerOptions Json = new() { PropertyNamingPolicy = JsonNamingPolicy.CamelCase };

    private string? _copiada;
    private DateTime _ultimoInforme = DateTime.MinValue;
    private bool _avisadoSinMigracion;
    private bool _avisadoSinRuta;

    protected override async Task ExecuteAsync(CancellationToken ct)
    {
        try { await Task.Delay(TimeSpan.FromSeconds(10), ct); }
        catch (OperationCanceledException) { return; }

        while (!ct.IsCancellationRequested)
        {
            try
            {
                await SincronizarAsync(ct);
            }
            catch (Npgsql.PostgresException ex) when (ex.SqlState == "42P01")
            {
                if (!_avisadoSinMigracion)
                    log.LogWarning("Esquemas XSD: falta aplicar la migración 033; no se sincronizan.");
                _avisadoSinMigracion = true;
            }
            catch (OperationCanceledException) when (ct.IsCancellationRequested) { return; }
            catch (Exception ex)
            {
                log.LogError(ex, "Esquemas XSD: falló la sincronización. Se reintenta en {Ciclo}.", Ciclo);
            }

            try { await Task.Delay(Ciclo, ct); }
            catch (OperationCanceledException) { return; }
        }
    }

    private async Task SincronizarAsync(CancellationToken ct)
    {
        if (string.IsNullOrWhiteSpace(ValidacionPrevia.Ruta))
        {
            if (!_avisadoSinRuta)
                log.LogWarning("Esquemas XSD: no hay carpeta de esquemas (FACTURACION_XSD_RUTA); no se copian.");
            _avisadoSinRuta = true;
            return;
        }

        var huella = await repo.HuellaAsync(ct);
        var cambio = huella != _copiada;

        if (cambio && huella.Length > 0)
        {
            var archivos = await repo.LeerTodosAsync(ct);
            var raiz = Path.TrimEndingDirectorySeparator(Path.GetFullPath(ValidacionPrevia.Ruta));
            var fallos = 0;

            foreach (var a in archivos)
            {
                var destino = Path.GetFullPath(Path.Combine(raiz, a.Ruta));

                // La ruta ya la limita la base (maindoc/ o common/ y un nombre
                // simple), pero se comprueba otra vez: nada fuera de la carpeta.
                if (!destino.StartsWith(raiz + Path.DirectorySeparatorChar, StringComparison.Ordinal))
                {
                    log.LogWarning("Esquemas XSD: se ignora {Ruta}, sale de la carpeta.", a.Ruta);
                    fallos++;
                    continue;
                }

                try
                {
                    Directory.CreateDirectory(Path.GetDirectoryName(destino)!);

                    // Primero a un temporal y luego se cambia: un validador que
                    // esté leyendo nunca ve un archivo a medias.
                    var temporal = destino + ".tmp";
                    await File.WriteAllBytesAsync(temporal, a.Contenido, ct);
                    File.Move(temporal, destino, overwrite: true);
                }
                catch (IOException ex)
                {
                    // En Windows, un archivo abierto por otro no se reemplaza.
                    // Se vuelve a intentar en la vuelta siguiente.
                    log.LogWarning("Esquemas XSD: no se pudo copiar {Ruta} ({Motivo}). Se reintenta.", a.Ruta, ex.Message);
                    fallos++;
                }
            }

            ValidacionPrevia.Recargar();

            log.LogInformation("Esquemas XSD: {Copiados} de {Total} archivo(s) subidos desde el panel, copiados a {Ruta}.",
                               archivos.Count - fallos, archivos.Count, raiz);

            // Si alguno no se copió, no se da por hecho: la próxima vuelta lo intenta otra vez.
            if (fallos > 0) huella = _copiada ?? "";
        }

        _copiada = huella;

        if (cambio || DateTime.UtcNow - _ultimoInforme > InformarCada)
        {
            var moldes = ValidacionPrevia.Moldes()
                .Select(m => new { m.Raiz, m.Archivo, m.Cargado });

            await repo.InformarEstadoAsync(
                Environment.MachineName, JsonSerializer.Serialize(moldes, Json),
                ValidacionPrevia.Bloquea, huella, ct);

            _ultimoInforme = DateTime.UtcNow;
        }
    }
}


/// <summary>
/// Compara un XML con su molde, lo dice en el log y lo anota para la pestaña
/// «Esquemas XSD». Lo usan los tres procesadores que firman: comprobantes,
/// resúmenes y bajas.
///
/// ANOTAR NUNCA PARA UNA EMISIÓN: si la base no responde, se dice en el log y
/// el documento sigue su camino.
/// </summary>
public static class RevisionXsdWorker
{
    public static async Task<RevisionXsd> RevisarYAnotarAsync(
        RepositorioXsd repo, ILogger log, Guid? tenantId, string? ruc,
        string documento, byte[] xml, CancellationToken ct)
    {
        var r = ValidacionPrevia.ComprobarDetallado(xml);

        if (r.Cumple) return r;

        log.LogWarning(
            "{Documento}: el XML no cumple el esquema de SUNAT ({Esquema}). {Problemas}",
            documento, r.Esquema ?? "sin esquema",
            string.Join(" | ", r.Errores.Select(e => e.ToString())));

        try
        {
            await repo.AnotarAsync(
                tenantId, ruc, documento, r.Raiz, r.Esquema,
                r.Errores
                    .Select(e => new ErrorXsdNuevo(e.Linea, e.Posicion, ExplicadorXsd.Explicar(e.Mensaje), e.Mensaje))
                    .ToList(),
                ct);
        }
        catch (Exception ex) when (!ct.IsCancellationRequested)
        {
            log.LogWarning(ex, "{Documento}: no se pudo anotar el aviso del esquema (¿falta la migración 033?).",
                           documento);
        }

        return r;
    }
}