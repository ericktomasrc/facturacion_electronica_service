using MailKit.Net.Smtp;
using MailKit.Security;
using Microsoft.Extensions.Logging;
using MimeKit;

namespace Facturacion.Persistencia;

/// <summary>Configuración del servidor de correo.</summary>
public sealed class OpcionesCorreo
{
    public string Host { get; set; } = "";
    public int Puerto { get; set; } = 587;
    public string Usuario { get; set; } = "";
    public string Clave { get; set; } = "";
    public string Desde { get; set; } = "";
    public string Nombre { get; set; } = "Facturación electrónica";

    /// <summary>
    /// Dirección base del panel, para armar los enlaces de los correos.
    ///
    /// Tiene que ser la que ve el usuario, no la interna del servidor: un
    /// enlace a "localhost" en un correo no lleva a ninguna parte.
    /// </summary>
    public string UrlPanel { get; set; } = "https://localhost:7295";

    public bool Configurado =>
        !string.IsNullOrWhiteSpace(Host) && !string.IsNullOrWhiteSpace(Desde);
}

/// <summary>
/// Envía los correos del sistema.
///
/// POR QUÉ NO SE ENVÍA DIRECTAMENTE DESDE DONDE HACE FALTA:
///
/// Un servidor de correo puede tardar segundos o estar caído. Si el envío
/// ocurriera dentro de la petición que lo provoca, restablecer una contraseña
/// se quedaría colgado esperando a Gmail.
///
/// Aquí se envía en segundo plano y los fallos se registran: que no llegue un
/// correo no debe romper la operación que lo originó.
/// </summary>
public sealed class ServicioCorreo
{
    private readonly OpcionesCorreo _opciones;
    private readonly ILogger<ServicioCorreo> _log;

    public ServicioCorreo(OpcionesCorreo opciones, ILogger<ServicioCorreo> log)
    {
        _opciones = opciones;
        _log = log;
    }

    public bool Disponible => _opciones.Configurado;

    /// <summary>
    /// Envía un correo. Devuelve false si falla, sin lanzar.
    ///
    /// NO LANZA A PROPÓSITO. Quien llama casi siempre está en medio de otra
    /// cosa —crear un usuario, restablecer una contraseña— y esa cosa ya se
    /// hizo. Fallar ahí dejaría al usuario creado pero la petición en error,
    /// que es el peor de los dos mundos.
    /// </summary>
    public async Task<bool> EnviarAsync(
        string para, string asunto, string cuerpoHtml,
        CancellationToken ct = default)
    {
        if (!Disponible)
        {
            _log.LogWarning(
                "Correo NO configurado: no se envió '{Asunto}' a {Para}. " +
                "Rellena MAIL_HOST y las demás variables en el .env.",
                asunto, para);

            return false;
        }

        try
        {
            var mensaje = new MimeMessage();

            mensaje.From.Add(new MailboxAddress(_opciones.Nombre, _opciones.Desde));
            mensaje.To.Add(MailboxAddress.Parse(para));
            mensaje.Subject = asunto;

            mensaje.Body = new BodyBuilder
            {
                HtmlBody = cuerpoHtml,

                // Versión en texto plano para los clientes que no muestran
                // HTML y para que los filtros de correo no lo marquen como
                // sospechoso.
                TextBody = AQuitarEtiquetas(cuerpoHtml)
            }.ToMessageBody();

            using var cliente = new SmtpClient();

            // STARTTLS en el 587 es lo habitual. En el 465 se usa SSL directo.
            var seguridad = _opciones.Puerto == 465
                ? SecureSocketOptions.SslOnConnect
                : SecureSocketOptions.StartTls;

            await cliente.ConnectAsync(_opciones.Host, _opciones.Puerto, seguridad, ct);

            if (!string.IsNullOrWhiteSpace(_opciones.Usuario))
                await cliente.AuthenticateAsync(_opciones.Usuario, _opciones.Clave, ct);

            await cliente.SendAsync(mensaje, ct);
            await cliente.DisconnectAsync(true, ct);

            _log.LogInformation("Correo '{Asunto}' enviado a {Para}.", asunto, para);

            return true;
        }
        catch (Exception ex)
        {
            _log.LogError(ex,
                "No se pudo enviar '{Asunto}' a {Para}. " +
                "Si usas Gmail, recuerda que hace falta una contraseña de " +
                "aplicación, no la de la cuenta.",
                asunto, para);

            return false;
        }
    }

    // ------------------------------------------------------------ plantillas

