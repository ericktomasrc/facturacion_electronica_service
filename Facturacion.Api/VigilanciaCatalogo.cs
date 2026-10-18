using System.Security.Cryptography;
using Facturacion.Cpe;
using Facturacion.Persistencia;
using Npgsql;

namespace Facturacion.Api;

/// <summary>Cómo fue una comparación del catálogo.</summary>
public sealed record ResultadoCatalogo(bool Exito, bool Igual, int Agregados, int Quitados, string Mensaje);

/// <summary>
/// VIGILANCIA SUNAT, PARTE 3: EL CATÁLOGO DE CÓDIGOS DE PRODUCTO (migración 031).
///
/// ══════════════════════════════════════════════════════════════════════════
/// EL HUECO QUE CIERRA. La plataforma lleva una copia del catálogo 25 de
/// SUNAT para su buscador. Si SUNAT quita un código y la copia sigue
/// teniéndolo, alguien puede guardar un producto con él, y desde 2027 sus
/// comprobantes se rechazan (ERR-3496).
///
/// POR QUÉ SE SUBE A MANO (14/10/2026). La primera versión descargaba el
/// Excel sola cada día, pero el portal de SUNAT responde 403 a todo lo que no
/// sea un navegador de verdad —también a su propia página—, aunque se
/// presente como navegador. No se intenta burlar ese bloqueo. Así que:
///
///   · Alguien baja el Excel con su navegador y lo SUBE en el panel; aquí se
///     lee y se compara código por código con la lista de la plataforma.
///   · Si no coinciden, UNA alerta por cada lista distinta, con los códigos
///     agregados y quitados (la manda por correo la vuelta de 5 minutos).
///   · CADA 30 DÍAS SIN COMPARAR, un recordatorio por correo. Callarse sería
///     lo peor: parecería que todo está al día.
///
/// QUÉ NO HACE: no cambia el catálogo de la plataforma solo. Eso se regenera
/// desde el Excel, revisando qué cambió.
/// ══════════════════════════════════════════════════════════════════════════
/// </summary>
public sealed class VigilanciaCatalogo
{
    /// <summary>Cada cuánto se recuerda bajar el Excel y compararlo.</summary>
    public static readonly TimeSpan RecordarCada = TimeSpan.FromDays(30);

    /// <summary>Más que esto no es el catálogo (hoy pesa 3,8 MB).</summary>
    public const int MaximoBytes = 30 * 1024 * 1024;

    private readonly RepositorioCatalogoSunat _repo;
    private readonly ILogger<VigilanciaCatalogo> _log;
    private readonly SemaphoreSlim _uno = new(1, 1);

    public VigilanciaCatalogo(RepositorioCatalogoSunat repo, ILogger<VigilanciaCatalogo> log)
    {
        _repo = repo;
        _log = log;
    }

    /// <summary>
    /// Compara el Excel subido con la lista de la plataforma. Un archivo que no
    /// es el catálogo NO cuenta como comparación: se devuelve el motivo y no se
    /// anota nada.
    /// </summary>
    public async Task<ResultadoCatalogo> CompararAsync(byte[] archivo, string quien, CancellationToken ct)
    {
        if (!await _uno.WaitAsync(0, ct))
            return new ResultadoCatalogo(false, false, 0, 0, "Ya se está comparando otro archivo. Espera unos segundos.");

        try
        {
            IReadOnlySet<string> deSunat;
            try { deSunat = LectorCatalogoXlsx.Leer(archivo); }
            catch (FormatException ex)
            {
                return new ResultadoCatalogo(false, false, 0, 0,
                    "Ese archivo no es el catálogo de SUNAT: " + ex.Message);
            }

            var dif = CatalogoProductosSunat.Comparar(deSunat);
            var huella = CatalogoProductosSunat.Huella(deSunat);

            var nueva = await _repo.RegistrarExitoAsync(
                huella, deSunat.Count, dif.Agregados.Count, dif.Quitados.Count,
                Muestra(dif.Agregados), Muestra(dif.Quitados),
                Convert.ToHexString(SHA256.HashData(archivo)).ToLowerInvariant(),
                archivo.LongLength, $"subido por {quien}", ct);

            _log.LogInformation(
                "Catálogo de productos SUNAT: {Quien} subió el Excel ({Codigos} códigos; {Agregados} agregados, {Quitados} quitados).",
                quien, deSunat.Count, dif.Agregados.Count, dif.Quitados.Count);

            if (dif.Igual)
                return new ResultadoCatalogo(true, true, 0, 0,
                    $"Al día: el Excel trae los mismos {deSunat.Count:N0} códigos que usa la plataforma.");

            if (nueva)
                await _repo.CrearAlertaAsync(
                    "catalogo_cambio",
                    "problema",
                    "SUNAT cambió el catálogo de códigos de producto",
                    DetalleCambio(deSunat.Count, dif, quien),
                    esFalla: false, ct);

            return new ResultadoCatalogo(true, false, dif.Agregados.Count, dif.Quitados.Count,
                $"SUNAT cambió la lista: {dif.Agregados.Count} código(s) agregado(s) y " +
                $"{dif.Quitados.Count} quitado(s). Hay que regenerar el catálogo de la plataforma." +
                (nueva ? " Se avisó por correo." : ""));
        }
        finally
        {
            _uno.Release();
        }
    }

