# =============================================================================
# Entrega 2026-10-10 — Portal del receptor, PASO 4: el correo de entrega
#
# Se ejecuta desde la raíz del servicio:
#   cd "D:\Reyban Consulting\facturacion electronica\facturacion_electronica_service"
#   .\entrega-2026-10-10-paso4-correo.ps1
#
#   ServicioCorreosEntrega.cs   NUEVO. Cada 30 s vacía la cola: arma el correo
#                               con el nombre, logo y color del emisor, el PDF
#                               adjunto (hasta 1 MB) y el enlace de 400 días.
#                               Reintenta 6 veces en ~9 horas
#   EndpointsPortalAdmin.cs     NUEVO. Panel: ver correo y enlaces de un
#                               comprobante, y anularlos
#   RepositorioCorreosPortal.cs NUEVO. La cola y los enlaces (rol operador)
#   ServicioCorreo.cs           Nuevo envío con «Responder a», adjunto y logo
#                               incrustado. Los correos del panel no cambian
#   EndpointsPortal.cs          El enlace se crea y se comprueba en un solo
#                               sitio (AccesoPortal), para búsqueda y correo
#   PdfDeComprobante.cs         El PDF en bytes, para adjuntar el mismo PDF
#   Program.cs                  Registra la cola, el envío y PORTAL_URL
#   wwwroot\comprobantes.html   En «Detalle»: el correo y los enlaces del
#                               portal, con el botón para anularlos
#   migraciones\022_portal_correos.sql   NUEVO. La cola y el disparador. No
#                               se aplica sola
#
# PROTECCIÓN: cada archivo solo se reemplaza si en tu disco sigue IGUAL al que
# tengo. Si alguno cambió, NO TOCA NADA. Todo o nada. UTF-8 sin BOM, .bak.
# La migración NO se aplica: se recuerda al final.
# =============================================================================

$ErrorActionPreference = 'Stop'
$raiz = (Get-Location).Path

if (-not (Test-Path (Join-Path $raiz 'Facturacion.Api')) -or -not (Test-Path (Join-Path $raiz 'migraciones'))) {
    Write-Host "No encuentro 'Facturacion.Api' y 'migraciones' aquí ($raiz)." -ForegroundColor Red
    Write-Host "Ejecuta el script desde la raíz del servicio (facturacion_electronica_service). No se tocó nada." -ForegroundColor Red
    exit 1
}

$utf8SinBom = New-Object System.Text.UTF8Encoding $false

function Normalizar([string]$t) { return $t.TrimStart([char]0xFEFF).Replace("`r", '').TrimEnd() }

function Huella([string]$t) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $bytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes((Normalizar $t)))
    return ([System.BitConverter]::ToString($bytes)).Replace('-', '')
}

function Respaldar([string]$completa) {
    $bak = "$completa.bak"
    if (Test-Path $bak) { $bak = "$completa.$(Get-Date -Format 'yyyyMMdd-HHmmss').bak" }
    Copy-Item $completa $bak -Force
    return (Split-Path $bak -Leaf)
}

$plan = New-Object System.Collections.Generic.List[object]

# Una ruta que empieza por '*' se busca por nombre dentro de reyban_plataforma_web\src.
function Planear([string]$ruta, [string]$esperada, [string]$texto) {
    $texto = $texto.Replace("`r", '')
    if ($ruta.StartsWith('*')) {
        $nombre = $ruta.Substring(1)
        $hallados = @(Get-ChildItem -Path (Join-Path $raiz 'reyban_plataforma_web\src') -Recurse -Filter $nombre -File |
            Where-Object { $_.FullName -notmatch '\\node_modules\\' })
        if ($hallados.Count -ne 1) {
            $plan.Add([pscustomobject]@{ Ruta = $nombre; Accion = 'conflicto'; Motivo = "lo encuentro $($hallados.Count) veces dentro de reyban_plataforma_web\src. Dime cuál es." })
            return
        }
        $completa = $hallados[0].FullName
        $ruta = $completa.Substring($raiz.Length).TrimStart('\')
    }
    else { $completa = Join-Path $raiz $ruta }

    $accion = ''; $motivo = ''; $crlf = $false
    if (-not (Test-Path $completa)) {
        if ($esperada -eq '') { $accion = 'nuevo' }
        else { $accion = 'conflicto'; $motivo = 'no existe. ¿Está en otra carpeta?' }
    }
    else {
        $actual = [System.IO.File]::ReadAllText($completa)
        $crlf = $actual.Contains("`r`n")
        if ((Normalizar $actual) -eq (Normalizar $texto)) { $accion = 'igual' }
        elseif ((Huella $actual) -ne $esperada) { $accion = 'conflicto'; $motivo = 'cambió desde que me lo pasaste. Pásamelo de nuevo.' }
        else { $accion = 'reemplazar' }
    }
    $plan.Add([pscustomobject]@{ Ruta = $ruta; Completa = $completa; Accion = $accion; Motivo = $motivo; Texto = $texto; Crlf = $crlf })
}

# --- Facturacion.Api\ServicioCorreosEntrega.cs
Planear 'Facturacion.Api\ServicioCorreosEntrega.cs' '' @'
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
        var logo = await LogoAsync(d, ct);

        var acceso = AccesoPortal.Nuevo();
        var accesoId = await _cola.CrearAccesoCorreoAsync(
            p.TenantId, p.ComprobanteId, AccesoPortal.Hash(acceso), ct);

        var enlace = $"{_opciones.UrlPortalEfectiva}/{d.Identificador}/e/{acceso}";

        var (asunto, html, texto) = PlantillaEntrega.Armar(d, enlace, pdf is not null, logo is not null);

        var error = await _correo.EnviarEntregaAsync(
            p.Para, d.NombreEmisor, d.CorreoRespuesta!, asunto, html, texto, pdf, logo, ct);

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
        DatosCorreoPortal d, string enlace, bool conPdf, bool conLogo)
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

        var notaPdf = conPdf
            ? "Adjuntamos el PDF del comprobante."
            : "El PDF no va adjunto: descárgalo desde el botón.";

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
'@

# --- Facturacion.Api\EndpointsPortalAdmin.cs
Planear 'Facturacion.Api\EndpointsPortalAdmin.cs' '' @'
using Facturacion.Persistencia;

namespace Facturacion.Api;

/// <summary>
/// El portal del receptor visto desde el panel: qué correo salió de un
/// comprobante, qué enlaces tiene y anularlos.
///
/// Anular es lo que se hace cuando el correo fue a la dirección equivocada o
/// el cliente lo pide. Se anula, no se borra: queda cuántas veces se usó el
/// enlace y cuándo dejó de servir.
/// </summary>
public static class EndpointsPortalAdmin
{
    public static void MapearPortalAdmin(this WebApplication app)
    {
        var grupo = app.MapGroup("/admin/comprobantes/{id:guid}/portal")
            .AddEndpointFilter<AutenticacionPanel>()
            .WithTags("Administración");

        grupo.MapGet("", async (
            Guid id, RepositorioCorreosPortal portal, CancellationToken ct) =>
        {
            var (correo, accesos) = await portal.ListarAsync(id, ct);

            return Results.Ok(new
            {
                correo,
                accesos = accesos.Select(a => new
                {
                    a.Id,
                    a.Origen,
                    a.CreadoEn,
                    a.ExpiraEn,
                    a.AnuladoEn,
                    a.AnuladoMotivo,
                    a.Usos,
                    a.UltimoUsoEn,
                    vigente = a.AnuladoEn is null && a.ExpiraEn > DateTime.UtcNow
                })
            });
        })
        .AddEndpointFilter(new ExigirPermiso(Permiso.ComprobantesVer))
        .WithSummary("El correo de entrega y los enlaces del portal de un comprobante");

        grupo.MapPost("/anular", async (
            Guid id, AnulacionAccesos peticion,
            RepositorioCorreosPortal portal, CancellationToken ct) =>
        {
            var motivo = (peticion.Motivo ?? "").Trim();

            if (motivo.Length < 3)
                return Results.BadRequest(new RespuestaError(
                    "Escribe el motivo.",
                    "Queda guardado junto al enlace: es lo que se lee después " +
                    "cuando alguien pregunta por qué dejó de abrir."));

            if (motivo.Length > 300) motivo = motivo[..300];

            var anulados = await portal.AnularAccesosAsync(id, motivo, ct);

            return Results.Ok(new
            {
                anulados,
                mensaje = anulados == 0
                    ? "No había enlaces vigentes."
                    : anulados == 1 ? "Se anuló 1 enlace." : $"Se anularon {anulados} enlaces."
            });
        })
        .AddEndpointFilter(new ExigirPermiso(Permiso.ComprobantesReprocesar))
        .WithSummary("Anula los enlaces vigentes del portal de un comprobante");
    }
}

public record AnulacionAccesos(string? Motivo);
'@

# --- Facturacion.Persistencia\RepositorioCorreosPortal.cs
Planear 'Facturacion.Persistencia\RepositorioCorreosPortal.cs' '' @'
using Dapper;
using Npgsql;

namespace Facturacion.Persistencia;

/// <summary>Un correo de entrega que toca enviar.</summary>
public record CorreoPendiente(
    Guid Id,
    Guid TenantId,
    Guid ComprobanteId,
    string Para,
    short Intentos);

/// <summary>Todo lo que hace falta para armar el correo de un comprobante.</summary>
public record DatosCorreoPortal(
    bool EmpresaActiva,
    string Ruc,
    string RazonSocial,
    string? NombreComercial,
    string? Identificador,
    string? ColorMarca,
    string? LogoRuta,
    string? CorreoRespuesta,
    string TipoComprobante,
    string Serie,
    int Correlativo,
    DateTime FechaEmision,
    string Moneda,
    decimal ImporteTotal,
    string Estado)
{
    public string Numero => $"{Serie}-{Correlativo:D8}";

    public string NombreEmisor =>
        string.IsNullOrWhiteSpace(NombreComercial) ? RazonSocial : NombreComercial!;
}

/// <summary>Lo que el panel enseña del portal para un comprobante.</summary>
public record CorreoPortalAdmin(
    string Para,
    string Estado,
    short Intentos,
    string? UltimoError,
    DateTime? EnviadoEn,
    bool? PdfAdjunto,
    DateTime CreadoEn);

public record AccesoPortalAdmin(
    Guid Id,
    string Origen,
    DateTime CreadoEn,
    DateTime ExpiraEn,
    DateTime? AnuladoEn,
    string? AnuladoMotivo,
    int Usos,
    DateTime? UltimoUsoEn);

/// <summary>
/// La cola del correo de entrega y la administración de los accesos.
///
/// USA EL ROL DE OPERADOR: quien envía recorre la cola de todas las empresas,
/// y anular accesos es cosa del panel. La aplicación no puede anular.
/// </summary>
public sealed class RepositorioCorreosPortal
{
    private readonly string _cadenaOperador;

    public RepositorioCorreosPortal(string cadenaConexionOperador)
    {
        _cadenaOperador = cadenaConexionOperador
            ?? throw new ArgumentNullException(nameof(cadenaConexionOperador));
    }

    private async Task<NpgsqlConnection> AbrirAsync(CancellationToken ct)
    {
        var conexion = new NpgsqlConnection(_cadenaOperador);
        await conexion.OpenAsync(ct);
        return conexion;
    }

    // ------------------------------------------------------------------ cola

    /// <summary>
    /// Toma un lote de correos y los aparta 10 minutos.
    ///
    /// APARTAR ES ADELANTAR proximo_intento_en: si el proceso muere a mitad de
    /// un envío, el correo vuelve a estar disponible solo, sin quedarse
    /// "en curso" para siempre. SKIP LOCKED evita que dos vueltas tomen el
    /// mismo.
    /// </summary>
    public async Task<IReadOnlyList<CorreoPendiente>> TomarPendientesAsync(
        int lote, CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);

        var filas = await conexion.QueryAsync<CorreoPendiente>(new CommandDefinition(
            """
            UPDATE portal_correos c
               SET proximo_intento_en = now() + interval '10 minutes',
                   intentos = c.intentos + 1
             WHERE c.id IN (
                   SELECT id FROM portal_correos
                    WHERE estado = 'PENDIENTE'
                      AND (proximo_intento_en IS NULL OR proximo_intento_en <= now())
                    ORDER BY proximo_intento_en NULLS FIRST, creado_en
                    LIMIT @lote
                      FOR UPDATE SKIP LOCKED)
            RETURNING c.id             AS "Id",
                      c.tenant_id      AS "TenantId",
                      c.comprobante_id AS "ComprobanteId",
                      c.para           AS "Para",
                      c.intentos       AS "Intentos"
            """,
            new { lote }, cancellationToken: ct));

        return filas.ToList();
    }

    public async Task<DatosCorreoPortal?> DatosAsync(
        Guid tenantId, Guid comprobanteId, CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);

        return await conexion.QuerySingleOrDefaultAsync<DatosCorreoPortal>(new CommandDefinition(
            """
            SELECT t.activo           AS "EmpresaActiva",
                   t.ruc              AS "Ruc",
                   t.razon_social     AS "RazonSocial",
                   t.nombre_comercial AS "NombreComercial",
                   t.identificador    AS "Identificador",
                   t.color_marca      AS "ColorMarca",
                   t.logo_ruta        AS "LogoRuta",
                   t.correo_respuesta AS "CorreoRespuesta",
                   c.tipo_comprobante AS "TipoComprobante",
                   c.serie            AS "Serie",
                   c.correlativo      AS "Correlativo",
                   c.fecha_emision    AS "FechaEmision",
                   c.moneda           AS "Moneda",
                   c.importe_total    AS "ImporteTotal",
                   c.estado           AS "Estado"
              FROM comprobantes c
              JOIN tenants t ON t.id = c.tenant_id
             WHERE c.id = @comprobanteId
               AND c.tenant_id = @tenantId
            """,
            new { tenantId, comprobanteId }, cancellationToken: ct));
    }

    /// <summary>Crea el acceso del correo: 400 días, origen 'correo'.</summary>
    public async Task<Guid> CrearAccesoCorreoAsync(
        Guid tenantId, Guid comprobanteId, string hash, CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);

        return await conexion.ExecuteScalarAsync<Guid>(new CommandDefinition(
            """
            INSERT INTO portal_accesos (tenant_id, comprobante_id, hash, origen, expira_en)
            VALUES (@tenantId, @comprobanteId, @hash, 'correo', now() + interval '400 days')
            RETURNING id
            """,
            new { tenantId, comprobanteId, hash }, cancellationToken: ct));
    }

    public async Task MarcarEnviadoAsync(
        Guid id, Guid accesoId, bool pdfAdjunto, CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);

        await conexion.ExecuteAsync(new CommandDefinition(
            """
            UPDATE portal_correos
               SET estado = 'ENVIADO',
                   enviado_en = now(),
                   acceso_id = @accesoId,
                   pdf_adjunto = @pdfAdjunto,
                   ultimo_error = NULL,
                   proximo_intento_en = NULL
             WHERE id = @id
            """,
            new { id, accesoId, pdfAdjunto }, cancellationToken: ct));
    }

    /// <summary>
    /// Un envío fallido. El acceso que se creó para ese intento se anula: su
    /// enlace no llegó a nadie, y uno nuevo saldrá en el siguiente intento.
    /// </summary>
    public async Task MarcarFalloAsync(
        Guid id, string error, TimeSpan? reintentarEn, Guid? accesoFallido,
        CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);
        await using var transaccion = await conexion.BeginTransactionAsync(ct);

        await conexion.ExecuteAsync(new CommandDefinition(
            """
            UPDATE portal_correos
               SET estado = CASE WHEN @agotado THEN 'AGOTADO' ELSE 'PENDIENTE' END,
                   ultimo_error = left(@error, 1000),
                   proximo_intento_en = CASE WHEN @agotado THEN NULL
                                             ELSE now() + make_interval(secs => @segundos) END
             WHERE id = @id
            """,
            new
            {
                id,
                error,
                agotado = reintentarEn is null,
                segundos = reintentarEn?.TotalSeconds ?? 0
            },
            transaccion, cancellationToken: ct));

        if (accesoFallido is { } accesoId)
            await conexion.ExecuteAsync(new CommandDefinition(
                """
                UPDATE portal_accesos
                   SET anulado_en = now(), anulado_motivo = 'El correo no se pudo enviar.'
                 WHERE id = @accesoId AND anulado_en IS NULL
                """,
                new { accesoId }, transaccion, cancellationToken: ct));

        await transaccion.CommitAsync(ct);
    }

    /// <summary>No se manda y no se reintenta: la empresa ya no está lista.</summary>
    public async Task MarcarOmitidoAsync(Guid id, string motivo, CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);

        await conexion.ExecuteAsync(new CommandDefinition(
            """
            UPDATE portal_correos
               SET estado = 'OMITIDO', ultimo_error = @motivo, proximo_intento_en = NULL
             WHERE id = @id
            """,
            new { id, motivo }, cancellationToken: ct));
    }

    // ----------------------------------------------------------------- panel

    public async Task<(CorreoPortalAdmin? Correo, IReadOnlyList<AccesoPortalAdmin> Accesos)>
        ListarAsync(Guid comprobanteId, CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);

        var correo = await conexion.QuerySingleOrDefaultAsync<CorreoPortalAdmin>(
            new CommandDefinition(
                """
                SELECT para         AS "Para",
                       estado       AS "Estado",
                       intentos     AS "Intentos",
                       ultimo_error AS "UltimoError",
                       enviado_en   AS "EnviadoEn",
                       pdf_adjunto  AS "PdfAdjunto",
                       creado_en    AS "CreadoEn"
                  FROM portal_correos
                 WHERE comprobante_id = @comprobanteId
                """,
                new { comprobanteId }, cancellationToken: ct));

        var accesos = await conexion.QueryAsync<AccesoPortalAdmin>(new CommandDefinition(
            """
            SELECT id             AS "Id",
                   origen         AS "Origen",
                   creado_en      AS "CreadoEn",
                   expira_en      AS "ExpiraEn",
                   anulado_en     AS "AnuladoEn",
                   anulado_motivo AS "AnuladoMotivo",
                   usos           AS "Usos",
                   ultimo_uso_en  AS "UltimoUsoEn"
              FROM portal_accesos
             WHERE comprobante_id = @comprobanteId
             ORDER BY creado_en DESC
            """,
            new { comprobanteId }, cancellationToken: ct));

        return (correo, accesos.ToList());
    }

    /// <summary>
    /// Anula todos los accesos vigentes de un comprobante. Devuelve cuántos.
    ///
    /// Se anulan, no se borran: queda quién los usó, cuántas veces y cuándo
    /// dejaron de servir, que es justo lo que hay que poder responder si el
    /// cliente pregunta.
    /// </summary>
    public async Task<int> AnularAccesosAsync(
        Guid comprobanteId, string motivo, CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);

        return await conexion.ExecuteAsync(new CommandDefinition(
            """
            UPDATE portal_accesos
               SET anulado_en = now(), anulado_motivo = @motivo
             WHERE comprobante_id = @comprobanteId
               AND anulado_en IS NULL
               AND expira_en > now()
            """,
            new { comprobanteId, motivo }, cancellationToken: ct));
    }
}
'@

