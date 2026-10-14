using System.Globalization;
using System.Net;
using Facturacion.Persistencia;

namespace Facturacion.Api;

/// <summary>
/// Manda el correo de entrega del portal: el comprobante aceptado, con el PDF
/// adjunto y un enlace de 400 días.
///
/// LA COLA LA LLENA LA BASE (disparador de la migración 022) en el mismo
/// instante en que el comprobante pasa a aceptado. Esto solo la vacía, cada
/// 30 segundos, igual que los webhooks.
///
/// VIVE EN LA API Y NO EN EL WORKER porque el PDF se genera aquí
/// (PdfDeComprobante). Llevarlo al worker obligaría a duplicar ese código, y
/// dos maneras de hacer el PDF acaban dando dos PDF distintos. La API corre
/// en una sola copia, como el worker. Si algún día corren varias, la cola ya
/// lo aguanta: cada vuelta aparta lo que toma (SKIP LOCKED).
///
/// CADA INTENTO CREA SU PROPIO ACCESO, y si el envío falla, se anula. El
/// identificador del enlace solo existe en claro mientras se arma el correo:
/// en la base queda su hash, así que un intento no puede reutilizar el del
/// anterior.
/// </summary>
public sealed class ServicioCorreosEntrega : BackgroundService
{
    private static readonly TimeSpan Ciclo = TimeSpan.FromSeconds(30);
    private const int Lote = 10;

    /// <summary>Hasta cuánto pesa un PDF para ir adjunto (decidido el 10 oct).</summary>
    private const int TopeAdjunto = 1024 * 1024;

    // Esperas entre intentos. Seis intentos en total, en unas nueve horas: lo
    // bastante para pasar una caída del servidor de correo, no tanto como
    // para que el cliente reciba el comprobante una semana tarde.
    private static readonly TimeSpan[] Esperas =
    {
        TimeSpan.FromMinutes(1), TimeSpan.FromMinutes(5), TimeSpan.FromMinutes(30),
        TimeSpan.FromHours(2), TimeSpan.FromHours(6)
    };

    private readonly RepositorioCorreosPortal _cola;
    private readonly RepositorioComprobantes _comprobantes;
    private readonly IAlmacenArchivos _archivos;
    private readonly ServicioCorreo _correo;
    private readonly OpcionesCorreo _opciones;
    private readonly ILogger<ServicioCorreosEntrega> _log;

    public ServicioCorreosEntrega(
        RepositorioCorreosPortal cola, RepositorioComprobantes comprobantes,
        IAlmacenArchivos archivos, ServicioCorreo correo, OpcionesCorreo opciones,
        ILogger<ServicioCorreosEntrega> log)
    {
        _cola = cola;
        _comprobantes = comprobantes;
        _archivos = archivos;
        _correo = correo;
        _opciones = opciones;
        _log = log;
    }

    protected override async Task ExecuteAsync(CancellationToken ct)
    {
        if (!_correo.Disponible)
        {
            // Los correos se quedan PENDIENTES, no se pierden: saldrán cuando
            // el correo esté configurado y la API se reinicie.
            _log.LogWarning(
                "Correo NO configurado: los correos de entrega del portal se " +
                "quedan en cola sin enviarse.");
            return;
        }

        _log.LogInformation(
            "Correos de entrega del portal: ciclo cada {Ciclo}, enlaces a {Url}.",
            Ciclo, _opciones.UrlPortalEfectiva);

        while (!ct.IsCancellationRequested)
        {
            try
            {
                var lote = await _cola.TomarPendientesAsync(Lote, ct);

                foreach (var pendiente in lote)
                    await ProcesarAsync(pendiente, ct);
            }
            catch (OperationCanceledException) when (ct.IsCancellationRequested)
            {
                break;
            }
            catch (Exception ex)
            {
                // Un fallo de la base no puede tumbar la API entera.
                _log.LogError(ex, "Falló una vuelta de los correos de entrega.");
            }

            try { await Task.Delay(Ciclo, ct); }
            catch (OperationCanceledException) { break; }
        }
    }