    /// <summary>
    /// El recordatorio: si hace más de 30 días que nadie compara (o desde que
    /// se instaló), y no se recordó en los últimos 30 días, una alerta.
    /// </summary>
    public async Task<bool> RecordarSiTocaAsync(CancellationToken ct)
    {
        var estado = await _repo.IniciarAsync(ct);
        var desde = (estado.UltimoExitoEn ?? estado.CreadoEn).ToUniversalTime();

        if (DateTime.UtcNow - desde < RecordarCada) return false;

        var ultimo = await _repo.UltimoRecordatorioAsync(ct);
        if (ultimo is { } u && DateTime.UtcNow - u.ToUniversalTime() < RecordarCada) return false;

        await _repo.CrearAlertaAsync(
            "catalogo_recordatorio",
            "atencion",
            "Toca comparar el catálogo de códigos de producto de SUNAT",
            (estado.UltimoExitoEn is { } e
                ? $"La última comparación fue el {e:yyyy-MM-dd}."
                : "Todavía no se comparó nunca.") + "\n" +
            $"Qué hacer: bajar el Excel con el navegador desde {CatalogoProductosSunat.UrlPagina} " +
            "(«Catálogo de Producto») y subirlo en el panel, pestaña Vigilancia SUNAT → «Catálogo de " +
            "productos SUNAT». Tarda un minuto. Si SUNAT quitó algún código, desde 2027 los " +
            "comprobantes que lo lleven se rechazan.",
            esFalla: false, ct);

        _log.LogInformation("Catálogo de productos SUNAT: se recordó compararlo (desde {Desde:yyyy-MM-dd}).", desde);
        return true;
    }

    private static string DetalleCambio(int deSunat, DiferenciaCatalogo dif, string quien) =>
        $"El Excel que subió {quien} trae {deSunat:N0} códigos; la plataforma usa " +
        $"{CatalogoProductosSunat.CantidadEnUso:N0} ({CatalogoProductosSunat.VersionEnUso}).\n" +
        $"Agregados: {dif.Agregados.Count}{(dif.Agregados.Count > 0 ? " · " + Muestra(dif.Agregados) : "")}\n" +
        $"Quitados: {dif.Quitados.Count}{(dif.Quitados.Count > 0 ? " · " + Muestra(dif.Quitados) : "")}\n" +
        (dif.Quitados.Count > 0
            ? "Un producto con un código quitado hace rechazar sus comprobantes desde 2027 (ERR-3496).\n"
            : "") +
        "Qué hacer: regenerar con ese Excel el catálogo de la plataforma (CatalogoSunatDatos.cs) y la " +
        "lista del servicio (CatalogoProductosSunat.cs). Después, revisar los productos que tengan un " +
        "código quitado.";

    /// <summary>Los primeros 30, separados por coma. Null si no hay.</summary>
    private static string? Muestra(IReadOnlyList<string> codigos) =>
        codigos.Count == 0 ? null
        : string.Join(", ", codigos.Take(30)) + (codigos.Count > 30 ? $" y {codigos.Count - 30} más" : "");
}


/// <summary>
/// El reloj del recordatorio: mira cada 6 horas si toca recordar. La fecha
/// sale de la base, así que reiniciar la API no lo repite.
/// </summary>
public sealed class ServicioVigilanciaCatalogo : BackgroundService
{
    private readonly VigilanciaCatalogo _vigilancia;
    private readonly ILogger<ServicioVigilanciaCatalogo> _log;

    public ServicioVigilanciaCatalogo(VigilanciaCatalogo vigilancia, ILogger<ServicioVigilanciaCatalogo> log)
    {
        _vigilancia = vigilancia;
        _log = log;
    }

    protected override async Task ExecuteAsync(CancellationToken ct)
    {
        try { await Task.Delay(TimeSpan.FromMinutes(3), ct); }
        catch (OperationCanceledException) { return; }

        var avisoMigracion = false;

        while (!ct.IsCancellationRequested)
        {
            try
            {
                await _vigilancia.RecordarSiTocaAsync(ct);
            }
            catch (PostgresException ex) when (ex.SqlState == "42P01")
            {
                if (!avisoMigracion)
                    _log.LogWarning("Catálogo de productos SUNAT: falta aplicar la migración 031; no se recuerda.");
                avisoMigracion = true;
            }
            catch (OperationCanceledException) when (ct.IsCancellationRequested) { return; }
            catch (Exception ex)
            {
                _log.LogError(ex, "Falló el recordatorio del catálogo de productos SUNAT. Se reintenta más tarde.");
            }

            try { await Task.Delay(TimeSpan.FromHours(6), ct); }
            catch (OperationCanceledException) { return; }
        }
    }
}