# --- Facturacion.Persistencia\ServicioCorreo.cs
Planear 'Facturacion.Persistencia\ServicioCorreo.cs' '320607D5544ED165B1C41777282665365AC84382DB7AC930B3FDCA4A48B3A768' @'
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

    /// <summary>
    /// Dirección base del portal del receptor, para el enlace del correo de
    /// entrega. En producción, https://comprobantes.reyban.pe (variable
    /// PORTAL_URL). Vacía: la del panel con /portal, que es lo que sirve en
    /// desarrollo.
    /// </summary>
    public string UrlPortal { get; set; } = "";

    public string UrlPortalEfectiva =>
        string.IsNullOrWhiteSpace(UrlPortal)
            ? UrlPanel.TrimEnd('/') + "/portal"
            : UrlPortal.TrimEnd('/');

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

    // ------------------------------------------------- correo de entrega

    /// <summary>
    /// El correo con el comprobante, en nombre del emisor.
    ///
    /// LO QUE LO HACE DISTINTO DE LOS CORREOS DEL PANEL:
    ///
    ///   - "De": el NOMBRE es el del emisor, la DIRECCIÓN es la nuestra
    ///     (MAIL_DESDE). Mandar desde la dirección del emisor sería suplantar
    ///     su dominio, y los filtros lo tirarían a spam.
    ///   - "Responder a": el correo de respuesta del emisor. Si el cliente
    ///     contesta, le llega a quien le vendió, no a nosotros.
    ///   - Puede llevar el PDF adjunto y el logo incrustado (cid:logo-emisor),
    ///     que se ve aunque el cliente de correo bloquee las imágenes de
    ///     fuera.
    ///
    /// Devuelve null si salió, o el motivo si no. No lanza: quien llama
    /// decide si reintenta.
    /// </summary>
    public async Task<string?> EnviarEntregaAsync(
        string para, string nombreRemitente, string responderA,
        string asunto, string html, string texto,
        AdjuntoCorreo? adjunto, AdjuntoCorreo? logo,
        CancellationToken ct = default)
    {
        if (!Disponible)
            return "El correo no está configurado (MAIL_HOST, MAIL_DESDE).";

        try
        {
            var mensaje = new MimeMessage();

            mensaje.From.Add(new MailboxAddress(nombreRemitente, _opciones.Desde));
            mensaje.ReplyTo.Add(MailboxAddress.Parse(responderA));
            mensaje.To.Add(MailboxAddress.Parse(para));
            mensaje.Subject = asunto;

            // Es un correo automático: que nadie conteste con un "fuera de
            // la oficina" que vuelva al emisor como si fuera una respuesta.
            mensaje.Headers.Add("Auto-Submitted", "auto-generated");
            mensaje.Headers.Add("X-Auto-Response-Suppress", "All");

            var cuerpo = new BodyBuilder { HtmlBody = html, TextBody = texto };

            if (logo is not null)
            {
                var recurso = cuerpo.LinkedResources.Add(
                    logo.Nombre, logo.Datos, ContentType.Parse(logo.TipoMime));
                recurso.ContentId = "logo-emisor";
            }

            if (adjunto is not null)
                cuerpo.Attachments.Add(
                    adjunto.Nombre, adjunto.Datos, ContentType.Parse(adjunto.TipoMime));

            mensaje.Body = cuerpo.ToMessageBody();

            using var cliente = new SmtpClient();

            var seguridad = _opciones.Puerto == 465
                ? SecureSocketOptions.SslOnConnect
                : SecureSocketOptions.StartTls;

            await cliente.ConnectAsync(_opciones.Host, _opciones.Puerto, seguridad, ct);

            if (!string.IsNullOrWhiteSpace(_opciones.Usuario))
                await cliente.AuthenticateAsync(_opciones.Usuario, _opciones.Clave, ct);

            await cliente.SendAsync(mensaje, ct);
            await cliente.DisconnectAsync(true, ct);

            _log.LogInformation("Correo de entrega '{Asunto}' enviado.", asunto);

            return null;
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            // En el registro no va la dirección del cliente: es un dato suyo,
            // y ya queda en la cola, que es donde se mira.
            _log.LogWarning(ex, "No se pudo enviar el correo de entrega '{Asunto}'.", asunto);

            return ex.Message;
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

/// <summary>Un archivo que va en un correo: adjunto o incrustado.</summary>
public sealed record AdjuntoCorreo(string Nombre, string TipoMime, byte[] Datos);
'@

# --- Facturacion.Api\EndpointsPortal.cs
Planear 'Facturacion.Api\EndpointsPortal.cs' 'D2451CC2F9019BD3FC099136CE5C084462756C27C0CD60A10406FDDEFF535BE6' @'
using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using Facturacion.Persistencia;

namespace Facturacion.Api;

/// <summary>
/// El portal del receptor: la página donde el cliente de cada emisor busca
/// su comprobante y lo descarga.
///
/// Cara pública: comprobantes.reyban.pe/{empresa}. Aquí todo cuelga de
/// /portal, y el proxy de producción añade ese prefijo (ver
/// despliegue-pendientes.md, §3.1).
///
/// ES LA ÚNICA PARTE DEL SERVICIO SIN CLAVE NI SESIÓN. Por eso:
///
///   - La empresa sale SIEMPRE de la dirección, y con ella se abre la sesión
///     con RLS. Lo que manda el navegador nunca elige empresa.
///   - Un acceso solo vale para la empresa de la dirección.
///   - Cualquier fallo responde lo mismo, para no ayudar a quien prueba.
///   - Los intentos se cuentan en la base, no en memoria: valen con varias
///     copias del servicio y sobreviven a un reinicio.
/// </summary>
public static partial class EndpointsPortal
{
    // Límite de intentos (diseño §2). Los dos a la vez: el del documento
    // protege a un cliente aunque el atacante cambie de red; el de la IP
    // frena a quien recorre clientes distintos.
    private const int MaxFallosDocumento = 5;   // en 15 minutos
    private const int MaxFallosIp = 30;         // en 1 hora

    private static readonly TimeSpan DuracionConsulta = TimeSpan.FromMinutes(30);

    private const string NoEncontrado = "No encontramos un comprobante con esos datos.";

    private const string CabeceraAcceso = "X-Portal-Acceso";

    // RUC, DNI, carné de extranjería y pasaporte. Sin "0" ni "-": una boleta a
    // consumidor final sin documento no tiene nada que solo su dueño sepa, y
    // solo se abre con el enlace del correo.
    private static readonly HashSet<string> TiposDocumento = new() { "6", "1", "4", "7" };

    private static readonly Dictionary<string, string> NombresTipo = new()
    {
        ["01"] = "Factura electrónica",
        ["03"] = "Boleta de venta electrónica",
        ["07"] = "Nota de crédito electrónica",
        ["08"] = "Nota de débito electrónica"
    };

    [GeneratedRegex("^[A-Za-z0-9_-]{43}$")]
    private static partial Regex FormaAcceso();

    [GeneratedRegex("^[A-Z0-9]{4}$")]
    private static partial Regex FormaSerie();

    public static void MapearPortal(this WebApplication app)
    {
        var grupo = app.MapGroup("/portal")
            .AddEndpointFilter(CabecerasPortal)
            .WithTags("Portal del receptor");

        // La página. La misma para la búsqueda y para el enlace del correo:
        // el JavaScript lee la dirección y sabe qué hacer.
        grupo.MapGet("/{empresa}", Pagina).ExcludeFromDescription();
        grupo.MapGet("/{empresa}/e/{enlace}", Pagina).ExcludeFromDescription();

        grupo.MapGet("/api/{empresa}", MarcaEmpresa)
            .WithSummary("La marca de la empresa: nombre, RUC, color y si tiene logo");

        grupo.MapGet("/api/{empresa}/logo", Logo)
            .WithSummary("El logo de la empresa");

        grupo.MapPost("/api/{empresa}/buscar", Buscar)
            .WithSummary("Opción A: busca un comprobante con cinco datos")
            .WithDescription(
                "Tipo y número de documento del cliente, serie, número, fecha de " +
                "emisión e importe total. Si cuadran, devuelve el comprobante y un " +
                "acceso de 30 minutos para descargarlo. Cualquier fallo responde " +
                "lo mismo. 5 fallos en 15 min por documento o 30 en 1 hora por IP " +
                "bloquean un rato.");

        grupo.MapGet("/api/{empresa}/comprobante", Resumen)
            .WithSummary("El comprobante de un acceso (cabecera X-Portal-Acceso)");

        grupo.MapGet("/api/{empresa}/comprobante/{archivo}", Descargar)
            .WithSummary("Descarga xml, cdr o pdf con un acceso (cabecera X-Portal-Acceso)");
    }

    // ------------------------------------------------------------- cabeceras

    /// <summary>
    /// Las cabeceras de todo lo que sale del portal.
    ///
    /// no-store: ni el navegador ni un proxy guardan un comprobante ajeno.
    /// no-referrer: el enlace del correo va en la dirección y no puede salir
    /// hacia otra web en la cabecera Referer. noindex: un buscador no tiene
    /// nada que hacer aquí. La CSP no deja cargar nada de fuera.
    /// </summary>
    private static async ValueTask<object?> CabecerasPortal(
        EndpointFilterInvocationContext contexto, EndpointFilterDelegate siguiente)
    {
        var h = contexto.HttpContext.Response.Headers;

        h.CacheControl = "no-store";
        h["Referrer-Policy"] = "no-referrer";
        h["X-Robots-Tag"] = "noindex, nofollow";
        h["X-Content-Type-Options"] = "nosniff";
        h["X-Frame-Options"] = "DENY";
        h["Content-Security-Policy"] =
            "default-src 'none'; script-src 'self' 'unsafe-inline'; " +
            "style-src 'self' 'unsafe-inline'; img-src 'self' blob: data:; " +
            "connect-src 'self'; base-uri 'none'; form-action 'none'; " +
            "frame-ancestors 'none'";

        return await siguiente(contexto);
    }

    // ------------------------------------------------------------- endpoints

    private static IResult Pagina(IWebHostEnvironment entorno)
    {
        var ruta = Path.Combine(entorno.WebRootPath ?? "", "portal.html");

        return File.Exists(ruta)
            ? Results.File(ruta, "text/html; charset=utf-8")
            : Results.NotFound();
    }

    private static async Task<IResult> MarcaEmpresa(
        string empresa, RepositorioPortal portal, CancellationToken ct)
    {
        var e = await portal.EmpresaAsync(empresa, ct);

        if (e is null)
            return Results.NotFound(new RespuestaError("No existe esta página."));

        return Results.Ok(new
        {
            razonSocial = e.RazonSocial,
            nombreComercial = string.IsNullOrWhiteSpace(e.NombreComercial) ? null : e.NombreComercial,
            ruc = e.Ruc,
            color = e.ColorMarca,
            tieneLogo = e.LogoRuta is not null
        });
    }

    private static async Task<IResult> Logo(
        string empresa, RepositorioPortal portal, IAlmacenArchivos archivos,
        CancellationToken ct)
    {
        var e = await portal.EmpresaAsync(empresa, ct);

        if (e?.LogoRuta is not { } ruta)
            return Results.NotFound();

        var datos = await archivos.LeerAsync(ruta, ct);

        return datos is not null && Marca.TipoDeImagen(datos) is { } tipo
            ? Results.File(datos, tipo.TipoMime)
            : Results.NotFound();
    }

    private static async Task<IResult> Buscar(
        string empresa, PeticionBusquedaPortal peticion, HttpContext http,
        RepositorioPortal portal, CancellationToken ct)
    {
        var e = await portal.EmpresaAsync(empresa, ct);

        if (e is null)
            return Results.NotFound(new RespuestaError("No existe esta página."));

        // Un dato con forma imposible no es un intento: es un error al
        // escribir. Se dice cuál, y no cuenta para el límite.
        if (Limpiar(peticion) is not { } busqueda)
            return Results.BadRequest(new RespuestaError(
                "Revisa los datos.", ProblemaDeForma(peticion)));

        var documento = Sha256($"{e.Id}|{busqueda.TipoDocumento}|{busqueda.NumeroDocumento}");
        var ip = http.Connection.RemoteIpAddress?.ToString() ?? "desconocida";

        var fallos = await portal.FallosRecientesAsync(e.Id, documento, ip, ct);

        // Bloqueado: la misma respuesta de siempre más el aviso, sin decir
        // cuánto falta. Y no se registra: el bloqueo dura lo que tarda en
        // envejecer el fallo más antiguo, no se alarga con cada intento.
        if (fallos.PorDocumento >= MaxFallosDocumento || fallos.PorIp >= MaxFallosIp)
            return Results.Json(
                new RespuestaError(NoEncontrado, "Demasiados intentos. Prueba dentro de un rato."),
                statusCode: StatusCodes.Status429TooManyRequests);

        var comprobante = await portal.BuscarAsync(e.Id, busqueda, ct);

        await portal.RegistrarIntentoAsync(e.Id, documento, ip, comprobante is not null, ct);

        if (comprobante is null)
            return Results.NotFound(new RespuestaError(NoEncontrado,
                "Revisa que los datos sean exactamente los del comprobante. " +
                "La fecha es la de emisión y el importe, el total con IGV."));

        var acceso = AccesoPortal.Nuevo();

        await portal.CrearAccesoAsync(
            e.Id, comprobante.Id, AccesoPortal.Hash(acceso), "consulta", DuracionConsulta, ct);

        return Results.Ok(new { acceso, comprobante = Resumir(comprobante) });
    }

    private static async Task<IResult> Resumen(
        string empresa, HttpContext http, RepositorioPortal portal, CancellationToken ct)
    {
        var (_, comprobante) = await ResolverAsync(empresa, http, portal, ct);

        return comprobante is null
            ? AccesoNoValido()
            : Results.Ok(new { comprobante = Resumir(comprobante) });
    }

    private static async Task<IResult> Descargar(
        string empresa, string archivo, HttpContext http,
        RepositorioPortal portal, RepositorioComprobantes comprobantes,
        IAlmacenArchivos archivos, CancellationToken ct)
    {
        var (e, c) = await ResolverAsync(empresa, http, portal, ct);

        if (e is null || c is null)
            return AccesoNoValido();

        if (archivo == "pdf")
        {
            var datos = await comprobantes.ObtenerParaPdfAsync(e.Id, c.Id, ct);

            return datos is null
                ? AccesoNoValido()
                : await PdfDeComprobante.ResponderAsync(datos, archivos, ct);
        }

        if (archivo is not ("xml" or "cdr"))
            return Results.NotFound();

        // Una boleta no tiene CDR propio (va en el resumen diario), y el
        // portal solo ofrece su PDF: la misma regla que la plataforma.
        if (EsBoleta(c))
            return Results.NotFound(new RespuestaError(
                "De una boleta solo se descarga el PDF."));

        var rutas = await comprobantes.ObtenerRutasAsync(e.Id, c.Id, ct);
        var ruta = archivo == "xml" ? rutas?.RutaXml : rutas?.RutaCdr;

        if (rutas is null || string.IsNullOrWhiteSpace(ruta))
            return Results.NotFound(new RespuestaError("Ese archivo no está disponible."));

        var contenido = await archivos.LeerAsync(ruta, ct);

        if (contenido is null)
            return Results.NotFound(new RespuestaError("Ese archivo no está disponible."));

        return archivo == "xml"
            ? Results.File(contenido, "application/xml", rutas.NombreDescarga("xml"))
            : Results.File(contenido, "application/zip", $"R-{rutas.NombreDescarga("zip")}");
    }

    // -------------------------------------------------------------- piezas

    /// <summary>
    /// La empresa de la dirección y el comprobante del acceso, o nulls.
    /// El acceso llega en una cabecera y no en la dirección: así no queda
    /// escrito en los registros del proxy ni en el historial.
    /// </summary>
    private static async Task<(EmpresaPortal? Empresa, ComprobantePortal? Comprobante)> ResolverAsync(
        string empresa, HttpContext http, RepositorioPortal portal, CancellationToken ct)
    {
        var acceso = http.Request.Headers[CabeceraAcceso].ToString();

        if (!FormaAcceso().IsMatch(acceso))
            return (null, null);

        var e = await portal.EmpresaAsync(empresa, ct);
        if (e is null) return (null, null);

        var comprobanteId = await portal.ResolverAccesoAsync(e.Id, AccesoPortal.Hash(acceso), ct);
        if (comprobanteId is not { } id) return (e, null);

        return (e, await portal.ObtenerAsync(e.Id, id, ct));
    }

    private static IResult AccesoNoValido() =>
        Results.NotFound(new RespuestaError(
            "Este acceso ya no es válido.",
            "Puede haber caducado o haberse anulado. Vuelve a buscar el " +
            "comprobante con tus datos."));

    private static bool EsBoleta(ComprobantePortal c) => c.TipoComprobante == "03";

    private static object Resumir(ComprobantePortal c) => new
    {
        tipo = c.TipoComprobante,
        tipoNombre = NombresTipo.GetValueOrDefault(c.TipoComprobante, c.TipoComprobante),
        numero = c.Numero,
        fechaEmision = c.FechaEmision.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture),
        moneda = c.Moneda,
        importeTotal = c.ImporteTotal,
        receptor = c.ReceptorNombre,
        anulado = c.Estado == "ANULADO",
        estado = c.Estado switch
        {
            "ACEPTADO" => "Aceptado por SUNAT",
            "ACEPTADO_CON_OBSERVACIONES" => "Aceptado por SUNAT con observaciones",
            "ANULADO" => "Anulado: dado de baja ante SUNAT",
            _ => c.Estado
        },
        archivos = new
        {
            pdf = true,
            xml = !EsBoleta(c) && c.TieneXml,
            cdr = !EsBoleta(c) && c.TieneCdr
        }
    };

    private static string Sha256(string texto) =>
        Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(texto))).ToLowerInvariant();

    /// <summary>Los cinco datos limpios, o null si alguno no tiene forma posible.</summary>
    private static BusquedaPortal? Limpiar(PeticionBusquedaPortal p)
    {
        var tipo = (p.TipoDocumento ?? "").Trim();
        var documento = (p.NumeroDocumento ?? "").Trim().ToUpperInvariant();
        var serie = (p.Serie ?? "").Trim().ToUpperInvariant();
        var numero = (p.Numero ?? "").Trim();
        var importe = (p.ImporteTotal ?? "").Trim().Replace(" ", "").Replace(",", ".");

        if (!TiposDocumento.Contains(tipo)) return null;
        if (documento.Length is < 6 or > 15 || !documento.All(char.IsLetterOrDigit)) return null;
        if (!FormaSerie().IsMatch(serie)) return null;
        if (!int.TryParse(numero, NumberStyles.None, CultureInfo.InvariantCulture, out var correlativo)
            || correlativo <= 0) return null;

        if (!DateTime.TryParseExact((p.FechaEmision ?? "").Trim(), "yyyy-MM-dd",
                CultureInfo.InvariantCulture, DateTimeStyles.None, out var fecha)) return null;

        if (!decimal.TryParse(importe, NumberStyles.AllowDecimalPoint,
                CultureInfo.InvariantCulture, out var total) || total < 0) return null;

        return new BusquedaPortal(
            tipo, documento, serie, correlativo,
            DateTime.SpecifyKind(fecha.Date, DateTimeKind.Unspecified),
            Math.Round(total, 2));
    }

    private static string ProblemaDeForma(PeticionBusquedaPortal p)
    {
        if (!TiposDocumento.Contains((p.TipoDocumento ?? "").Trim()))
            return "Elige el tipo de documento. Si tu comprobante no tiene documento " +
                   "(boleta sin DNI), ábrelo con el enlace del correo.";

        var documento = (p.NumeroDocumento ?? "").Trim();
        if (documento.Length is < 6 or > 15 || !documento.All(char.IsLetterOrDigit))
            return "El número de documento solo lleva letras y números.";

        if (!FormaSerie().IsMatch((p.Serie ?? "").Trim().ToUpperInvariant()))
            return "La serie tiene 4 caracteres, por ejemplo F001 o B001.";

        if (!int.TryParse((p.Numero ?? "").Trim(), NumberStyles.None,
                CultureInfo.InvariantCulture, out var n) || n <= 0)
            return "El número del comprobante solo lleva dígitos, por ejemplo 96.";

        if (!DateTime.TryParseExact((p.FechaEmision ?? "").Trim(), "yyyy-MM-dd",
                CultureInfo.InvariantCulture, DateTimeStyles.None, out _))
            return "Falta la fecha de emisión.";

        return "El importe total va con punto o coma decimal, por ejemplo 100.01.";
    }
}