    private async Task ProcesarAsync(CorreoPendiente p, CancellationToken ct)
    {
        var d = await _cola.DatosAsync(p.TenantId, p.ComprobanteId, ct);

        // Lo que ya no tiene arreglo no se reintenta: se marca y se explica.
        var motivoOmitir =
            d is null ? "El comprobante ya no existe." :
            !d.EmpresaActiva ? "La empresa está desactivada." :
            d.Identificador is null ? "La empresa no tiene dirección del portal." :
            d.CorreoRespuesta is null ? "La empresa no tiene correo de respuesta." :
            d.Estado is not ("ACEPTADO" or "ACEPTADO_CON_OBSERVACIONES")
                ? $"El comprobante está en estado {d.Estado}." :
            null;

        if (motivoOmitir is not null || d is null)
        {
            await _cola.MarcarOmitidoAsync(p.Id, motivoOmitir ?? "Sin datos.", ct);
            return;
        }

        var pdf = await PdfAdjuntoAsync(p, d, ct);
        var xmlYCdr = await XmlYCdrAsync(p, d, ct);
        var logo = await LogoAsync(d, ct);

        var acceso = AccesoPortal.Nuevo();
        var accesoId = await _cola.CrearAccesoCorreoAsync(
            p.TenantId, p.ComprobanteId, AccesoPortal.Hash(acceso), ct);

        var enlace = $"{_opciones.UrlPortalEfectiva}/{d.Identificador}/e/{acceso}";

        var (asunto, html, texto) = PlantillaEntrega.Armar(d, enlace, pdf is not null, logo is not null, xmlYCdr.Count > 0);

        // LA COPIA AL EMISOR (migración 026): solo si la pidió, a su correo de
        // respuesta, y oculta. Lleva el mismo enlace que el del receptor: es su
        // propio comprobante, y así ve exactamente lo que recibió su cliente.
        var error = await _correo.EnviarEntregaAsync(
            p.Para, d.NombreEmisor, d.CorreoRespuesta!, asunto, html, texto, pdf, logo, ct,
            copiaOculta: d.CopiaAlEmisor ? d.CorreoRespuesta : null,
            otrosAdjuntos: xmlYCdr);

        if (error is null)
        {
            await _cola.MarcarEnviadoAsync(p.Id, accesoId, pdf is not null, ct);
            return;
        }

        var espera = p.Intentos > Esperas.Length ? (TimeSpan?)null : Esperas[p.Intentos - 1];

        await _cola.MarcarFalloAsync(p.Id, error, espera, accesoId, ct);
    }

    /// <summary>
    /// El PDF para adjuntar, o null si pesa más de 1 MB o no se pudo hacer.
    /// En los dos casos el correo sale igual, solo con el enlace: un PDF que
    /// falla no puede dejar al cliente sin su comprobante.
    /// </summary>
    private async Task<AdjuntoCorreo?> PdfAdjuntoAsync(
        CorreoPendiente p, DatosCorreoPortal d, CancellationToken ct)
    {
        try
        {
            var datos = await _comprobantes.ObtenerParaPdfAsync(p.TenantId, p.ComprobanteId, ct);
            if (datos is null) return null;

            var comprobante = PdfDeComprobante.Deserializar(datos);
            var bytes = await PdfDeComprobante.GenerarBytesAsync(comprobante, datos, _archivos, ct);

            return bytes.Length <= TopeAdjunto
                ? new AdjuntoCorreo($"{d.Ruc}-{d.TipoComprobante}-{d.Numero}.pdf", "application/pdf", bytes)
                : null;
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            _log.LogWarning(ex, "No se pudo generar el PDF de {Numero} para el correo; va solo el enlace.",
                d.Numero);
            return null;
        }
    }

