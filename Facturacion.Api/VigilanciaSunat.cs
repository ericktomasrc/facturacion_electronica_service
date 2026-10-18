using System.Net;
using System.Text;
using Facturacion.Persistencia;

namespace Facturacion.Api;

/// <summary>
/// VIGILANCIA SUNAT, PARTE 1: la alarma de códigos nuevos (migración 029).
///
/// Dos pasos, siempre en este orden:
///   1. Revisar: anotar los códigos que SUNAT devolvió desde la última vuelta
///      y crear una alerta por cada uno que nunca había salido.
///   2. Avisar: mandar por correo las alertas pendientes, todas juntas en un
///      solo correo, a los administradores del panel y a la lista de correos
///      para alertas.
///
/// Lo usan el reloj (ServicioVigilancia, cada 5 minutos) y el botón «Revisar
/// ahora» del panel.
///
/// VIVE EN LA API, como los correos de entrega: aquí ya están el correo y el
/// panel. Solo lee lo que ya pasó: si algo de esto falla, la facturación
/// sigue exactamente igual.
/// </summary>
public sealed class VigilanciaSunat
{
    // Esperas entre intentos del correo: seis intentos en unas nueve horas,
    // igual que los correos de entrega.
    private static readonly TimeSpan[] Esperas =
    {
        TimeSpan.FromMinutes(1), TimeSpan.FromMinutes(5), TimeSpan.FromMinutes(30),
        TimeSpan.FromHours(2), TimeSpan.FromHours(6)
    };

    private readonly RepositorioVigilancia _repo;
    private readonly ServicioCorreo _correo;
    private readonly OpcionesCorreo _opciones;
    private readonly ILogger<VigilanciaSunat> _log;
    private readonly PruebaMadrugada _madrugada;

    public VigilanciaSunat(
        RepositorioVigilancia repo, ServicioCorreo correo, OpcionesCorreo opciones,
        ILogger<VigilanciaSunat> log, PruebaMadrugada madrugada)
    {
        _madrugada = madrugada;
        _repo = repo;
        _correo = correo;
        _opciones = opciones;
        _log = log;
    }

    public string UrlPanel => _opciones.UrlPanel.TrimEnd('/') + "/vigilancia.html";

    /// <summary>Una vuelta completa: revisar y avisar.</summary>
    public async Task<ResultadoRevision> VueltaAsync(CancellationToken ct)
    {
        var r = await _repo.RevisarAsync(ct);

        if (r.FueLaPrimera)
            _log.LogInformation(
                "Vigilancia SUNAT: primera vuelta. Se anotaron {Codigos} códigos que ya existían, " +
                "sin avisar. Desde ahora avisa solo los nuevos.", r.CodigosNuevos);
        else if (r.AlertasCreadas > 0)
            _log.LogWarning(
                "Vigilancia SUNAT: {Alertas} código(s) de SUNAT nunca visto(s).", r.AlertasCreadas);

        if (_repo.TablasSinPermiso.Count > 0)
            _log.LogWarning(
                "Vigilancia SUNAT: el rol operador no puede leer {Tablas}; esos códigos no se vigilan.",
                string.Join(", ", _repo.TablasSinPermiso));

        // PRUEBA DE MADRUGADA (migración 030): compara con la noche anterior
        // los casos que ya tienen desenlace. Si la 030 no está, no dice nada.
        try
        {
            var cambios = await _madrugada.EvaluarAsync(ct);
            if (cambios > 0)
                _log.LogWarning("Prueba de madrugada: {Cambios} cambio(s) respecto a la noche anterior.", cambios);
        }
        catch (Npgsql.PostgresException ex) when (ex.SqlState == "42P01") { }

        await AvisarPendientesAsync(ct);

        return r;
    }