/// <summary>
/// Lo que manda la página. Todo como texto: se limpia aquí, y un dato mal
/// escrito devuelve un mensaje en vez de un error de formato de JSON.
/// </summary>
public record PeticionBusquedaPortal(
    string? TipoDocumento,
    string? NumeroDocumento,
    string? Serie,
    string? Numero,
    string? FechaEmision,
    string? ImporteTotal);

/// <summary>
/// Cómo nace un acceso del portal y cómo se guarda.
///
/// EN UN SOLO SITIO A PROPÓSITO: la búsqueda (opción A) y el correo
/// (opción B) crean accesos, y la página los resuelve. Si dos sitios
/// calcularan el hash de forma distinta, los enlaces de los correos dejarían
/// de abrir sin que nada fallara al enviarlos.
/// </summary>
public static class AccesoPortal
{
    /// <summary>32 bytes aleatorios en base64url: 43 caracteres.</summary>
    public static string Nuevo() =>
        Convert.ToBase64String(RandomNumberGenerator.GetBytes(32))
            .TrimEnd('=').Replace('+', '-').Replace('/', '_');

    /// <summary>Lo que se guarda en la base: su SHA-256 en hexadecimal.</summary>
    public static string Hash(string acceso) =>
        Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(acceso))).ToLowerInvariant();
}
'@

# --- Facturacion.Api\PdfDeComprobante.cs
Planear 'Facturacion.Api\PdfDeComprobante.cs' 'B272B23D42576585F970ABACA59BDE06146BFBE5D4466D014A0A31C06C6E8DD0' @'
using System.Text.Json;
using Facturacion.Cpe;
using Facturacion.Pdf;
using Facturacion.Persistencia;

namespace Facturacion.Api;

/// <summary>
/// Reconstruye un comprobante guardado y genera su PDF.
///
/// POR QUÉ ESTO ES UNA CLASE Y NO DOS TROZOS DE CÓDIGO REPETIDOS:
///
/// Hay dos rutas que generan PDF y no se pueden juntar, porque resuelven de
/// quién es el comprobante de formas distintas:
///
///   /v1/comprobantes/{id}/pdf     lo pide el emisor con su clave
///   /admin/comprobantes/{id}/pdf  lo pide el operador desde el panel, que
///                                 primero averigua a qué empresa pertenece
///
/// Lo que sí es idéntico es TODO lo que viene después: saber qué tipo de
/// documento es, reconstruirlo desde el JSON, elegir el generador que le
/// toca y traducir el estado.
///
/// Eso estaba escrito dos veces, y pasó lo que siempre pasa: al aparecer la
/// liquidación de compra, la retención y la percepción, se arregló una ruta
/// y se olvidó la otra. /v1 devolvía el PDF y /admin devolvía "tipo de
/// comprobante no soportado: 04".
///
/// Ahora las dos llaman aquí. Un documento nuevo se añade en un solo sitio.
/// </summary>
public static class PdfDeComprobante
{
    private static readonly JsonSerializerOptions OpcionesJson = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        PropertyNameCaseInsensitive = true
    };

    /// <summary>
    /// Reconstruye el comprobante desde el JSON guardado.
    ///
    /// AQUÍ SE AÑADE UN DOCUMENTO NUEVO, y en ningún otro sitio de la API.
    /// </summary>
    public static ComprobanteBase Deserializar(DatosParaPdf datos) =>
        datos.TipoComprobante switch
        {
            TipoComprobante.Factura =>
                JsonSerializer.Deserialize<Factura>(datos.CpeJson, OpcionesJson)!,

            TipoComprobante.Boleta =>
                JsonSerializer.Deserialize<Boleta>(datos.CpeJson, OpcionesJson)!,

            TipoComprobante.NotaCredito =>
                JsonSerializer.Deserialize<NotaCredito>(datos.CpeJson, OpcionesJson)!,

            TipoComprobante.NotaDebito =>
                JsonSerializer.Deserialize<NotaDebito>(datos.CpeJson, OpcionesJson)!,

            LiquidacionCompra.Tipo =>
                JsonSerializer.Deserialize<LiquidacionCompra>(datos.CpeJson, OpcionesJson)!,

            ComprobanteRetencion.Tipo =>
                JsonSerializer.Deserialize<ComprobanteRetencion>(datos.CpeJson, OpcionesJson)!,

            ComprobantePercepcion.Tipo =>
                JsonSerializer.Deserialize<ComprobantePercepcion>(datos.CpeJson, OpcionesJson)!,

            _ => throw new InvalidOperationException(
                $"Tipo de comprobante no soportado: {datos.TipoComprobante}")
        };

    /// <summary>
    /// Elige el generador y produce el PDF.
    ///
    /// GeneradorPdf imprime una VENTA: detalle de productos, IGV que el
    /// cliente paga y un total que es el número más grande de la hoja. Los
    /// tres documentos de abajo no cumplen ninguna de las tres cosas, y por
    /// eso tienen el suyo.
    /// </summary>
    public static byte[] Generar(
        ComprobanteBase comprobante, string? digest, OpcionesImpresion opciones) =>
        comprobante switch
        {
            LiquidacionCompra lc =>
                GeneradorPdfEspeciales.Generar(lc, digest, opciones),

            ComprobanteRetencion r =>
                GeneradorPdfEspeciales.Generar(r, digest, opciones),

            ComprobantePercepcion p =>
                GeneradorPdfEspeciales.Generar(p, digest, opciones),

            _ => GeneradorPdf.Generar(comprobante, digest, opciones)
        };

    /// <summary>
    /// Cómo se imprime el estado en el pie del documento.
    ///
    /// Es lo que lee quien recibe el papel, así que dice qué pasó, no cómo se
    /// llama la constante en la base.
    /// </summary>
    public static string TextoEstado(string estado) => estado switch
    {
        "ACEPTADO" => "Aceptado por SUNAT",
        "ACEPTADO_CON_OBSERVACIONES" => "Aceptado con observaciones",
        "RECHAZADO" => "Rechazado por SUNAT",
        "ANULADO" => "Dado de baja",
        _ => "Pendiente de envío"
    };

    /// <summary>
    /// Convierte el `extra` guardado del comprobante en pares listos para
    /// imprimir.
    ///
    /// ESTO NO VIAJA A SUNAT Y NO DEBE VIAJAR. Son campos propios de la
    /// empresa: la orden de compra, un centro de costo, el nombre del
    /// vendedor. El XML no tiene sitio para ellos y el papel sí.
    ///
    /// UN JSON ILEGIBLE NO PUEDE IMPEDIR QUE SE ENTREGUE EL COMPROBANTE. Si
    /// algo no cuadra, devuelve null y el PDF sale exactamente como antes.
    /// Un dato de adorno no vale una factura que no se puede imprimir.
    ///
    /// Los objetos y los arreglos se descartan: no hay forma de ponerlos en
    /// una línea, y escribir su JSON crudo en una factura sería peor que no
    /// escribir nada.
    /// </summary>
    private static IReadOnlyDictionary<string, string>? LeerExtra(string? extraJson)
    {
        if (string.IsNullOrWhiteSpace(extraJson)) return null;

        try
        {
            using var doc = JsonDocument.Parse(extraJson);

            if (doc.RootElement.ValueKind != JsonValueKind.Object) return null;

            var pares = new Dictionary<string, string>();

            foreach (var campo in doc.RootElement.EnumerateObject())
            {
                var texto = campo.Value.ValueKind switch
                {
                    JsonValueKind.String => campo.Value.GetString(),
                    JsonValueKind.Number => campo.Value.GetRawText(),
                    JsonValueKind.True   => "Sí",
                    JsonValueKind.False  => "No",
                    _                    => null
                };

                if (!string.IsNullOrWhiteSpace(texto))
                    pares[campo.Name] = texto!;
            }

            return pares.Count > 0 ? pares : null;
        }
        catch (JsonException)
        {
            return null;
        }
    }

    /// <summary>
    /// El logo de la empresa, o null si no tiene o no se puede leer.
    ///
    /// Que el almacén falle al leer el logo tampoco impide el PDF: se
    /// entrega sin él.
    /// </summary>
    private static async Task<byte[]?> LeerLogoAsync(
        string? ruta, IAlmacenArchivos archivos, CancellationToken ct)
    {
        if (string.IsNullOrWhiteSpace(ruta)) return null;

        try
        {
            return await archivos.LeerAsync(ruta, ct);
        }
        catch (Exception) when (!ct.IsCancellationRequested)
        {
            return null;
        }
    }

    /// <summary>
    /// Todo el camino de una vez: comprobar el estado, reconstruir, leer el
    /// resumen de la firma y generar.
    ///
    /// Devuelve el PDF, o un IResult con el problema si algo impide hacerlo.
    /// Las dos rutas entran aquí con lo que cada una supo averiguar por su
    /// cuenta.
    /// </summary>
    public static async Task<IResult> ResponderAsync(
        DatosParaPdf datos, IAlmacenArchivos archivos, CancellationToken ct)
    {
        // UN PDF DE UN BORRADOR INDUCE A ERROR y por eso no se genera.
        //
        // El comprobante todavía no se firmó ni se envió: puede terminar
        // rechazado, y quien reciba ese papel creería que tiene algo válido.
        if (datos.Estado == "BORRADOR")
        {
            return Results.NotFound(new RespuestaError(
                "Todavía no se puede generar el PDF.",
                "El comprobante está en BORRADOR: aún no se firmó ni se envió " +
                "a SUNAT. Un PDF de algo que puede terminar rechazado induciría " +
                "a error a quien lo reciba."));
        }

        ComprobanteBase comprobante;

        try
        {
            comprobante = Deserializar(datos);
        }
        catch (Exception ex)
        {
            return Results.Problem(
                detail: $"No se pudo reconstruir el comprobante: {ex.Message}",
                statusCode: StatusCodes.Status500InternalServerError,
                title: "Comprobante ilegible");
        }

        var pdf = await GenerarBytesAsync(comprobante, datos, archivos, ct);

        return Results.File(pdf, "application/pdf", $"{datos.Numero}.pdf");
    }

    /// <summary>
    /// El PDF de un comprobante ya reconstruido, en bytes.
    ///
    /// Es lo mismo que sirve ResponderAsync, separado para que el correo de
    /// entrega adjunte EXACTAMENTE el mismo PDF que se descarga del panel y
    /// del portal. Dos caminos para hacer el PDF acabarían dando dos PDF.
    /// </summary>
    public static async Task<byte[]> GenerarBytesAsync(
        ComprobanteBase comprobante, DatosParaPdf datos,
        IAlmacenArchivos archivos, CancellationToken ct)
    {
        // EL RESUMEN DE LA FIRMA SE LEE DEL XML, no se recalcula.
        //
        // El QR debe declarar exactamente lo que se firmó. Calcularlo por
        // separado abriría la puerta a que los dos valores se separen sin que
        // nadie lo note, y un QR que no cuadra con la firma es peor que no
        // tener QR.
        string? digest = null;

        if (!string.IsNullOrWhiteSpace(datos.RutaXml))
        {
            var xml = await archivos.LeerAsync(datos.RutaXml, ct);

            if (xml is not null)
            {
                try
                {
                    digest = CodigoQr.LeerDigest(System.Xml.Linq.XDocument.Parse(
                        System.Text.Encoding.UTF8.GetString(xml)));
                }
                catch (Exception)
                {
                    // Sin resumen el PDF se genera igual, solo que su QR no
                    // podrá verificarse contra la firma. Entregar un documento
                    // incompleto es mejor que no entregar ninguno.
                }
            }
        }

        var logo = await LeerLogoAsync(datos.LogoRuta, archivos, ct);

        var opciones = new OpcionesImpresion(
            EstadoSunat: TextoEstado(datos.Estado),
            MensajeSunat: datos.MensajeSunat,
            Logo: logo,
            Extra: LeerExtra(datos.ExtraJson));

        byte[] pdf;

        try
        {
            pdf = Generar(comprobante, digest, opciones);
        }
        catch (Exception) when (logo is not null)
        {
            // UN LOGO QUE NO SE PUEDE DIBUJAR NO DEJA SIN COMPROBANTE A NADIE.
            //
            // Al subirlo se prueba a dibujarlo (Marca.ProblemaAlDibujar), así
            // que esto no debería pasar. Si pasa, el PDF sale sin logo: es el
            // mismo criterio que con `extra`. Un adorno no vale una factura
            // que no se puede entregar.
            pdf = Generar(comprobante, digest, opciones with { Logo = null });
        }

        return pdf;
    }
}
'@

# --- Facturacion.Api\Program.cs
Planear 'Facturacion.Api\Program.cs' '06850DE143A192D1BA2B80815160C4639CD0A46FDD1C15268E1A2CF5D3040A16' @'
using System.ComponentModel.DataAnnotations;
using System.Text.Json;
using Facturacion.Api;
using Facturacion.Cpe;
using Facturacion.Persistencia;
using Microsoft.OpenApi.Models;

// Los secretos se leen del entorno, no de appsettings.json.
//
// En desarrollo vienen de un archivo .env en la raíz de la solución, que
// está en el .gitignore. En producción los pone el contenedor o el gestor
// de secretos, y este código no cambia.
ConfiguracionSecretos.CargarArchivoEnv();

var builder = WebApplication.CreateBuilder(args);

// --- Servicios -------------------------------------------------------------

var cadenaConexion = ConfiguracionSecretos.CadenaPostgres(
    "facturacion_app", "FACTURACION_APP_PASSWORD",
    "la conexión de la aplicación, sujeta a Row Level Security");

// El diagnóstico mira TODAS las empresas, así que usa el rol de operador.
// Es una vista de infraestructura, no de cliente, y por eso su endpoint
// está protegido con una clave distinta.
var cadenaOperador = ConfiguracionSecretos.CadenaPostgres(
    "facturacion_operador", "FACTURACION_OPERADOR_PASSWORD",
    "las consultas del panel, que ven todas las empresas");

