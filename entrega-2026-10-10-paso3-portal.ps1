# =============================================================================
# Entrega 2026-10-10 — Portal del receptor, PASO 3: la página y la opción A
#
# Se ejecuta desde la raíz del servicio:
#   cd "D:\Reyban Consulting\facturacion electronica\facturacion_electronica_service"
#   .\entrega-2026-10-10-paso3-portal.ps1
#
#   EndpointsPortal.cs          NUEVO. /portal/{empresa} (la página) y su API:
#                               marca, logo, buscar con los cinco datos, ver el
#                               comprobante y descargar PDF, XML y CDR
#   wwwroot\portal.html         NUEVO. La página que ve el cliente del emisor
#   RepositorioPortal.cs        NUEVO. Empresa por identificador, búsqueda
#                               (con RLS), accesos e intentos
#   Autenticacion.cs            /portal pasa a la lista de rutas sin clave
#   Program.cs                  Registra RepositorioPortal y MapearPortal
#   migraciones\021_portal.sql  NUEVO. portal_accesos, portal_intentos y el
#                               índice para buscar por número. No se aplica sola
#
# PROTECCIÓN: Autenticacion.cs y Program.cs solo se reemplazan si siguen IGUAL
# a los que tengo (Program.cs: el que dejó el paso 1). Si alguno cambió, NO
# TOCA NADA. Todo o nada. UTF-8 sin BOM, .bak. La migración NO se aplica.
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

# --- Facturacion.Api\EndpointsPortal.cs
Planear 'Facturacion.Api\EndpointsPortal.cs' '' @'
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

        var acceso = NuevoAcceso();

        await portal.CrearAccesoAsync(
            e.Id, comprobante.Id, Sha256(acceso), "consulta", DuracionConsulta, ct);

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

        var comprobanteId = await portal.ResolverAccesoAsync(e.Id, Sha256(acceso), ct);
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

    /// <summary>32 bytes aleatorios en base64url: 43 caracteres.</summary>
    private static string NuevoAcceso() =>
        Convert.ToBase64String(RandomNumberGenerator.GetBytes(32))
            .TrimEnd('=').Replace('+', '-').Replace('/', '_');

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
'@

# --- Facturacion.Api\wwwroot\portal.html
Planear 'Facturacion.Api\wwwroot\portal.html' '' @'
<!DOCTYPE html>
<html lang="es">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex, nofollow">
<meta name="referrer" content="no-referrer">
<title>Comprobantes electrónicos</title>
<style>
  /* El color de la marca llega de la empresa (--marca y --sobre-marca se
     ponen desde el script). Todo lo demás es neutro a propósito: la página
     tiene que verse del emisor, no de quien la sirve. */
  :root {
    --fondo:#f5f6f8; --panel:#ffffff; --sutil:#f0f2f5; --borde:#e2e5ea;
    --texto:#1a1d21; --tenue:#5d6672;
    --ok:#15803d; --ok-fondo:#eaf6ee;
    --mal:#b42318; --mal-fondo:#fdecea;
    --aviso:#9a6700; --aviso-fondo:#fdf6e3;
    --marca:#334155; --sobre-marca:#ffffff;
    --radio:10px;
  }

  @media (prefers-color-scheme: dark) {
    :root {
      --fondo:#0f1115; --panel:#171a21; --sutil:#1d222b; --borde:#2a303c;
      --texto:#e7e9ed; --tenue:#9aa3af;
      --ok:#3fb950; --ok-fondo:#13261a;
      --mal:#f47067; --mal-fondo:#2c1517;
      --aviso:#d4a72c; --aviso-fondo:#2a2312;
    }
  }

  * { box-sizing:border-box; }

  body { margin:0; background:var(--fondo); color:var(--texto);
         font:16px/1.55 ui-sans-serif, system-ui, "Segoe UI", Roboto, sans-serif; }

  .franja { height:5px; background:var(--marca); }

  .contenedor { max-width:620px; margin:0 auto; padding:28px 16px 40px; }

  header { display:flex; align-items:center; gap:16px; margin-bottom:26px; }

  /* El logo va sobre blanco en los dos temas: así está diseñado casi
     cualquier logo, y así sale en el PDF. */
  .logo { background:#fff; border:1px solid var(--borde); border-radius:var(--radio);
          padding:8px; height:64px; max-width:180px; display:flex;
          align-items:center; justify-content:center; flex:none; }
  .logo img { max-height:100%; max-width:100%; }

  .empresa h1 { margin:0; font-size:20px; font-weight:600; line-height:1.25; }
  .empresa .ruc { color:var(--tenue); font-size:14px; margin-top:2px; }

  .tarjeta { background:var(--panel); border:1px solid var(--borde);
             border-radius:14px; padding:22px 22px 24px; margin-bottom:16px; }

  h2 { font-size:17px; margin:0 0 4px; font-weight:600; }
  .ayuda { color:var(--tenue); font-size:14px; margin:0 0 18px; }

  .rejilla { display:grid; grid-template-columns:1fr 1fr; gap:14px; }
  .ancho { grid-column:1 / -1; }
  @media (max-width:520px) { .rejilla { grid-template-columns:1fr; } }

  label { display:block; font-size:13.5px; color:var(--tenue); margin-bottom:5px; }

  input, select { width:100%; font:inherit; font-size:16px; color:var(--texto);
                  background:var(--panel); border:1px solid var(--borde);
                  border-radius:var(--radio); padding:10px 12px; }
  input:focus, select:focus { outline:2px solid var(--marca); outline-offset:1px;
                              border-color:transparent; }

  .boton { display:inline-flex; align-items:center; justify-content:center; gap:8px;
           font:inherit; font-size:15px; font-weight:600; cursor:pointer;
           border-radius:var(--radio); padding:11px 18px; border:1px solid var(--borde);
           background:var(--panel); color:var(--texto); }
  .boton:disabled { opacity:.55; cursor:default; }
  .boton.principal { background:var(--marca); border-color:var(--marca);
                     color:var(--sobre-marca); width:100%; margin-top:20px; }
  .boton svg { width:17px; height:17px; stroke:currentColor; fill:none;
               stroke-width:2; stroke-linecap:round; stroke-linejoin:round; }

  .mensaje { border-radius:var(--radio); padding:12px 14px; font-size:14.5px;
             margin-top:16px; display:none; }
  .mensaje.visible { display:block; }
  .mensaje.mal { background:var(--mal-fondo); color:var(--mal); }
  .mensaje .detalle { display:block; font-size:13.5px; margin-top:3px; opacity:.9; }

  .nota { font-size:13.5px; color:var(--tenue); margin-top:16px;
          border-top:1px solid var(--borde); padding-top:14px; }

  .resultado .tipo { font-size:13.5px; color:var(--tenue); }
  .resultado .numero { font-size:22px; font-weight:600; margin:2px 0 10px;
                       font-variant-numeric:tabular-nums; }

  .estado { display:inline-block; font-size:13px; font-weight:600;
            padding:3px 10px; border-radius:999px; margin-bottom:16px; }
  .estado.ok { background:var(--ok-fondo); color:var(--ok); }
  .estado.anulado { background:var(--mal-fondo); color:var(--mal); }

  dl { display:grid; grid-template-columns:auto 1fr; gap:6px 16px; margin:0 0 20px;
       font-size:15px; }
  dt { color:var(--tenue); }
  dd { margin:0; font-variant-numeric:tabular-nums; }

  .descargas { display:flex; gap:10px; flex-wrap:wrap; }
  .descargas .boton { flex:1 1 140px; }

  .enlace { background:none; border:none; padding:0; font:inherit; font-size:14.5px;
            color:var(--texto); text-decoration:underline; cursor:pointer;
            margin-top:18px; }

  footer { color:var(--tenue); font-size:12.5px; text-align:center; margin-top:26px;
           line-height:1.6; }

  .oculto { display:none !important; }
  .vacio { text-align:center; color:var(--tenue); padding:40px 0; }