    /// <summary>
    /// Manda las alertas pendientes en UN correo. Si sale para al menos un
    /// destinatario, se dan por avisadas; si no sale para nadie, se reintenta
    /// más tarde.
    /// </summary>
    public async Task AvisarPendientesAsync(CancellationToken ct)
    {
        if (!_correo.Disponible) return; // Se quedan pendientes, no se pierden.

        var (conexion, tx, alertas) = await _repo.TomarPendientesAsync(20, ct);

        await using (conexion)
        await using (tx)
        {
            if (alertas.Count == 0) { await tx.CommitAsync(ct); return; }

            var ids = alertas.Select(a => a.Id).ToList();
            var destinatarios = await _repo.DestinatariosAsync(ct);

            if (destinatarios.Count == 0)
            {
                await RepositorioVigilancia.MarcarFalloAsync(conexion, tx, ids,
                    "No hay a quién avisar: ningún administrador activo ni correos en la lista.",
                    Esperas[^1], ct);
                await tx.CommitAsync(ct);
                return;
            }

            var (asunto, html) = Armar(alertas);
            var salieron = new List<string>();

            foreach (var para in destinatarios)
                if (await _correo.EnviarAsync(para, asunto, html, ct))
                    salieron.Add(para);

            if (salieron.Count > 0)
            {
                await RepositorioVigilancia.MarcarEnviadasAsync(
                    conexion, tx, ids, string.Join(", ", salieron), ct);
            }
            else
            {
                var intento = alertas.Max(a => a.CorreoIntentos);
                await RepositorioVigilancia.MarcarFalloAsync(conexion, tx, ids,
                    "El correo no salió para ningún destinatario. Mira el log de la API.",
                    Esperas[Math.Min(intento, Esperas.Length - 1)], ct);
            }

            await tx.CommitAsync(ct);
        }
    }

    /// <summary>Un correo de prueba, para comprobar que las alertas llegan.</summary>
    public async Task<(IReadOnlyList<string> Salieron, IReadOnlyList<string> Fallaron)>
        ProbarCorreoAsync(string quien, CancellationToken ct)
    {
        var destinatarios = await _repo.DestinatariosAsync(ct);
        var salieron = new List<string>();
        var fallaron = new List<string>();

        var html =
            Marco(
                "<p>Este es un correo de prueba de <b>Vigilancia SUNAT</b>. Si te llegó, las " +
                "alertas también te van a llegar.</p>" +
                $"<p>Lo pidió {E(quien)} desde el panel.</p>" +
                $"<p>Hoy llega a: {E(string.Join(", ", destinatarios))}.</p>");

        foreach (var para in destinatarios)
        {
            if (await _correo.EnviarAsync(para, "Prueba de las alertas de Vigilancia SUNAT", html, ct))
                salieron.Add(para);
            else
                fallaron.Add(para);
        }

        return (salieron, fallaron);
    }

    private (string Asunto, string Html) Armar(IReadOnlyList<AlertaPendiente> alertas)
    {
        var soloCodigos = alertas.All(a => a.Tipo == "codigo_nuevo");

        // EL ENLACE ABRE LA PESTAÑA QUE TOCA (vigilancia.html#codigos…).
        var pestana =
            soloCodigos ? "codigos"
            : alertas.All(a => a.Tipo.StartsWith("catalogo", StringComparison.Ordinal)) ? "catalogo"
            : alertas.All(a => a.Tipo is "prueba_cambio" or "beta_caida") ? "madrugada"
            : "";
        var enlace = pestana == "" ? UrlPanel : $"{UrlPanel}#{pestana}";

        var asunto = alertas.Count == 1
            ? alertas[0].Titulo
            : soloCodigos ? $"{alertas.Count} códigos de SUNAT nunca vistos"
                          : $"Vigilancia SUNAT: {alertas.Count} avisos";

        var sb = new StringBuilder();

        if (!soloCodigos)
            sb.Append("<p>Vigilancia SUNAT encontró algo que mirar. Puede ser una regla nueva de SUNAT: " +
                      "si es así, los clientes que emitan ese tipo de comprobante van a recibir lo mismo.</p>");
        else sb.Append(alertas.Count == 1
            ? "<p>SUNAT devolvió un código que nunca había salido. Puede ser una regla nueva de SUNAT: " +
              "si es así, otros clientes van a recibir lo mismo.</p>"
            : "<p>SUNAT devolvió códigos que nunca habían salido. Puede ser una regla nueva de SUNAT: " +
              "si es así, otros clientes van a recibir lo mismo.</p>");

        foreach (var a in alertas)
        {
            var color = a.Gravedad == "problema" ? "#b91c1c" : "#a16207";
            sb.Append(
                "<div style=\"background:#f1f3f5;border-radius:8px;padding:12px 14px;margin:12px 0;" +
                $"border-left:3px solid {color}\">" +
                $"<b>{E(a.Titulo)}</b><br>" +
                E(a.Detalle).Replace("\n", "<br>") +
                PistaCodigoProducto(a.Titulo) +
                "</div>");
        }

        sb.Append(
            "<p><b>Qué hacer:</b> abrir el panel, pestaña Vigilancia SUNAT, leer el mensaje completo " +
            "y buscar si SUNAT publicó un cambio. Después, «Marcar revisado» con una nota.</p>" +
            $"<p><a href=\"{E(enlace)}\">{E(enlace)}</a></p>" +
            "<p style=\"color:#5c6570;font-size:13px\">Cada código avisa una sola vez. " +
            "Te llega por ser administrador del panel o por estar en la lista de correos para alertas.</p>");

        return (asunto, Marco(sb.ToString()));
    }

