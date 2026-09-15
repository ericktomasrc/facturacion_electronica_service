using System.Diagnostics;
using System.Security.Cryptography;
using System.Text;
using Facturacion.Persistencia;

namespace Facturacion.Worker;

/// <summary>
/// Entrega los avisos a los sistemas de los clientes.
///
/// CÓMO SE FIRMA CADA ENVÍO, Y POR QUÉ IMPORTA:
///
/// La URL de un webhook es pública: está abierta a internet esperando
/// peticiones. Si no se firmara nada, cualquiera que la descubriera podría
/// enviarle al cliente un aviso falso diciendo que una factura de diez mil
/// soles fue aceptada.
///
/// Por eso cada envío lleva dos cabeceras:
///
///   X-Facturacion-Timestamp   momento del envío
///   X-Facturacion-Firma       HMAC-SHA256 de "timestamp.cuerpo"
///
/// El cliente recalcula ese HMAC con el secreto que le dimos y compara. Si
/// no coincide, descarta el mensaje.
///
/// El timestamp entra en la firma a propósito: sin él, alguien que capturara
/// un aviso legítimo podría reenviarlo tal cual más tarde y el cliente lo
/// daría por bueno. Con él, basta rechazar los mensajes demasiado viejos.
/// </summary>
public sealed class DespachadorWebhooks
{
    /// <summary>
    /// Tras estos intentos la entrega se da por perdida.
    ///
    /// Con la escalera de espera, ocho intentos cubren varias horas. Si el
    /// servidor del cliente sigue caído después de eso, insistir no ayuda:
    /// el problema es suyo y alguien tiene que avisarle.
    /// </summary>
    public const int MaximoIntentos = 8;

    private readonly RepositorioWebhooks _webhooks;
    private readonly HttpClient _http;
    private readonly ILogger<DespachadorWebhooks> _log;

    public DespachadorWebhooks(
        RepositorioWebhooks webhooks,
        IHttpClientFactory fabricaHttp,
        ILogger<DespachadorWebhooks> log)
    {
        _webhooks = webhooks;
        _log = log;

        _http = fabricaHttp.CreateClient("webhooks");

        // Un cliente lento no debe retener el despachador. Diez segundos es
        // generoso para recibir un aviso y responder.
        _http.Timeout = TimeSpan.FromSeconds(10);
    }

    public async Task DespacharAsync(CancellationToken ct)
    {
        var entregas = await _webhooks.ReclamarAsync(ct: ct);

        if (entregas.Count == 0) return;

        // Se despachan en paralelo con un tope: un cliente lento no debe
        // retrasar los avisos de los demás.
        using var semaforo = new SemaphoreSlim(5);

        await Task.WhenAll(entregas.Select(async entrega =>
        {
            await semaforo.WaitAsync(ct);

            try { await EntregarAsync(entrega, ct); }
            finally { semaforo.Release(); }
        }));
    }