</style>
</head>
<body>

<div class="franja"></div>

<div class="contenedor">

  <header id="cabecera" class="oculto">
    <div class="logo oculto" id="logo"></div>
    <div class="empresa">
      <h1 id="nombre"></h1>
      <div class="ruc" id="ruc"></div>
    </div>
  </header>

  <div id="cargando" class="vacio">Cargando…</div>

  <div id="no-existe" class="tarjeta oculto">
    <h2>Esta página no existe</h2>
    <p class="ayuda" style="margin:0">Revisa la dirección. Si llegaste desde un
      correo, usa el enlace tal como vino.</p>
  </div>

  <!-- Búsqueda: los cinco datos -->
  <section id="busqueda" class="tarjeta oculto" aria-labelledby="t-busqueda">
    <h2 id="t-busqueda">Busca tu comprobante</h2>
    <p class="ayuda">Escribe los datos tal como aparecen en el comprobante.</p>

    <form id="formulario" novalidate>
      <div class="rejilla">
        <div>
          <label for="tipo">Tu tipo de documento</label>
          <select id="tipo">
            <option value="6">RUC</option>
            <option value="1">DNI</option>
            <option value="4">Carné de extranjería</option>
            <option value="7">Pasaporte</option>
          </select>
        </div>
        <div>
          <label for="documento">Tu número de documento</label>
          <input id="documento" inputmode="numeric" autocomplete="off" maxlength="15">
        </div>
        <div>
          <label for="serie">Serie</label>
          <input id="serie" placeholder="F001" maxlength="4" autocomplete="off"
                 style="text-transform:uppercase">
        </div>
        <div>
          <label for="numero">Número</label>
          <input id="numero" inputmode="numeric" placeholder="96" maxlength="8" autocomplete="off">
        </div>
        <div>
          <label for="fecha">Fecha de emisión</label>
          <input id="fecha" type="date">
        </div>
        <div>
          <label for="importe">Importe total</label>
          <input id="importe" inputmode="decimal" placeholder="100.01" autocomplete="off">
        </div>
      </div>

      <button class="boton principal" id="buscar" type="submit">Buscar</button>
    </form>

    <div class="mensaje mal" id="error" role="alert"></div>

    <div class="nota">
      Si tu comprobante es una boleta sin documento, ábrelo con el enlace del
      correo que recibiste.
    </div>
  </section>

  <!-- El comprobante encontrado -->
  <section id="resultado" class="tarjeta resultado oculto" aria-live="polite">
    <div class="tipo" id="r-tipo"></div>
    <div class="numero" id="r-numero"></div>
    <span class="estado" id="r-estado"></span>

    <dl>
      <dt>Fecha de emisión</dt><dd id="r-fecha"></dd>
      <dt>Importe total</dt><dd id="r-importe"></dd>
      <dt>Cliente</dt><dd id="r-cliente"></dd>
    </dl>

    <div class="descargas" id="descargas"></div>
    <div class="mensaje mal" id="error-descarga" role="alert"></div>

    <button class="enlace" id="otro" type="button">Buscar otro comprobante</button>
  </section>

  <footer id="pie" class="oculto"></footer>