builder.Services.AddSingleton(new FabricaSesiones(cadenaConexion));
builder.Services.AddSingleton(new RepositorioDiagnostico(cadenaOperador));
builder.Services.AddSingleton<RepositorioTenants>();
builder.Services.AddSingleton<RepositorioComprobantes>();
builder.Services.AddSingleton<RepositorioPortal>();

// ALMACÉN COMPARTIDO CON EL WORKER.
//
// Los dos procesos leen y escriben en el mismo sitio. Con carpetas locales
// eso era frágil: bastaba que cada uno apuntara a una ruta distinta para que
// el worker generara archivos y la API respondiera que no existen.
//
// Con S3 el problema desaparece: ambos apuntan al mismo servidor, y da igual
// desde qué máquina corran.
var opcionesAlmacen = new OpcionesAlmacen();
builder.Configuration.GetSection("Almacen").Bind(opcionesAlmacen);

// Las credenciales del almacén también son secretos.
if (opcionesAlmacen.Tipo.Equals("s3", StringComparison.OrdinalIgnoreCase))
{
    opcionesAlmacen.Usuario = ConfiguracionSecretos.Exigir(
        "ALMACEN_USUARIO", "el acceso al almacén de comprobantes");

    opcionesAlmacen.Clave = ConfiguracionSecretos.Exigir(
        "ALMACEN_CLAVE", "el acceso al almacén de comprobantes");
}

builder.Services.AddSingleton(opcionesAlmacen);
builder.Services.AddSingleton(FabricaAlmacen.Crear(opcionesAlmacen));

// Administración de empresas, series y claves.
builder.Services.AddSingleton(new RepositorioAdmin(cadenaOperador));
builder.Services.AddSingleton(new RepositorioWebhooks(cadenaOperador));
builder.Services.AddSingleton(new RepositorioConsultas(cadenaOperador));
builder.Services.AddSingleton(new RepositorioRoles(cadenaOperador));

// Las guías tienen su propio repositorio: otra tabla, otro canal y otro
// ritmo de reintentos.
builder.Services.AddSingleton(proveedor =>
    new RepositorioGuias(
        proveedor.GetRequiredService<FabricaSesiones>(),
        cadenaOperador));

// La baja escribe en la misma tabla que los resúmenes, con tipo 'RA'.
builder.Services.AddSingleton(proveedor =>
    new RepositorioBajas(
        proveedor.GetRequiredService<FabricaSesiones>(),
        cadenaOperador));

// --- Correo ----------------------------------------------------------------
//
// Las credenciales son secretos y salen del .env, como todo lo demás. Si no
// están configuradas, el sistema funciona igual: los correos simplemente no
// se envían y queda constancia en el log.
var opcionesCorreo = new OpcionesCorreo
{
    Host = ConfiguracionSecretos.Opcional("MAIL_HOST", ""),
    Puerto = int.TryParse(
        ConfiguracionSecretos.Opcional("MAIL_PORT", "587"), out var puertoCorreo)
        ? puertoCorreo : 587,
    Usuario = ConfiguracionSecretos.Opcional("MAIL_USUARIO", ""),
    Clave = ConfiguracionSecretos.Opcional("MAIL_CLAVE", ""),
    Desde = ConfiguracionSecretos.Opcional("MAIL_DESDE", ""),
    Nombre = ConfiguracionSecretos.Opcional("MAIL_NOMBRE", "Facturación electrónica"),
    UrlPanel = ConfiguracionSecretos.Opcional("PANEL_URL", "https://localhost:7295"),

    // La dirección pública del portal del receptor, para el enlace del
    // correo de entrega. En producción: https://comprobantes.reyban.pe.
    // Vacía: la del panel con /portal, que es lo que sirve en desarrollo.
    UrlPortal = ConfiguracionSecretos.Opcional("PORTAL_URL", "")
};

builder.Services.AddSingleton(opcionesCorreo);
builder.Services.AddSingleton<ServicioCorreo>();

// El correo de entrega del portal: la cola (rol de operador, recorre todas
// las empresas) y el proceso que la vacía cada 30 segundos.
builder.Services.AddSingleton(new RepositorioCorreosPortal(cadenaOperador));
builder.Services.AddHostedService<ServicioCorreosEntrega>();

// El repositorio de usuarios necesita el protector para cifrar el secreto
// del segundo factor, igual que los certificados.
builder.Services.AddSingleton(proveedor =>
    new RepositorioUsuarios(
        cadenaOperador,
        proveedor.GetRequiredService<IProtectorDeSecretos>()));

// El operador de cada petición. Con ámbito de petición, como el emisor.
builder.Services.AddScoped<ContextoOperador>();

// La API necesita la llave maestra porque cifra los certificados al cargarlos.
// Si falta la variable de entorno, el proceso no arranca: es preferible a
// descubrirlo cuando alguien intente subir un certificado.
builder.Services.AddSingleton<IProtectorDeSecretos>(_ => ProtectorAesGcm.DesdeEntorno());
builder.Services.AddSingleton<AlmacenCertificados>();

// El panel necesita comprobar si una empresa está lista para producción.
builder.Services.AddSingleton(proveedor =>
    new ProveedorCredenciales(
        cadenaOperador,
        proveedor.GetRequiredService<IProtectorDeSecretos>()));

// Con ámbito de petición: cada llamada tiene su propio emisor.
builder.Services.AddScoped<ContextoEmisor>();

builder.Services.ConfigureHttpJsonOptions(opciones =>
{
    opciones.SerializerOptions.PropertyNamingPolicy = JsonNamingPolicy.CamelCase;
    opciones.SerializerOptions.DefaultIgnoreCondition =
        System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull;
});

// --- Documentación interactiva ---------------------------------------------
//
// Swagger sirve para dos cosas distintas, y la segunda importa más:
//
//   1. Probar la API sin escribir un cliente.
//   2. Ser el contrato que le entregas a quien integra. Cuando un cliente
//      pregunte "¿qué campos acepta?", la respuesta es una URL, no un correo
//      con un ejemplo que quedará desactualizado.
//
// En producción conviene protegerlo o desactivarlo: expone la forma completa
// de la API a cualquiera que la alcance.

builder.Services.AddEndpointsApiExplorer();

builder.Services.AddSwaggerGen(opciones =>
{
    opciones.SwaggerDoc("v1", new OpenApiInfo
    {
        Title = "Servicio de facturación electrónica",
        Version = "v1",
        Description =
            "Emisión de comprobantes electrónicos para SUNAT.\n\n" +
            "Toda petición requiere una clave de acceso.\n\n" +
            "**Emisión y consulta** (`/v1/*`): la clave determina qué empresa " +
            "emite, así que el RUC del emisor NO se envía en el cuerpo. " +
            "En Authorize, campo `ApiKey`, escribe `Bearer` seguido de la " +
            "clave que se le entregó a esa empresa.\n\n" +
            "**Administración** (`/admin/*`): se entra con usuario y " +
            "contraseña desde el panel, y la sesión viaja en una cookie.\n\n" +
            "Ninguna clave aparece en esta documentación a propósito: si " +
            "estuviera aquí, estaría también en el repositorio."
    });

    // DOS ESQUEMAS DE AUTENTICACIÓN, Y ES A PROPÓSITO.
    //
    // Los emisores usan su clave en Authorization: Bearer. El panel usa
    // sesión con cookie, que el navegador envía sola.
    //
    // Declarar el primero en Swagger no es un detalle cosmético: sin él,
    // probar la API obligaría a escribir comandos a mano, y eso hace que se
    // pruebe menos.

    opciones.AddSecurityDefinition("ApiKey", new OpenApiSecurityScheme
    {
        Name = "Authorization",
        Type = SecuritySchemeType.ApiKey,
        In = ParameterLocation.Header,
        Description =
            "Clave del EMISOR. Escribe: Bearer {tu clave}\n\n" +
            "Sirve para /v1/*: emitir comprobantes, guías y consultarlos.",
        Scheme = "Bearer"
    });

    opciones.AddSecurityRequirement(new OpenApiSecurityRequirement
    {
        {
            new OpenApiSecurityScheme
            {
                Reference = new OpenApiReference
                {
                    Type = ReferenceType.SecurityScheme,
                    Id = "ApiKey"
                }
            },
            Array.Empty<string>()
        }
    });
});

var app = builder.Build();

// Comprobar el almacén AL ARRANCAR, no al primer uso.
//
// Descubrir que la configuración está mal cuando un cliente emite su primera
// factura es mucho peor que descubrirlo al encender el servicio.
if (app.Services.GetRequiredService<IAlmacenArchivos>() is AlmacenArchivosS3 almacenS3)
{
    var mensaje = await almacenS3.ComprobarAsync();
    app.Logger.LogInformation("{Mensaje}", mensaje);
}

// --- Middleware ------------------------------------------------------------

if (app.Environment.IsDevelopment())
{
    app.UseSwagger();

    app.UseSwaggerUI(opciones =>
    {
        opciones.SwaggerEndpoint("/swagger/v1/swagger.json", "Facturación v1");

        opciones.RoutePrefix = "docs";
        opciones.DocumentTitle = "Facturación electrónica";
    });
}

// Aviso si el correo no está configurado.
//
// No impide arrancar: el sistema funciona sin correo. Pero conviene saberlo
// antes de que alguien pida recuperar su contraseña y no le llegue nada.
if (!opcionesCorreo.Configurado)
{
    app.Logger.LogWarning(
        "El correo NO está configurado. La recuperación de contraseña y los " +
        "avisos no se enviarán. Rellena MAIL_HOST, MAIL_DESDE y las demás " +
        "variables en el .env.");
}

// Primer administrador, si todavía no hay ninguno.
//
// Sin usuarios no se puede entrar al panel, y sin entrar no se pueden crear
// usuarios. Alguien tiene que romper ese círculo, y es este arranque.
{
    var usuarios = app.Services.GetRequiredService<RepositorioUsuarios>();

    var correo = ConfiguracionSecretos.Opcional(
        "ADMIN_CORREO", "admin@localhost");

    var provisional = await usuarios.AsegurarPrimerAdministradorAsync(
        correo,
        Environment.GetEnvironmentVariable("ADMIN_CONTRASENA"));

    if (provisional is not null)
    {
        app.Logger.LogWarning(
            "PRIMER ADMINISTRADOR CREADO.\n" +
            "  Correo:     {Correo}\n" +
            "  Contraseña: {Clave}\n" +
            "Se pedirá cambiarla al entrar. Este mensaje NO se repite: " +
            "anótala ahora.",
            correo, provisional);
    }
}

// Sirve el panel desde wwwroot.
app.UseDefaultFiles();
app.UseStaticFiles();

// Registra en la bitácora toda acción que modifique algo.
app.UseMiddleware<AuditoriaPanel>();

app.UseMiddleware<AutenticacionApiKey>();

// --- Endpoints -------------------------------------------------------------

app.MapearSesion();
app.MapearRoles();
app.MapearDiagnostico();
app.MapearAdministracion();
app.MapearWebhooks();
app.MapearConsultas();
app.MapearNotas();
app.MapearDescargas();
app.MapearGuias();
app.MapearLiquidaciones();
app.MapearRetencionPercepcion();
app.MapearBajas();
app.MapearAnulacionBoletas();
app.MapearEstadoSunat();
app.MapearPortal();
app.MapearPortalAdmin();

app.MapGet("/health", () => Results.Ok(new { estado = "vivo" }))
   .WithName("Salud")
   .WithTags("Servicio")
   .WithSummary("Comprueba que el servicio responde. No requiere clave.");

// La raíz lleva al panel.
//
// Devolver un JSON informativo era cómodo para desarrollar y confuso para
// quien llega desde un correo: ve un texto técnico y no sabe qué hacer.
app.MapGet("/", () => Results.Redirect("/login.html"))
   .ExcludeFromDescription();