    // LOS CÓDIGOS DE SUNAT QUE SON DEL CÓDIGO DE PRODUCTO (catálogo 25). Si
    // aparece uno nuevo, lo primero es mirar si el catálogo de la plataforma
    // quedó viejo (migración 031, «Catálogo de productos SUNAT»).
    private static readonly System.Text.RegularExpressions.Regex CodigosDeProducto =
        new(@"\b(3496|3506|3181|4331|4332|4337)\b");

    private static string PistaCodigoProducto(string titulo) =>
        CodigosDeProducto.IsMatch(titulo)
            ? "<br><i>Es del código de producto SUNAT (catálogo 25). Mira en Vigilancia SUNAT la " +
              "sección «Catálogo de productos SUNAT»: si SUNAT cambió su lista, hay que regenerar " +
              "la de la plataforma.</i>"
            : "";

    private static string Marco(string cuerpo) =>
        "<div style=\"font-family:Segoe UI,system-ui,sans-serif;font-size:15px;line-height:1.55;" +
        "color:#1b1f24;max-width:620px\">" + cuerpo + "</div>";

    private static string E(string? t) => WebUtility.HtmlEncode(t ?? "");
}

/// <summary>
/// El reloj de la vigilancia: una vuelta cada 5 minutos. La primera, al minuto
/// de arrancar, para no competir con el arranque de la API.
/// </summary>
public sealed class ServicioVigilancia : BackgroundService
{
    private static readonly TimeSpan Ciclo = TimeSpan.FromMinutes(5);

    private readonly VigilanciaSunat _vigilancia;
    private readonly ILogger<ServicioVigilancia> _log;

    public ServicioVigilancia(VigilanciaSunat vigilancia, ILogger<ServicioVigilancia> log)
    {
        _vigilancia = vigilancia;
        _log = log;
    }

    protected override async Task ExecuteAsync(CancellationToken ct)
    {
        try { await Task.Delay(TimeSpan.FromMinutes(1), ct); }
        catch (OperationCanceledException) { return; }

        _log.LogInformation("Vigilancia SUNAT: revisa los códigos de SUNAT cada {Ciclo}.", Ciclo);

        while (!ct.IsCancellationRequested)
        {
            try
            {
                await _vigilancia.VueltaAsync(ct);
            }
            catch (OperationCanceledException) when (ct.IsCancellationRequested)
            {
                break;
            }
            catch (Npgsql.PostgresException ex) when (ex.SqlState == "42P01")
            {
                // Falta la migración 029. Se dice una vez y se deja de intentar:
                // no tiene arreglo hasta que se aplique y se reinicie la API.
                _log.LogWarning(
                    "Vigilancia SUNAT apagada: falta aplicar la migración 029 ({Mensaje}).",
                    ex.MessageText);
                return;
            }
            catch (Exception ex)
            {
                // Un fallo aquí no puede tumbar la API.
                _log.LogError(ex, "Falló una vuelta de Vigilancia SUNAT. Se reintenta en {Ciclo}.", Ciclo);
            }

            try { await Task.Delay(Ciclo, ct); }
            catch (OperationCanceledException) { break; }
        }
    }
}