</div>

<script>
// ---------------------------------------------------------------- dirección
//
// En producción el navegador ve comprobantes.reyban.pe/{empresa} y el proxy
// añade /portal por delante. En desarrollo se entra directo a
// /portal/{empresa}. La página funciona en los dos casos.

const elem = id => document.getElementById(id);

const BASE = location.pathname.startsWith("/portal/") ? "/portal" : "";
const partes = location.pathname.slice(BASE.length).split("/").filter(Boolean);
const EMPRESA = partes[0] || "";
const ENLACE = partes[1] === "e" ? (partes[2] || "") : "";
const API = `${BASE}/api/${encodeURIComponent(EMPRESA)}`;

// El acceso vive solo en memoria. Si llegó en la dirección (enlace del
// correo), se quita de la barra en cuanto se lee: así no queda en el
// historial a la vista de quien use el mismo equipo después.
let acceso = ENLACE || null;

if (ENLACE) history.replaceState(null, "", `${BASE}/${EMPRESA}`);

const MONEDAS = { PEN: "PEN", USD: "USD", EUR: "EUR" };

const dinero = (valor, moneda) => {
  try {
    return new Intl.NumberFormat("es-PE", { style: "currency",
      currency: MONEDAS[moneda] || "PEN" }).format(valor);
  } catch { return `${moneda} ${Number(valor).toFixed(2)}`; }
};

// "2026-10-10" → "10/10/2026". Es un día, no un instante: no se convierte.
const dia = v => { const [a, m, d] = String(v).split("-"); return `${d}/${m}/${a}`; };

function mostrar(id, visible = true) { elem(id).classList.toggle("oculto", !visible); }

function error(id, titulo, detalle = "") {
  const caja = elem(id);
  caja.innerHTML = "";
  if (!titulo) { caja.classList.remove("visible"); return; }
  caja.textContent = titulo;
  if (detalle) {
    const d = document.createElement("span");
    d.className = "detalle";
    d.textContent = detalle;
    caja.appendChild(d);
  }
  caja.classList.add("visible");
}

// ------------------------------------------------------------------- marca

// El texto sobre el color de la marca: blanco o casi negro, el que se lea.
function textoSobre(hex) {
  const n = parseInt(hex.slice(1), 16);
  const canal = c => { c /= 255; return c <= .03928 ? c / 12.92 : ((c + .055) / 1.055) ** 2.4; };
  const l = .2126 * canal(n >> 16 & 255) + .7152 * canal(n >> 8 & 255) + .0722 * canal(n & 255);
  return l > .4 ? "#111418" : "#ffffff";
}

async function cargarMarca() {
  const r = await fetch(API);

  if (!r.ok) {
    mostrar("cargando", false);
    mostrar("no-existe");
    return false;
  }

  const m = await r.json();
  const nombre = m.nombreComercial || m.razonSocial;

  document.title = `Comprobantes · ${nombre}`;
  elem("nombre").textContent = nombre;
  elem("ruc").textContent = `RUC ${m.ruc}`;

  if (m.color && /^#[0-9a-f]{6}$/i.test(m.color)) {
    document.documentElement.style.setProperty("--marca", m.color);
    document.documentElement.style.setProperty("--sobre-marca", textoSobre(m.color));
  }

  if (m.tieneLogo) {
    const img = document.createElement("img");
    img.src = `${API}/logo`;
    img.alt = `Logo de ${nombre}`;
    img.onerror = () => mostrar("logo", false);
    elem("logo").appendChild(img);
    mostrar("logo");
  }

  elem("pie").textContent =
    `Comprobantes electrónicos de ${m.razonSocial} · RUC ${m.ruc}. ` +
    "También puedes consultar su validez en el portal de SUNAT.";

  mostrar("cabecera");
  mostrar("pie");
  return true;
}

// ---------------------------------------------------------------- búsqueda

elem("formulario").onsubmit = async ev => {
  ev.preventDefault();
  error("error", "");

  const datos = {
    tipoDocumento: elem("tipo").value,
    numeroDocumento: elem("documento").value.trim(),
    serie: elem("serie").value.trim().toUpperCase(),
    numero: elem("numero").value.trim(),
    fechaEmision: elem("fecha").value,
    importeTotal: elem("importe").value.trim()
  };

  const falta = Object.entries(datos).find(([, v]) => !v);
  if (falta) {
    error("error", "Completa los seis campos.");
    return;
  }

  const boton = elem("buscar");
  boton.disabled = true;
  boton.textContent = "Buscando…";

  try {
    const r = await fetch(`${API}/buscar`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(datos)
    });

    const cuerpo = await r.json().catch(() => ({}));

    if (!r.ok) {
      error("error", cuerpo.error || "No se pudo buscar.", cuerpo.detalle || "");
      return;
    }

    acceso = cuerpo.acceso;
    pintar(cuerpo.comprobante);

  } catch {
    error("error", "No se pudo conectar. Revisa tu conexión e inténtalo otra vez.");
  } finally {
    boton.disabled = false;
    boton.textContent = "Buscar";
  }
};