/// Emite un comprobante.
///
/// Responde 202 Accepted: el comprobante quedó registrado, pero TODAVÍA NO
/// fue a SUNAT. Eso lo hará el worker. Esperar aquí a SUNAT dejaría la
/// petición colgada varios segundos y el sistema caería cuando SUNAT caiga.
app.MapPost("/v1/comprobantes", async (
    PeticionComprobante peticion,
    HttpContext contexto,
    ContextoEmisor emisor,
    RepositorioComprobantes repositorio,
    ILogger<Program> registro,
    CancellationToken ct) =>
{
    var tenant = emisor.Exigir();

    // --- Validación del contrato ---
    var errores = new List<ValidationResult>();

    if (!Validator.TryValidateObject(
            peticion, new ValidationContext(peticion), errores, validateAllProperties: true))
    {
        return Results.BadRequest(new RespuestaError(
            "La petición no es válida.",
            string.Join(" ", errores.Select(e => e.ErrorMessage))));
    }

    if (peticion.Lineas.Count == 0)
        return Results.BadRequest(new RespuestaError(
            "El comprobante necesita al menos una línea."));

    // El correo del receptor es opcional, pero si viene tiene que tener forma
    // de correo: un comprobante aceptado cuyo correo rebota es un cliente que
    // cree que no le facturaron.
    if (peticion.Receptor.ProblemaCorreo() is { } problemaCorreo)
        return Results.BadRequest(new RespuestaError(
            "El correo del receptor no es válido.", problemaCorreo));

    if (peticion.Moneda != "PEN" && peticion.TipoCambio is null)
        return Results.BadRequest(new RespuestaError(
            "Falta el tipo de cambio.",
            "Los comprobantes en moneda distinta de PEN deben declararlo."));

    // La detracción solo existe en facturas.
    //
    // SUNAT no la admite en boletas porque no dan crédito fiscal, y el
    // sistema de detracciones está pensado para operaciones que sí lo dan.
    if (peticion.Detraccion is not null && peticion.Tipo != TipoComprobante.Factura)
    {
        return Results.BadRequest(new RespuestaError(
            "La detracción solo aplica a facturas.",
            "SUNAT no admite detracción en comprobantes que no dan crédito " +
            "fiscal, como las boletas."));
    }

    // Los anticipos, de momento, solo en facturas.
    //
    // SUNAT sí los admite en boletas, pero las boletas viajan por resumen
    // diario, que es otro formato con sus propias reglas y que no hemos
    // probado con anticipos. Rechazarlo es más honesto que aceptarlo y
    // emitir un comprobante donde el anticipo no aparece por ningún lado.
    if (peticion.Anticipos.Count > 0 && peticion.Tipo != TipoComprobante.Factura)
    {
        return Results.BadRequest(new RespuestaError(
            "Los anticipos solo están implementados en facturas.",
            "Las boletas viajan por resumen diario, y ese camino todavía no " +
            "declara anticipos."));
    }

    // La percepción, por lo mismo que los anticipos.
    if (peticion.Percepcion is not null && peticion.Tipo != TipoComprobante.Factura)
    {
        return Results.BadRequest(new RespuestaError(
            "La percepción solo está implementada en facturas.",
            "Las boletas viajan por resumen diario, y ese camino todavía no " +
            "declara percepción."));
    }

    // Las cuotas de crédito, lo mismo.
    //
    // SUNAT solo las exige cuando el receptor tiene RUC, y una boleta nunca
    // lo tiene, así que en rigor no harían falta. Pero el resumen diario no
    // las declara, y aceptarlas para después perderlas es peor que decir
    // que no están.
    if (peticion.Cuotas.Count > 0 && peticion.Tipo != TipoComprobante.Factura)
    {
        return Results.BadRequest(new RespuestaError(
            "Las cuotas de crédito solo están implementadas en facturas.",
            "Las boletas viajan por resumen diario, y ese formato no declara " +
            "cuotas."));
    }

    // --- Construcción del comprobante ---
    // El emisor sale del tenant, NUNCA de la petición.

    ComprobanteBase comprobante;

    try
    {
        comprobante = ConstruirComprobante(peticion, tenant);
    }
    catch (ArgumentException ex)
    {
        return Results.BadRequest(new RespuestaError("Datos inválidos.", ex.Message));
    }

    // LOS AVISOS DE PLAZO NO BLOQUEAN, PERO TIENEN QUE VERSE.
    //
    // Facturar el lunes una venta del sábado es legítimo y frecuente. Lo que
    // no puede pasar es que nadie sepa que ese comprobante vence hoy, porque
    // si el envío falla no hay segunda oportunidad: SUNAT lo rechaza con el
    // 2108 y queda emitido sin declarar.
    foreach (var aviso in ReglasFechaEmision.Avisos(comprobante)
                 .Concat(ReglasIsc.Avisos(comprobante))
                 .Concat(comprobante is Factura fx
                     ? ReglasHidrobiologicos.Revisar(fx)
                         .Where(p => p.StartsWith("Aviso:"))
                     : []))
        registro.LogWarning("{Serie}: {Aviso}", peticion.Serie, aviso);


    // --- Los anticipos tienen que existir de verdad ---
    //
    // SUNAT valida esto con las reglas 3218 y 3219, pero solo en producción:
    // en beta su listado de comprobantes está vacío y acepta cualquier
    // número inventado. Lo comprobamos aquí mientras el anticipo lo haya
    // emitido este mismo contribuyente, que es el caso normal.
    //
    // Si lo emitió otro RUC, SUNAT admite el caso y nosotros no tenemos
    // forma de verificarlo: se deja pasar y que decida SUNAT.

    foreach (var anticipo in peticion.Anticipos)
    {
        if (anticipo.RucEmisor != tenant.Ruc) continue;

        var partes = (anticipo.Numero ?? "").Split('-');

        if (partes.Length != 2 || !int.TryParse(partes[1], out var correlativoPrevio))
        {
            return Results.BadRequest(new RespuestaError(
                "El número del comprobante de anticipo no es válido.",
                $"'{anticipo.Numero}' debería tener la forma SERIE-CORRELATIVO."));
        }

        // CATÁLOGO 12 → CATÁLOGO 01, Y NO SON EL MISMO NÚMERO.
        //
        // En el bloque de anticipos, "02" significa factura. En nuestra base
        // la factura es "01". Buscar por "02" no encontraría nada, y el
        // error acusaría al usuario de algo que hizo bien.
        var tipoEnLaBase = anticipo.TipoComprobante == TipoComprobanteAnticipo.Factura
            ? TipoComprobante.Factura
            : TipoComprobante.Boleta;

        var previo = await repositorio.BuscarPorNumeroAsync(
            tenant.Id, tipoEnLaBase, partes[0], correlativoPrevio, ct);

        if (previo is null)
        {
            return Results.BadRequest(new RespuestaError(
                "El comprobante del anticipo no existe.",
                $"No se encontró {anticipo.Numero} entre los comprobantes de " +
                "este emisor. SUNAT lo rechazaría con el error 3218."));
        }

        if (previo.Estado is not ("ACEPTADO" or "ACEPTADO_CON_OBSERVACIONES"))
        {
            return Results.BadRequest(new RespuestaError(
                "El comprobante del anticipo todavía no fue aceptado.",
                $"{anticipo.Numero} está en estado {previo.Estado}. Solo se " +
                "puede descontar un anticipo que SUNAT ya aceptó (error 3219)."));
        }

        if (previo.Moneda != peticion.Moneda)
        {
            return Results.BadRequest(new RespuestaError(
                "El anticipo está en otra moneda.",
                $"{anticipo.Numero} se emitió en {previo.Moneda} y esta factura " +
                $"está en {peticion.Moneda}. SUNAT exige la misma moneda en " +
                "todo el documento."));
        }

        // SE PUEDE DESCONTAR MENOS, NUNCA MÁS.
        //
        // Aplicar solo una parte del anticipo es legítimo: un adelanto grande
        // puede repartirse entre dos entregas. Declarar más de lo que aquella
        // factura cobró no lo es nunca.
        //
        // Esta comprobación atrapa de paso el error más común del módulo:
        // mandar el monto SIN IGV. Como sale un 18% por debajo, no salta
        // aquí — pero si alguien manda el valor con IGV de una factura que
        // no lo llevaba, sí.
        if (anticipo.MontoTotal > previo.ImporteTotal)
        {
            return Results.BadRequest(new RespuestaError(
                "El anticipo declara más de lo que su factura cobró.",
                $"{anticipo.Numero} se emitió por {previo.ImporteTotal:0.00} y " +
                $"aquí se declaran {anticipo.MontoTotal:0.00}."));
        }
    }

    // --- Persistencia ---

    var idempotencyKey = contexto.Request.Headers["Idempotency-Key"].ToString();

    try
    {
        var guardado = await repositorio.CrearAsync(
            tenant.Id,
            comprobante,
            extraJson: peticion.Extra is null
                ? null
                : JsonSerializer.Serialize(peticion.Extra),
            idempotencyKey: string.IsNullOrWhiteSpace(idempotencyKey) ? null : idempotencyKey,
            correoReceptor: peticion.Receptor.CorreoLimpio(),
            ct: ct);

        var respuesta = RespuestaComprobante.Desde(guardado, peticion.Moneda);

        // Si la clave de idempotencia ya se había usado, no se creó nada:
        // se devuelve el comprobante original con 200, no con 202.
        return guardado.YaExistia
            ? Results.Ok(respuesta)
            : Results.Accepted($"/v1/comprobantes/{guardado.Id}", respuesta);
    }
    catch (InvalidOperationException ex)
    {
        // Serie inexistente o inactiva.
        return Results.BadRequest(new RespuestaError("No se pudo emitir.", ex.Message));
    }
})
.WithName("EmitirComprobante")
.WithTags("Comprobantes")
.WithSummary("Emite una factura o boleta")
.WithDescription(
    "Responde 202: el comprobante queda registrado, pero todavía NO fue a SUNAT. " +
    "Eso lo hace el worker.\n\n" +
    "Envía la cabecera Idempotency-Key para que un reintento no produzca un duplicado: " +
    "si la clave ya se usó, responde 200 con el comprobante original.\n\n" +
    "**Detracción:** si la operación está sujeta al SPOT, incluye el objeto " +
    "`detraccion`. El monto se calcula solo si no lo envías.\n\n" +
    "**Percepción:** solo si el emisor es agente de percepción designado, y " +
    "solo al contado. El importe total del comprobante sale SIN percepción: " +
    "el total con percepción viaja en un bloque aparte del XML.\n\n" +
    "**Crédito:** si la forma de pago es `Credito` y el receptor tiene RUC, " +
    "hay que enviar al menos una cuota en `cuotas`, con su monto y su fecha " +
    "de vencimiento. SUNAT lo exige desde 2022.\n\n" +
    "**Operaciones gratuitas:** lo que se entrega sin cobrar va en su propia " +
    "línea, con su valor referencial en `valorUnitario` y el código que " +
    "corresponda en `tipoAfectacionIgv` — el más habitual es `15`, " +
    "bonificaciones. No suman al importe total: el cliente paga lo mismo. " +
    "El IGV de esas líneas sí se declara, y lo asume el emisor.\n\n" +
    "**Cargos y descuentos globales:** en `cargosGlobales`, con el código " +
    "del catálogo 53 — `50` cargo, `03` descuento, `45` FISE, `46` recargo " +
    "al consumo. Esos cuatro no generan IGV ni entran en el valor de venta: " +
    "solo mueven el importe a pagar.\n\n" +
    "El `49` es la excepción: SÍ se suma a la base imponible y genera su " +
    "propio IGV. Para un descuento que reduzca el IGV, usa " +
    "`descuentoGlobalPorcentaje`.\n\n" +
    "**Detracción de pesca:** con `tipoOperacion` `1002` y código de bien " +
    "`004`, hay que enviar el bloque `hidrobiologicos` con los seis datos " +
    "del desembarque. SUNAT los cruza contra el parte de descarga.\n\n" +
    "**Retenciones:** `62` retención del IGV, que es informativa y no mueve " +
    "el importe total; `63` retención de renta de segunda categoría, que sí " +
    "resta. La `62` necesita `baseImponible` y `porcentaje`.\n\n" +
    "**ICBPER:** las bolsas de plástico van en su propia línea con " +
    "`afectoIcbper: true`. La cantidad de esa línea es el número de bolsas. " +
    "La tasa sale sola de la fecha de emisión —0.50 soles por bolsa desde " +
    "2023— y este impuesto SÍ sube el importe total.\n\n" +
    "**IVAP (arroz pilado):** afectación `17` en las líneas. Sustituye al " +
    "IGV con una tasa del 4%, y es excluyente: si una línea lo lleva, todas " +
    "tienen que llevarlo. No hace falta enviar `porcentajeIgv`.\n\n" +
    "**Plazo:** SUNAT da 3 días calendario para que una factura le llegue, " +
    "y 7 para una boleta. Pasado el plazo la rechaza con el error 2108 y el " +
    "correlativo se pierde, así que una petición con `fechaEmision` vencida " +
    "se rechaza aquí mismo.\n\n" +
    "**ISC:** en la línea, con `sistemaIsc` (catálogo 08) y `tasaIsc`. " +
    "A diferencia de los demás impuestos, el ISC **entra en la base del " +
    "IGV**: con 1000 de valor y 10% de ISC, el IGV sale sobre 1100.")
.Produces<RespuestaComprobante>(StatusCodes.Status202Accepted)
.Produces<RespuestaComprobante>(StatusCodes.Status200OK)
.Produces<RespuestaError>(StatusCodes.Status400BadRequest)
.Produces<RespuestaError>(StatusCodes.Status401Unauthorized);


/// Estado de un comprobante.
app.MapGet("/v1/comprobantes/{id:guid}", async (
    Guid id,
    ContextoEmisor emisor,
    RepositorioComprobantes repositorio,
    CancellationToken ct) =>
{
    var tenant = emisor.Exigir();

    var comprobante = await repositorio.ObtenerAsync(tenant.Id, id, ct);

    // Si el comprobante es de otra empresa, Row Level Security hace que
    // simplemente no exista para esta consulta. El 404 es correcto y además
    // no revela que el identificador pertenece a alguien más.
    return comprobante is null
        ? Results.NotFound(new RespuestaError("No se encontró el comprobante."))
        : Results.Ok(RespuestaEstado.Desde(comprobante));
})
.WithName("ConsultarComprobante")
.WithTags("Comprobantes")
.WithSummary("Estado de un comprobante")
.Produces<RespuestaEstado>()
.Produces<RespuestaError>(StatusCodes.Status404NotFound);


/// Lista los comprobantes del emisor.
app.MapGet("/v1/comprobantes", async (
    ContextoEmisor emisor,
    RepositorioComprobantes repositorio,
    int? limite,
    CancellationToken ct) =>
{
    var tenant = emisor.Exigir();

    var comprobantes = await repositorio.ListarAsync(
        tenant.Id, Math.Clamp(limite ?? 50, 1, 200), ct);

    return Results.Ok(comprobantes.Select(RespuestaEstado.Desde));
})
.WithName("ListarComprobantes")
.WithTags("Comprobantes")
.WithSummary("Lista los comprobantes del emisor")
.Produces<IEnumerable<RespuestaEstado>>();


/// Historial de intentos de un comprobante.
app.MapGet("/v1/comprobantes/{id:guid}/historial", async (
    Guid id,
    ContextoEmisor emisor,
    RepositorioComprobantes repositorio,
    CancellationToken ct) =>
{
    var tenant = emisor.Exigir();

    var historial = await repositorio.HistorialAsync(tenant.Id, id, ct);

    return Results.Ok(historial.Select(i => new
    {
        intento = i.IntentoNro,
        desde = i.EstadoAnterior,
        hasta = i.EstadoNuevo,
        codigoSunat = i.CodigoSunat,
        mensaje = i.Mensaje,
        duracionMs = i.DuracionMs,
        fecha = i.CreadoEn
    }));
})
.WithName("HistorialComprobante")
.WithTags("Comprobantes")
.WithSummary("Bitácora de un comprobante")
.WithDescription(
    "Cada cambio de estado, con su código de SUNAT y su duración. " +
    "La bitácora es append-only: nunca se modifica ni se borra.");


/// Datos del emisor autenticado. Útil para verificar que la clave funciona.
app.MapGet("/v1/emisor", async (
    ContextoEmisor emisor, AlmacenCertificados certificados, CancellationToken ct) =>
{
    var tenant = emisor.Exigir();

    // EL VENCIMIENTO DEL CERTIFICADO, para que quien integra avise antes.
    //
    // El dato existía, pero solo en `/admin/tenants/{id}/certificados`, que va
    // con la sesión del panel y cruza empresas: nadie de fuera puede ni debe
    // usar esa ruta. Aquí sale solo la fecha del activo de ESTA empresa.
    // Null si no tiene certificado cargado.
    var validoHasta = await certificados.VencimientoActivoAsync(tenant.Id, ct);

    return Results.Ok(new
    {
        ruc = tenant.Ruc,
        razonSocial = tenant.RazonSocial,
        ambiente = tenant.Ambiente,
        certificadoValidoHasta = validoHasta,
        certificadoDiasParaVencer = validoHasta is { } h
            ? (int?)Math.Ceiling((h - DateTime.UtcNow).TotalDays)
            : null
    });
})
.WithName("Emisor")
.WithTags("Servicio")
.WithSummary("Datos del emisor autenticado")
.WithDescription("Sirve para verificar que una clave de acceso funciona.");

app.Run();


// ---------------------------------------------------------------------------

static ComprobanteBase ConstruirComprobante(
    PeticionComprobante peticion, TenantResuelto tenant)
{
    var emisor = new Emisor
    {
        Ruc = tenant.Ruc,
        RazonSocial = tenant.RazonSocial,
        NombreComercial = tenant.NombreComercial,
        Ubigeo = tenant.Ubigeo,
        Direccion = tenant.Direccion,
        Distrito = tenant.Distrito,
        Provincia = tenant.Provincia,
        Departamento = tenant.Departamento
    };

    var receptor = new Receptor
    {
        TipoDocumento = peticion.Receptor.TipoDocumento,
        NumeroDocumento = peticion.Receptor.NumeroDocumento,
        RazonSocial = peticion.Receptor.RazonSocial,
        Direccion = peticion.Receptor.Direccion
    };

    // EL RECEPTOR SE REVISA LO PRIMERO, y antes de gastar un correlativo.
    //
    // Un RUC con el digito verificador cambiado no existe, y la factura
    // emitida a ese numero hay que anularla con una nota de credito. Eso
    // cuesta mas que este if.
    var problemasReceptor = ReglasReceptor.Errores(receptor);

    if (problemasReceptor.Count > 0)
        throw new ArgumentException(string.Join(" ", problemasReceptor));

    if (peticion.Tipo == TipoComprobante.Factura &&
    !TipoOperacion.EsExportacion(peticion.TipoOperacion ?? "") &&
    receptor.TipoDocumento != TipoDocIdentidad.Ruc)
    {
        throw new ArgumentException(
            $"Una factura solo se puede emitir a un RUC, y el receptor llego " +
            $"con documento de tipo '{receptor.TipoDocumento}'. Si el cliente " +
            $"no tiene RUC, el documento que le corresponde es una boleta de " +
            $"venta (tipo 03). La unica factura que admite otro documento es " +
            $"la de exportacion, y esa se declara con tipo de operacion " +
            $"0200-0208.");
    }

    var lineas = peticion.Lineas.Select((l, indice) => new LineaComprobante
    {
        Numero = indice + 1,
        CodigoProducto = l.CodigoProducto,
        Descripcion = l.Descripcion,
        UnidadMedida = l.UnidadMedida,
        Cantidad = l.Cantidad,
        ValorUnitario = l.ValorUnitario,
        DescuentoPorcentaje = l.DescuentoPorcentaje,
        TipoAfectacionIgv = l.TipoAfectacionIgv,
        PorcentajeIgv = l.PorcentajeIgv
            ?? AfectacionIgv.TasaPorDefecto(l.TipoAfectacionIgv),
        AfectoIcbper = l.AfectoIcbper,
        IcbperUnitario = l.IcbperUnitario,
        SistemaIsc = l.SistemaIsc,
        TasaIsc = l.TasaIsc
    }).ToList();

    // --- Que un dedazo en la afectación dé 400 y no 500 ---------------------
    //
    // Un "1O" con la letra O en vez del cero llegaba hasta el cálculo de
    // totales y reventaba allí con una excepción interna: el cliente de la
    // API recibía "error del servidor" y no tenía forma de saber qué había
    // puesto mal.
    //
    // Con quince códigos válidos en el catálogo 07 —los cuatro de siempre
    // más las once gratuitas— el dedazo ya no es raro.

    var afectacionesRaras = lineas
        .Where(l => !AfectacionIgv.Existe(l.TipoAfectacionIgv))
        .Select(l => $"la linea {l.Numero} llego con '{l.TipoAfectacionIgv}'")
        .ToList();

    if (afectacionesRaras.Count > 0)
    {
        throw new ArgumentException(
            "Hay afectaciones de IGV que no existen en el catalogo 07: " +
            $"{string.Join(", ", afectacionesRaras)}.");
    }

    var tipoCambio = peticion.TipoCambio is null ? null : new TipoCambio
    {
        MonedaOrigen = peticion.TipoCambio.MonedaOrigen,
        MonedaDestino = peticion.TipoCambio.MonedaDestino,
        Tasa = peticion.TipoCambio.Tasa,
        Fecha = peticion.TipoCambio.Fecha ?? RelojPeru.Hoy
    };

    var fecha = peticion.FechaEmision ?? RelojPeru.Ahora;

    // LA FACTURA SE CONSTRUYE APARTE porque puede llevar detracción, y eso
    // no cabe en un inicializador: el monto depende de los totales, y los
    // totales dependen de la factura ya completa.
    if (peticion.Tipo == TipoComprobante.Factura)
    {
        var factura = new Factura
        {
            Serie = peticion.Serie,
            FechaEmision = fecha,
            Moneda = peticion.Moneda,
            FormaPago = peticion.FormaPago,
            TipoOperacion = peticion.TipoOperacion,
            PaisDeUso = peticion.PaisDeUso,
            Drawback = peticion.Drawback,
            DescuentoGlobalPorcentaje = peticion.DescuentoGlobalPorcentaje,
            TipoCambio = tipoCambio,
            Emisor = emisor,
            Receptor = receptor,
            Lineas = lineas
        };

        // LOS CARGOS GLOBALES VAN LOS PRIMEROS, y el orden no es casual:
        // cambian el importe total, y la detracción, la percepción y las
        // cuotas se comprueban todas contra ese importe. Copiarlos después
        // haría que esas tres miraran un total que ya no es el final.
        factura.CargosGlobales = MapearCargosGlobales(peticion);

        // Las cuotas se copian antes que nada: la revisión de crédito mira
        // los totales, y los totales no cambian por las cuotas, pero sí las
        // demás revisiones miran la factura entera.
        factura.Cuotas = peticion.Cuotas.Select(c => new CuotaCredito
        {
            Numero = c.Numero,
            Monto = c.Monto,
            FechaVencimiento = c.FechaVencimiento
        }).ToList();

        if (peticion.Detraccion is not null)
            AplicarDetraccion(factura, peticion.Detraccion);

        // Los anticipos se copian ANTES de revisar nada, porque cambian
        // los totales y las dos revisiones miran totales.
        factura.Anticipos = peticion.Anticipos.Select(a => new Anticipo
        {
            IdentificadorPago = a.IdentificadorPago,
            TipoComprobante = a.TipoComprobante,
            Numero = a.Numero,
            RucEmisor = a.RucEmisor,
            MontoTotal = a.MontoTotal,
            FechaPago = a.FechaPago,
            TipoAfectacion = a.TipoAfectacion,
            PorcentajeIgv = a.PorcentajeIgv
        }).ToList();

        if (peticion.Percepcion is not null)
            AplicarPercepcion(factura, peticion.Percepcion);

        var problemasExportacion = Exportacion.Errores(factura);

        if (problemasExportacion.Count > 0)
            throw new ArgumentException(string.Join(" ", problemasExportacion));

        var problemasAnticipos = ReglasAnticipos.Errores(factura);

        if (problemasAnticipos.Count > 0)
            throw new ArgumentException(string.Join(" ", problemasAnticipos));

        var problemasPercepcion = ReglasPercepcion.Errores(factura);

        if (problemasPercepcion.Count > 0)
            throw new ArgumentException(string.Join(" ", problemasPercepcion));

        var problemasCredito = ReglasCredito.Errores(factura);

        if (problemasCredito.Count > 0)
            throw new ArgumentException(string.Join(" ", problemasCredito));

        // Las líneas gratuitas y los cargos globales se revisan lo mismo que
        // en la boleta de más abajo, y por eso están escritos dos veces en
        // vez de una: la factura sale por su propio return, unas líneas
        // antes de que exista el comprobante genérico.
        var problemasGratuitas = Gratuitas.Errores(factura);

        if (problemasGratuitas.Count > 0)
            throw new ArgumentException(string.Join(" ", problemasGratuitas));

        var problemasCargos = ReglasCargosGlobales.Errores(factura);

        if (problemasCargos.Count > 0)
            throw new ArgumentException(string.Join(" ", problemasCargos));

        var problemasIcbper = ReglasIcbper.Errores(factura);

        if (problemasIcbper.Count > 0)
            throw new ArgumentException(string.Join(" ", problemasIcbper));

        var problemasIvap = ReglasIvap.Errores(factura);

        if (problemasIvap.Count > 0)
            throw new ArgumentException(string.Join(" ", problemasIvap));

        // Los datos del desembarque se copian ANTES de revisar, porque la
        // revision los mira, y se vuelcan en la primera linea: SUNAT solo
        // comprueba que cada codigo exista en el comprobante.
        if (peticion.Hidrobiologicos is { } h)
        {
            factura.Hidrobiologicos = new RecursosHidrobiologicos(
                h.Matricula,
                h.NombreEmbarcacion,
                h.TipoEspecie,
                h.LugarDescarga,
                h.FechaDescarga,
                h.CantidadEspecie);

            if (factura.Lineas.Count > 0)
            {
                factura.Lineas[0].Propiedades =
                    factura.Hidrobiologicos.ComoPropiedades().ToList();
            }
        }

        var problemasHidro = ReglasHidrobiologicos.Errores(factura);

        if (problemasHidro.Count > 0)
            throw new ArgumentException(string.Join(" ", problemasHidro));

        var problemasIsc = ReglasIsc.Errores(factura);

        if (problemasIsc.Count > 0)
            throw new ArgumentException(string.Join(" ", problemasIsc));

        // La fecha, al final: necesita saber el tipo de comprobante, porque
        // el plazo de una factura no es el de una boleta.
        var problemasFecha = ReglasFechaEmision.Errores(factura);

        if (problemasFecha.Count > 0)
            throw new ArgumentException(string.Join(" ", problemasFecha));

        return factura;
    }

    var comprobante = peticion.Tipo switch
    {
        TipoComprobante.Boleta => new Boleta
        {
            Serie = peticion.Serie,
            FechaEmision = fecha,
            Moneda = peticion.Moneda,
            FormaPago = peticion.FormaPago,
            DescuentoGlobalPorcentaje = peticion.DescuentoGlobalPorcentaje,
            TipoCambio = tipoCambio,
            Emisor = emisor,
            Receptor = receptor,
            Lineas = lineas,
            CargosGlobales = MapearCargosGlobales(peticion)
        },

        _ => throw new ArgumentException(
            $"Tipo de comprobante no soportado por este endpoint: {peticion.Tipo}. " +
            "Las notas de crédito y débito tienen su propia ruta.")
    };

    // Una bonificación en una boleta es tan común como en una factura: el
    // "llévate 3 y paga 2" de mostrador va casi siempre a consumidor final.
    //
    // OJO: esto rechaza lo que está mal, pero las boletas todavía viajan por
    // resumen diario y ese camino no declara el total de gratuitas. Hasta
    // que lo haga, las bonificaciones conviene emitirlas en factura.
    var problemasGratuitasBoleta = Gratuitas.Errores(comprobante);

    if (problemasGratuitasBoleta.Count > 0)
        throw new ArgumentException(string.Join(" ", problemasGratuitasBoleta));

    // El recargo al consumo es el caso típico de boleta: un restaurante que
    // cobra el 10% a un consumidor final.
    var problemasCargosBoleta = ReglasCargosGlobales.Errores(comprobante);

    if (problemasCargosBoleta.Count > 0)
        throw new ArgumentException(string.Join(" ", problemasCargosBoleta));

    // EL ICBPER ES, SOBRE TODO, UN ASUNTO DE BOLETAS: grava las bolsas que
    // se entregan a un consumidor final, y el consumidor final compra con
    // boleta. Que funcione aqui importa mas que en la factura.
    var problemasIcbperBoleta = ReglasIcbper.Errores(comprobante);

    if (problemasIcbperBoleta.Count > 0)
        throw new ArgumentException(string.Join(" ", problemasIcbperBoleta));

    var problemasIvapBoleta = ReglasIvap.Errores(comprobante);

    if (problemasIvapBoleta.Count > 0)
        throw new ArgumentException(string.Join(" ", problemasIvapBoleta));

    var problemasIscBoleta = ReglasIsc.Errores(comprobante);

    if (problemasIscBoleta.Count > 0)
        throw new ArgumentException(string.Join(" ", problemasIscBoleta));

    var problemasFechaBoleta = ReglasFechaEmision.Errores(comprobante);

    if (problemasFechaBoleta.Count > 0)
        throw new ArgumentException(string.Join(" ", problemasFechaBoleta));

    return comprobante;
}

