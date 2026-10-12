# =============================================================================
# Entrega 2026-10-10 — Portal: textos que no confunden enlace con factura
#
# Se ejecuta desde la raíz del servicio:
#   cd "D:\Reyban Consulting\facturacion electronica\facturacion_electronica_service"
#   .\entrega-2026-10-10-paso4d-textos.ps1
#
#   EndpointsPortal.cs          Lo que ve el cliente con un enlace revocado o
#                               caducado: «Este enlace ya no está disponible.
#                               Puede haber caducado o haberse desactivado. Tu
#                               comprobante sigue siendo válido: búscalo con tus
#                               datos.» (antes decía «haberse anulado»)
#   wwwroot\comprobantes.html   La columna del portal pasa a «Estado del
#                               enlace», para no confundirla con el de la factura
#
# EndpointsPortal.cs es código: hay que reiniciar la API del servicio.
# Todo o nada, UTF-8 sin BOM, .bak. Sin migración.
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
Planear 'Facturacion.Api\EndpointsPortal.cs' '8626BE376DA622EE48CE42B4C6F7E75870F64D7F8CB70D1622C967799724556F' @'
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
        // "ANULADO" NO: al cliente le suena a que anularon SU FACTURA, y la
        // factura no cambia cuando se revoca o caduca un enlace.
        Results.NotFound(new RespuestaError(
            "Este enlace ya no está disponible.",
            "Puede haber caducado o haberse desactivado. Tu comprobante sigue " +
            "siendo válido: búscalo con tus datos."));

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