// --------------------------------------------------------------- resultado

const ICONO = `<svg viewBox="0 0 24 24"><path d="M12 4v11m0 0l-4-4m4 4l4-4"/><path d="M5 19h14"/></svg>`;

function pintar(c) {
  elem("r-tipo").textContent = c.tipoNombre;
  elem("r-numero").textContent = c.numero;

  const estado = elem("r-estado");
  estado.textContent = c.estado;
  estado.className = "estado " + (c.anulado ? "anulado" : "ok");

  elem("r-fecha").textContent = dia(c.fechaEmision);
  elem("r-importe").textContent = dinero(c.importeTotal, c.moneda);
  elem("r-cliente").textContent = c.receptor || "—";

  const lista = [["pdf", "PDF"], ["xml", "XML"], ["cdr", "CDR de SUNAT"]]
    .filter(([clave]) => c.archivos[clave]);

  elem("descargas").innerHTML = "";

  for (const [clave, texto] of lista) {
    const b = document.createElement("button");
    b.type = "button";
    b.className = "boton" + (clave === "pdf" ? " principal" : "");
    if (clave === "pdf") b.style.marginTop = "0";
    b.innerHTML = `${ICONO}<span></span>`;
    b.querySelector("span").textContent = texto;
    b.onclick = () => descargar(clave, b);
    elem("descargas").appendChild(b);
  }

  error("error-descarga", "");
  mostrar("busqueda", false);
  mostrar("resultado");
  elem("resultado").scrollIntoView({ behavior: "smooth", block: "start" });
}

// El acceso va en una cabecera, no en la dirección: por eso se descarga con
// fetch y se entrega al navegador como archivo.
async function descargar(tipo, boton) {
  boton.disabled = true;
  error("error-descarga", "");

  try {
    const r = await fetch(`${API}/comprobante/${tipo}`,
      { headers: { "X-Portal-Acceso": acceso } });

    if (!r.ok) {
      const cuerpo = await r.json().catch(() => ({}));
      error("error-descarga", cuerpo.error || "No se pudo descargar.", cuerpo.detalle || "");
      return;
    }

    const nombre = (r.headers.get("content-disposition") || "")
      .match(/filename="?([^";]+)"?/)?.[1] || `comprobante.${tipo === "cdr" ? "zip" : tipo}`;

    const url = URL.createObjectURL(await r.blob());
    const a = document.createElement("a");
    a.href = url;
    a.download = nombre;
    document.body.appendChild(a);
    a.click();
    a.remove();
    setTimeout(() => URL.revokeObjectURL(url), 10000);

  } catch {
    error("error-descarga", "No se pudo descargar. Revisa tu conexión.");
  } finally {
    boton.disabled = false;
  }
}

elem("otro").onclick = () => {
  acceso = null;
  mostrar("resultado", false);
  mostrar("busqueda");
  elem("documento").focus();
};

// ---------------------------------------------------------------- arranque

(async () => {
  if (!EMPRESA || !(await cargarMarca().catch(() => false))) {
    mostrar("cargando", false);
    mostrar("no-existe");
    return;
  }

  mostrar("cargando", false);

  // Llegó con el enlace del correo: se abre directamente el comprobante.
  if (acceso) {
    try {
      const r = await fetch(`${API}/comprobante`, { headers: { "X-Portal-Acceso": acceso } });
      const cuerpo = await r.json().catch(() => ({}));

      if (r.ok) { pintar(cuerpo.comprobante); return; }

      acceso = null;
      mostrar("busqueda");
      error("error", cuerpo.error || "Este enlace ya no es válido.", cuerpo.detalle || "");
      return;
    } catch { acceso = null; }
  }

  mostrar("busqueda");
})();
</script>
</body>
</html>
'@

# --- Facturacion.Persistencia\RepositorioPortal.cs
Planear 'Facturacion.Persistencia\RepositorioPortal.cs' '' @'
using Dapper;

namespace Facturacion.Persistencia;

/// <summary>Una empresa vista desde su portal: solo lo que se enseña.</summary>
public record EmpresaPortal(
    Guid Id,
    string Ruc,
    string RazonSocial,
    string? NombreComercial,
    string Identificador,
    string? ColorMarca,
    string? LogoRuta);

/// <summary>
/// Un comprobante visto desde el portal. Sin el cpe entero: el receptor ya
/// sabe lo que compró, y lo que no hace falta enseñar no se puede filtrar.
/// </summary>
public record ComprobantePortal(
    Guid Id,
    string TipoComprobante,
    string Serie,
    int Correlativo,
    DateTime FechaEmision,
    string Moneda,
    decimal ImporteTotal,
    string Estado,
    string? ReceptorNombre,
    bool TieneXml,
    bool TieneCdr)
{
    public string Numero => $"{Serie}-{Correlativo:D8}";
}

/// <summary>Los cinco datos de la opción A, ya limpios.</summary>
public record BusquedaPortal(
    string TipoDocumento,
    string NumeroDocumento,
    string Serie,
    int Correlativo,
    DateTime FechaEmision,
    decimal ImporteTotal);