/// <summary>
/// Pasa los cargos y descuentos globales del DTO al modelo.
///
/// Está aparte porque lo usan las dos ramas —factura y boleta— y porque
/// duplicar un mapeo es la forma más silenciosa de que un campo nuevo se
/// copie en un sitio y en el otro no.
/// </summary>
static List<CargoGlobal> MapearCargosGlobales(PeticionComprobante peticion) =>
    peticion.CargosGlobales.Select(cg => new CargoGlobal
    {
        Codigo = cg.Codigo,
        Monto = cg.Monto,
        BaseImponible = cg.BaseImponible,
        Porcentaje = cg.Porcentaje,
        Descripcion = cg.Descripcion
    }).ToList();

/// <summary>
/// Añade los datos de detracción a una factura ya construida.
///
/// SE HACE APARTE Y NO EN EL INICIALIZADOR porque necesita los totales, y los
/// totales necesitan la factura completa. Calcularlo todo de una vez obligaría
/// a duplicar aquí la lógica del IGV y los descuentos, que es justo el tipo de
/// duplicación que termina divergiendo.
///
/// Lanza ArgumentException si los datos no sirven, para que el endpoint
/// responda 400 con el motivo en vez de dejar que SUNAT lo rechace después.
/// </summary>
static void AplicarDetraccion(Factura factura, DetraccionDto datos)
{
    var totales = CalculadoraTotales.Calcular(factura);

    factura.Detraccion = new Detraccion(
        datos.TipoOperacion,
        datos.CodigoBienServicio,
        datos.Porcentaje,

        // Si el cliente no manda el monto, se calcula.
        //
        // Es lo habitual: el porcentaje lo sabe, pero el redondeo al entero
        // que hace el Banco de la Nación no tiene por qué conocerlo.
        datos.Monto ?? Detraccion.CalcularMonto(
            totales.ImporteTotal, datos.Porcentaje),

        datos.CuentaBancoNacion,
        datos.MedioDePago);

    var problemas = factura.Detraccion.Revisar(totales.ImporteTotal, factura.Moneda);

    // Los avisos empiezan por "Aviso:" y NO impiden emitir.
    //
    // El del umbral de 700 soles es uno: hay operaciones que se detraen
    // igualmente por acuerdo o régimen especial. Bloquearlo haría que el
    // sistema decidiera por el contribuyente en un asunto que es suyo.
    var errores = problemas.Where(p => !p.StartsWith("Aviso:")).ToList();

    if (errores.Count > 0)
        throw new ArgumentException(string.Join(" ", errores));
}

/// <summary>
/// Añade la percepción a una factura ya construida.
///
/// SE HACE APARTE, como la detracción, porque necesita el importe total y
/// el importe total necesita la factura completa.
///
/// LA BASE VA SIEMPRE EN SOLES. Si la factura está en otra moneda hay que
/// convertirla: SUNAT exige la percepción en moneda nacional aunque todo lo
/// demás del documento esté en dólares. Es la única excepción que admite a
/// "la moneda debe ser la misma en todo el comprobante".
/// </summary>
static void AplicarPercepcion(Factura factura, PercepcionDto datos)
{
    if (!RegimenPercepcion.Existe(datos.Regimen))
    {
        throw new ArgumentException(
            $"El regimen de percepcion '{datos.Regimen}' no existe en el " +
            $"catalogo 22. Solo 01 (venta interna), 02 (combustible) y " +
            $"03 (agente con tasa especial).");
    }

    var totales = CalculadoraTotales.Calcular(factura);

    // El importe total, convertido a soles si hace falta.
    //
    // La tasa que corresponde es la que YA se declaró en este comprobante,
    // no otra consultada aparte: si se usara una distinta, el XML diría dos
    // cosas diferentes sobre el mismo día y el mismo documento.
    var baseEnSoles = factura.Moneda == "PEN"
        ? totales.ImporteTotal
        : CalculadoraTotales.Redondear(
            totales.ImporteTotal * (factura.TipoCambio?.Tasa ?? 0m));

    var porcentaje = datos.Porcentaje
        ?? RegimenPercepcion.TasaReferencia(datos.Regimen);

    factura.Percepcion = new Percepcion(
        datos.Regimen,
        porcentaje,
        baseEnSoles,

        // Si el cliente no manda el monto, se calcula. Es lo habitual: el
        // régimen lo sabe, el redondeo no tiene por qué conocerlo.
        datos.Monto ?? Percepcion.CalcularMonto(baseEnSoles, porcentaje));
}
'@

# --- Facturacion.Api\wwwroot\comprobantes.html
Planear 'Facturacion.Api\wwwroot\comprobantes.html' 'AF628DDB643C366969814E72D500E5FBE7FBB4B0E89FE2317E346714FA73AE4B' @'
<!DOCTYPE html>
<html lang="es">
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Comprobantes · Facturación electrónica</title>
    <style>
        :root {
            --fondo: #f6f7f9;
            --panel: #ffffff;
            --sutil: #f1f3f5;
            --borde: #e3e6ea;
            --borde-fuerte: #cfd4da;
            --texto: #1b1f24;
            --tenue: #5c6570;
            --apagado: #8a929c;
            --acento: #2563eb;
            --acento-fondo: #eef4ff;
            --ok: #15803d;
            --ok-fondo: #eaf6ee;
            --aviso: #a16207;
            --aviso-fondo: #fdf5e3;
            --mal: #b91c1c;
            --mal-fondo: #fdeded;
            --radio: 8px;
        }

        @media (prefers-color-scheme: dark) {
            :root {
                --fondo: #0f1115;
                --panel: #171a21;
                --sutil: #1c212b;
                --borde: #262b36;
                --borde-fuerte: #3a4152;
                --texto: #e6e8ec;
                --tenue: #98a1ae;
                --apagado: #6f7884;
                --acento: #4493f8;
                --acento-fondo: #12233c;
                --ok: #3fb950;
                --ok-fondo: #122a18;
                --aviso: #d29922;
                --aviso-fondo: #2b2311;
                --mal: #f85149;
                --mal-fondo: #2d1516;
            }
        }

        * {
            box-sizing: border-box;
        }

        body {
            margin: 0;
            padding: 22px;
            background: var(--fondo);
            color: var(--texto);
            font: 15px/1.55 ui-sans-serif, system-ui, "Segoe UI", sans-serif;
        }

        .contenedor {
            max-width: 1280px;
            margin: 0 auto;
        }

        header {
            display: flex;
            align-items: center;
            justify-content: space-between;
            gap: 16px;
            margin-bottom: 6px;
            flex-wrap: wrap;
        }

        h1 {
            font-size: 19px;
            margin: 0;
            font-weight: 500;
        }

        nav {
            display: flex;
            gap: 18px;
            border-bottom: 1px solid var(--borde);
            margin-bottom: 16px;
        }

            nav a {
                color: var(--tenue);
                text-decoration: none;
                font-size: 14px;
                padding: 0 2px 9px;
                border-bottom: 2px solid transparent;
                margin-bottom: -1px;
            }

                nav a:hover {
                    color: var(--texto);
                }

                nav a.activo {
                    color: var(--texto);
                    border-bottom-color: var(--acento);
                }

        input, select, button {
            font: inherit;
            font-size: 14px;
            color: var(--texto);
            background: var(--panel);
            border: 1px solid var(--borde);
            border-radius: var(--radio);
            padding: 7px 11px;
        }

            input:focus, select:focus {
                outline: none;
                border-color: var(--acento);
            }

        button {
            cursor: pointer;
        }

            button:hover:not(:disabled) {
                border-color: var(--borde-fuerte);
            }

            button:disabled {
                opacity: .5;
                cursor: default;
            }

            button.principal {
                background: var(--acento);
                border-color: var(--acento);
                color: #fff;
                font-weight: 500;
            }

            button.mini {
                padding: 4px 9px;
                font-size: 12.5px;
            }

        .tarjeta {
            background: var(--panel);
            border: 1px solid var(--borde);
            border-radius: 12px;
            padding: 16px 18px;
            margin-bottom: 14px;
        }

        .filtros {
            display: grid;
            grid-template-columns: minmax(220px,1.6fr) repeat(auto-fit,minmax(130px,1fr));
            gap: 10px;
            align-items: end;
        }

        label {
            display: block;
            font-size: 12px;
            color: var(--tenue);
            margin-bottom: 4px;
        }

            label input, label select {
                width: 100%;
            }

        .buscador {
            position: relative;
        }

            .buscador input {
                padding-left: 32px;
            }

            .buscador svg {
                position: absolute;
                left: 10px;
                bottom: 9px;
                width: 15px;
                height: 15px;
                stroke: var(--apagado);
                fill: none;
                stroke-width: 2;
            }

        table {
            width: 100%;
            border-collapse: collapse;
            font-size: 13.5px;
        }

        th {
            text-align: left;
            color: var(--tenue);
            font-weight: 400;
            padding: 7px 8px;
            border-bottom: 1px solid var(--borde);
            font-size: 12.5px;
            white-space: nowrap;
        }

        td {
            padding: 9px 8px;
            border-bottom: 1px solid var(--borde);
            vertical-align: middle;
        }

        tr:last-child td {
            border-bottom: none;
        }

        tr.fila:hover td {
            background: var(--sutil);
        }

        .mono {
            font-family: ui-monospace, Consolas, monospace;
            font-size: 12.5px;
        }

        .tenue {
            color: var(--tenue);
        }

        .num {
            text-align: right;
            white-space: nowrap;
        }

        .recorte {
            max-width: 190px;
            overflow: hidden;
            text-overflow: ellipsis;
            white-space: nowrap;
        }

        .vacio {
            color: var(--tenue);
            padding: 26px 0;
            text-align: center;
        }

        .insignia {
            font-size: 11.5px;
            padding: 2px 8px;
            border-radius: var(--radio);
            white-space: nowrap;
        }

        .i-ok {
            background: var(--ok-fondo);
            color: var(--ok);
        }

        .i-aviso {
            background: var(--aviso-fondo);
            color: var(--aviso);
        }

        .i-mal {
            background: var(--mal-fondo);
            color: var(--mal);
        }

        .i-tenue {
            background: var(--sutil);
            color: var(--tenue);
        }


        .usuario {
            display: flex;
            align-items: center;
            gap: 12px;
            font-size: 13.5px;
            color: var(--tenue);
        }

            .usuario .rol {
                background: var(--sutil);
                border-radius: var(--radio);
                padding: 2px 9px;
                font-size: 12px;
            }

            .usuario a {
                color: var(--acento);
                text-decoration: none;
            }

                .usuario a:hover {
                    text-decoration: underline;
                }

        .pestanas {
            display: flex;
            gap: 16px;
            border-bottom: 1px solid var(--borde);
            margin-bottom: 16px;
        }

        .pestana {
            font-size: 14px;
            color: var(--tenue);
            cursor: pointer;
            padding: 0 2px 9px;
            border: none;
            background: none;
            border-bottom: 2px solid transparent;
            margin-bottom: -1px;
        }

            .pestana.activa {
                color: var(--texto);
                border-bottom-color: var(--acento);
            }

        .paginacion {
            display: flex;
            align-items: center;
            justify-content: space-between;
            gap: 12px;
            margin-top: 14px;
            font-size: 13.5px;
            color: var(--tenue);
        }

        #avisos {
            position: fixed;
            top: 18px;
            right: 18px;
            z-index: 60;
            display: flex;
            flex-direction: column;
            gap: 8px;
            max-width: 370px;
        }

        .flotante {
            background: var(--panel);
            border: 1px solid var(--borde);
            border-left: 3px solid var(--acento);
            border-radius: var(--radio);
            padding: 11px 14px;
            font-size: 14px;
            box-shadow: 0 6px 22px rgba(0,0,0,.14);
        }

            .flotante.mal {
                border-left-color: var(--mal);
            }

            .flotante.ok {
                border-left-color: var(--ok);
            }

            .flotante .t {
                font-weight: 500;
            }

            .flotante .d {
                color: var(--tenue);
                font-size: 13px;
                margin-top: 2px;
            }

        .velo {
            position: fixed;
            inset: 0;
            background: rgba(15,18,23,.5);
            z-index: 70;
            display: none;
            align-items: center;
            justify-content: center;
            padding: 20px;
        }

            .velo.visible {
                display: flex;
            }

        .modal {
            background: var(--panel);
            border: 1px solid var(--borde);
            border-radius: 14px;
            padding: 22px 24px;
            width: 100%;
            max-width: 720px;
            max-height: 86vh;
            overflow-y: auto;
        }

            .modal h3 {
                margin: 0 0 3px;
                font-size: 17px;
                font-weight: 500;
            }

            .modal .sub {
                color: var(--tenue);
                font-size: 13.5px;
                margin-bottom: 16px;
            }

            .modal .cerrar {
                display: flex;
                justify-content: flex-end;
                margin-top: 16px;
            }
    </style>