    private async Task EntregarAsync(EntregaPendiente entrega, CancellationToken ct)
    {
        var cronometro = Stopwatch.StartNew();

        try
        {
            var marca = DateTimeOffset.UtcNow.ToUnixTimeSeconds().ToString();
            var firma = Firmar(marca, entrega.Cuerpo, entrega.Secreto);

            using var peticion = new HttpRequestMessage(HttpMethod.Post, entrega.Url)
            {
                Content = new StringContent(
                    entrega.Cuerpo, Encoding.UTF8, "application/json")
            };

            peticion.Headers.TryAddWithoutValidation("X-Facturacion-Timestamp", marca);
            peticion.Headers.TryAddWithoutValidation("X-Facturacion-Firma", firma);
            peticion.Headers.TryAddWithoutValidation("X-Facturacion-Evento", entrega.EventoId.ToString());
            peticion.Headers.TryAddWithoutValidation("X-Facturacion-Tipo", entrega.Tipo);

            var respuesta = await _http.SendAsync(peticion, ct);

            cronometro.Stop();

            if (respuesta.IsSuccessStatusCode)
            {
                await _webhooks.MarcarEntregadaAsync(
                    entrega.Id, (int)respuesta.StatusCode, ct);

                _log.LogInformation(
                    "Webhook {Tipo} entregado en {Ms} ms ({Codigo}).",
                    entrega.Tipo, cronometro.ElapsedMilliseconds,
                    (int)respuesta.StatusCode);

                return;
            }

            // UN 4xx NO SE REINTENTA, salvo el 429.
            //
            // Un 404 o un 401 significan que la URL está mal o que el cliente
            // cambió su autenticación. Reintentar ocho veces lo mismo no lo
            // va a arreglar: hace falta que alguien corrija la configuración.
            var codigo = (int)respuesta.StatusCode;

            var reintentable = codigo >= 500 || codigo == 429;

            await _webhooks.RegistrarFalloAsync(
                entrega.Id,
                reintentable ? entrega.Intentos : MaximoIntentos,
                MaximoIntentos,
                codigo,
                $"El servidor respondió {codigo} {respuesta.ReasonPhrase}." +
                (reintentable ? "" : " No se reintenta: revisa la URL."),
                EsperaReintento.Calcular(entrega.Intentos),
                ct);

            _log.LogWarning(
                "Webhook {Tipo} rechazado con {Codigo}. {Accion}",
                entrega.Tipo, codigo,
                reintentable ? "Se reintentará." : "No se reintenta.");
        }
        catch (TaskCanceledException) when (!ct.IsCancellationRequested)
        {
            await RegistrarFalloAsync(entrega,
                "El servidor del cliente no respondió dentro del plazo.", ct);
        }
        catch (HttpRequestException ex)
        {
            await RegistrarFalloAsync(entrega,
                $"No se pudo contactar el servidor: {ex.Message}", ct);
        }
        catch (Exception ex)
        {
            await RegistrarFalloAsync(entrega, ex.Message, ct);
        }
    }

    private Task RegistrarFalloAsync(
        EntregaPendiente entrega, string error, CancellationToken ct)
    {
        _log.LogWarning(
            "Webhook {Tipo} falló (intento {Intento}): {Error}",
            entrega.Tipo, entrega.Intentos, error);

        return _webhooks.RegistrarFalloAsync(
            entrega.Id, entrega.Intentos, MaximoIntentos,
            null, error, EsperaReintento.Calcular(entrega.Intentos), ct);
    }

    /// <summary>
    /// Calcula la firma que el cliente debe recalcular por su cuenta.
    ///
    /// El formato es deliberadamente simple para que sea fácil de reproducir
    /// en cualquier lenguaje: HMAC-SHA256 de "timestamp.cuerpo", en
    /// hexadecimal minúsculo.
    /// </summary>
    public static string Firmar(string marcaTiempo, string cuerpo, string secreto)
    {
        var contenido = Encoding.UTF8.GetBytes($"{marcaTiempo}.{cuerpo}");
        var llave = Encoding.UTF8.GetBytes(secreto);

        using var hmac = new HMACSHA256(llave);

        return Convert.ToHexString(hmac.ComputeHash(contenido)).ToLowerInvariant();
    }
}

/// <summary>
/// Despacha webhooks en segundo plano.
///
/// Corre aparte del worker de comprobantes porque su fallo no debe afectar a
/// la facturación: que el servidor de un cliente esté caído no puede impedir
/// que las facturas de los demás lleguen a SUNAT.
/// </summary>
public sealed class ServicioWebhooks : BackgroundService
{
    private readonly DespachadorWebhooks _despachador;
    private readonly ILogger<ServicioWebhooks> _log;
    private readonly TimeSpan _intervalo;

    public ServicioWebhooks(
        DespachadorWebhooks despachador,
        ILogger<ServicioWebhooks> log,
        TimeSpan? intervalo = null)
    {
        _despachador = despachador;
        _log = log;
        _intervalo = intervalo ?? TimeSpan.FromSeconds(10);
    }

    protected override async Task ExecuteAsync(CancellationToken ct)
    {
        _log.LogInformation(
            "Despachador de webhooks iniciado. Ciclo cada {Intervalo}.", _intervalo);

        while (!ct.IsCancellationRequested)
        {
            try
            {
                await _despachador.DespacharAsync(ct);
            }
            catch (OperationCanceledException) when (ct.IsCancellationRequested)
            {
                break;
            }
            catch (Exception ex)
            {
                _log.LogError(ex, "Error en el ciclo de webhooks. Se reintenta.");
            }

            await Task.Delay(_intervalo, ct);
        }

        _log.LogInformation("Despachador de webhooks detenido.");
    }
}