/// <summary>Fallos recientes, para el límite de intentos.</summary>
public record FallosPortal(int PorDocumento, int PorIp);

/// <summary>
/// Lo que el portal del receptor necesita de la base.
///
/// DOS CLASES DE CONEXIÓN, Y NO SE MEZCLAN:
///
///   - Catálogo (sin RLS): empresas, accesos e intentos. Ninguna de esas
///     tablas guarda datos del comprobante.
///   - Sesión de la empresa (con RLS): todo lo que lee `comprobantes`. El
///     tenant de esa sesión sale SIEMPRE de la dirección del portal, nunca
///     de lo que manda el navegador.
///
/// Usa el rol de la aplicación, no el de operador: el portal es público y
/// tiene que poder lo justo.
/// </summary>
public sealed class RepositorioPortal
{
    // Los estados que existen para el portal. Un RECHAZADO no es un
    // comprobante, y uno que sigue en camino todavía no lo es.
    private const string EstadosVisibles =
        "('ACEPTADO', 'ACEPTADO_CON_OBSERVACIONES', 'ANULADO')";

    // Facturas, boletas y notas. Las guías, retenciones y percepciones no
    // tienen "comprador" con el mismo significado; se añaden cuando toque.
    private const string TiposVisibles = "('01', '03', '07', '08')";

    private const string ColumnasComprobante = """
        c.id                                   AS "Id",
        c.tipo_comprobante                     AS "TipoComprobante",
        c.serie                                AS "Serie",
        c.correlativo                          AS "Correlativo",
        c.fecha_emision                        AS "FechaEmision",
        c.moneda                               AS "Moneda",
        c.importe_total                        AS "ImporteTotal",
        c.estado                               AS "Estado",
        c.cpe->'receptor'->>'razonSocial'      AS "ReceptorNombre",
        (c.ruta_xml IS NOT NULL)               AS "TieneXml",
        (c.ruta_cdr IS NOT NULL)               AS "TieneCdr"
        """;

    private readonly FabricaSesiones _sesiones;

    public RepositorioPortal(FabricaSesiones sesiones)
    {
        _sesiones = sesiones ?? throw new ArgumentNullException(nameof(sesiones));
    }

    /// <summary>
    /// La empresa de la dirección, o null si no existe, está desactivada o no
    /// tiene identificador. Las tres cosas se ven igual desde fuera.
    /// </summary>
    public async Task<EmpresaPortal?> EmpresaAsync(
        string identificador, CancellationToken ct = default)
    {
        await using var conexion = await _sesiones.AbrirCatalogoAsync(ct);

        return await conexion.QuerySingleOrDefaultAsync<EmpresaPortal>(new CommandDefinition(
            """
            SELECT id               AS "Id",
                   ruc              AS "Ruc",
                   razon_social     AS "RazonSocial",
                   nombre_comercial AS "NombreComercial",
                   identificador    AS "Identificador",
                   color_marca      AS "ColorMarca",
                   logo_ruta        AS "LogoRuta"
              FROM tenants
             WHERE identificador = @identificador
               AND activo
            """,
            new { identificador }, cancellationToken: ct));
    }

    /// <summary>
    /// Los fallos de este documento en esta empresa (15 min) y los de esta IP
    /// en todas las empresas (1 hora).
    /// </summary>
    public async Task<FallosPortal> FallosRecientesAsync(
        Guid tenantId, string documentoHash, string ip, CancellationToken ct = default)
    {
        await using var conexion = await _sesiones.AbrirCatalogoAsync(ct);

        return await conexion.QuerySingleAsync<FallosPortal>(new CommandDefinition(
            """
            SELECT (SELECT count(*)::int FROM portal_intentos
                     WHERE tenant_id = @tenantId
                       AND documento = @documentoHash
                       AND NOT exito
                       AND ocurrido_en > now() - interval '15 minutes') AS "PorDocumento",

                   (SELECT count(*)::int FROM portal_intentos
                     WHERE ip = @ip
                       AND NOT exito
                       AND ocurrido_en > now() - interval '1 hour')     AS "PorIp"
            """,
            new { tenantId, documentoHash, ip }, cancellationToken: ct));
    }

    public async Task RegistrarIntentoAsync(
        Guid tenantId, string documentoHash, string ip, bool exito,
        CancellationToken ct = default)
    {
        await using var conexion = await _sesiones.AbrirCatalogoAsync(ct);

        await conexion.ExecuteAsync(new CommandDefinition(
            """
            INSERT INTO portal_intentos (tenant_id, documento, ip, exito)
            VALUES (@tenantId, @documentoHash, @ip, @exito)
            """,
            new { tenantId, documentoHash, ip, exito }, cancellationToken: ct));
    }