</head>
<body>

    <div id="avisos"></div>

    <div class="velo" id="velo-detalle">
        <div class="modal">
            <h3 id="d-titulo"></h3>
            <div class="sub" id="d-sub"></div>
            <div id="d-cuerpo"></div>
            <div class="cerrar"><button id="d-cerrar">Cerrar</button></div>
        </div>
    </div>

    <div class="contenedor">
        <header>
            <h1>Facturación electrónica</h1>
            <div id="usuario-actual" class="usuario"></div>
        </header>

        <nav>
            <a href="/diagnostico.html">Estado del servicio</a>
            <a href="/admin.html">Empresas</a>
            <a href="/comprobantes.html" class="activo">Comprobantes</a>
            <a href="/cuenta.html">Mi cuenta</a>
        </nav>

        <div class="pestanas">
            <button class="pestana activa" data-vista="comprobantes">Comprobantes</button>
            <button class="pestana" data-vista="guias">Guías de remisión</button>
        </div>

        <div class="tarjeta">
            <div class="filtros">
                <div class="buscador">
                    <label for="f-texto">Buscar</label>
                    <svg viewBox="0 0 24 24"><circle cx="11" cy="11" r="7" /><path d="M20 20l-3.5-3.5" /></svg>
                    <input id="f-texto" placeholder="RUC, empresa, número o cliente">
                </div>

                <label>
                    Tipo
                    <select id="f-tipo">
                        <option value="">Todos</option>
                        <option value="01">Factura</option>
                        <option value="03">Boleta</option>
                        <option value="04">Liquidación de compra</option>
                        <option value="07">Nota de crédito</option>
                        <option value="08">Nota de débito</option>
                        <option value="20">Comprobante de retención</option>
                        <option value="40">Comprobante de percepción</option>
                    </select>
                </label>

                <label>
                    Estado
                    <select id="f-estado">
                        <option value="">Todos</option>
                        <option value="ACEPTADO">Aceptado</option>
                        <option value="ACEPTADO_CON_OBSERVACIONES">Con observaciones</option>
                        <option value="RECHAZADO">Rechazado</option>
                        <option value="BORRADOR">Pendiente</option>
                        <option value="ENCOLADO">En proceso</option>
                        <option value="ANULADO">Anulado</option>
                    </select>
                </label>

                <label>Desde<input id="f-desde" type="date"></label>
                <label>Hasta<input id="f-hasta" type="date"></label>

                <button class="principal" id="btn-buscar">Buscar</button>
            </div>
        </div>

        <div class="tarjeta" id="resultados">
            <div class="vacio">Cargando…</div>
        </div>
    </div>

    <script src="/fechas.js"></script>
    <script>
        // NO SE USA "$" COMO NOMBRE DE FUNCIÓN: Browser Link, la herramienta de
        // Visual Studio que recarga la página al guardar, inyecta jQuery y espera
        // encontrarlo ahí.
        const elem = id => document.getElementById(id);

        // SE DEFINE AQUÍ, ANTES QUE CUALQUIER FUNCIÓN QUE LA USE.
        //
        // Las constantes declaradas con const no existen hasta que su línea se
        // ejecuta, aunque la función que las llama esté escrita más arriba. Tenerla
        // al final del archivo hacía que la cabecera del usuario fallara con
        // "esc is not defined", y el panel se quedaba en "Cargando...".
        const esc = t => String(t ?? "").replace(/[&<>"']/g,
            c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));

        const estado = { vista: "comprobantes", pagina: 1, ultima: null };


        // ---------------------------------------------------------------- sesión
        //
        // La autenticación va por cookie, no por una clave escrita en la página.
        // La cookie es HttpOnly: este JavaScript no puede leerla, el navegador la
        // envía sola. Si algún día se cuela un script malicioso, no podrá robarla.

        let usuarioActual = null;


        // ------------------------------------------------------------------- menú
        //
        // El menú se arma según los permisos del usuario: cada quien ve solo las
        // pantallas que puede usar.
        //
        // OCULTAR NO ES PROTEGER. El servidor comprueba el permiso en cada petición;
        // esto solo evita mostrar opciones que darían un error al pulsarlas.

        const PANTALLAS = [
            { url: "/diagnostico.html", texto: "Estado del servicio", permiso: "diagnostico.ver" },
            { url: "/admin.html", texto: "Empresas", permiso: "empresas.ver" },
            { url: "/comprobantes.html", texto: "Comprobantes", permiso: "comprobantes.ver" },
            { url: "/usuarios.html", texto: "Usuarios", permiso: "usuarios.gestionar" },
            { url: "/cuenta.html", texto: "Mi cuenta", permiso: null }
        ];

        const puede = permiso => usuarioActual?.permisos?.includes(permiso) === true;

        function pintarMenu() {
            const menu = document.querySelector("nav");
            if (!menu) return;

            const actual = location.pathname;

            menu.innerHTML = PANTALLAS
                .filter(p => p.permiso === null || puede(p.permiso))
                .map(p => `<a href="${p.url}" class="${actual === p.url ? "activo" : ""}">
                     ${esc(p.texto)}</a>`)
                .join("");
        }

        async function cargarUsuario() {
            const r = await fetch("/admin/yo");

            if (r.status === 401) {
                location.href = "/login.html";
                return false;
            }

            usuarioActual = await r.json();

            const caja = elem("usuario-actual");

            if (caja) {
                caja.innerHTML =
                    `<span>${esc(usuarioActual.nombre || usuarioActual.correo)}</span>` +
                    `<span class="rol">${esc(usuarioActual.rol)}</span>` +
                    `<a href="#" id="salir">Salir</a>`;

                elem("salir").onclick = async e => {
                    e.preventDefault();
                    await fetch("/admin/sesion", { method: "DELETE" });
                    location.href = "/login.html";
                };
            }

            pintarMenu();

            return true;
        }

        elem("btn-buscar").onclick = () => { estado.pagina = 1; buscar(); };

        document.querySelectorAll("[data-vista]").forEach(b =>
            b.onclick = () => {
                estado.vista = b.dataset.vista;
                estado.pagina = 1;

                document.querySelectorAll("[data-vista]").forEach(x =>
                    x.classList.toggle("activa", x.dataset.vista === estado.vista));

                // Los filtros no son los mismos: una guía no tiene tipo de comprobante
                // ni importe, y sus estados son otros.
                ajustarFiltros();

                buscar();
            });

        function ajustarFiltros() {
            const esGuia = estado.vista === "guias";

            // El tipo de comprobante no aplica a las guías.
            elem("f-tipo").parentElement.style.display = esGuia ? "none" : "";

            elem("f-texto").placeholder = esGuia
                ? "RUC, empresa, número, destinatario o PLACA"
                : "RUC, empresa, número o cliente";

            // Los estados de una guía incluyen ANULADO y no incluyen los de boleta.
            const opciones = esGuia
                ? [["", "Todos"], ["ACEPTADO", "Aceptada"],
                ["RECHAZADO", "Rechazada"], ["ENVIADO", "Esperando respuesta"],
                ["ENCOLADO", "En proceso"], ["BORRADOR", "Pendiente"],
                ["ANULADO", "Anulada"]]
                : [["", "Todos"], ["ACEPTADO", "Aceptado"],
                ["ACEPTADO_CON_OBSERVACIONES", "Con observaciones"],
                ["RECHAZADO", "Rechazado"], ["BORRADOR", "Pendiente"],
                ["ENCOLADO", "En proceso"], ["ANULADO", "Anulado"]];

            elem("f-estado").innerHTML = opciones
                .map(([v, t]) => `<option value="${v}">${t}</option>`).join("");
        }
        elem("d-cerrar").onclick = () => elem("velo-detalle").classList.remove("visible");

        ["f-texto", "f-tipo", "f-estado", "f-desde", "f-hasta"].forEach(id =>
            elem(id).onkeydown = e => { if (e.key === "Enter") { estado.pagina = 1; buscar(); } });

        function avisar(titulo, detalle = "", tipo = "") {
            const caja = document.createElement("div");
            caja.className = "flotante " + tipo;
            caja.innerHTML = `<div class="t">${esc(titulo)}</div>` +
                (detalle ? `<div class="d">${esc(detalle)}</div>` : "");
            elem("avisos").appendChild(caja);
            setTimeout(() => caja.remove(), tipo === "mal" ? 8000 : 4000);
        }

        async function api(ruta) {
            const r = await fetch(ruta);

            if (r.status === 401) {
                location.href = "/login.html";
                throw new Error("Sesión caducada.");
            }

            const cuerpo = await r.json().catch(() => ({}));

            if (!r.ok) {
                const error = new Error(cuerpo.error || `Error ${r.status}`);
                error.detalle = cuerpo.detalle || "";
                throw error;
            }

            return cuerpo;
        }

        async function buscar() {
            const parametros = new URLSearchParams();

            const texto = elem("f-texto").value.trim();
            if (texto) parametros.set("texto", texto);
            if (estado.vista !== "guias" && elem("f-tipo").value)
                parametros.set("tipo", elem("f-tipo").value);
            if (elem("f-estado").value) parametros.set("estado", elem("f-estado").value);
            if (elem("f-desde").value) parametros.set("desde", elem("f-desde").value);
            if (elem("f-hasta").value) parametros.set("hasta", elem("f-hasta").value);

            parametros.set("pagina", estado.pagina);
            parametros.set("porPagina", 25);

            const boton = elem("btn-buscar");
            boton.disabled = true;

            try {
                const ruta = estado.vista === "guias"
                    ? "/admin/comprobantes/guias?"
                    : "/admin/comprobantes?";

                estado.ultima = await api(ruta + parametros);

                if (estado.vista === "guias") pintarGuias();
                else pintar();
            } catch (e) {
                elem("resultados").innerHTML =
                    `<div class="vacio" style="color:var(--mal)">${esc(e.message)}</div>`;
            } finally {
                boton.disabled = false;
            }
        }

        function pintar() {
            const d = estado.ultima;

            if (d.total === 0) {
                elem("resultados").innerHTML =
                    `<div class="vacio">Ningún comprobante coincide con la búsqueda.</div>`;
                return;
            }

            elem("resultados").innerHTML = `
        <table>
          <tr>
            <th>Emisor</th><th>Comprobante</th><th>Fecha</th><th>Cliente</th>
            <th class="num">Importe</th><th>Estado</th>
            <th style="text-align:right">Archivos</th>
          </tr>
          ${d.resultados.map(fila).join("")}
        </table>

        <div class="paginacion">
          <span>${d.total.toLocaleString("es-PE")}
            ${d.total === 1 ? "comprobante" : "comprobantes"}</span>
          <span>
            <button class="mini" id="btn-anterior" ${d.pagina <= 1 ? "disabled" : ""}>Anterior</button>
            <span style="margin:0 10px">Página ${d.pagina} de ${d.paginas}</span>
            <button class="mini" id="btn-siguiente" ${d.pagina >= d.paginas ? "disabled" : ""}>Siguiente</button>
          </span>
        </div>`;

            elem("btn-anterior").onclick = () => { estado.pagina--; buscar(); };
            elem("btn-siguiente").onclick = () => { estado.pagina++; buscar(); };

            document.querySelectorAll("[data-detalle]").forEach(b =>
                b.onclick = () => verDetalle(b.dataset.detalle));

            document.querySelectorAll("[data-descargar]").forEach(b =>
                b.onclick = () => descargar(b.dataset.descargar, b.dataset.tipo, b));
        }

        function pintarGuias() {
            const d = estado.ultima;

            if (d.total === 0) {
                elem("resultados").innerHTML =
                    `<div class="vacio">Ninguna guía coincide con la búsqueda.</div>`;
                return;
            }

            elem("resultados").innerHTML = `
        <table>
          <tr>
            <th>Emisor</th><th>Guía</th><th>Traslado</th><th>Destino</th>
            <th>Vehículo</th><th>Estado</th>
            <th style="text-align:right">Archivos</th>
          </tr>
          ${d.resultados.map(filaGuia).join("")}
        </table>

        <div class="paginacion">
          <span>${d.total.toLocaleString("es-PE")}
            ${d.total === 1 ? "guía" : "guías"}</span>
          <span>
            <button class="mini" id="btn-anterior" ${d.pagina <= 1 ? "disabled" : ""}>Anterior</button>
            <span style="margin:0 10px">Página ${d.pagina} de ${d.paginas}</span>
            <button class="mini" id="btn-siguiente" ${d.pagina >= d.paginas ? "disabled" : ""}>Siguiente</button>
          </span>
        </div>`;

            elem("btn-anterior").onclick = () => { estado.pagina--; buscar(); };
            elem("btn-siguiente").onclick = () => { estado.pagina++; buscar(); };

            document.querySelectorAll("[data-descargar-guia]").forEach(b =>
                b.onclick = () => descargar(
                    b.dataset.descargarGuia, b.dataset.tipo, b, "guias/"));
        }

        const MOTIVOS = {
            "01": "Venta", "02": "Compra", "03": "Venta a terceros",
            "04": "Entre establecimientos", "05": "Consignación", "06": "Devolución",
            "07": "Recojo transformados", "08": "Importación", "09": "Exportación",
            "13": "Otros", "14": "Venta por confirmar", "17": "Para transformación",
            "18": "Emisor itinerante"
        };

        function filaGuia(g) {
            return `<tr class="fila">
        <td>
          <div class="recorte" title="${esc(g.razonSocial)}">${esc(g.razonSocial)}</div>
          <div class="mono tenue">${esc(g.ruc)}</div>
        </td>
        <td>
          <div class="mono">${esc(g.numero)}</div>
          <div class="tenue" style="font-size:12px">
            ${esc(MOTIVOS[g.motivoTraslado] ?? g.motivoTraslado)}</div>
        </td>
        <td class="tenue" style="white-space:nowrap">
          ${dia(g.fechaTraslado)}
          <div style="font-size:12px">${g.pesoBruto ?? 0} kg</div>
        </td>
        <td>
          <div class="recorte" title="${esc(g.destinatarioNombre)}">
            ${esc(g.destinatarioNombre)}</div>
          <div class="tenue recorte" style="font-size:12px;max-width:190px"
               title="${esc(g.direccionLlegada)}">${esc(g.direccionLlegada)}</div>
        </td>
        <td class="mono">${esc(g.placa) || "—"}
          <div class="tenue" style="font-size:12px;font-family:inherit">
            ${g.modalidadTraslado === "01" ? "público" : "privado"}</div>
        </td>
        <td>${insigniaGuia(g)}</td>
        <td style="text-align:right;white-space:nowrap">
          ${g.tieneXml ? `<button class="mini" data-descargar-guia="${g.id}" data-tipo="xml">XML</button>` : ""}
          ${g.tieneCdr ? `<button class="mini" data-descargar-guia="${g.id}" data-tipo="cdr">CDR</button>` : ""}
        </td>
      </tr>`;
        }

        /// La insignia de una guía dice si el vehículo puede salir.
        ///
        /// Es la única pregunta que importa cuando alguien consulta una guía, y por
        /// eso el texto no repite el estado técnico sino su consecuencia.
        function insigniaGuia(g) {
            if (g.puedeIniciarTraslado)
                return `<span class="insignia i-ok" title="${esc(g.mensajeSunat ?? "")}">` +
                    `puede trasladar</span>`;

            const mapa = {
                RECHAZADO: ["i-mal", "rechazada"],
                ANULADO: ["i-tenue", "anulada"],
                ENVIADO: ["i-aviso", "esperando SUNAT"],
                ENCOLADO: ["i-aviso", "en proceso"],
                BORRADOR: ["i-aviso", "pendiente"]
            };

            const [clase, texto] = mapa[g.estado] || ["i-tenue", g.estado.toLowerCase()];

            return `<span class="insignia ${clase}" title="${esc(g.mensajeSunat ?? "")}">` +
                `${texto}</span>`;
        }

        function fila(c) {
            return `<tr class="fila">
        <td>
          <div class="recorte" title="${esc(c.razonSocial)}">${esc(c.razonSocial)}</div>
          <div class="mono tenue">${esc(c.ruc)}</div>
        </td>
        <td>
          <div class="mono">${esc(c.numero)}</div>
          <div class="tenue" style="font-size:12px">${nombreTipo(c.tipoComprobante)}</div>
        </td>
        <td class="tenue">${dia(c.fechaEmision)}</td>
        <td>
          <div class="recorte" title="${esc(c.receptorNombre)}">${esc(c.receptorNombre) || "—"}</div>
          <div class="mono tenue">${esc(c.receptorDocumento)}</div>
        </td>
        <td class="num">${c.importeTotal.toLocaleString("es-PE",
                { minimumFractionDigits: 2 })} <span class="tenue">${esc(c.moneda)}</span></td>
        <td>${insignia(c)}</td>
        <td style="text-align:right;white-space:nowrap">
          ${c.tieneXml ? `<button class="mini" data-descargar="${c.id}" data-tipo="xml">XML</button>` : ""}
          ${c.tieneCdr ? `<button class="mini" data-descargar="${c.id}" data-tipo="cdr">CDR</button>` : ""}
          ${c.estado !== "BORRADOR" ? `<button class="mini" data-descargar="${c.id}" data-tipo="pdf">PDF</button>` : ""}
          <button class="mini" data-detalle="${c.id}">Detalle</button>
        </td>
      </tr>`;
        }

        function insignia(c) {
            const mapa = {
                ACEPTADO: ["i-ok", "aceptado"],
                ACEPTADO_CON_OBSERVACIONES: ["i-aviso", "con observaciones"],
                RECHAZADO: ["i-mal", "rechazado"],
                ANULADO: ["i-tenue", "anulado"],
                BORRADOR: ["i-aviso", "pendiente"],
                ENCOLADO: ["i-aviso", "en proceso"],
                ENVIADO: ["i-aviso", "enviado"],
                FIRMADO: ["i-aviso", "firmado"]
            };

            const [clase, texto] = mapa[c.estado] || ["i-tenue", c.estado.toLowerCase()];

            return `<span class="insignia ${clase}" title="${esc(c.mensajeSunat ?? "")}">${texto}</span>`;
        }

        // LOS NUEVE TIPOS QUE EL SISTEMA EMITE.
        //
        // Faltaban el 04, el 20 y el 40, y el panel los enseñaba como el número
        // crudo: quien daba soporte veía "20" y no sabía si era un comprobante de
        // retención o un error de datos.
        //
        // Las guías (09 y 31) tienen su propia vista y no pasan por aquí, pero se
        // dejan en el mapa por si algún día aparecen en un listado mezclado.
        const nombreTipo = t => ({
            "01": "Factura",
            "03": "Boleta",
            "04": "Liquidación de compra",
            "07": "Nota de crédito",
            "08": "Nota de débito",
            "09": "Guía de remisión remitente",
            "20": "Comprobante de retención",
            "31": "Guía de remisión transportista",
            "40": "Comprobante de percepción"
        }[t] || t);

        // DESCARGA CON CABECERA DE AUTENTICACIÓN.
        //
        // Un enlace normal no puede llevar la clave del operador, así que se pide
        // el archivo con fetch y se entrega al navegador como un blob. Es la única
        // forma de descargar desde un endpoint protegido sin exponer la clave en
        // la dirección, donde quedaría en el historial y en los registros del
        // servidor.
        async function descargar(id, tipo, boton, prefijo = "") {
            boton.disabled = true;

            try {
                const r = await fetch(`/admin/comprobantes/${prefijo}${id}/${tipo}`);

                if (r.status === 401) { location.href = "/login.html"; return; }

                if (!r.ok) {
                    const cuerpo = await r.json().catch(() => ({}));
                    avisar(cuerpo.error || cuerpo.title || "No se pudo descargar",
                        cuerpo.detalle || cuerpo.detail, "mal");
                    return;
                }

                const nombre = (r.headers.get("content-disposition") || "")
                    .match(/filename="?([^";]+)"?/)?.[1] || `${id}.${tipo}`;

                const blob = await r.blob();
                const url = URL.createObjectURL(blob);

                const enlace = document.createElement("a");
                enlace.href = url;
                enlace.download = nombre;
                enlace.click();

                URL.revokeObjectURL(url);

            } catch (e) {
                avisar("Error al descargar", e.message, "mal");
            } finally {
                boton.disabled = false;
            }
        }

        async function verDetalle(id) {
            const c = estado.ultima.resultados.find(x => x.id === id);

            elem("d-titulo").textContent = `${c.numero} · ${nombreTipo(c.tipoComprobante)}`;
            elem("d-sub").textContent = `${c.razonSocial} · ${c.ruc}`;
            elem("d-cuerpo").innerHTML = `<div class="vacio">Cargando historial…</div>`;
            elem("velo-detalle").classList.add("visible");

            try {
                const historial = await api(`/admin/comprobantes/${id}/historial`);

                elem("d-cuerpo").innerHTML = `
          ${c.mensajeSunat ? `
            <div style="background:var(--sutil);border-radius:var(--radio);
                        padding:11px 13px;margin-bottom:14px;font-size:13.5px">
              <strong>SUNAT ${esc(c.codigoSunat ?? "")}:</strong>
              ${esc(c.mensajeSunat)}
            </div>` : ""}

          <table>
            <tr><th>#</th><th>Transición</th><th>Código</th><th>Mensaje</th>
                <th>Duración</th><th>Cuándo</th></tr>
            ${historial.map(h => `<tr>
              <td>${h.intento}</td>
              <td class="tenue" style="white-space:nowrap">
                ${esc(h.desde ?? "—")} → ${esc(h.hasta)}</td>
              <td class="mono">${esc(h.codigoSunat ?? "—")}</td>
              <td style="font-size:12.5px">${esc(h.mensaje ?? "")}</td>
              <td class="tenue num">${h.duracionMs ? h.duracionMs + " ms" : ""}</td>
              <td class="tenue" style="white-space:nowrap">
                ${fechaHora(h.fecha)}</td>
            </tr>`).join("")}
          </table>
          <div id="d-portal"></div>`;

                cargarPortal(id);

            } catch (e) {
                elem("d-cuerpo").innerHTML =
                    `<div class="vacio" style="color:var(--mal)">${esc(e.message)}</div>`;
            }
        }

        // ------------------------------------------------- portal del receptor
        //
        // Qué correo de entrega salió de este comprobante y qué enlaces del
        // portal tiene. Anular es para el correo enviado a la dirección
        // equivocada o el cliente que lo pide: el enlace deja de abrir, y
        // queda escrito por qué.

        const ESTADO_CORREO = {
            ENVIADO: ["i-ok", "enviado"],
            PENDIENTE: ["i-aviso", "pendiente"],
            AGOTADO: ["i-mal", "no se pudo enviar"],
            OMITIDO: ["i-tenue", "no se envió"]
        };

        async function cargarPortal(id) {
            const caja = elem("d-portal");
            if (!caja) return;

            let datos;
            try {
                datos = await api(`/admin/comprobantes/${id}/portal`);
            } catch (e) {
                caja.innerHTML = `<div class="tenue" style="margin-top:16px;font-size:13px">
                    Portal del receptor: ${esc(e.message)}</div>`;
                return;
            }

            const c = datos.correo;
            const [clase, texto] = c ? (ESTADO_CORREO[c.estado] || ["i-tenue", c.estado]) : [];

            const correo = c
                ? `<div style="display:flex;gap:10px;align-items:center;flex-wrap:wrap">
                     <span class="insignia ${clase}">${texto}</span>
                     <span class="mono">${esc(c.para)}</span>
                     ${c.enviadoEn ? `<span class="tenue">${fechaHora(c.enviadoEn)}</span>` : ""}
                     ${c.estado === "ENVIADO"
                        ? `<span class="tenue">${c.pdfAdjunto ? "con PDF adjunto" : "solo enlace (PDF de más de 1 MB)"}</span>`
                        : ""}
                   </div>
                   ${c.ultimoError ? `<div class="tenue" style="font-size:12.5px;margin-top:6px">
                       ${c.estado === "PENDIENTE" ? `Intento ${c.intentos}: ` : ""}${esc(c.ultimoError)}</div>` : ""}`
                : `<div class="tenue" style="font-size:13px">Sin correo de entrega: el comprobante
                     no traía correo del cliente, o la empresa no tenía dirección del portal y
                     correo de respuesta cuando SUNAT lo aceptó.</div>`;

            const vigentes = datos.accesos.filter(a => a.vigente).length;

            const accesos = datos.accesos.length === 0 ? "" : `
                <table style="margin-top:12px">
                  <tr><th>Enlace</th><th>Creado</th><th>Vale hasta</th><th>Usos</th><th>Estado</th></tr>
                  ${datos.accesos.map(a => `<tr>
                    <td>${a.origen === "correo" ? "del correo" : "búsqueda (30 min)"}</td>
                    <td class="tenue" style="white-space:nowrap">${fechaHora(a.creadoEn)}</td>
                    <td class="tenue" style="white-space:nowrap">${fechaHora(a.expiraEn)}</td>
                    <td>${a.usos}</td>
                    <td>${a.vigente
                        ? `<span class="insignia i-ok">vigente</span>`
                        : a.anuladoEn
                            ? `<span class="insignia i-tenue" title="${esc(a.anuladoMotivo ?? "")}">anulado</span>`
                            : `<span class="insignia i-tenue">caducado</span>`}</td>
                  </tr>`).join("")}
                </table>`;

            const boton = vigentes > 0 && puede("comprobantes.reprocesar")
                ? `<button class="mini" id="btn-anular-enlaces" style="margin-top:12px;color:var(--mal)">
                     Anular ${vigentes === 1 ? "el enlace vigente" : `los ${vigentes} enlaces vigentes`}</button>`
                : "";

            caja.innerHTML = `
                <div style="border-top:1px solid var(--borde);margin-top:18px;padding-top:14px">
                  <div style="font-size:12.5px;color:var(--tenue);text-transform:uppercase;
                              letter-spacing:.05em;margin-bottom:10px">Portal del receptor</div>
                  ${correo}
                  ${accesos}
                  ${boton}
                </div>`;

            const b = elem("btn-anular-enlaces");
            if (b) b.onclick = () => anularEnlaces(id, b);
        }

        async function anularEnlaces(id, boton) {
            const motivo = prompt(
                "Los enlaces dejarán de abrir de inmediato, también el del correo. " +
                "El cliente podrá seguir buscando el comprobante con sus datos.\n\n" +
                "Motivo (queda guardado):");

            if (motivo === null) return;

            if (motivo.trim().length < 3) {
                avisar("Escribe el motivo", "Queda guardado junto al enlace.", "mal");
                return;
            }

            boton.disabled = true;

            try {
                const r = await fetch(`/admin/comprobantes/${id}/portal/anular`, {
                    method: "POST",
                    headers: { "Content-Type": "application/json" },
                    body: JSON.stringify({ motivo: motivo.trim() })
                });

                if (r.status === 401) { location.href = "/login.html"; return; }

                const cuerpo = await r.json().catch(() => ({}));

                if (!r.ok) {
                    avisar(cuerpo.error || "No se pudo anular", cuerpo.detalle, "mal");
                    boton.disabled = false;
                    return;
                }

                avisar(cuerpo.mensaje, "", "ok");
                await cargarPortal(id);

            } catch (e) {
                avisar("Error al anular", e.message, "mal");
                boton.disabled = false;
            }
        }

        cargarUsuario().then(ok => { if (ok) { ajustarFiltros(); buscar(); } });
    </script>