    public Task<bool> EnviarRecuperacionAsync(
        string para, string nombre, string token, CancellationToken ct = default)
    {
        var enlace = $"{_opciones.UrlPanel.TrimEnd('/')}/restablecer.html?token={token}";

        return EnviarAsync(para,
            "Restablece tu contraseña",
            Plantilla(
                "Restablece tu contraseña",
                $"Hola{(string.IsNullOrWhiteSpace(nombre) ? "" : " " + Escapar(nombre))},",
                "Pediste restablecer la contraseña de tu cuenta del panel de " +
                "facturación. Pulsa el botón para elegir una nueva.",
                ("Elegir contraseña nueva", enlace),
                "El enlace caduca en una hora y solo sirve una vez.<br><br>" +
                "Si no fuiste tú, ignora este correo: tu contraseña no ha " +
                "cambiado y nadie ha entrado a tu cuenta."),
            ct);
    }

    public Task<bool> EnviarBienvenidaAsync(
        string para, string nombre, string provisional, int horasVigencia = 48,
        CancellationToken ct = default)
    {
        return EnviarAsync(para,
            "Tu acceso al panel de facturación",
            Plantilla(
                "Bienvenido",
                $"Hola{(string.IsNullOrWhiteSpace(nombre) ? "" : " " + Escapar(nombre))},",
                "Se creó tu cuenta en el panel de facturación electrónica. " +
                "Entra con tu correo y esta contraseña provisional:",
                ("Entrar al panel", _opciones.UrlPanel.TrimEnd('/') + "/login.html"),
                $"<div style=\"font-family:monospace;font-size:18px;" +
                $"background:#f1f3f5;padding:12px 16px;border-radius:8px;" +
                $"margin:16px 0;text-align:center\">{Escapar(provisional)}</div>" +
                $"<strong>Esta contraseña caduca en {horasVigencia} horas.</strong> " +
                "Si no entras antes, pídele al administrador que te la " +
                "restablezca.<br><br>" +
                "Tendrás que cambiarla en tu primer ingreso.<br><br>" +
                "Te recomendamos activar la verificación en dos pasos desde " +
                "&laquo;Mi cuenta&raquo;: este panel da acceso a datos " +
                "sensibles de los clientes."),
            ct);
    }

    public Task<bool> EnviarAvisoContrasenaCambiadaAsync(
        string para, string nombre, CancellationToken ct = default)
    {
        // POR QUÉ SE AVISA: si alguien cambia la contraseña sin que el dueño
        // lo sepa, este correo es lo único que lo alerta. Es barato y a veces
        // es la diferencia entre detectar un acceso indebido el mismo día o
        // no detectarlo nunca.
        return EnviarAsync(para,
            "Tu contraseña cambió",
            Plantilla(
                "Contraseña cambiada",
                $"Hola{(string.IsNullOrWhiteSpace(nombre) ? "" : " " + Escapar(nombre))},",
                "La contraseña de tu cuenta del panel de facturación acaba de " +
                "cambiar.",
                null,
                "<strong>Si no fuiste tú</strong>, avisa al administrador de " +
                "inmediato: alguien más tiene acceso a tu cuenta."),
            ct);
    }

    private string Plantilla(
        string titulo, string saludo, string cuerpo,
        (string Texto, string Url)? boton, string pie)
    {
        var botonHtml = boton is null ? "" : $"""
            <p style="margin:26px 0">
              <a href="{boton.Value.Url}"
                 style="background:#2563eb;color:#ffffff;text-decoration:none;
                        padding:11px 22px;border-radius:8px;display:inline-block;
                        font-weight:500">{Escapar(boton.Value.Texto)}</a>
            </p>
            """;

        return $"""
            <!DOCTYPE html>
            <html lang="es"><head><meta charset="utf-8"></head>
            <body style="margin:0;padding:24px;background:#f6f7f9;
                         font-family:system-ui,-apple-system,'Segoe UI',sans-serif;
                         color:#1b1f24">
              <div style="max-width:520px;margin:0 auto;background:#ffffff;
                          border:1px solid #e3e6ea;border-radius:12px;
                          padding:28px 30px">

                <h1 style="font-size:18px;font-weight:600;margin:0 0 18px">
                  {Escapar(titulo)}</h1>

                <p style="margin:0 0 14px;font-size:15px">{saludo}</p>
                <p style="margin:0;font-size:15px;line-height:1.55">{cuerpo}</p>

                {botonHtml}

                <div style="border-top:1px solid #e3e6ea;margin-top:24px;
                            padding-top:16px;color:#5c6570;font-size:13px;
                            line-height:1.55">{pie}</div>
              </div>

              <div style="max-width:520px;margin:14px auto 0;color:#8a929c;
                          font-size:12px;text-align:center">
                {Escapar(_opciones.Nombre)}
              </div>
            </body></html>
            """;
    }

    private static string Escapar(string texto) =>
        texto.Replace("&", "&amp;").Replace("<", "&lt;").Replace(">", "&gt;");

    private static string AQuitarEtiquetas(string html) =>
        System.Text.RegularExpressions.Regex
            .Replace(html, "<[^>]+>", " ")
            .Replace("&nbsp;", " ")
            .Replace("&laquo;", "\"")
            .Replace("&raquo;", "\"")
            .Replace("&amp;", "&");
}