    /// <summary>
    /// Opción A: el comprobante que cuadra con los cinco datos, o null.
    ///
    /// Si dos cuadraran a la vez (una factura y una nota con la misma serie,
    /// número, fecha, importe y cliente), se devuelve la factura. Que pase es
    /// casi imposible, y aun así el cliente ve un comprobante suyo.
    /// </summary>
    public async Task<ComprobantePortal?> BuscarAsync(
        Guid tenantId, BusquedaPortal b, CancellationToken ct = default)
    {
        await using var sesion = await _sesiones.AbrirAsync(tenantId, ct);

        var fila = await sesion.Conexion.QueryFirstOrDefaultAsync<ComprobantePortal>(
            new CommandDefinition(
                $"""
                SELECT {ColumnasComprobante}
                  FROM comprobantes c
                 WHERE c.tenant_id     = @tenantId
                   AND c.serie         = @Serie
                   AND c.correlativo   = @Correlativo
                   AND c.fecha_emision = @FechaEmision::date
                   AND c.importe_total = @ImporteTotal
                   AND c.tipo_comprobante IN {TiposVisibles}
                   AND c.estado IN {EstadosVisibles}
                   AND c.cpe->'receptor'->>'tipoDocumento'   = @TipoDocumento
                   AND c.cpe->'receptor'->>'numeroDocumento' = @NumeroDocumento
                 ORDER BY c.tipo_comprobante
                 LIMIT 1
                """,
                new
                {
                    tenantId,
                    b.Serie,
                    b.Correlativo,
                    FechaEmision = b.FechaEmision.Date,
                    b.ImporteTotal,
                    b.TipoDocumento,
                    b.NumeroDocumento
                },
                sesion.Transaccion, cancellationToken: ct));

        await sesion.ConfirmarAsync(ct);
        return fila;
    }

    /// <summary>
    /// Un comprobante por id, dentro de la sesión de su empresa. Con los
    /// mismos filtros que la búsqueda: un acceso no abre lo que el portal no
    /// enseña.
    /// </summary>
    public async Task<ComprobantePortal?> ObtenerAsync(
        Guid tenantId, Guid comprobanteId, CancellationToken ct = default)
    {
        await using var sesion = await _sesiones.AbrirAsync(tenantId, ct);

        var fila = await sesion.Conexion.QuerySingleOrDefaultAsync<ComprobantePortal>(
            new CommandDefinition(
                $"""
                SELECT {ColumnasComprobante}
                  FROM comprobantes c
                 WHERE c.id = @comprobanteId
                   AND c.tipo_comprobante IN {TiposVisibles}
                   AND c.estado IN {EstadosVisibles}
                """,
                new { comprobanteId },
                sesion.Transaccion, cancellationToken: ct));

        await sesion.ConfirmarAsync(ct);
        return fila;
    }

    /// <summary>Crea un acceso. Se guarda el hash, nunca el identificador.</summary>
    public async Task CrearAccesoAsync(
        Guid tenantId, Guid comprobanteId, string hash, string origen, TimeSpan duracion,
        CancellationToken ct = default)
    {
        await using var conexion = await _sesiones.AbrirCatalogoAsync(ct);

        await conexion.ExecuteAsync(new CommandDefinition(
            """
            INSERT INTO portal_accesos (tenant_id, comprobante_id, hash, origen, expira_en)
            VALUES (@tenantId, @comprobanteId, @hash, @origen,
                    now() + make_interval(secs => @segundos))
            """,
            new { tenantId, comprobanteId, hash, origen, segundos = duracion.TotalSeconds },
            cancellationToken: ct));
    }

    /// <summary>
    /// El comprobante de un acceso vigente DE ESTA EMPRESA, y anota el uso.
    /// Null si no existe, es de otra empresa, caducó o se anuló: las cuatro
    /// cosas se ven igual desde fuera.
    /// </summary>
    public async Task<Guid?> ResolverAccesoAsync(
        Guid tenantId, string hash, CancellationToken ct = default)
    {
        await using var conexion = await _sesiones.AbrirCatalogoAsync(ct);

        return await conexion.QuerySingleOrDefaultAsync<Guid?>(new CommandDefinition(
            """
            UPDATE portal_accesos
               SET usos = usos + 1,
                   ultimo_uso_en = now()
             WHERE hash = @hash
               AND tenant_id = @tenantId
               AND anulado_en IS NULL
               AND expira_en > now()
            RETURNING comprobante_id
            """,
            new { tenantId, hash }, cancellationToken: ct));
    }
}
'@

# --- Facturacion.Api\Autenticacion.cs
Planear 'Facturacion.Api\Autenticacion.cs' '71B64CAB7D3DF6A8D5E0B5DEFBBF40739A0AA47E8C41BB8B46C256452519B486' @'
using Facturacion.Persistencia;

namespace Facturacion.Api;

/// <summary>
/// El emisor de la petición en curso.
///
/// Se registra como servicio con ámbito de petición, así que cualquier
/// endpoint puede pedirlo y siempre corresponde a quien está llamando.
/// </summary>
public sealed class ContextoEmisor
{
    public TenantResuelto? Tenant { get; private set; }

    public bool Autenticado => Tenant is not null;

    public TenantResuelto Exigir() =>
        Tenant ?? throw new InvalidOperationException(
            "No hay emisor en el contexto. El endpoint debería estar protegido.");

    internal void Establecer(TenantResuelto tenant) => Tenant = tenant;
}

/// <summary>
/// Middleware que resuelve el emisor a partir de la clave de acceso.
///
/// ESTE ES EL PUNTO DONDE EL AISLAMIENTO SE VUELVE REAL. Row Level Security
/// da la capacidad, pero solo sirve si el tenant_id que se declara viene de
/// algo que el cliente no controla. Esa es la clave de acceso.
///
/// Si el tenant viniera en el cuerpo de la petición o en un parámetro,
/// cualquiera podría poner el de otra empresa.
///
/// La clave se envía así:
///
///     Authorization: Bearer fac_test_xxxxx
///
/// o bien:
///
///     X-Api-Key: fac_test_xxxxx
/// </summary>
public sealed class AutenticacionApiKey
{
    private readonly RequestDelegate _siguiente;