</body>
</html>
'@

# --- migraciones\022_portal_correos.sql
Planear 'migraciones\022_portal_correos.sql' '' @'
-- ===========================================================================
-- 022 — El correo de entrega del portal
--
-- POR QUÉ HACE FALTA:
--
-- Cuando SUNAT acepta un comprobante que trae correo del cliente
-- (comprobantes.correo_receptor, migración 019), el servicio le manda un
-- correo con el PDF adjunto y un enlace de 400 días al portal.
--
-- Igual que los webhooks, se hace con una COLA: un disparador mete una fila
-- aquí en el mismo instante en que el comprobante pasa a aceptado, y un
-- proceso aparte la envía. Mandarlo desde la petición no vale: el correo
-- tarda, falla, y no puede retrasar ni romper la respuesta de SUNAT.
--
--
-- UNA FILA POR COMPROBANTE, NUNCA DOS (único por comprobante_id). Si el
-- estado pasara dos veces por aceptado, el cliente no recibe dos correos.
--
-- SOLO SE ENCOLA SI LA EMPRESA ESTÁ LISTA: con dirección del portal
-- (identificador) y correo de respuesta. Sin lo primero el enlace no lleva a
-- ninguna parte; sin lo segundo, las respuestas del cliente se perderían.
--
-- CON RLS, como webhook_entregas: guarda el correo del cliente, que es un
-- dato suyo. El disparador corre dentro de la sesión de la empresa, así que
-- la fila que mete es de esa empresa. Quien envía usa el rol de operador.
--
-- NADA SE BORRA: no hay DELETE para nadie.
-- ===========================================================================

BEGIN;

CREATE TABLE IF NOT EXISTS portal_correos (
    id                  uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id           uuid        NOT NULL REFERENCES tenants(id)        ON DELETE RESTRICT,
    comprobante_id      uuid        NOT NULL REFERENCES comprobantes(id)   ON DELETE RESTRICT,
    para                text        NOT NULL,
    estado              text        NOT NULL DEFAULT 'PENDIENTE',
    intentos            smallint    NOT NULL DEFAULT 0,
    proximo_intento_en  timestamptz,
    ultimo_error        text,
    enviado_en          timestamptz,
    acceso_id           uuid        REFERENCES portal_accesos(id)          ON DELETE RESTRICT,
    pdf_adjunto         boolean,
    creado_en           timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT ux_portal_correos_comprobante UNIQUE (comprobante_id),
    CONSTRAINT ck_portal_correos_estado
        CHECK (estado IN ('PENDIENTE', 'ENVIADO', 'AGOTADO', 'OMITIDO')),
    CONSTRAINT ck_portal_correos_enviado
        CHECK ((estado = 'ENVIADO') = (enviado_en IS NOT NULL))
);

CREATE INDEX IF NOT EXISTS ix_portal_correos_pendientes
    ON portal_correos (proximo_intento_en NULLS FIRST, creado_en)
    WHERE estado = 'PENDIENTE';

ALTER TABLE portal_correos ENABLE ROW LEVEL SECURITY;
ALTER TABLE portal_correos FORCE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS aislamiento_tenant ON portal_correos;
CREATE POLICY aislamiento_tenant ON portal_correos
    USING (tenant_id = app_tenant_actual())
    WITH CHECK (tenant_id = app_tenant_actual());

-- La aplicación solo mete filas (desde el disparador). El operador, que se
-- salta RLS, las lee y las actualiza al enviar.
GRANT SELECT, INSERT         ON portal_correos TO facturacion_app;
GRANT SELECT, INSERT, UPDATE ON portal_correos TO facturacion_operador;


-- El disparador. Corre con el rol de quien cambia el estado del comprobante
-- y dentro de su sesión: la fila nueva queda en la empresa correcta.
CREATE OR REPLACE FUNCTION encolar_correo_portal()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.estado IS NOT DISTINCT FROM OLD.estado THEN
        RETURN NEW;
    END IF;

    IF NEW.estado NOT IN ('ACEPTADO', 'ACEPTADO_CON_OBSERVACIONES')
       OR NEW.correo_receptor IS NULL
       OR NEW.tipo_comprobante NOT IN ('01', '03', '07', '08') THEN
        RETURN NEW;
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM tenants t
         WHERE t.id = NEW.tenant_id
           AND t.activo
           AND t.identificador IS NOT NULL
           AND t.correo_respuesta IS NOT NULL
    ) THEN
        RETURN NEW;
    END IF;

    INSERT INTO portal_correos (tenant_id, comprobante_id, para)
    VALUES (NEW.tenant_id, NEW.id, NEW.correo_receptor)
    ON CONFLICT (comprobante_id) DO NOTHING;

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS tg_comprobantes_correo_portal ON comprobantes;

CREATE TRIGGER tg_comprobantes_correo_portal
    AFTER UPDATE OF estado ON comprobantes
    FOR EACH ROW
    EXECUTE FUNCTION encolar_correo_portal();

-- Sin tildes: PowerShell 5.1 manda este archivo a psql en ASCII.
COMMENT ON TABLE portal_correos IS
    'Cola del correo de entrega: uno por comprobante aceptado con correo_receptor. PDF adjunto (hasta 1 MB) y enlace de 400 dias al portal.';

COMMIT;
'@

# --- Todo o nada -------------------------------------------------------------
$conflictos = @($plan | Where-Object { $_.Accion -eq 'conflicto' })
if ($conflictos.Count -gt 0) {
    Write-Host ''
    Write-Host 'NO SE TOCÓ NINGÚN ARCHIVO. Esto no cuadra:' -ForegroundColor Red
    foreach ($c in $conflictos) { Write-Host "  $($c.Ruta)`n      $($c.Motivo)" -ForegroundColor Red }
    Write-Host ''
    exit 2
}

Write-Host ''
foreach ($p in $plan) {
    if ($p.Accion -eq 'reemplazar') {
        $copia = Respaldar $p.Completa
        $salida = if ($p.Crlf) { $p.Texto.Replace("`n", "`r`n") } else { $p.Texto }
        [System.IO.File]::WriteAllText($p.Completa, $salida, $utf8SinBom)
        Write-Host "  REEMPLAZADO  $($p.Ruta)  (copia: $copia)" -ForegroundColor Green
    }
    elseif ($p.Accion -eq 'nuevo') {
        New-Item -ItemType Directory -Path (Split-Path $p.Completa) -Force | Out-Null
        [System.IO.File]::WriteAllText($p.Completa, $p.Texto.Replace("`n", "`r`n"), $utf8SinBom)
        Write-Host "  NUEVO        $($p.Ruta)" -ForegroundColor Green
    }
    else {
        Write-Host "  IGUAL        $($p.Ruta)  (sin cambios)" -ForegroundColor DarkGray
    }
}

Write-Host ''
Write-Host 'FALTA APLICAR LA MIGRACIÓN 022 (este script NO la aplica). Desde esta carpeta:' -ForegroundColor Cyan
Write-Host ''
Write-Host '  Get-Content migraciones\022_portal_correos.sql -Raw | docker compose exec -T postgres psql -U facturacion_owner -d facturacion -v ON_ERROR_STOP=1' -ForegroundColor White
Write-Host ''
Write-Host 'Tiene que terminar en COMMIT. Después, reinicia la API del servicio.' -ForegroundColor Cyan
Write-Host ''