    /// <summary>
    /// El XML firmado y el CDR de SUNAT, adjuntos (fase 4c). Solo en facturas
    /// y notas: la boleta no tiene CDR propio (va en el resumen diario) y quien
    /// la recibe no suele pedir el XML. Si algo falla o pesa más de 1 MB, no
    /// va: el correo sale igual, con el enlace.
    /// </summary>
    private async Task<List<AdjuntoCorreo>> XmlYCdrAsync(
        CorreoPendiente p, DatosCorreoPortal d, CancellationToken ct)
    {
        var lista = new List<AdjuntoCorreo>();
        if (d.TipoComprobante == "03") return lista;

        try
        {
            var rutas = await _comprobantes.ObtenerRutasAsync(p.TenantId, p.ComprobanteId, ct);
            if (rutas is null) return lista;

            foreach (var (ruta, extension, mime) in new[]
                     {
                         (rutas.RutaXml, "xml", "application/xml"),
                         (rutas.RutaCdr, "zip", "application/zip")
                     })
            {
                if (string.IsNullOrWhiteSpace(ruta)) continue;
                var bytes = await _archivos.LeerAsync(ruta, ct);
                if (bytes is { Length: > 0 } && bytes.Length <= TopeAdjunto)
                    lista.Add(new AdjuntoCorreo(
                        extension == "zip" ? "R-" + rutas.NombreDescarga(extension) : rutas.NombreDescarga(extension),
                        mime, bytes));
            }
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            _log.LogWarning(ex, "No se pudieron adjuntar el XML y el CDR de {Numero}; va solo el enlace.", d.Numero);
            lista.Clear();
        }

        return lista;
    }

    private async Task<AdjuntoCorreo?> LogoAsync(DatosCorreoPortal d, CancellationToken ct)
    {
        if (d.LogoRuta is null) return null;

        try
        {
            var bytes = await _archivos.LeerAsync(d.LogoRuta, ct);

            return bytes is not null && Marca.TipoDeImagen(bytes) is { } tipo
                ? new AdjuntoCorreo($"logo.{tipo.Extension}", tipo.TipoMime, bytes)
                : null;
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            return null;
        }
    }
}

/// <summary>
/// El correo que recibe el cliente del emisor.
///
/// SE VE DEL EMISOR, NO DE REYBAN: su nombre, su logo, su color. Tablas y
/// estilos en línea porque es lo único que respetan todos los clientes de
/// correo; nada de hojas de estilo ni de imágenes de fuera.
/// </summary>
public static class PlantillaEntrega
{
    // Los meses a mano y no con CultureInfo("es-PE"): en un contenedor con
    // globalización invariante esa cultura no existe y la llamada lanza.
    private static readonly string[] Meses =
    {
        "enero", "febrero", "marzo", "abril", "mayo", "junio", "julio",
        "agosto", "septiembre", "octubre", "noviembre", "diciembre"
    };

    private static string FechaLarga(DateTime f) => $"{f.Day} de {Meses[f.Month - 1]} de {f.Year}";

    private static string TipoLargo(string tipo) => tipo switch
    {
        "01" => "Factura electrónica",
        "03" => "Boleta de venta electrónica",
        "07" => "Nota de crédito electrónica",
        "08" => "Nota de débito electrónica",
        _ => "Comprobante electrónico"
    };

    private static string TipoCorto(string tipo) => tipo switch
    {
        "01" => "Factura",
        "03" => "Boleta",
        "07" => "Nota de crédito",
        "08" => "Nota de débito",
        _ => "Comprobante"
    };

    private static string Importe(decimal valor, string moneda)
    {
        var simbolo = moneda switch { "PEN" => "S/", "USD" => "US$", "EUR" => "€", _ => moneda };
        return $"{simbolo} {valor.ToString("#,##0.00", CultureInfo.InvariantCulture)}";
    }

    /// <summary>Blanco o casi negro sobre el color de la marca: el que se lea.</summary>
    private static string TextoSobre(string hex)
    {
        static double Canal(int c)
        {
            var v = c / 255.0;
            return v <= 0.03928 ? v / 12.92 : Math.Pow((v + 0.055) / 1.055, 2.4);
        }

        var n = Convert.ToInt32(hex[1..], 16);
        var l = 0.2126 * Canal(n >> 16 & 255) + 0.7152 * Canal(n >> 8 & 255) + 0.0722 * Canal(n & 255);
        return l > 0.4 ? "#111418" : "#ffffff";
    }