    public AutenticacionApiKey(RequestDelegate siguiente)
    {
        _siguiente = siguiente;
    }

    public async Task InvokeAsync(
        HttpContext contexto,
        RepositorioTenants tenants,
        ContextoEmisor emisor)
    {
        // Las rutas públicas no exigen clave.
        if (EsRutaPublica(contexto.Request.Path))
        {
            await _siguiente(contexto);
            return;
        }

        var clave = LeerClave(contexto.Request);

        if (string.IsNullOrWhiteSpace(clave))
        {
            await Responder(contexto, StatusCodes.Status401Unauthorized,
                "Falta la clave de acceso.",
                "Envíala en la cabecera Authorization: Bearer <clave> o X-Api-Key: <clave>.");
            return;
        }

        var tenant = await tenants.ResolverPorClaveAsync(
            clave, contexto.RequestAborted);

        if (tenant is null)
        {
            // Un solo mensaje para clave inexistente, revocada o emisor
            // desactivado. Distinguirlos le diría a quien prueba claves
            // cuáles existen.
            await Responder(contexto, StatusCodes.Status401Unauthorized,
                "Clave de acceso no válida.");
            return;
        }

        emisor.Establecer(tenant);

        await _siguiente(contexto);
    }

    private static bool EsRutaPublica(PathString ruta) =>
        ruta.StartsWithSegments("/health") ||
        ruta.StartsWithSegments("/openapi") ||
        ruta.StartsWithSegments("/swagger") ||
        ruta.StartsWithSegments("/docs") ||

        // Los endpoints de operación NO son públicos: tienen su propia
        // autenticación, con una clave distinta a la de los emisores.
        // Una clave de emisor jamás debe abrirlos, porque muestran datos
        // de todas las empresas.
        ruta.StartsWithSegments("/admin") ||

        // El portal del receptor es público POR DISEÑO: lo abre el cliente
        // de cada emisor, que no tiene clave ni cuenta. No muestra nada sin
        // los cinco datos del comprobante o un acceso válido, y la empresa
        // sale siempre de la dirección (EndpointsPortal).
        ruta.StartsWithSegments("/portal") ||

        EsArchivoEstatico(ruta.Value) ||

        ruta == "/";

    /// <summary>
    /// Los archivos del panel se sirven sin clave de emisor.
    ///
    /// No exponen nada: el HTML pide la clave de operador por su cuenta antes
    /// de consultar cualquier dato. Lo que está protegido son los endpoints
    /// que devuelven información, no la página que los llama.
    ///
    /// PathString no es una cadena: es un tipo propio de ASP.NET. Su
    /// propiedad Value sí lo es, y puede ser nula.
    /// </summary>
    private static bool EsArchivoEstatico(string? ruta)
    {
        if (string.IsNullOrEmpty(ruta)) return false;

        return ruta.EndsWith(".html", StringComparison.OrdinalIgnoreCase)
            || ruta.EndsWith(".css", StringComparison.OrdinalIgnoreCase)
            || ruta.EndsWith(".js", StringComparison.OrdinalIgnoreCase)
            || ruta.EndsWith(".ico", StringComparison.OrdinalIgnoreCase);
    }

    private static string? LeerClave(HttpRequest peticion)
    {
        var autorizacion = peticion.Headers.Authorization.ToString();

        if (autorizacion.StartsWith("Bearer ", StringComparison.OrdinalIgnoreCase))
            return autorizacion["Bearer ".Length..].Trim();

        var cabecera = peticion.Headers["X-Api-Key"].ToString();

        return string.IsNullOrWhiteSpace(cabecera) ? null : cabecera.Trim();
    }

    private static async Task Responder(
        HttpContext contexto, int codigo, string error, string? detalle = null)
    {
        contexto.Response.StatusCode = codigo;
        await contexto.Response.WriteAsJsonAsync(new RespuestaError(error, detalle));
    }
}
'@

# --- Facturacion.Api\Program.cs
Planear 'Facturacion.Api\Program.cs' 'CC8A35B77305EBE02E13F7043F563F92260AE73C2EBC3AE1C5C598AF06F78519' @'
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
    UrlPanel = ConfiguracionSecretos.Opcional("PANEL_URL", "https://localhost:7295")
};

builder.Services.AddSingleton(opcionesCorreo);
builder.Services.AddSingleton<ServicioCorreo>();

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