# --- Facturacion.Api\wwwroot\comprobantes.html
Planear 'Facturacion.Api\wwwroot\comprobantes.html' '46151765A5AE787CE0E5BA9AB111729E5803031645AD976C6B83CD171BAE908B' @'
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

            /* Ventana para anular enlaces del portal. Va encima del detalle,
               por eso su velo tiene un z-index mayor. */
            #velo-anular {
                z-index: 80;
            }

            .modal textarea {
                width: 100%;
                font: inherit;
                font-size: 14px;
                color: var(--texto);
                background: var(--panel);
                border: 1px solid var(--borde);
                border-radius: var(--radio);
                padding: 9px 11px;
                resize: vertical;
                min-height: 74px;
            }

                .modal textarea:focus {
                    outline: none;
                    border-color: var(--acento);
                }

            .modal .aviso-modal {
                background: var(--mal-fondo);
                color: var(--mal);
                border-radius: var(--radio);
                padding: 10px 13px;
                font-size: 13.5px;
                margin-bottom: 16px;
                line-height: 1.5;
            }

            .modal .sugerencias {
                display: flex;
                gap: 6px;
                flex-wrap: wrap;
                margin: 8px 0 4px;
            }

                .modal .sugerencias button {
                    font-size: 12.5px;
                    padding: 4px 10px;
                    border-radius: 999px;
                    color: var(--tenue);
                    background: var(--sutil);
                    border-color: var(--sutil);
                }

                    .modal .sugerencias button:hover {
                        color: var(--texto);
                        border-color: var(--borde-fuerte);
                    }

            .modal .error-campo {
                color: var(--mal);
                font-size: 12.5px;
                min-height: 18px;
                margin-top: 4px;
            }

            .modal .botones {
                display: flex;
                gap: 8px;
                justify-content: flex-end;
                margin-top: 14px;
            }

            button.peligro-lleno {
                background: var(--mal);
                border-color: var(--mal);
                color: #fff;
                font-weight: 500;
            }

                button.peligro-lleno:hover:not(:disabled) {
                    filter: brightness(1.08);
                    border-color: var(--mal);
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

    <div class="velo" id="velo-anular" role="dialog" aria-modal="true" aria-labelledby="an-titulo">
        <div class="modal" style="max-width:480px">
            <h3 id="an-titulo">Revocar enlaces del portal</h3>
            <div class="sub" id="an-sub"></div>

            <div class="aviso-modal">
                Los enlaces dejan de abrir de inmediato, también el del correo que
                recibió el cliente. <strong>El comprobante no cambia</strong>: sigue
                aceptado ante SUNAT, y el cliente puede seguir buscándolo con sus
                datos en el portal.
            </div>

            <label for="an-motivo">Motivo</label>
            <textarea id="an-motivo" maxlength="300"
                      placeholder="Queda guardado junto al enlace"></textarea>

            <div class="sugerencias" id="an-sugerencias">
                <button type="button">El correo se envió a una dirección equivocada</button>
                <button type="button">Lo pidió el cliente</button>
                <button type="button">Prueba</button>
            </div>

            <div class="error-campo" id="an-error"></div>

            <div class="botones">
                <button type="button" id="an-cancelar">Cancelar</button>
                <button type="button" id="an-aceptar" class="peligro-lleno">Revocar enlaces</button>
            </div>
        </div>
    </div>

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
                  <tr><th>Enlace</th><th>Creado</th><th>Vale hasta</th><th>Usos</th><th>Estado del enlace</th></tr>
                  ${datos.accesos.map(a => `<tr>
                    <td>${a.origen === "correo" ? "del correo" : "búsqueda (30 min)"}</td>
                    <td class="tenue" style="white-space:nowrap">${fechaHora(a.creadoEn)}</td>
                    <td class="tenue" style="white-space:nowrap">${fechaHora(a.expiraEn)}</td>
                    <td>${a.usos}</td>
                    <td>${a.vigente
                        ? `<span class="insignia i-ok">vigente</span>`
                        : a.anuladoEn
                            ? `<span class="insignia i-tenue" title="${esc(a.anuladoMotivo ?? "")}">revocado</span>`
                            : `<span class="insignia i-tenue">caducado</span>`}</td>
                  </tr>`).join("")}
                </table>`;

            const boton = vigentes > 0 && puede("comprobantes.reprocesar")
                ? `<button class="mini" id="btn-anular-enlaces" data-vigentes="${vigentes}"
                           style="margin-top:12px;color:var(--mal)">
                     Revocar ${vigentes === 1 ? "el enlace vigente" : `los ${vigentes} enlaces vigentes`}</button>`
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

        /// Pide el motivo en una ventana del panel, no con prompt() del
        /// navegador: el de Brave o Chrome dice "localhost:5100 dice" y no
        /// se puede validar ni dar estilo.
        function pedirMotivo(numero, vigentes) {
            return new Promise(resolver => {
                const campo = elem("an-motivo");
                const error = elem("an-error");

                elem("an-sub").textContent = vigentes === 1
                    ? `${numero} · 1 enlace vigente`
                    : `${numero} · ${vigentes} enlaces vigentes`;

                campo.value = "";
                error.textContent = "";
                elem("velo-anular").classList.add("visible");
                campo.focus();

                elem("an-sugerencias").querySelectorAll("button").forEach(b =>
                    b.onclick = () => { campo.value = b.textContent; error.textContent = ""; campo.focus(); });

                const cerrar = valor => {
                    elem("velo-anular").classList.remove("visible");
                    document.removeEventListener("keydown", teclas);
                    resolver(valor);
                };

                const aceptar = () => {
                    const motivo = campo.value.trim();

                    if (motivo.length < 3) {
                        error.textContent = "Escribe el motivo: es lo que se lee después cuando alguien pregunta por qué dejó de abrir.";
                        campo.focus();
                        return;
                    }

                    cerrar(motivo);
                };

                const teclas = ev => {
                    if (ev.key === "Escape") cerrar(null);
                    if (ev.key === "Enter" && (ev.ctrlKey || ev.metaKey)) aceptar();
                };

                document.addEventListener("keydown", teclas);
                elem("an-cancelar").onclick = () => cerrar(null);
                elem("an-aceptar").onclick = aceptar;
            });
        }

        async function anularEnlaces(id, boton) {
            const numero = estado.ultima?.resultados?.find(x => x.id === id)?.numero ?? "";
            const vigentes = parseInt(boton.dataset.vigentes || "1", 10);

            const motivo = await pedirMotivo(numero, vigentes);
            if (motivo === null) return;

            boton.disabled = true;

            try {
                const r = await fetch(`/admin/comprobantes/${id}/portal/anular`, {
                    method: "POST",
                    headers: { "Content-Type": "application/json" },
                    body: JSON.stringify({ motivo })
                });

                if (r.status === 401) { location.href = "/login.html"; return; }

                const cuerpo = await r.json().catch(() => ({}));

                if (!r.ok) {
                    avisar(cuerpo.error || "No se pudo revocar", cuerpo.detalle, "mal");
                    boton.disabled = false;
                    return;
                }

                avisar(cuerpo.anulados === 1 ? "Enlace revocado"
                         : cuerpo.anulados > 1 ? `${cuerpo.anulados} enlaces revocados`
                         : "No había enlaces vigentes",
                       "El comprobante no cambia: sigue aceptado.", "ok");
                await cargarPortal(id);

            } catch (e) {
                avisar("Error al revocar", e.message, "mal");
                boton.disabled = false;
            }
        }

        cargarUsuario().then(ok => { if (ok) { ajustarFiltros(); buscar(); } });
    </script>
</body>
</html>
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
Write-Host 'Sin migración. Reinicia la API del servicio y recarga el panel con Ctrl+F5.' -ForegroundColor Cyan
Write-Host ''