    public static (string Asunto, string Html, string Texto) Armar(
        DatosCorreoPortal d, string enlace, bool conPdf, bool conLogo, bool conXmlCdr = false)
    {
        static string E(string? t) => WebUtility.HtmlEncode(t ?? "");

        var color = d.ColorMarca is { Length: 7 } c && c[0] == '#' ? c : "#334155";
        var sobre = TextoSobre(color);
        var nombre = d.NombreEmisor;
        var fecha = d.FechaEmision.ToString("dd/MM/yyyy", CultureInfo.InvariantCulture);
        var importe = Importe(d.ImporteTotal, d.Moneda);
        var hasta = FechaLarga(DateTime.UtcNow.AddDays(400));
        var esBoleta = d.TipoComprobante == "03";

        var asunto = $"{TipoCorto(d.TipoComprobante)} {d.Numero} de {nombre}";

        var notaPdf = (conPdf, conXmlCdr) switch
        {
            (true, true)  => "Adjuntamos el PDF, el XML y la constancia de SUNAT (CDR).",
            (true, false) => "Adjuntamos el PDF del comprobante.",
            (false, true) => "Adjuntamos el XML y la constancia de SUNAT (CDR). El PDF descárgalo desde el botón.",
            _             => "El PDF no va adjunto: descárgalo desde el botón.",
        };

        var archivos = esBoleta ? "el PDF" : "el PDF, el XML y el CDR de SUNAT";

        var logoHtml = conLogo
            ? $"""<img src="cid:logo-emisor" alt="{E(nombre)}" style="max-height:56px;max-width:200px;display:block;margin:0 0 18px;border:0">"""
            : "";

        var html = $"""
            <!DOCTYPE html>
            <html lang="es"><head><meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1"></head>
            <body style="margin:0;padding:24px 12px;background:#f5f6f8;font-family:system-ui,-apple-system,'Segoe UI',Roboto,sans-serif;color:#1a1d21">
              <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:520px;margin:0 auto;background:#ffffff;border:1px solid #e2e5ea;border-radius:12px;border-collapse:separate;overflow:hidden">
                <tr><td style="height:5px;background:{color};font-size:0;line-height:0">&nbsp;</td></tr>
                <tr><td style="padding:26px 28px">
                  {logoHtml}
                  <p style="margin:0 0 4px;font-size:15px;color:#5d6672">{E(nombre)} te envió</p>
                  <p style="margin:0 0 18px;font-size:20px;font-weight:600">{E(TipoLargo(d.TipoComprobante))} {E(d.Numero)}</p>
                  <table role="presentation" cellpadding="0" cellspacing="0" style="font-size:15px;margin:0 0 22px">
                    <tr><td style="color:#5d6672;padding:3px 18px 3px 0">Fecha de emisión</td><td>{E(fecha)}</td></tr>
                    <tr><td style="color:#5d6672;padding:3px 18px 3px 0">Importe total</td><td>{E(importe)}</td></tr>
                  </table>
                  <a href="{E(enlace)}" style="background:{color};color:{sobre};text-decoration:none;padding:12px 24px;border-radius:8px;display:inline-block;font-weight:600;font-size:15px">Ver y descargar</a>
                  <p style="margin:18px 0 0;font-size:13.5px;color:#5d6672">{E(notaPdf)}</p>
                </td></tr>
                <tr><td style="border-top:1px solid #e2e5ea;padding:16px 28px;font-size:12.5px;color:#5d6672;line-height:1.6">
                  Desde el botón puedes descargar {E(archivos)} hasta el {E(hasta)}.
                  El enlace es personal: no lo compartas.<br>
                  ¿Dudas sobre este comprobante? Responde a este correo y le llegará a {E(nombre)}.
                </td></tr>
              </table>
              <p style="max-width:520px;margin:12px auto 0;text-align:center;font-size:11.5px;color:#8a929c">{E(d.RazonSocial)} · RUC {E(d.Ruc)}</p>
            </body></html>
            """;

        var texto =
            $"{nombre} te envió: {TipoLargo(d.TipoComprobante)} {d.Numero}\n\n" +
            $"Fecha de emisión: {fecha}\n" +
            $"Importe total: {importe}\n\n" +
            $"Ver y descargar: {enlace}\n\n" +
            $"{notaPdf}\n\n" +
            $"Desde el enlace puedes descargar {archivos} hasta el {hasta}. " +
            "El enlace es personal: no lo compartas.\n" +
            $"¿Dudas? Responde a este correo y le llegará a {nombre}.\n\n" +
            $"{d.RazonSocial} · RUC {d.Ruc}\n";

        return (asunto, html, texto);
    }
}