# --- migraciones\021_portal.sql
Planear 'migraciones\021_portal.sql' '' @'
-- ===========================================================================
-- 021 — El portal del receptor: accesos e intentos
--
-- POR QUÉ HACE FALTA:
--
-- El cliente de cada emisor entra en comprobantes.reyban.pe/{empresa}, da
-- cinco datos de su comprobante y lo descarga (opción A). Más adelante
-- llegará también por un enlace del correo (opción B). Las dos cosas acaban
-- en un ACCESO: una fila que dice "quien tenga este identificador puede ver
-- este comprobante hasta tal hora".
--
--
-- LAS DOS TABLAS NUEVAS NO TIENEN RLS, Y ES A PROPÓSITO. Siguen el mismo
-- patrón que api_keys:
--
--   - Se buscan por un hash que nadie puede adivinar, no por empresa. La
--     empresa sale de la fila, igual que con una clave `fac_`.
--   - No guardan nada del comprobante: solo ids, hashes, IP y horas. El
--     comprobante en sí se sigue leyendo SIEMPRE con la sesión de la
--     empresa, con RLS, y además se comprueba que el acceso es de la empresa
--     de la dirección.
--   - El límite por IP tiene que contar intentos de TODAS las empresas: con
--     RLS haría falta una función SECURITY DEFINER, que en producción solo
--     funciona si el dueño de la tabla se salta RLS. Sin RLS no hace falta.
--
--
-- NO SE GUARDA EL IDENTIFICADOR DEL ACCESO, SOLO SU SHA-256. Quien se lleve
-- una copia de la base no se lleva enlaces que funcionen.
--
-- NO SE GUARDA EL DOCUMENTO DEL RECEPTOR EN LOS INTENTOS, SOLO SU SHA-256
-- (junto con la empresa). Para contar fallos basta con saber si dos intentos
-- son del mismo documento, no cuál es.
--
-- NADA SE BORRA: no hay DELETE para nadie. Un acceso se anula (anulado_en).
-- ===========================================================================

BEGIN;

-- Buscar por número dentro de una empresa. El índice único que ya existe
-- lleva el tipo de comprobante en medio, y el portal no lo pregunta.
CREATE INDEX IF NOT EXISTS ix_comprobantes_portal
    ON comprobantes (tenant_id, serie, correlativo);


CREATE TABLE IF NOT EXISTS portal_accesos (
    id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       uuid        NOT NULL REFERENCES tenants(id)      ON DELETE RESTRICT,
    comprobante_id  uuid        NOT NULL REFERENCES comprobantes(id) ON DELETE RESTRICT,
    hash            char(64)    NOT NULL,
    origen          text        NOT NULL,
    creado_en       timestamptz NOT NULL DEFAULT now(),
    expira_en       timestamptz NOT NULL,
    anulado_en      timestamptz,
    anulado_motivo  text,
    usos            integer     NOT NULL DEFAULT 0,
    ultimo_uso_en   timestamptz,

    CONSTRAINT ux_portal_accesos_hash    UNIQUE (hash),
    CONSTRAINT ck_portal_accesos_hash    CHECK (hash ~ '^[0-9a-f]{64}$'),
    CONSTRAINT ck_portal_accesos_origen  CHECK (origen IN ('consulta', 'correo')),
    CONSTRAINT ck_portal_accesos_expira  CHECK (expira_en > creado_en),
    CONSTRAINT ck_portal_accesos_anulado CHECK ((anulado_en IS NULL) = (anulado_motivo IS NULL))
);

CREATE INDEX IF NOT EXISTS ix_portal_accesos_comprobante
    ON portal_accesos (comprobante_id);


CREATE TABLE IF NOT EXISTS portal_intentos (
    id           uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id    uuid        NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
    documento    char(64)    NOT NULL,
    ip           text        NOT NULL,
    exito        boolean     NOT NULL,
    ocurrido_en  timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT ck_portal_intentos_documento CHECK (documento ~ '^[0-9a-f]{64}$')
);

-- Solo se cuentan los fallos, así que solo se indexan los fallos.
CREATE INDEX IF NOT EXISTS ix_portal_intentos_documento
    ON portal_intentos (tenant_id, documento, ocurrido_en) WHERE NOT exito;

CREATE INDEX IF NOT EXISTS ix_portal_intentos_ip
    ON portal_intentos (ip, ocurrido_en) WHERE NOT exito;


-- PERMISOS. La aplicación crea accesos, cuenta sus usos y registra intentos.
-- Anular un acceso lo hace el operador desde el panel (paso 4). Nadie borra.
GRANT SELECT, INSERT                 ON portal_accesos  TO facturacion_app;
GRANT UPDATE (usos, ultimo_uso_en)   ON portal_accesos  TO facturacion_app;
GRANT SELECT, INSERT                 ON portal_intentos TO facturacion_app;

GRANT SELECT, INSERT, UPDATE         ON portal_accesos  TO facturacion_operador;
GRANT SELECT                         ON portal_intentos TO facturacion_operador;


-- Los comentarios van sin tildes: PowerShell 5.1 manda este archivo a psql
-- en ASCII.
COMMENT ON TABLE portal_accesos IS
    'Quien tenga el identificador (aqui solo su SHA-256) puede ver ese comprobante hasta expira_en. Consulta: 30 min. Correo: 400 dias. Se anula, no se borra.';
COMMENT ON TABLE portal_intentos IS
    'Busquedas del portal, para limitar intentos: 5 fallos en 15 min por documento y 30 en 1 hora por IP. documento es un SHA-256.';

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
Write-Host 'FALTA APLICAR LA MIGRACIÓN 021 (este script NO la aplica). Desde esta carpeta:' -ForegroundColor Cyan
Write-Host ''
Write-Host '  Get-Content migraciones\021_portal.sql -Raw | docker compose exec -T postgres psql -U facturacion_owner -d facturacion -v ON_ERROR_STOP=1' -ForegroundColor White
Write-Host ''
Write-Host 'Tiene que terminar en COMMIT. Después, reinicia la API del servicio.' -ForegroundColor Cyan
Write-Host ''
