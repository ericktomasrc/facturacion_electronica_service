# =============================================================================
# Entrega 2026-10-10 — Portal del receptor, PASO 2: la marca de cada empresa
#
# Se ejecuta desde la raíz del servicio:
#   cd "D:\Reyban Consulting\facturacion electronica\facturacion_electronica_service"
#   .\entrega-2026-10-10-paso2-marca.ps1
#
#   Marca.cs                    NUEVO. Las reglas del identificador del portal,
#                               el color, el correo de respuesta y el logo
#   EndpointsAdmin.cs           PUT /admin/tenants/{id}/marca, GET y POST
#                               /admin/tenants/{id}/logo; el alta acepta el
#                               identificador; la contraseña del certificado
#                               pasa de la dirección (?clave=) al cuerpo
#   PdfDeComprobante.cs         El PDF lleva el logo; si no se puede dibujar,
#                               sale sin él
#   wwwroot\admin.html          Pestaña «Marca»; identificador en el alta;
#                               contraseña del certificado en el cuerpo
#   wwwroot\login.html          Los ojitos de la contraseña salían solo después
#                               de intentar entrar sin correo
#   RepositorioAdmin.cs         La marca en la lista de empresas; guardarla;
#                               guardar y leer el logo
#   ModelosPersistencia.cs      DatosParaPdf gana LogoRuta
#   RepositorioComprobantes.cs  La consulta del PDF trae el logo de la empresa
#   migraciones\020_marca_empresa.sql   NUEVO. No se aplica sola
#
# PROTECCIÓN: cada archivo solo se reemplaza si en tu disco sigue IGUAL al que
# me pasaste (RepositorioComprobantes.cs: igual al que dejó el paso 1). Si
# alguno cambió, NO TOCA NADA. Todo o nada. UTF-8 sin BOM, .bak.
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

# --- Facturacion.Api\Marca.cs
Planear 'Facturacion.Api\Marca.cs' '' @'
using System.Text.RegularExpressions;
using Facturacion.Pdf;
using QuestPDF.Fluent;
using QuestPDF.Helpers;

namespace Facturacion.Api;

/// <summary>
/// Las comprobaciones de la marca de una empresa: identificador del portal,
/// color, correo de respuesta y logo.
///
/// LA BASE TIENE LAS MISMAS REGLAS (migración 020) y es la última barrera.
/// Estas existen para devolver un mensaje que se entienda en lugar de un
/// error de restricción. Si se cambia una regla aquí, hay que cambiarla allí.
///
/// Cada función devuelve null si el valor está bien, o el motivo si no.
/// </summary>
public static partial class Marca
{
    /// <summary>Lo que el logo puede pesar como máximo.</summary>
    public const int LogoMaximoBytes = 300 * 1024;

    // Palabras que ya usa o usará la dirección del portal. Una empresa
    // llamada "api" dejaría su página tapada por las rutas de la API.
    private static readonly HashSet<string> Reservados = new(StringComparer.Ordinal)
    {
        "api", "e", "portal", "admin", "www", "static", "assets", "health", "docs"
    };

    [GeneratedRegex("^[a-z0-9][a-z0-9-]{1,38}[a-z0-9]$")]
    private static partial Regex FormaIdentificador();

    [GeneratedRegex("^#[0-9a-fA-F]{6}$")]
    private static partial Regex FormaColor();

    /// <summary>Quita espacios y pasa a minúsculas. Vacío es null.</summary>
    public static string? LimpiarIdentificador(string? valor) =>
        string.IsNullOrWhiteSpace(valor) ? null : valor.Trim().ToLowerInvariant();

    public static string? ProblemaIdentificador(string? identificador)
    {
        if (identificador is null) return null;

        if (identificador.Length is < 3 or > 40)
            return "Debe tener entre 3 y 40 caracteres.";

        if (!FormaIdentificador().IsMatch(identificador))
            return "Solo letras minúsculas sin tilde, números y guiones, y no puede " +
                   "empezar ni terminar con guion. Ejemplo: ferreteria-lopez.";

        if (identificador.Contains("--"))
            return "No puede llevar dos guiones seguidos.";

        if (Reservados.Contains(identificador))
            return $"«{identificador}» está reservado para la dirección del portal. Elige otro.";

        return null;
    }

    /// <summary>#RRGGBB a #rrggbb. Vacío es null: sin color.</summary>
    public static string? LimpiarColor(string? valor) =>
        string.IsNullOrWhiteSpace(valor) ? null : valor.Trim().ToLowerInvariant();

    public static string? ProblemaColor(string? color) =>
        color is null || FormaColor().IsMatch(color)
            ? null
            : "El color tiene que ir como #rrggbb, por ejemplo #1f6feb.";

    public static string? LimpiarCorreo(string? valor) =>
        string.IsNullOrWhiteSpace(valor) ? null : valor.Trim();

    /// <summary>La misma regla que el correo del receptor (ReceptorDto).</summary>
    public static string? ProblemaCorreo(string? correo)
    {
        if (correo is null) return null;

        if (correo.Length > 254)
            return "El correo es demasiado largo (máximo 254 caracteres).";

        var arroba = correo.IndexOf('@');
        var dominio = arroba > 0 ? correo[(arroba + 1)..] : "";

        var tieneForma =
            arroba > 0 &&
            arroba == correo.LastIndexOf('@') &&
            dominio.Contains('.') &&
            !dominio.StartsWith('.') &&
            !dominio.EndsWith('.') &&
            !correo.Any(char.IsWhiteSpace);

        return tieneForma ? null : $"«{correo}» no tiene forma de correo.";
    }

    /// <summary>
    /// Qué clase de imagen es, mirando sus primeros bytes. Null si no es PNG
    /// ni JPG.
    ///
    /// NO SE FÍA DEL NOMBRE NI DEL TIPO QUE MANDA EL NAVEGADOR: los dos los
    /// pone quien sube el archivo. Los primeros bytes los pone el formato.
    /// SVG no se acepta: es texto con posibilidad de llevar código, y se
    /// serviría desde una página pública.
    /// </summary>
    public static (string Extension, string TipoMime)? TipoDeImagen(byte[] datos)
    {
        if (datos.Length >= 8 &&
            datos[0] == 0x89 && datos[1] == 0x50 && datos[2] == 0x4E && datos[3] == 0x47 &&
            datos[4] == 0x0D && datos[5] == 0x0A && datos[6] == 0x1A && datos[7] == 0x0A)
            return ("png", "image/png");

        if (datos.Length >= 3 && datos[0] == 0xFF && datos[1] == 0xD8 && datos[2] == 0xFF)
            return ("jpg", "image/jpeg");

        return null;
    }

    /// <summary>
    /// Prueba a dibujar el logo en un PDF de verdad, del mismo alto que en la
    /// factura. Null si sale; el motivo si no.
    ///
    /// POR QUÉ SE PRUEBA AL SUBIRLO Y NO AL USARLO: unos bytes que empiezan
    /// como PNG pueden estar cortados o dañados. Si eso se descubre al generar
    /// el PDF de una factura, el que se queda sin su comprobante es el cliente
    /// del emisor. Así se descubre aquí, con quien lo subió delante.
    /// </summary>
    public static string? ProblemaAlDibujar(byte[] datos)
    {
        try
        {
            GeneradorPdf.ConfigurarLicencia();

            Document.Create(contenedor => contenedor.Page(pagina =>
            {
                pagina.Size(PageSizes.A4);
                pagina.Content().Height(50).Image(datos).FitHeight();
            })).GeneratePdf();

            return null;
        }
        catch (Exception)
        {
            return "La imagen está dañada o no se puede dibujar en el PDF. " +
                   "Vuelve a exportarla como PNG o JPG.";
        }
    }
}
'@

# --- Facturacion.Api\EndpointsAdmin.cs
Planear 'Facturacion.Api\EndpointsAdmin.cs' 'D834B32DD83FF8747A457D078FFBF0E556EC057E4ED66A1505A655882977BC6B' @'
using System.Security.Cryptography;
using Facturacion.Persistencia;
using Microsoft.AspNetCore.Mvc;

namespace Facturacion.Api;

/// <summary>
/// Administración de la plataforma: empresas, certificados, series y claves.
///
/// Todo esto se hacía hasta ahora escribiendo SQL a mano, lo cual funciona
/// mientras el sistema lo maneja quien lo construyó. Deja de funcionar el día
/// que hay que delegarlo, y ese día llega antes de lo que parece.
/// </summary>
public static class EndpointsAdmin
{
    public static void MapearAdministracion(this WebApplication app)
    {
        // CADA ACCIÓN EXIGE SU PROPIO PERMISO, no un rol entero.
        //
        // Quien da de alta clientes no necesita cargar certificados, y quien
        // atiende llamadas no necesita crear empresas. Repartirlo así permite
        // dar a cada persona exactamente lo que usa.
        var grupo = app.MapGroup("/admin")
            .AddEndpointFilter<AutenticacionPanel>()
            .WithTags("Administración");

        // ------------------------------------------------------------ empresas

        grupo.MapGet("/tenants", async (
            RepositorioAdmin admin, CancellationToken ct) =>
            Results.Ok(await admin.ListarTenantsAsync(ct)))
            .AddEndpointFilter(new ExigirPermiso(Permiso.EmpresasVer))
        .WithSummary("Lista las empresas");

        grupo.MapPost("/tenants", async (
            NuevoTenant nuevo, RepositorioAdmin admin, CancellationToken ct) =>
        {
            if (nuevo.Ruc.Length != 11 || !nuevo.Ruc.All(char.IsDigit))
                return Results.BadRequest(new RespuestaError(
                    "RUC inválido.", "Debe tener exactamente 11 dígitos."));

            if (string.IsNullOrWhiteSpace(nuevo.RazonSocial))
                return Results.BadRequest(new RespuestaError(
                    "Falta la razón social."));

            // El identificador del portal es opcional al dar de alta.
            nuevo.Identificador = Marca.LimpiarIdentificador(nuevo.Identificador);

            if (Marca.ProblemaIdentificador(nuevo.Identificador) is { } problema)
                return Results.BadRequest(new RespuestaError(
                    "El identificador del portal no es válido.", problema));

            try
            {
                var id = await admin.CrearTenantAsync(nuevo, ct);
                return Results.Ok(new { id, mensaje = "Empresa creada." });
            }
            catch (Npgsql.PostgresException ex) when (
                ex.SqlState == "23505" && ex.ConstraintName == "ux_tenants_identificador")
            {
                return Results.Conflict(IdentificadorEnUso(nuevo.Identificador));
            }
            catch (Npgsql.PostgresException ex) when (ex.SqlState == "23505")
            {
                // Violación de unicidad: el RUC ya existe.
                return Results.Conflict(new RespuestaError(
                    "Ese RUC ya está registrado.",
                    "Cada empresa se da de alta una sola vez."));
            }
        })
        .AddEndpointFilter(new ExigirPermiso(Permiso.EmpresasEditar))
        .WithSummary("Da de alta una empresa");

        grupo.MapPatch("/tenants/{id:guid}", async (
            Guid id, ActualizacionTenant cambios,
            RepositorioAdmin admin, CancellationToken ct) =>
        {
            var actualizado = await admin.ActualizarTenantAsync(
                id, cambios.Activo, cambios.MaxConcurrencia, ct);

            return actualizado
                ? Results.Ok(new { mensaje = "Empresa actualizada." })
                : Results.NotFound(new RespuestaError("No se encontró la empresa."));
        })
        .AddEndpointFilter(new ExigirPermiso(Permiso.EmpresasEditar))
        .WithSummary("Activa, desactiva o ajusta la concurrencia");

        // --------------------------------------------------------------- marca

        grupo.MapPut("/tenants/{id:guid}/marca", async (
            Guid id, CambioMarca cambio,
            RepositorioAdmin admin, CancellationToken ct) =>
        {
            var identificador = Marca.LimpiarIdentificador(cambio.Identificador);
            var color = Marca.LimpiarColor(cambio.ColorMarca);
            var correo = Marca.LimpiarCorreo(cambio.CorreoRespuesta);

            if (Marca.ProblemaIdentificador(identificador) is { } pi)
                return Results.BadRequest(new RespuestaError(
                    "El identificador del portal no es válido.", pi));

            if (Marca.ProblemaColor(color) is { } pc)
                return Results.BadRequest(new RespuestaError("El color no es válido.", pc));

            if (Marca.ProblemaCorreo(correo) is { } pr)
                return Results.BadRequest(new RespuestaError(
                    "El correo de respuesta no es válido.", pr));

            try
            {
                var (resultado, actual) = await admin.GuardarMarcaAsync(
                    id, identificador, color, correo, ct);

                return resultado switch
                {
                    ResultadoMarca.NoExiste =>
                        Results.NotFound(new RespuestaError("No se encontró la empresa.")),

                    ResultadoMarca.IdentificadorFijo =>
                        Results.Conflict(new RespuestaError(
                            "El identificador del portal no se puede cambiar.",
                            $"Esta empresa ya es «{actual}». Es la dirección que va " +
                            "en los correos ya enviados: cambiarla rompería esos " +
                            "enlaces. No se guardó nada.")),

                    _ => Results.Ok(new { mensaje = "Marca guardada.", identificador = actual })
                };
            }
            catch (Npgsql.PostgresException ex) when (
                ex.SqlState == "23505" && ex.ConstraintName == "ux_tenants_identificador")
            {
                return Results.Conflict(IdentificadorEnUso(identificador));
            }
        })
        .AddEndpointFilter(new ExigirPermiso(Permiso.EmpresasEditar))
        .WithSummary("Guarda el identificador del portal, el color y el correo de respuesta")
        .WithDescription(
            "Se mandan los tres campos cada vez. El color y el correo se " +
            "reemplazan: vacío los quita. El identificador solo se puede poner " +
            "una vez; si ya tiene uno y llega otro, responde 409 y no guarda " +
            "nada.");

        grupo.MapGet("/tenants/{id:guid}/logo", async (
            Guid id, HttpContext contexto,
            RepositorioAdmin admin, IAlmacenArchivos archivos, CancellationToken ct) =>
        {
            var logo = await admin.ObtenerLogoAsync(id, ct);

            if (logo?.LogoRuta is not { } ruta)
                return Results.NotFound(new RespuestaError("Esta empresa no tiene logo."));

            var datos = await archivos.LeerAsync(ruta, ct);

            if (datos is null || Marca.TipoDeImagen(datos) is not { } tipo)
                return Results.NotFound(new RespuestaError(
                    "No se encontró el archivo del logo en el almacén."));

            // La dirección lleva ?v=<versión>, que cambia al subir otro logo.
            // Por eso se puede guardar un día sin miedo a enseñar el viejo.
            contexto.Response.Headers.CacheControl = "private, max-age=86400";
            contexto.Response.Headers["X-Content-Type-Options"] = "nosniff";

            return Results.File(datos, tipo.TipoMime);
        })
        .AddEndpointFilter(new ExigirPermiso(Permiso.EmpresasVer))
        .WithSummary("El logo de la empresa, para verlo en el panel");

        grupo.MapPost("/tenants/{id:guid}/logo", async (
            Guid id, IFormFile archivo,
            RepositorioAdmin admin, IAlmacenArchivos archivos, CancellationToken ct) =>
        {
            if (archivo.Length == 0)
                return Results.BadRequest(new RespuestaError("El archivo está vacío."));

            if (archivo.Length > Marca.LogoMaximoBytes)
                return Results.BadRequest(new RespuestaError(
                    "El logo es demasiado grande.",
                    $"Pesa {archivo.Length / 1024} KB y el máximo es " +
                    $"{Marca.LogoMaximoBytes / 1024} KB. Exporta una versión más " +
                    "pequeña: en el PDF se imprime a 50 puntos de alto."));

            using var memoria = new MemoryStream();
            await archivo.CopyToAsync(memoria, ct);
            var datos = memoria.ToArray();

            if (Marca.TipoDeImagen(datos) is not { } tipo)
                return Results.BadRequest(new RespuestaError(
                    "El logo tiene que ser PNG o JPG.",
                    "Se comprueba por el contenido del archivo, no por su nombre."));

            if (Marca.ProblemaAlDibujar(datos) is { } problema)
                return Results.BadRequest(new RespuestaError("No se puede usar ese logo.", problema));

            var empresa = await admin.ObtenerLogoAsync(id, ct);

            if (empresa is null)
                return Results.NotFound(new RespuestaError("No se encontró la empresa."));

            // El nombre sale del contenido: el mismo logo subido dos veces es
            // el mismo archivo, y uno distinto nunca pisa al anterior.
            var huella = Convert.ToHexString(SHA256.HashData(datos))[..16].ToLowerInvariant();

            var ruta = await archivos.GuardarAsync(
                empresa.Ruc, DateTime.UtcNow, $"logo-{huella}.{tipo.Extension}", datos, ct);

            await admin.GuardarLogoAsync(id, ruta, ct);

            return Results.Ok(new { mensaje = "Logo guardado. Ya sale en los PDF." });
        })
        .DisableAntiforgery()
        .AddEndpointFilter(new ExigirPermiso(Permiso.EmpresasEditar))
        .WithSummary("Sube el logo de la empresa")
        .WithDescription(
            "PNG o JPG, máximo 300 KB. Se comprueba que se puede dibujar antes " +
            "de guardarlo. El anterior no se borra del almacén: solo deja de " +
            "usarse.");

        // ------------------------------------------------- credenciales SOL

        grupo.MapPost("/tenants/{id:guid}/credenciales-sol", async (
            Guid id, CredencialesSol credenciales,
            RepositorioAdmin admin, IProtectorDeSecretos protector,
            CancellationToken ct) =>
        {
            if (credenciales.Usuario.Equals("MODDATOS", StringComparison.OrdinalIgnoreCase))
            {
                return Results.BadRequest(new RespuestaError(
                    "MODDATOS es el usuario del ambiente de pruebas.",
                    "Para producción hace falta el usuario SOL secundario real " +
                    "del contribuyente."));
            }

            try
            {
                var guardadas = await admin.GuardarCredencialesSolAsync(
                    id, credenciales.Usuario, credenciales.Clave, protector, ct);

                return guardadas
                    ? Results.Ok(new { mensaje = "Credenciales guardadas y cifradas." })
                    : Results.NotFound(new RespuestaError("No se encontró la empresa."));
            }
            catch (ArgumentException ex)
            {
                return Results.BadRequest(new RespuestaError("Datos inválidos.", ex.Message));
            }
        })
        .AddEndpointFilter(new ExigirPermiso(Permiso.ProduccionCambiar))
        .WithSummary("Guarda las credenciales SOL del contribuyente")
        .WithDescription(
            "La clave se cifra igual que el certificado.\n\n" +
            "Debe ser el usuario SOL SECUNDARIO, nunca el principal: el " +
            "principal puede declarar, pagar y modificar datos en el portal " +
            "de SUNAT, y ese nivel de acceso no tiene por qué vivir aquí.");

        // ------------------------------------------- credenciales de guías

        grupo.MapPost("/tenants/{id:guid}/credenciales-gre", async (
            Guid id, CredencialesGre credenciales,
            RepositorioAdmin admin, IProtectorDeSecretos protector,
            CancellationToken ct) =>
        {
            try
            {
                var guardadas = await admin.GuardarCredencialesGreAsync(
                    id, credenciales.ClientId, credenciales.ClientSecret,
                    protector, ct);

                return guardadas
                    ? Results.Ok(new
                    {
                        mensaje =
                            "Credenciales de guías guardadas y cifradas. " +
                            "La emisión de guías queda habilitada."
                    })
                    : Results.NotFound(new RespuestaError("No se encontró la empresa."));
            }
            catch (ArgumentException ex)
            {
                return Results.BadRequest(new RespuestaError("Datos inválidos.", ex.Message));
            }
        })
        .AddEndpointFilter(new ExigirPermiso(Permiso.ProduccionCambiar))
        .WithSummary("Guarda las credenciales de API para guías de remisión")
        .WithDescription(
            "El client_id y el client_secret los genera el contribuyente en " +
            "su menú SOL, opción 'Credenciales de API SUNAT'.\n\n" +
            "Son DISTINTAS de la clave SOL: esta sirve para las facturas, " +
            "aquellas solo para guías. Una empresa que emita ambas cosas " +
            "necesita los dos juegos.");

        grupo.MapPost("/tenants/{id:guid}/gre-habilitado", async (
            Guid id, CambioGreHabilitado cambio,
            RepositorioAdmin admin, CancellationToken ct) =>
        {
            var cambiado = await admin.CambiarGreHabilitadoAsync(
                id, cambio.Habilitado, ct);

            return cambiado
                ? Results.Ok(new
                {
                    mensaje = cambio.Habilitado
                        ? "Emisión de guías habilitada."
                        : "Emisión de guías deshabilitada."
                })
                : Results.NotFound(new RespuestaError("No se encontró la empresa."));
        })
        .AddEndpointFilter(new ExigirPermiso(Permiso.ProduccionCambiar))
        .WithSummary("Activa o desactiva la emisión de guías");

        grupo.MapGet("/tenants/{id:guid}/revision-produccion", async (
            Guid id, ProveedorCredenciales credenciales, CancellationToken ct) =>
            Results.Ok(await credenciales.RevisarAsync(id, ct)))
            .AddEndpointFilter(new ExigirPermiso(Permiso.EmpresasVer))
            .WithSummary("Comprueba si la empresa puede pasar a producción")
            .WithDescription(
                "Revisa certificado, credenciales SOL y series. Pasar a " +
                "producción sin alguno de ellos hace que todas las facturas " +
                "de esa empresa fallen desde el primer minuto.");

        grupo.MapPost("/tenants/{id:guid}/ambiente", async (
            Guid id, CambioAmbiente cambio,
            RepositorioAdmin admin, ProveedorCredenciales credenciales,
            CancellationToken ct) =>
        {
            // Volver a beta siempre se permite: es la salida cuando algo va mal.
            if (cambio.Ambiente == "beta")
            {
                var vuelto = await admin.CambiarAmbienteAsync(id, "beta", ct);

                return vuelto
                    ? Results.Ok(new { mensaje = "La empresa volvió al ambiente de pruebas." })
                    : Results.NotFound(new RespuestaError("No se encontró la empresa."));
            }

            // Pasar a producción NO. Se comprueba antes.
            var revision = await credenciales.RevisarAsync(id, ct);

            if (!revision.Listo)
            {
                return Results.BadRequest(new RespuestaError(
                    "La empresa todavía no puede pasar a producción.",
                    string.Join(" ", revision.Faltantes)));
            }

            var cambiado = await admin.CambiarAmbienteAsync(id, "produccion", ct);

            return cambiado
                ? Results.Ok(new
                {
                    mensaje = "La empresa pasó a producción.",
                    advertencias = revision.Advertencias
                })
                : Results.NotFound(new RespuestaError("No se encontró la empresa."));
        })
        .AddEndpointFilter(new ExigirPermiso(Permiso.ProduccionCambiar))
        .WithSummary("Cambia el ambiente de la empresa")
        .WithDescription(
            "Pasar a producción exige superar la revisión previa. Volver a " +
            "beta siempre se permite: es la salida cuando algo va mal.");

        // -------------------------------------------------------- certificados

        grupo.MapPost("/tenants/{id:guid}/certificado", async (
            Guid id,
            IFormFile archivo,

            // LA CONTRASEÑA VA EN EL CUERPO, NO EN LA DIRECCIÓN.
            //
            // Antes llegaba como ?clave=... y una dirección queda escrita en
            // los registros de acceso del proxy, en los de cualquier
            // intermediario y en las trazas de error. La contraseña de un
            // certificado no puede acabar en un log.
            [FromForm] string? clave,
            AlmacenCertificados certificados,
            CancellationToken ct) =>
        {
            if (archivo.Length == 0)
                return Results.BadRequest(new RespuestaError("El archivo está vacío."));

            // Un PFX legítimo no llega a este tamaño. El límite evita que
            // alguien suba un archivo enorme y agote la memoria del proceso.
            if (archivo.Length > 512 * 1024)
                return Results.BadRequest(new RespuestaError(
                    "El archivo es demasiado grande.",
                    "Un certificado PFX pesa unos pocos kilobytes."));

            using var memoria = new MemoryStream();
            await archivo.CopyToAsync(memoria, ct);

            try
            {
                var certificadoId = await certificados.GuardarAsync(
                    id, memoria.ToArray(), clave ?? "", ct);

                return Results.Ok(new
                {
                    id = certificadoId,
                    mensaje = "Certificado guardado y cifrado."
                });
            }
            catch (InvalidOperationException ex)
            {
                // Contraseña incorrecta, certificado vencido, o sin llave
                // privada. El mensaje de AlmacenCertificados ya explica cuál.
                return Results.BadRequest(new RespuestaError(
                    "No se pudo guardar el certificado.", ex.Message));
            }
        })
        .DisableAntiforgery()
        .AddEndpointFilter(new ExigirPermiso(Permiso.CertificadosGestionar))
        .WithSummary("Carga el certificado digital de una empresa")
        .WithDescription(
            "El archivo .pfx se cifra antes de guardarse. Solo se descifra en " +
            "memoria y solo en el momento de firmar.\\n\\n" +
            "Reemplaza al certificado activo anterior, que queda desactivado " +
            "en la misma operación: nunca hay dos activos ni un hueco sin " +
            "ninguno.");

        grupo.MapGet("/tenants/{id:guid}/certificados", async (
            Guid id, AlmacenCertificados certificados, CancellationToken ct) =>
            Results.Ok(await certificados.ListarAsync(id, ct)))
            .AddEndpointFilter(new ExigirPermiso(Permiso.EmpresasVer))
            .WithSummary("Lista los certificados de una empresa");

        grupo.MapDelete("/tenants/{id:guid}/certificados/{certificadoId:guid}", async (
            Guid id, Guid certificadoId,
            AlmacenCertificados certificados, CancellationToken ct) =>
        {
            var eliminado = await certificados.EliminarAsync(id, certificadoId, ct);

            return eliminado
                ? Results.Ok(new { mensaje = "Certificado eliminado." })
                : Results.Conflict(new RespuestaError(
                    "No se puede eliminar este certificado.",
                    "O está activo, o ya firmó comprobantes. Un certificado " +
                    "que firmó hay que conservarlo: sin él no se puede " +
                    "verificar esas firmas durante una fiscalización."));
        })
        .AddEndpointFilter(new ExigirPermiso(Permiso.CertificadosGestionar))
        .WithSummary("Elimina un certificado nunca usado")
        .WithDescription(
            "Para el caso de haber cargado el archivo equivocado. Solo " +
            "funciona si el certificado está inactivo y nunca firmó nada.");

        // -------------------------------------------------------------- series

        grupo.MapGet("/tenants/{id:guid}/series", async (
            Guid id, RepositorioAdmin admin, CancellationToken ct) =>
            Results.Ok(await admin.ListarSeriesAsync(id, ct)))
            .AddEndpointFilter(new ExigirPermiso(Permiso.EmpresasVer))
            .WithSummary("Lista las series de una empresa");

        grupo.MapPost("/tenants/{id:guid}/series", async (
            Guid id, NuevaSerie nueva,
            RepositorioAdmin admin, CancellationToken ct) =>
        {
            if (string.IsNullOrWhiteSpace(nueva.Serie) || nueva.Serie.Length != 4)
                return Results.BadRequest(new RespuestaError(
                    "Serie inválida.",
                    "Debe tener 4 caracteres. Ej: F001 para facturas, B001 para boletas."));

            var serieId = await admin.CrearSerieAsync(
                id, nueva.TipoComprobante, nueva.Serie.ToUpperInvariant(),
                nueva.CorrelativoInicial, ct);

            return Results.Ok(new { id = serieId, mensaje = "Serie dada de alta." });
        })
        .AddEndpointFilter(new ExigirPermiso(Permiso.EmpresasEditar))
        .WithSummary("Da de alta una serie")
        .WithDescription(
            "El correlativo inicial normalmente es 0, pero si la empresa migra " +
            "desde otro sistema hay que poner el último número que ya emitió. " +
            "Empezar de nuevo en 1 generaría duplicados que SUNAT rechaza.");

        grupo.MapDelete("/tenants/{id:guid}/series/{serieId:guid}", async (
            Guid id, Guid serieId, RepositorioAdmin admin, CancellationToken ct) =>
        {
            var eliminada = await admin.EliminarSerieAsync(id, serieId, ct);

            return eliminada
                ? Results.Ok(new { mensaje = "Serie eliminada." })
                : Results.Conflict(new RespuestaError(
                    "No se puede eliminar esta serie.",
                    "Ya tiene comprobantes emitidos. Borrarla dejaría huérfano " +
                    "el rastro de esa numeración. Desactívala: deja de poder " +
                    "emitir y el histórico queda intacto."));
        })
        .AddEndpointFilter(new ExigirPermiso(Permiso.EmpresasEditar))
        .WithSummary("Elimina una serie sin usar")
        .WithDescription(
            "Solo funciona si la serie nunca emitió comprobantes. En caso " +
            "contrario hay que desactivarla.");

        grupo.MapPatch("/tenants/{id:guid}/series/{serieId:guid}", async (
            Guid id, Guid serieId, CambioEstadoSerie cambio,
            RepositorioAdmin admin, CancellationToken ct) =>
        {
            var cambiada = await admin.CambiarEstadoSerieAsync(
                id, serieId, cambio.Activo, ct);

            return cambiada
                ? Results.Ok(new { mensaje = cambio.Activo
                    ? "Serie reactivada." : "Serie desactivada." })
                : Results.NotFound(new RespuestaError("No se encontró la serie."));
        })
        .AddEndpointFilter(new ExigirPermiso(Permiso.EmpresasEditar))
        .WithSummary("Activa o desactiva una serie")
        .WithDescription(
            "Una serie desactivada no puede emitir, pero sus comprobantes " +
            "siguen consultándose y descargándose igual.");

        // -------------------------------------------------------------- claves

        grupo.MapGet("/tenants/{id:guid}/claves", async (
            Guid id, RepositorioAdmin admin, CancellationToken ct) =>
            Results.Ok(await admin.ListarClavesAsync(id, ct)))
            .AddEndpointFilter(new ExigirPermiso(Permiso.EmpresasVer))
            .WithSummary("Lista las claves de acceso de una empresa");

        grupo.MapPost("/tenants/{id:guid}/claves", async (
            Guid id, NuevaClave nueva,
            RepositorioAdmin admin, CancellationToken ct) =>
        {
            var (claveId, secreto) = await admin.CrearClaveAsync(
                id, nueva.Nombre, nueva.Produccion, ct);

            return Results.Ok(new
            {
                id = claveId,
                clave = secreto,
                aviso =
                    "Esta es la ÚNICA vez que se muestra la clave. En la base " +
                    "solo queda su hash. Si se pierde, hay que revocarla y " +
                    "emitir otra."
            });
        })
        .AddEndpointFilter(new ExigirPermiso(Permiso.ClavesGestionar))
        .WithSummary("Emite una clave de acceso")
        .WithDescription(
            "Devuelve el secreto en claro UNA sola vez. Después ya no se puede " +
            "recuperar, igual que con una contraseña.");

        grupo.MapDelete("/claves/{claveId:guid}", async (
            Guid claveId, RepositorioAdmin admin, CancellationToken ct) =>
        {
            var revocada = await admin.RevocarClaveAsync(claveId, ct);

            return revocada
                ? Results.Ok(new { mensaje = "Clave revocada." })
                : Results.NotFound(new RespuestaError(
                    "No se encontró la clave, o ya estaba revocada."));
        })
        .AddEndpointFilter(new ExigirPermiso(Permiso.ClavesGestionar))
        .WithSummary("Revoca una clave")
        .WithDescription(
            "La clave se desactiva, no se borra. Borrarla dejaría sin rastro " +
            "quién tuvo acceso y hasta cuándo, que es justo lo que hay que " +
            "poder responder después de un incidente.");
    }

    private static RespuestaError IdentificadorEnUso(string? identificador) =>
        new("Ese identificador ya lo usa otra empresa.",
            $"«{identificador}» está tomado. Prueba con el nombre comercial y la " +
            "ciudad, por ejemplo ferreteria-lopez-arequipa.");
}

public record ActualizacionTenant(bool? Activo, short? MaxConcurrencia);

public record CambioMarca(string? Identificador, string? ColorMarca, string? CorreoRespuesta);

public record NuevaSerie(
    string TipoComprobante,
    string Serie,
    int CorrelativoInicial = 0);

public record NuevaClave(string Nombre, bool Produccion = false);

public record CambioEstadoSerie(bool Activo);

public record CredencialesSol(string Usuario, string Clave);

public record CambioAmbiente(string Ambiente);

public record CredencialesGre(string ClientId, string ClientSecret);

public record CambioGreHabilitado(bool Habilitado);
'@

# --- Facturacion.Api\PdfDeComprobante.cs
Planear 'Facturacion.Api\PdfDeComprobante.cs' 'C7781661C3C14880FAF66C1DD3A2E1ACD5CEBCCAA1596EAD8B2E30C789201256' @'
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

        return Results.File(pdf, "application/pdf", $"{datos.Numero}.pdf");
    }
}
'@

# --- Facturacion.Api\wwwroot\admin.html
Planear 'Facturacion.Api\wwwroot\admin.html' '8BE0B41C20165FADF3AFACF514A447CC4D34508F9CDB8A3EB9FB53CB7CE58590' @'
<!DOCTYPE html>
<html lang="es">
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Empresas · Facturación electrónica</title>
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
               max-width: 1180px;
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

                   button.principal:hover:not(:disabled) {
                       filter: brightness(1.08);
                   }

               button.peligro {
                   color: var(--mal);
                   border-color: var(--borde);
               }

               button.mini {
                   padding: 4px 10px;
                   font-size: 13px;
               }

           .barra {
               display: flex;
               gap: 10px;
               align-items: center;
               margin-bottom: 12px;
           }

           .buscador {
               flex: 1;
               max-width: 340px;
               position: relative;
           }

               .buscador input {
                   width: 100%;
                   padding-left: 32px;
               }

               .buscador svg {
                   position: absolute;
                   left: 10px;
                   top: 9px;
                   width: 15px;
                   height: 15px;
                   stroke: var(--apagado);
                   fill: none;
                   stroke-width: 2;
               }

           .maestro-detalle {
               display: grid;
               grid-template-columns: 266px minmax(0,1fr);
               gap: 14px;
               align-items: start;
           }

           @media (max-width:880px) {
               .maestro-detalle {
                   grid-template-columns: 1fr;
               }
           }

           .tarjeta {
               background: var(--panel);
               border: 1px solid var(--borde);
               border-radius: 12px;
           }

           .lista {
               max-height: calc(100vh - 210px);
               overflow-y: auto;
           }

           .fila-empresa {
               padding: 10px 13px;
               border-bottom: 1px solid var(--borde);
               cursor: pointer;
           }

               .fila-empresa:last-child {
                   border-bottom: none;
               }

               .fila-empresa:hover {
                   background: var(--sutil);
               }

               .fila-empresa.activa {
                   background: var(--acento-fondo);
               }

                   .fila-empresa.activa .nombre {
                       color: var(--acento);
                   }

               .fila-empresa.inactiva {
                   opacity: .55;
               }

               .fila-empresa .nombre {
                   font-size: 14px;
                   display: flex;
                   align-items: center;
                   gap: 6px;
               }

               .fila-empresa .ruc {
                   font-size: 12px;
                   color: var(--tenue);
                   font-family: ui-monospace, Consolas, monospace;
               }

           .pie-lista {
               padding: 9px 13px;
               font-size: 12px;
               color: var(--apagado);
               border-top: 1px solid var(--borde);
           }

           .detalle {
               padding: 18px 20px;
           }

           .cabecera-detalle {
               display: flex;
               align-items: flex-start;
               justify-content: space-between;
               gap: 14px;
               margin-bottom: 16px;
           }

               .cabecera-detalle h2 {
                   font-size: 17px;
                   margin: 0;
                   font-weight: 500;
               }

               .cabecera-detalle .sub {
                   font-size: 13px;
                   color: var(--tenue);
                   font-family: ui-monospace, Consolas, monospace;
                   margin-top: 2px;
               }

           .insignia {
               font-size: 12px;
               padding: 3px 10px;
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

           .metricas {
               display: grid;
               grid-template-columns: repeat(auto-fit,minmax(130px,1fr));
               gap: 10px;
               margin-bottom: 18px;
           }

           .metrica {
               background: var(--sutil);
               border-radius: var(--radio);
               padding: 11px 13px;
           }

               .metrica .et {
                   font-size: 12px;
                   color: var(--tenue);
               }

               .metrica .va {
                   font-size: 15px;
                   margin-top: 2px;
               }

           .pestanas {
               display: flex;
               gap: 16px;
               border-bottom: 1px solid var(--borde);
               margin-bottom: 14px;
           }

           .pestana {
               font-size: 13px;
               color: var(--tenue);
               cursor: pointer;
               padding: 0 2px 8px;
               border-bottom: 2px solid transparent;
               margin-bottom: -1px;
               background: none;
               border-top: none;
               border-left: none;
               border-right: none;
           }

               .pestana:hover {
                   color: var(--texto);
               }

               .pestana.activa {
                   color: var(--texto);
                   border-bottom-color: var(--acento);
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
               padding: 6px 8px;
               border-bottom: 1px solid var(--borde);
               font-size: 12.5px;
           }

           td {
               padding: 9px 8px;
               border-bottom: 1px solid var(--borde);
           }

           tr:last-child td {
               border-bottom: none;
           }

           .mono {
               font-family: ui-monospace, Consolas, monospace;
               font-size: 13px;
           }

           .recorte {
               overflow: hidden;
               text-overflow: ellipsis;
               white-space: nowrap;
           }

           td.mal, .mal {
               color: var(--mal);
           }

           /* La fila recién creada. El resaltado se va solo a los pocos segundos:
        sirve para encontrarla, no para quedarse ahí. */
           tr.fila-inactiva td:not(:last-child) {
               opacity: .55;
           }

           tr.recien {
               background: var(--ok-fondo);
           }

               tr.recien td:first-child {
                   box-shadow: inset 3px 0 0 var(--ok);
               }

           .filtro-tabla {
               display: flex;
               align-items: center;
               justify-content: space-between;
               gap: 12px;
               margin-bottom: 8px;
           }

               .filtro-tabla .buscador {
                   max-width: 260px;
                   flex: 1;
               }

                   .filtro-tabla .buscador input {
                       padding: 6px 11px 6px 30px;
                       font-size: 13.5px;
                   }

                   .filtro-tabla .buscador svg {
                       top: 8px;
                       width: 14px;
                       height: 14px;
                   }

               .filtro-tabla .conteo {
                   font-size: 12.5px;
                   color: var(--tenue);
               }

           .tenue {
               color: var(--tenue);
           }

           .vacio {
               color: var(--tenue);
               font-size: 14px;
               padding: 14px 0;
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

           .rejilla {
               display: grid;
               grid-template-columns: repeat(auto-fit,minmax(170px,1fr));
               gap: 11px;
               margin: 14px 0;
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

           .err {
               color: var(--mal);
               font-size: 12px;
               margin-top: 3px;
               min-height: 14px;
           }

           label.invalido input {
               border-color: var(--mal);
           }

           /* El input de archivo nativo no se puede estilizar: se oculta y se usa
        una etiqueta como botón. El input sigue ahí, así que el teclado y los
        lectores de pantalla lo siguen alcanzando. */
           .archivo {
               position: relative;
           }

               .archivo input[type=file] {
                   position: absolute;
                   inset: 0;
                   opacity: 0;
                   width: 100%;
                   height: 100%;
                   cursor: pointer;
               }

               .archivo .caja {
                   display: flex;
                   align-items: center;
                   gap: 9px;
                   border: 1px dashed var(--borde-fuerte);
                   border-radius: var(--radio);
                   padding: 8px 11px;
                   background: var(--panel);
                   font-size: 13.5px;
                   color: var(--tenue);
               }

               .archivo:hover .caja {
                   border-color: var(--acento);
                   color: var(--texto);
               }

               .archivo.con-archivo .caja {
                   border-style: solid;
                   border-color: var(--ok);
                   color: var(--texto);
               }

               .archivo .caja svg {
                   width: 16px;
                   height: 16px;
                   stroke: currentColor;
                   fill: none;
                   stroke-width: 2;
                   flex: none;
               }

               .archivo .nombre-archivo {
                   overflow: hidden;
                   text-overflow: ellipsis;
                   white-space: nowrap;
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
               animation: entrar .16s ease-out;
           }

               .flotante.ok {
                   border-left-color: var(--ok);
               }

               .flotante.mal {
                   border-left-color: var(--mal);
               }

               .flotante .t {
                   font-weight: 500;
               }

               .flotante .d {
                   color: var(--tenue);
                   font-size: 13px;
                   margin-top: 2px;
               }

           @keyframes entrar {
               from {
                   opacity: 0;
                   transform: translateX(14px);
               }
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
               max-width: 560px;
               max-height: 88vh;
               overflow-y: auto;
           }

               .modal h3 {
                   margin: 0 0 4px;
                   font-size: 17px;
                   font-weight: 500;
               }

               .modal .ayuda {
                   margin: 0 0 4px;
                   color: var(--tenue);
                   font-size: 13.5px;
               }

               .modal .botones {
                   display: flex;
                   gap: 8px;
                   justify-content: flex-end;
                   margin-top: 18px;
               }

           /* El logo se enseña sobre blanco en los dos temas: así va a salir
        en el PDF y en el correo, que son blancos. */
           .logo-caja {
               width: 200px;
               height: 76px;
               border: 1px dashed var(--borde-fuerte);
               border-radius: var(--radio);
               background: #fff;
               display: flex;
               align-items: center;
               justify-content: center;
               padding: 8px;
               flex: none;
           }

               .logo-caja img {
                   max-width: 100%;
                   max-height: 100%;
               }

               .logo-caja .tenue {
                   font-size: 13px;
                   color: #8a929c;
               }

           .direccion-portal {
               background: var(--sutil);
               border-radius: var(--radio);
               padding: 11px 13px;
               margin-bottom: 8px;
               font-size: 14px;
           }

           .muestra-color {
               display: flex;
               gap: 8px;
               align-items: center;
           }

               .muestra-color input[type=color] {
                   width: 46px;
                   height: 36px;
                   padding: 2px;
                   flex: none;
                   cursor: pointer;
               }

           .secreto {
               background: var(--ok-fondo);
               border: 1px solid var(--ok);
               border-radius: var(--radio);
               padding: 13px 15px;
               margin-top: 12px;
           }

               .secreto code {
                   display: block;
                   font-family: ui-monospace,Consolas,monospace;
                   font-size: 14px;
                   word-break: break-all;
                   margin: 9px 0;
                   color: var(--ok);
               }
    </style>
</head>
<body>

    <div id="avisos"></div>

    <div class="velo" id="velo-confirmar">
        <div class="modal" style="max-width:430px">
            <h3 id="cf-titulo"></h3>
            <p class="ayuda" id="cf-texto"></p>
            <div class="botones">
                <button id="cf-cancelar">Cancelar</button>
                <button id="cf-aceptar" class="principal">Confirmar</button>
            </div>
        </div>
    </div>

    <div class="velo" id="velo-nueva">
        <div class="modal">
            <h3>Nueva empresa</h3>
            <p class="ayuda">
                Después habrá que cargarle un certificado, dar de alta al
                menos una serie y emitirle una clave de acceso.
            </p>

            <div class="rejilla">
                <label>
                    RUC<input id="n-ruc" maxlength="11" placeholder="20601234567">
                    <div class="err" id="e-ruc"></div>
                </label>
                <label>
                    Razón social<input id="n-razon" placeholder="Comercial Andina EIRL">
                    <div class="err" id="e-razon"></div>
                </label>
                <label>Nombre comercial<input id="n-comercial" placeholder="opcional"></label>
                <label>
                    Identificador del portal<input id="n-identificador" maxlength="40" placeholder="opcional · ferreteria-lopez">
                    <div class="err" id="e-identificador"></div>
                </label>
                <label>Dirección<input id="n-direccion"></label>
                <label>Distrito<input id="n-distrito" value="LIMA"></label>
                <label>Provincia<input id="n-provincia" value="LIMA"></label>
                <label>Departamento<input id="n-departamento" value="LIMA"></label>
                <label>Ubigeo<input id="n-ubigeo" value="150101"></label>
                <label>
                    Ambiente
                    <select id="n-ambiente">
                        <option value="beta">beta (pruebas)</option>
                        <option value="produccion">producción</option>
                    </select>
                </label>
                <label>Usuario SOL<input id="n-sol" value="MODDATOS"></label>
            </div>

            <div class="botones">
                <button id="nv-cancelar">Cancelar</button>
                <button id="nv-crear" class="principal">Crear empresa</button>
            </div>
        </div>
    </div>

    <div class="contenedor">
        <header>
            <h1>Facturación electrónica</h1>
            <div id="usuario-actual" class="usuario"></div>
        </header>

        <nav>
            <a href="/diagnostico.html">Estado del servicio</a>
            <a href="/admin.html" class="activo">Empresas</a>
            <a href="/comprobantes.html">Comprobantes</a>
            <a href="/cuenta.html">Mi cuenta</a>
        </nav>

        <div id="raiz">
            <div class="tarjeta" style="padding:18px 20px">
                <span class="vacio">Cargando…</span>
            </div>
        </div>
    </div>

    <script src="/fechas.js"></script>
    <script>
        // NO SE USA "$" COMO NOMBRE DE FUNCIÓN. Browser Link, la herramienta de
        // Visual Studio que recarga la página al guardar, inyecta jQuery y espera
        // encontrarlo ahí. Definir otra cosa rompe su script con un error que parece
        // del panel y no lo es.
        const elem = id => document.getElementById(id);
        const esc = t => String(t ?? "").replace(/[&<>"']/g,
            c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));

        const estado = {
            empresas: [],
            seleccionada: null,

            // Buscador de la lista de empresas. Tiene nombre propio a propósito:
            // "filtro" a secas se confundía con los filtros de las pestañas, que son
            // otra cosa, y esa colisión rompía la página al arrancar.
            filtroEmpresas: "",

            pestana: "series",
            series: [],
            claves: [],
            certificados: [],
            webhooks: [],
            entregas: [],
            revision: null,

            // Identificador de lo recién creado en cada pestaña, para resaltarlo.
            recien: { series: null, claves: null, certificado: null, webhooks: null },

            // Filtro de texto de cada pestaña. Son independientes: buscar en claves
            // no debe alterar lo que ves al volver a series.
            filtro: { series: "", claves: "", certificado: "", webhooks: "" }
        };


        // ---------------------------------------------------------------- sesión
        //
        // La autenticación va por cookie, no por una clave escrita en la página.
        //
        // La cookie es HttpOnly, así que este JavaScript NO puede leerla: el
        // navegador la envía sola en cada petición. Si algún día se cuela un script
        // malicioso, no podrá robar la sesión.

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

        const esAdministrador = () => usuarioActual?.esAdministrador === true;


        // ------------------------------------------------------------------ avisos

        function avisar(titulo, detalle = "", tipo = "") {
            const caja = document.createElement("div");
            caja.className = "flotante " + tipo;

            caja.innerHTML = `<div class="t">${esc(titulo)}</div>` +
                (detalle ? `<div class="d">${esc(detalle)}</div>` : "");

            elem("avisos").appendChild(caja);

            // Los errores duran más: hay que poder leerlos con calma.
            setTimeout(() => caja.remove(), tipo === "mal" ? 8000 : 4000);
        }

        function confirmar(titulo, texto, textoBoton = "Confirmar") {
            return new Promise(resolver => {
                elem("cf-titulo").textContent = titulo;
                elem("cf-texto").textContent = texto;
                elem("cf-aceptar").textContent = textoBoton;
                elem("velo-confirmar").classList.add("visible");

                const cerrar = r => {
                    elem("velo-confirmar").classList.remove("visible");
                    resolver(r);
                };

                elem("cf-aceptar").onclick = () => cerrar(true);
                elem("cf-cancelar").onclick = () => cerrar(false);
            });
        }

        // --------------------------------------------------------------------- api

        async function api(ruta, opciones = {}) {
            const r = await fetch(ruta, opciones);

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

        async function iniciar() {
            try {
                estado.empresas = await api("/admin/tenants");
                pintar();
            } catch (e) {
                elem("raiz").innerHTML =
                    `<div class="tarjeta" style="padding:18px 20px;color:var(--mal)">
             ${esc(e.message)}</div>`;
            }
        }

        // ----------------------------------------------------------------- pintado

        function empresasVisibles() {
            const f = estado.filtroEmpresas.trim().toLowerCase();

            if (!f) return estado.empresas;

            return estado.empresas.filter(e =>
                e.razonSocial.toLowerCase().includes(f) || e.ruc.includes(f));
        }

        function pintar() {
            const visibles = empresasVisibles();

            elem("raiz").innerHTML = `
        <div class="barra">
          <div class="buscador">
            <svg viewBox="0 0 24 24"><circle cx="11" cy="11" r="7"/><path d="M20 20l-3.5-3.5"/></svg>
            <input id="buscar" placeholder="Buscar por RUC o nombre" value="${esc(estado.filtroEmpresas)}">
          </div>
          ${puede("empresas.editar")
                    ? `<button class="principal" id="btn-nueva">Nueva empresa</button>` : ""}
        </div>

        <div class="maestro-detalle">
          <div class="tarjeta">
            <div class="lista" id="lista">
              ${visibles.length === 0
                    ? `<div class="vacio" style="padding:16px 13px">
                     ${estado.empresas.length === 0
                        ? "Todavía no hay empresas."
                        : "Ninguna empresa coincide con la búsqueda."}</div>`
                    : visibles.map(filaEmpresa).join("")}
            </div>
            <div class="pie-lista">
              ${visibles.length === estado.empresas.length
                    ? `${estado.empresas.length} ${estado.empresas.length === 1 ? "empresa" : "empresas"}`
                    : `${visibles.length} de ${estado.empresas.length}`}
            </div>
          </div>

          <div class="tarjeta detalle" id="detalle">
            ${estado.seleccionada ? "" : `<div class="vacio">Elige una empresa de la lista.</div>`}
          </div>
        </div>`;

            const buscar = elem("buscar");

            buscar.oninput = () => {
                estado.filtroEmpresas = buscar.value;

                // Se repinta solo la lista para no perder el foco del buscador.
                const posicion = buscar.selectionStart;
                pintar();
                const nuevo = elem("buscar");
                nuevo.focus();
                nuevo.setSelectionRange(posicion, posicion);
            };

            if (elem("btn-nueva")) elem("btn-nueva").onclick = abrirNueva;

            document.querySelectorAll("[data-empresa]").forEach(fila =>
                fila.onclick = () => seleccionar(fila.dataset.empresa));

            if (estado.seleccionada) pintarDetalle();
        }

        function filaEmpresa(e) {
            const activa = estado.seleccionada?.id === e.id;
            const alerta = problemaDe(e);

            return `
        <div class="fila-empresa ${activa ? "activa" : ""} ${e.activo ? "" : "inactiva"}"
             data-empresa="${e.id}" title="${alerta ? esc(alerta) : ""}">
          <div class="nombre">
            ${esc(e.razonSocial)}
            ${alerta ? `<span style="color:var(--aviso);font-size:13px">&#9679;</span>` : ""}
          </div>
          <div class="ruc">${esc(e.ruc)}${e.ambiente === "produccion" ? " · producción" : ""}</div>
        </div>`;
        }

        /// Lo que hace falta mirar en esta empresa. Aparece como punto en la lista
        /// para que los problemas se vean sin abrir una por una.
        function problemaDe(e) {
            if (!e.activo) return null;
            if (!e.tieneCertificado) return "Sin certificado: no puede emitir.";

            const dias = Math.ceil((new Date(e.certificadoVence) - new Date()) / 86400000);

            if (dias < 0) return "Certificado vencido: no puede emitir.";
            if (dias <= 30) return `El certificado vence en ${dias} días.`;
            if (e.series === 0) return "Sin series: no puede emitir.";
            if (e.claves === 0) return "Sin claves: el cliente no puede conectarse.";

            return null;
        }

        function pintarDetalle() {
            const t = estado.seleccionada;

            elem("detalle").innerHTML = `
        <div class="cabecera-detalle">
          <div>
            <h2>${esc(t.razonSocial)}</h2>
            <div class="sub">${esc(t.ruc)} · ${t.ambiente}</div>
          </div>
          <div style="display:flex;gap:8px;align-items:center">
            <span class="insignia ${t.activo ? "i-ok" : "i-tenue"}">
              ${t.activo ? "Activa" : "Inactiva"}</span>
            ${puede("empresas.editar")
                    ? `<button class="mini" id="btn-alternar">
                   ${t.activo ? "Desactivar" : "Activar"}</button>` : ""}
          </div>
        </div>

        <div class="metricas">
          <div class="metrica">
            <div class="et">Certificado</div>
            <div class="va">${estadoCertificado(t)}</div>
          </div>
          <div class="metrica">
            <div class="et">Comprobantes</div>
            <div class="va">${t.comprobantes.toLocaleString("es-PE")}</div>
          </div>
          <div class="metrica">
            <div class="et">Series activas</div>
            <div class="va">${t.series}</div>
          </div>
          <div class="metrica">
            <div class="et">Claves activas</div>
            <div class="va">${t.claves}</div>
          </div>
        </div>

        <div class="pestanas">
          ${pestanasVisibles().map(p => `
            <button class="pestana ${estado.pestana === p ? "activa" : ""}"
                    data-pestana="${p}">${nombrePestana(p)}</button>`).join("")}
        </div>

        <div id="cuerpo-pestana"><div class="vacio">Cargando…</div></div>`;

            if (elem("btn-alternar")) elem("btn-alternar").onclick = alternarActiva;

            document.querySelectorAll("[data-pestana]").forEach(boton =>
                boton.onclick = () => {
                    estado.pestana = boton.dataset.pestana;
                    pintarDetalle();
                });

            cargarPestana();
        }

        /// Las pestañas del detalle también dependen de los permisos.
        ///
        /// Sin esto, alguien de soporte vería la pestaña de certificados y al pulsar
        /// recibiría un 403. Es mejor no mostrar lo que no se puede usar.
        function pestanasVisibles() {
            const todas = [
                { clave: "series", permiso: "empresas.ver" },
                { clave: "marca", permiso: "empresas.ver" },
                { clave: "claves", permiso: "claves.gestionar" },
                { clave: "certificado", permiso: "certificados.gestionar" },
                { clave: "webhooks", permiso: "webhooks.gestionar" },
                { clave: "produccion", permiso: "produccion.cambiar" }
            ];

            return todas.filter(p => puede(p.permiso)).map(p => p.clave);
        }

        const nombrePestana = p => ({
            series: "Series",
            marca: "Marca",
            claves: "Claves de acceso",
            certificado: "Certificado",
            webhooks: "Webhooks",
            produccion: "Producción"
        }[p]);

        function estadoCertificado(t) {
            if (!t.tieneCertificado)
                return `<span style="color:var(--mal)">Falta</span>`;

            const dias = Math.ceil((new Date(t.certificadoVence) - new Date()) / 86400000);

            if (dias < 0) return `<span style="color:var(--mal)">Vencido</span>`;
            if (dias <= 30) return `<span style="color:var(--aviso)">Vence en ${dias} d</span>`;

            return `<span style="color:var(--ok)">Vence en ${dias} d</span>`;
        }

        // -------------------------------------------------------------- pestañas

        async function cargarPestana() {
            const id = estado.seleccionada.id;
            const cuerpo = elem("cuerpo-pestana");

            try {
                if (estado.pestana === "series") {
                    estado.series = await api(`/admin/tenants/${id}/series`);
                    cuerpo.innerHTML = vistaSeries();
                    elem("btn-serie").onclick = crearSerie;

                    // El ejemplo del recuadro sigue al tipo elegido: así se ve la inicial
                    // que toca antes de escribir, no después del rechazo.
                    const tipo = elem("s-tipo");

                    if (tipo) tipo.onchange = () => {
                        const campo = elem("s-serie");
                        if (campo) campo.placeholder = serieSugerida(tipo.value);
                    };

                    enlazarAccionesSerie();

                    enlazarFiltro("series", () => {
                        elem("tabla-series").innerHTML = tablaSeries();
                        enlazarAccionesSerie();
                    });

                } else if (estado.pestana === "claves") {
                    estado.claves = await api(`/admin/tenants/${id}/claves`);
                    cuerpo.innerHTML = vistaClaves();
                    elem("btn-clave").onclick = crearClave;

                    enlazarRevocar();

                    enlazarFiltro("claves", () => {
                        elem("tabla-claves").innerHTML = tablaClaves();
                        enlazarRevocar();
                    });

                } else if (estado.pestana === "marca") {
                    // No hace falta pedir nada: la marca viene con la lista de
                    // empresas, que ya está cargada.
                    cuerpo.innerHTML = vistaMarca();
                    enlazarMarca();

                } else if (estado.pestana === "produccion") {
                    estado.revision = await api(`/admin/tenants/${id}/revision-produccion`);

                    cuerpo.innerHTML = vistaProduccion();

                    elem("btn-sol").onclick = guardarCredenciales;
                    elem("btn-ambiente").onclick = cambiarAmbiente;
                    elem("btn-gre").onclick = guardarCredencialesGre;

                } else if (estado.pestana === "webhooks") {
                    estado.webhooks = await api(`/admin/tenants/${id}/webhooks`);
                    estado.entregas = await api(`/admin/tenants/${id}/webhook-entregas?limite=20`);

                    cuerpo.innerHTML = vistaWebhooks();
                    elem("btn-webhook").onclick = crearWebhook;

                    enlazarAccionesWebhook();

                    enlazarFiltro("webhooks", () => {
                        elem("tabla-webhooks").innerHTML = tablaWebhooks();
                        enlazarAccionesWebhook();
                    });

                } else {
                    estado.certificados = await api(`/admin/tenants/${id}/certificados`);
                    cuerpo.innerHTML = vistaCertificado();
                    elem("btn-certificado").onclick = subirCertificado;

                    enlazarAccionesCertificado();

                    enlazarFiltro("certificado", () => {
                        elem("tabla-certificado").innerHTML = tablaCertificados();
                        enlazarAccionesCertificado();
                    });

                    // El input de archivo está oculto: hay que reflejar el nombre elegido
                    // en la caja visible, o el usuario no sabe si seleccionó algo.
                    elem("c-archivo").onchange = e => {
                        const archivo = e.target.files[0];

                        elem("nombre-archivo").textContent =
                            archivo ? archivo.name : "Elegir archivo .pfx o .p12";

                        elem("envoltura-archivo").classList.toggle("con-archivo", !!archivo);
                    };
                }
            } catch (e) {
                cuerpo.innerHTML = `<div class="vacio" style="color:var(--mal)">${esc(e.message)}</div>`;
            }
        }

        function vistaSeries() {
            return `
        <div class="rejilla" style="margin-top:0">
          <label>Tipo
            <select id="s-tipo">
              <option value="01">Factura</option>
              <option value="03">Boleta</option>
              <option value="04">Liquidación de compra</option>
              <option value="07">Nota de crédito</option>
              <option value="08">Nota de débito</option>
              <option value="09">Guía de remisión remitente</option>
              <option value="20">Comprobante de retención</option>
              <option value="31">Guía de remisión transportista</option>
              <option value="40">Comprobante de percepción</option>
            </select></label>
          <label>Serie<input id="s-serie" maxlength="4" placeholder="F001">
            <div class="err" id="e-serie"></div></label>
          <label>Último correlativo ya emitido<input id="s-corr" type="number" value="0"></label>
        </div>

        <div style="display:flex;align-items:center;gap:12px;margin-bottom:16px">
          <button id="btn-serie">Agregar serie</button>
          <span class="tenue" style="font-size:12.5px">
            Si la empresa viene de otro sistema, pon el último número que ya emitió.
          </span>
        </div>

        ${estado.series.length === 0
                    ? `<div class="vacio" style="border-top:1px solid var(--borde)">
               Sin series. Hace falta al menos una para poder emitir.</div>`
                    : barraFiltro("series", estado.series.length, filtrar("series").length) +
                    `<div id="tabla-series">${tablaSeries()}</div>`}`;
        }

        function tablaSeries() {
            const filas = filtrar("series");

            if (filas.length === 0)
                return `<div class="vacio">Ninguna serie coincide con la búsqueda.</div>`;

            return `<table>
          <tr><th>Tipo</th><th>Serie</th><th>Emitidos</th><th>Siguiente</th>
              <th>Estado</th><th style="text-align:right">Acciones</th></tr>
          ${filas.map(s => `<tr class="${s.id === estado.recien.series ? "recien" : ""}
                                        ${s.activo ? "" : "fila-inactiva"}">
            <td>${nombreTipo(s.tipoComprobante)}</td>
            <td class="mono">${esc(s.serie)}</td>
            <td>${s.comprobantes}</td>
            <td class="tenue">${s.ultimoCorrelativo + 1}</td>
            <td>${s.activo
                    ? `<span class="insignia i-ok">activa</span>`
                    : `<span class="insignia i-tenue">cerrada</span>`}</td>
            <td style="text-align:right;white-space:nowrap">
              ${accionesSerie(s)}
            </td>
          </tr>`).join("")}
        </table>`;
        }

        /// Qué se puede hacer con una serie depende de si ya se usó.
        ///
        /// Sin comprobantes se puede borrar sin consecuencias. Con comprobantes
        /// solo se puede cerrar: borrarla dejaría huérfano el rastro de esa
        /// numeración, y eso es un problema tributario, no de datos.
        function accionesSerie(s) {
            if (s.sePuedeEliminar)
                return `<button class="mini peligro" data-borrar-serie="${s.id}"
                  data-serie-nombre="${esc(s.serie)}">Eliminar</button>`;

            return s.activo
                ? `<button class="mini" data-cerrar-serie="${s.id}"
             data-serie-nombre="${esc(s.serie)}"
             title="Deja de poder emitir. El histórico no se toca.">Cerrar</button>`
                : `<button class="mini" data-abrir-serie="${s.id}"
             data-serie-nombre="${esc(s.serie)}">Reactivar</button>`;
        }

        function vistaClaves() {
            return `
        <div class="rejilla" style="margin-top:0">
          <label>Nombre de la clave<input id="k-nombre" placeholder="ERP producción"></label>
        </div>

        <div style="display:flex;align-items:center;gap:12px;margin-bottom:16px">
          <button id="btn-clave">Emitir clave</button>
          <span class="tenue" style="font-size:12.5px">
            El secreto se muestra una sola vez.
          </span>
        </div>

        <div id="k-resultado"></div>

        ${estado.claves.length === 0
                    ? `<div class="vacio" style="border-top:1px solid var(--borde)">
               Sin claves. El cliente todavía no puede conectarse.</div>`
                    : barraFiltro("claves", estado.claves.length, filtrar("claves").length) +
                    `<div id="tabla-claves">${tablaClaves()}</div>`}`;
        }

        function tablaClaves() {
            const filas = filtrar("claves");

            if (filas.length === 0)
                return `<div class="vacio">Ninguna clave coincide con la búsqueda.</div>`;

            return `<table>
          <tr><th>Nombre</th><th>Prefijo</th><th>Creada</th><th>Último uso</th>
              <th>Estado</th><th></th></tr>
          ${filas.map(k => `<tr class="${k.id === estado.recien.claves ? "recien" : ""}">
            <td>${esc(k.nombre)}</td>
            <td class="mono">${esc(k.prefijo)}…</td>
            <td class="tenue">${diaDe(k.creadoEn)}</td>
            <td class="tenue">${k.ultimoUso ? diaDe(k.ultimoUso) : "nunca"}</td>
            <td>${k.activo
                    ? `<span class="insignia i-ok">activa</span>`
                    : `<span class="insignia i-tenue">revocada</span>`}</td>
            <td>${k.activo
                    ? `<button class="mini peligro" data-revocar="${k.id}">Revocar</button>`
                    : ""}</td>
          </tr>`).join("")}
        </table>`;
        }

        function vistaCertificado() {
            return `
        <div class="rejilla" style="margin-top:0">
          <label>Archivo del certificado
            <span class="archivo" id="envoltura-archivo">
              <input id="c-archivo" type="file" accept=".pfx,.p12">
              <span class="caja">
                <svg viewBox="0 0 24 24"><path d="M12 16V4m0 0L8 8m4-4l4 4"/><path d="M4 16v3a1 1 0 001 1h14a1 1 0 001-1v-3"/></svg>
                <span class="nombre-archivo" id="nombre-archivo">Elegir archivo .pfx o .p12</span>
              </span>
            </span>
          </label>
          <label>Contraseña del certificado
            <input id="c-clave" type="password" placeholder="la que entregó el cliente"></label>
        </div>

        <div style="display:flex;align-items:center;gap:12px;margin-bottom:16px">
          <button id="btn-certificado">Cargar certificado</button>
          <span class="tenue" style="font-size:12.5px">
            Se cifra antes de guardarse y reemplaza al activo anterior.
          </span>
        </div>

        <div id="c-resultado"></div>

        ${estado.certificados.length === 0
                    ? `<div class="vacio" style="border-top:1px solid var(--borde)">
               Sin certificado. Esta empresa no puede firmar ni emitir.</div>`
                    : barraFiltro("certificado", estado.certificados.length,
                        filtrar("certificado").length) +
                    `<div id="tabla-certificado">${tablaCertificados()}</div>`}`;
        }

        function tablaCertificados() {
            const filas = filtrar("certificado");

            if (filas.length === 0)
                return `<div class="vacio">Ningún certificado coincide con la búsqueda.</div>`;

            return `<table>
          <tr><th>Titular</th><th>Vence</th><th>Firmó</th><th>Estado</th>
              <th style="text-align:right">Acciones</th></tr>
          ${filas.map(c => `<tr class="${c.id === estado.recien.certificado ? "recien" : ""}
                                        ${c.activo ? "" : "fila-inactiva"}">
            <td style="font-size:13px">${esc(c.subject)}</td>
            <td class="mono">${dia(c.validoHasta)}</td>
            <td>${c.comprobantesFirmados}</td>
            <td>${c.activo
                    ? `<span class="insignia ${c.diasParaVencer <= 30 ? "i-aviso" : "i-ok"}">
                     activo · ${c.diasParaVencer} d</span>`
                    : `<span class="insignia i-tenue">reemplazado</span>`}</td>
            <td style="text-align:right;white-space:nowrap">
              ${c.sePuedeEliminar
                    ? `<button class="mini peligro" data-borrar-cert="${c.id}">Eliminar</button>`
                    : `<span class="tenue" style="font-size:12px"
                     title="${c.activo
                        ? "Es el certificado en uso."
                        : "Firmó comprobantes: hay que conservarlo para poder verificar esas firmas."}">
                     ${c.activo ? "en uso" : "se conserva"}</span>`}
            </td>
          </tr>`).join("")}
        </table>`;
        }

        /// Busca el texto en cualquier campo de la fila.
        ///
        /// Se concatenan todos los valores en vez de comparar campo por campo:
        /// así el buscador sirve para lo que el usuario tenga en la cabeza, sea el
        /// número de serie, el tipo, una fecha o el nombre de una clave, sin que
        /// haya que anticipar por cuál va a buscar.
        function coincide(fila, filtro, extras = []) {
            const f = filtro.trim().toLowerCase();
            if (!f) return true;

            const texto = [...Object.values(fila), ...extras]
                .filter(v => v !== null && v !== undefined && typeof v !== "object")
                .join(" ")
                .toLowerCase();

            return texto.includes(f);
        }

        /// Cabecera con buscador y conteo, común a las tres pestañas.
        function barraFiltro(clave, total, visibles) {
            return `
        <div class="filtro-tabla">
          <div class="buscador">
            <svg viewBox="0 0 24 24"><circle cx="11" cy="11" r="7"/><path d="M20 20l-3.5-3.5"/></svg>
            <input id="f-${clave}" placeholder="Buscar" value="${esc(estado.filtro[clave])}">
          </div>
          <span class="conteo">${visibles === total
                    ? `${total} ${total === 1 ? "registro" : "registros"}`
                    : `${visibles} de ${total}`}</span>
        </div>`;
        }

        /// Reengancha el buscador sin repintar la pestaña entera, para no perder
        /// el foco ni el cursor mientras se escribe.
        function enlazarFiltro(clave, repintarTabla) {
            const campo = elem("f-" + clave);
            if (!campo) return;

            campo.oninput = () => {
                estado.filtro[clave] = campo.value;
                repintarTabla();

                const conteo = document.querySelector(".filtro-tabla .conteo");
                if (conteo) conteo.textContent = textoConteo(clave);
            };
        }

        function enlazarRevocar() {
            document.querySelectorAll("[data-revocar]").forEach(b =>
                b.onclick = () => revocar(b.dataset.revocar));
        }

        function enlazarAccionesSerie() {
            document.querySelectorAll("[data-borrar-serie]").forEach(b =>
                b.onclick = () => eliminarSerie(b.dataset.borrarSerie, b.dataset.serieNombre));

            document.querySelectorAll("[data-cerrar-serie]").forEach(b =>
                b.onclick = () => cambiarSerie(b.dataset.cerrarSerie, false, b.dataset.serieNombre));

            document.querySelectorAll("[data-abrir-serie]").forEach(b =>
                b.onclick = () => cambiarSerie(b.dataset.abrirSerie, true, b.dataset.serieNombre));
        }

        function enlazarAccionesCertificado() {
            document.querySelectorAll("[data-borrar-cert]").forEach(b =>
                b.onclick = () => eliminarCertificado(b.dataset.borrarCert));
        }

        function textoConteo(clave) {
            const total = estado[clave === "certificado" ? "certificados" : clave].length;
            const visibles = filtrar(clave).length;

            return visibles === total
                ? `${total} ${total === 1 ? "registro" : "registros"}`
                : `${visibles} de ${total}`;
        }

        function filtrar(clave) {
            const f = estado.filtro[clave];

            if (clave === "series")
                return estado.series.filter(x =>
                    coincide(x, f, [nombreTipo(x.tipoComprobante)]));

            if (clave === "claves")
                return estado.claves.filter(x => coincide(x, f));

            if (clave === "webhooks")
                return estado.webhooks.filter(x => coincide(x, f, x.eventos ?? []));

            return estado.certificados.filter(x => coincide(x, f));
        }

        // ------------------------------------------------------------------ marca
        //
        // Cómo ve a la empresa su cliente: el portal donde descarga sus
        // comprobantes, el correo que recibe y el PDF.
        //
        // LAS MISMAS REGLAS QUE Marca.cs Y QUE LA MIGRACIÓN 020. Las de aquí
        // solo sirven para avisar mientras se escribe; las que mandan son las
        // del servidor.

        const DOMINIO_PORTAL = "comprobantes.reyban.pe";

        const RESERVADOS = ["api", "e", "portal", "admin", "www", "static",
            "assets", "health", "docs"];

        function problemaIdentificador(v) {
            if (!v) return "";
            if (v.length < 3 || v.length > 40) return "Entre 3 y 40 caracteres.";
            if (!/^[a-z0-9][a-z0-9-]{1,38}[a-z0-9]$/.test(v))
                return "Solo minúsculas sin tilde, números y guiones, sin guion al principio ni al final.";
            if (v.includes("--")) return "Sin dos guiones seguidos.";
            if (RESERVADOS.includes(v)) return `«${v}» está reservado. Elige otro.`;
            return "";
        }

        /// Una sugerencia sacada del nombre. SOLO SE SUGIERE: el
        /// identificador no se puede cambiar después, así que lo decide una
        /// persona, no el nombre comercial, que sí puede cambiar.
        function sugerirIdentificador(t) {
            const base = (t.nombreComercial || t.razonSocial || "")
                .normalize("NFD").replace(/[\u0300-\u036f]/g, "")
                .toLowerCase()
                .replace(/\b(s\.?a\.?c\.?|e\.?i\.?r\.?l\.?|s\.?r\.?l\.?|s\.?a\.?a\.?|s\.?a\.?)$/, "")
                .replace(/[^a-z0-9]+/g, "-")
                .replace(/^-+|-+$/g, "")
                .slice(0, 40)
                .replace(/-+$/g, "");

            return problemaIdentificador(base) ? "" : base;
        }

        function vistaMarca() {
            const t = estado.seleccionada;
            const editar = puede("empresas.editar");
            const dis = editar ? "" : "disabled";
            const sugerido = sugerirIdentificador(t);

            return `
        <p class="ayuda" style="margin-top:0">
          Cómo ve a esta empresa su cliente: en el portal donde descarga sus
          comprobantes, en el correo que recibe y en el PDF.
        </p>

        <h2>Dirección del portal</h2>
        ${t.identificador
                    ? `<div class="direccion-portal">
               ${DOMINIO_PORTAL}/<strong class="mono" style="font-size:14px">${esc(t.identificador)}</strong>
             </div>
             <div class="tenue" style="font-size:12.5px;margin-bottom:22px">
               Ya no se puede cambiar: es la dirección que va en los correos enviados.
             </div>`
                    : `<div class="rejilla" style="margin-top:0">
               <label>Identificador
                 <input id="m-identificador" maxlength="40" ${dis}
                        placeholder="${esc(sugerido || "ferreteria-lopez")}">
                 <div class="err" id="e-identificador"></div></label>
             </div>
             <div class="direccion-portal tenue" id="m-direccion">
               ${DOMINIO_PORTAL}/<span class="mono">…</span>
             </div>
             <div class="tenue" style="font-size:12.5px;margin-bottom:22px;
                                      border-left:2px solid var(--aviso);padding-left:11px">
               <strong>Se pone una sola vez.</strong> Va en la dirección de cada
               correo que se mande a los clientes de esta empresa, y cambiarlo
               rompería esos enlaces. Minúsculas, números y guiones.
               ${sugerido && editar
                        ? `<a href="#" id="m-sugerencia" style="color:var(--acento)">Usar «${esc(sugerido)}»</a>`
                        : ""}
             </div>`}

        <h2>Correo y color</h2>
        <div class="rejilla" style="margin-top:0">
          <label>Correo de respuesta
            <input id="m-correo" type="email" maxlength="254" ${dis}
                   value="${esc(t.correoRespuesta ?? "")}" placeholder="ventas@empresa.pe">
            <div class="err" id="e-correo"></div></label>
          <label>Color de la marca
            <span class="muestra-color">
              <input id="m-color-elegir" type="color" ${dis}
                     value="${esc(t.colorMarca ?? "#2563eb")}" title="Elegir color">
              <input id="m-color" maxlength="7" ${dis}
                     value="${esc(t.colorMarca ?? "")}" placeholder="vacío: sin color">
            </span>
            <div class="err" id="e-color"></div></label>
        </div>

        <div class="tenue" style="font-size:12.5px;margin-bottom:14px">
          Las respuestas de sus clientes al correo del comprobante llegan a ese
          correo. <strong>Sin él, no se les manda correo.</strong>
        </div>

        ${editar ? `<button class="principal" id="btn-marca">Guardar</button>` : ""}

        <h2 style="margin-top:26px">Logo</h2>
        <div style="display:flex;gap:16px;align-items:center;flex-wrap:wrap;margin-bottom:10px">
          <div class="logo-caja">
            ${t.tieneLogo
                    ? `<img src="/admin/tenants/${t.id}/logo?v=${encodeURIComponent(t.logoVersion)}"
                      alt="Logo de ${esc(t.razonSocial)}">`
                    : `<span class="tenue">Sin logo</span>`}
          </div>

          ${editar ? `
            <div style="display:flex;gap:10px;align-items:center;flex-wrap:wrap">
              <span class="archivo" id="envoltura-logo" style="min-width:220px">
                <input id="l-archivo" type="file" accept=".png,.jpg,.jpeg,image/png,image/jpeg">
                <span class="caja">
                  <svg viewBox="0 0 24 24"><path d="M12 16V4m0 0L8 8m4-4l4 4"/><path d="M4 16v3a1 1 0 001 1h14a1 1 0 001-1v-3"/></svg>
                  <span class="nombre-archivo" id="nombre-logo">Elegir PNG o JPG</span>
                </span>
              </span>
              <button id="btn-logo">${t.tieneLogo ? "Cambiar logo" : "Subir logo"}</button>
            </div>` : ""}
        </div>

        <div class="tenue" style="font-size:12.5px">
          PNG o JPG, máximo 300 KB. En el PDF sale a la izquierda del recuadro del
          RUC, a 50 puntos de alto. Mejor con fondo transparente o blanco.
        </div>
        <div id="l-resultado"></div>`;
        }

        function enlazarMarca() {
            const campo = elem("m-identificador");

            if (campo) {
                const reflejar = () => {
                    const v = campo.value.trim().toLowerCase();
                    const problema = problemaIdentificador(v);

                    elem("e-identificador").textContent = problema;
                    campo.parentElement.classList.toggle("invalido", !!problema);

                    elem("m-direccion").innerHTML =
                        `${DOMINIO_PORTAL}/<span class="mono">${esc(v || "…")}</span>`;
                };

                campo.oninput = reflejar;

                const sugerencia = elem("m-sugerencia");
                if (sugerencia) sugerencia.onclick = ev => {
                    ev.preventDefault();
                    campo.value = sugerirIdentificador(estado.seleccionada);
                    reflejar();
                    campo.focus();
                };
            }

            // El selector de color y el texto se siguen el uno al otro. El
            // texto manda: vacío significa "sin color".
            const elegir = elem("m-color-elegir");
            const texto = elem("m-color");

            if (elegir && texto) {
                elegir.oninput = () => { texto.value = elegir.value; };
                texto.oninput = () => {
                    if (/^#[0-9a-fA-F]{6}$/.test(texto.value.trim()))
                        elegir.value = texto.value.trim().toLowerCase();
                };
            }

            if (elem("btn-marca")) elem("btn-marca").onclick = guardarMarca;
            if (elem("btn-logo")) elem("btn-logo").onclick = subirLogo;

            const archivo = elem("l-archivo");
            if (archivo) archivo.onchange = ev => {
                const f = ev.target.files[0];
                elem("nombre-logo").textContent = f ? f.name : "Elegir PNG o JPG";
                elem("envoltura-logo").classList.toggle("con-archivo", !!f);
            };
        }

        async function guardarMarca() {
            const t = estado.seleccionada;
            const campo = elem("m-identificador");
            const identificador = campo ? campo.value.trim().toLowerCase() : null;
            const correo = elem("m-correo").value.trim();
            const color = elem("m-color").value.trim().toLowerCase();

            let valido = true;

            const marcar = (id, mensaje) => {
                elem("e-" + id).textContent = mensaje;
                elem("m-" + id).parentElement.classList.toggle("invalido", !!mensaje);
                if (mensaje) valido = false;
            };

            if (campo) marcar("identificador", problemaIdentificador(identificador));

            marcar("correo", !correo || /^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(correo)
                ? "" : "No tiene forma de correo.");

            elem("e-color").textContent =
                !color || /^#[0-9a-f]{6}$/.test(color) ? "" : "Tiene que ir como #rrggbb.";
            if (elem("e-color").textContent) valido = false;

            if (!valido) return;

            // FIJAR EL IDENTIFICADOR SE CONFIRMA APARTE, porque no tiene vuelta.
            if (identificador) {
                const seguro = await confirmar(
                    "Fijar la dirección del portal",
                    `La dirección de ${t.razonSocial} será ${DOMINIO_PORTAL}/${identificador}. ` +
                    "No se podrá cambiar nunca: va en cada correo que se mande a sus clientes.",
                    "Sí, fijarla");

                if (!seguro) return;
            }

            const boton = elem("btn-marca");
            boton.disabled = true;

            try {
                await api(`/admin/tenants/${t.id}/marca`, {
                    method: "PUT",
                    headers: { "Content-Type": "application/json" },
                    body: JSON.stringify({
                        identificador: identificador || null,
                        colorMarca: color || null,
                        correoRespuesta: correo || null
                    })
                });

                avisar("Marca guardada", "", "ok");
                await recargar();

            } catch (ex) {
                avisar(ex.message, ex.detalle, "mal");
                boton.disabled = false;
            }
        }

        async function subirLogo() {
            const archivo = elem("l-archivo").files[0];
            const resultado = elem("l-resultado");

            if (!archivo) {
                resultado.innerHTML =
                    `<div style="color:var(--mal);margin-top:10px">Elige el archivo del logo.</div>`;
                return;
            }

            // Se avisa antes de subir para no gastar el viaje. El servidor lo
            // vuelve a comprobar, y además mira que de verdad sea PNG o JPG.
            if (archivo.size > 300 * 1024) {
                resultado.innerHTML =
                    `<div style="color:var(--mal);margin-top:10px">Pesa
                 ${Math.ceil(archivo.size / 1024)} KB y el máximo es 300 KB.</div>`;
                return;
            }

            const datos = new FormData();
            datos.append("archivo", archivo);

            const boton = elem("btn-logo");
            boton.disabled = true;
            resultado.innerHTML = `<div class="tenue" style="margin-top:10px">Comprobando y guardando…</div>`;

            try {
                const r = await api(`/admin/tenants/${estado.seleccionada.id}/logo`,
                    { method: "POST", body: datos });

                avisar("Logo guardado", r.mensaje, "ok");
                await recargar();

            } catch (ex) {
                resultado.innerHTML =
                    `<div style="color:var(--mal);margin-top:10px">${esc(ex.message)}<br>
             <span class="tenue">${esc(ex.detalle || "")}</span></div>`;
                boton.disabled = false;
            }
        }

        function vistaProduccion() {
            const t = estado.seleccionada;
            const r = estado.revision;

            return `
        <div style="background:var(--sutil);border-radius:var(--radio);
                    padding:13px 15px;margin-bottom:18px">
          <div style="display:flex;align-items:center;justify-content:space-between;
                      gap:12px;flex-wrap:wrap">
            <div>
              <div style="font-size:14px">Ambiente actual:
                <strong>${t.ambiente === "produccion" ? "Producción" : "Beta (pruebas)"}</strong>
              </div>
              <div class="tenue" style="font-size:12.5px;margin-top:2px">
                ${t.ambiente === "produccion"
                    ? "Los comprobantes van a SUNAT de verdad y tienen valor legal."
                    : "Los comprobantes van al ambiente de pruebas y no tienen validez."}
              </div>
            </div>
            <button id="btn-ambiente" class="${t.ambiente === "produccion" ? "" : "principal"}">
              ${t.ambiente === "produccion" ? "Volver a pruebas" : "Pasar a producción"}
            </button>
          </div>
        </div>

        <h2>Credenciales SOL</h2>
        <div class="rejilla" style="margin-top:0">
          <label>Usuario SOL secundario
            <input id="s-usuario" placeholder="FACTURA01"
                   value="${esc(t.usuarioSol && t.usuarioSol !== "MODDATOS" ? t.usuarioSol : "")}">
            <div class="err" id="e-usuario"></div></label>
          <label>Clave SOL
            <input id="s-clave" type="password"
                   placeholder="${t.tieneClaveSol ? "•••••• (guardada)" : "la del usuario secundario"}">
          </label>
        </div>

        <div style="display:flex;align-items:center;gap:12px;margin-bottom:18px">
          <button id="btn-sol">Guardar credenciales</button>
          <span class="tenue" style="font-size:12.5px">
            La clave se cifra igual que el certificado.
          </span>
        </div>

        <div class="tenue" style="font-size:12.5px;margin-bottom:22px;
                                  border-left:2px solid var(--borde);padding-left:11px">
          Debe ser el usuario SOL <strong>secundario</strong> del contribuyente,
          nunca el principal. El principal puede declarar, pagar y modificar datos
          en el portal de SUNAT, y ese nivel de acceso no tiene por qué vivir aquí.
        </div>

        <h2>Guías de remisión</h2>
        <p class="ayuda" style="margin-top:0">
          Las guías usan un canal distinto al de las facturas: no es SOAP con
          clave SOL, sino una API REST con credenciales propias. El contribuyente
          las genera en su menú SOL, opción &laquo;Credenciales de API SUNAT&raquo;.
        </p>

        <div style="display:flex;align-items:center;gap:12px;margin-bottom:14px">
          ${t.greListo
                    ? `<span class="insignia i-ok">habilitadas</span>`
                    : `<span class="insignia i-tenue">sin configurar</span>`}
          ${t.greClientId
                    ? `<span class="tenue mono" style="font-size:12.5px">
                 ${esc(t.greClientId)}</span>` : ""}
        </div>

        <div class="rejilla" style="margin-top:0">
          <label>client_id
            <input id="g-client" placeholder="el que generó en su menú SOL"
                   value="${esc(t.greClientId ?? "")}"></label>
          <label>client_secret
            <input id="g-secret" type="password"
                   placeholder="${t.tieneGreSecret ? "•••••• (guardado)" : "el secreto"}">
          </label>
        </div>

        <div style="display:flex;align-items:center;gap:12px;margin-bottom:22px">
          <button id="btn-gre">Guardar credenciales de guías</button>
          <span class="tenue" style="font-size:12.5px">
            El secreto se cifra igual que el certificado.
          </span>
        </div>

        <h2>Revisión previa</h2>
        ${r.listo
                    ? `<div class="secreto">Todo listo. Esta empresa puede emitir en producción.</div>`
                    : `<div style="background:var(--mal-fondo);border:1px solid var(--mal);
                         border-radius:var(--radio);padding:13px 15px">
               <strong style="color:var(--mal)">Falta lo siguiente:</strong>
               <ul style="margin:8px 0 0;padding-left:20px;font-size:13.5px">
                 ${r.faltantes.map(f => `<li>${esc(f)}</li>`).join("")}
               </ul>
             </div>`}

        ${r.advertencias.length === 0 ? "" : `
          <div style="background:var(--aviso-fondo);border:1px solid var(--aviso);
                      border-radius:var(--radio);padding:13px 15px;margin-top:12px">
            <strong style="color:var(--aviso)">Conviene revisar:</strong>
            <ul style="margin:8px 0 0;padding-left:20px;font-size:13.5px">
              ${r.advertencias.map(a => `<li>${esc(a)}</li>`).join("")}
            </ul>
          </div>`}`;
        }

        async function guardarCredenciales() {
            const usuario = elem("s-usuario").value.trim();
            const clave = elem("s-clave").value;

            elem("e-usuario").textContent = "";

            if (!usuario) {
                elem("e-usuario").textContent = "Escribe el usuario SOL.";
                return;
            }

            if (!clave) {
                avisar("Falta la clave SOL",
                    "Escríbela aunque ya hubiera una guardada: no se puede leer.", "mal");
                return;
            }

            const boton = elem("btn-sol");
            boton.disabled = true;

            try {
                await api(`/admin/tenants/${estado.seleccionada.id}/credenciales-sol`, {
                    method: "POST",
                    headers: { "Content-Type": "application/json" },
                    body: JSON.stringify({ usuario, clave })
                });

                avisar("Credenciales guardadas y cifradas", "", "ok");

                elem("s-clave").value = "";
                await recargar();

            } catch (e) {
                avisar(e.message, e.detalle, "mal");
            } finally {
                boton.disabled = false;
            }
        }

        async function guardarCredencialesGre() {
            const clientId = elem("g-client").value.trim();
            const secret = elem("g-secret").value;

            if (!clientId) {
                avisar("Falta el client_id", "", "mal");
                return;
            }

            if (!secret) {
                avisar("Falta el client_secret",
                    "Escríbelo aunque ya hubiera uno guardado: no se puede leer.", "mal");
                return;
            }

            const boton = elem("btn-gre");
            boton.disabled = true;

            try {
                const r = await api(`/admin/tenants/${estado.seleccionada.id}/credenciales-gre`, {
                    method: "POST",
                    headers: { "Content-Type": "application/json" },
                    body: JSON.stringify({ clientId, clientSecret: secret })
                });

                avisar("Credenciales de guías guardadas", r.mensaje, "ok");

                elem("g-secret").value = "";
                await recargar();

            } catch (e) {
                avisar(e.message, e.detalle, "mal");
            } finally {
                boton.disabled = false;
            }
        }

        async function cambiarAmbiente() {
            const t = estado.seleccionada;
            const aProduccion = t.ambiente !== "produccion";

            const seguro = await confirmar(
                aProduccion ? "Pasar a producción" : "Volver al ambiente de pruebas",

                aProduccion
                    ? `${t.razonSocial} empezará a emitir comprobantes REALES ante SUNAT, ` +
                    "con valor legal. Los correlativos que consuma no se pueden recuperar."
                    : `${t.razonSocial} volverá a emitir contra el ambiente de pruebas. ` +
                    "Los comprobantes que emita dejarán de tener validez legal.",

                aProduccion ? "Pasar a producción" : "Volver a pruebas");

            if (!seguro) return;

            try {
                const r = await api(`/admin/tenants/${t.id}/ambiente`, {
                    method: "POST",
                    headers: { "Content-Type": "application/json" },
                    body: JSON.stringify({ ambiente: aProduccion ? "produccion" : "beta" })
                });

                avisar(r.mensaje,
                    r.advertencias?.length ? r.advertencias.join(" ") : "", "ok");

                await recargar();

            } catch (e) {
                avisar(e.message, e.detalle, "mal");
            }
        }

        function vistaWebhooks() {
            return `
        <div class="rejilla" style="margin-top:0">
          <label>Nombre<input id="w-nombre" placeholder="ERP del cliente"></label>
          <label>URL de destino
            <input id="w-url" placeholder="https://sistema-del-cliente.com/avisos">
            <div class="err" id="e-url"></div></label>
        </div>

        <div style="display:flex;align-items:center;gap:12px;margin-bottom:16px">
          <button id="btn-webhook">Registrar webhook</button>
          <span class="tenue" style="font-size:12.5px">
            El secreto de firma se muestra una sola vez.
          </span>
        </div>

        <div id="w-resultado"></div>

        ${estado.webhooks.length === 0
                    ? `<div class="vacio" style="border-top:1px solid var(--borde)">
               Sin webhooks. El cliente tendrá que consultar el estado por su cuenta.</div>`
                    : barraFiltro("webhooks", estado.webhooks.length,
                        filtrar("webhooks").length) +
                    `<div id="tabla-webhooks">${tablaWebhooks()}</div>`}

        ${estado.entregas.length === 0 ? "" : `
          <h2 style="margin-top:26px">Últimas entregas</h2>
          ${tablaEntregas()}`}`;
        }

        function tablaWebhooks() {
            const filas = filtrar("webhooks");

            if (filas.length === 0)
                return `<div class="vacio">Ningún webhook coincide con la búsqueda.</div>`;

            return `<table>
          <tr><th>Nombre</th><th>URL</th><th>Pendientes</th><th>Agotadas</th>
              <th>Estado</th><th style="text-align:right">Acciones</th></tr>
          ${filas.map(w => `<tr class="${w.id === estado.recien.webhooks ? "recien" : ""}
                                        ${w.activo ? "" : "fila-inactiva"}">
            <td>${esc(w.nombre)}</td>
            <td class="mono recorte" title="${esc(w.url)}"
                style="max-width:230px">${esc(w.url)}</td>
            <td>${w.pendientes}</td>
            <td class="${w.agotados > 0 ? "mal" : ""}">${w.agotados}</td>
            <td>${w.activo
                    ? `<span class="insignia i-ok">activo</span>`
                    : `<span class="insignia i-tenue">inactivo</span>`}</td>
            <td style="text-align:right;white-space:nowrap">
              <button class="mini" data-probar-wh="${w.id}">Probar</button>
              <button class="mini" data-alternar-wh="${w.id}"
                      data-activo="${w.activo}">${w.activo ? "Desactivar" : "Activar"}</button>
              <button class="mini peligro" data-borrar-wh="${w.id}"
                      data-wh-nombre="${esc(w.nombre)}">Eliminar</button>
            </td>
          </tr>`).join("")}
        </table>`;
        }

        function tablaEntregas() {
            return `<table>
          <tr><th>Evento</th><th>Estado</th><th>Intentos</th><th>Detalle</th>
              <th>Cuándo</th><th></th></tr>
          ${estado.entregas.map(e => `<tr>
            <td class="mono" style="font-size:12.5px">${esc(e.tipo)}</td>
            <td>${insigniaEntrega(e.estado)}</td>
            <td>${e.intentos}</td>
            <td class="recorte tenue" style="max-width:260px"
                title="${esc(e.ultimoError ?? "")}">
              ${e.ultimoCodigo ? `HTTP ${e.ultimoCodigo}` : ""}
              ${esc(e.ultimoError ?? "")}</td>
            <td class="tenue">${fechaHora(e.creadoEn)}</td>
            <td>${e.estado === "AGOTADO"
                    ? `<button class="mini" data-reintentar-entrega="${e.id}">Reintentar</button>`
                    : ""}</td>
          </tr>`).join("")}
        </table>`;
        }

        const insigniaEntrega = estado => ({
            ENTREGADO: `<span class="insignia i-ok">entregado</span>`,
            PENDIENTE: `<span class="insignia i-aviso">pendiente</span>`,
            AGOTADO: `<span class="insignia i-mal">agotado</span>`
        }[estado] || esc(estado));

        function enlazarAccionesWebhook() {
            document.querySelectorAll("[data-probar-wh]").forEach(b =>
                b.onclick = () => probarWebhook(b.dataset.probarWh));

            document.querySelectorAll("[data-alternar-wh]").forEach(b =>
                b.onclick = () => alternarWebhook(
                    b.dataset.alternarWh, b.dataset.activo !== "true"));

            document.querySelectorAll("[data-borrar-wh]").forEach(b =>
                b.onclick = () => eliminarWebhook(b.dataset.borrarWh, b.dataset.whNombre));

            document.querySelectorAll("[data-reintentar-entrega]").forEach(b =>
                b.onclick = () => reintentarEntrega(b.dataset.reintentarEntrega));
        }

        async function crearWebhook() {
            const url = elem("w-url").value.trim();
            const caja = elem("e-url");

            if (!/^https?:\/\/.+/i.test(url)) {
                caja.textContent = "Debe ser una dirección completa, con https:// delante.";
                elem("w-url").parentElement.classList.add("invalido");
                return;
            }

            caja.textContent = "";
            elem("w-url").parentElement.classList.remove("invalido");

            const boton = elem("btn-webhook");
            boton.disabled = true;

            try {
                const r = await api(`/admin/tenants/${estado.seleccionada.id}/webhooks`, {
                    method: "POST",
                    headers: { "Content-Type": "application/json" },
                    body: JSON.stringify({
                        nombre: elem("w-nombre").value.trim() || "Sin nombre",
                        url,
                        eventos: []
                    })
                });

                // Igual que con las claves: el secreto se muestra fijo, no como aviso
                // flotante. Es la única vez que existe fuera del cliente.
                elem("w-resultado").innerHTML = `
          <div class="secreto">
            <strong>Entrega este secreto al cliente ahora.</strong>
            <code>${esc(r.secreto)}</code>
            <button class="mini" id="btn-copiar-secreto">Copiar</button>
            <div class="tenue" style="font-size:12.5px;margin-top:8px">${esc(r.aviso)}</div>
          </div>`;

                elem("btn-copiar-secreto").onclick = async () => {
                    await navigator.clipboard.writeText(r.secreto);
                    avisar("Secreto copiado", "", "ok");
                };

                elem("w-nombre").value = "";
                elem("w-url").value = "";

                marcarRecien("webhooks", r.id);

                estado.webhooks = await api(`/admin/tenants/${estado.seleccionada.id}/webhooks`);

                const tabla = elem("tabla-webhooks");
                if (tabla) { tabla.innerHTML = tablaWebhooks(); enlazarAccionesWebhook(); }
                else cargarPestana();

            } catch (e) {
                avisar(e.message, e.detalle, "mal");
            } finally {
                boton.disabled = false;
            }
        }

        async function probarWebhook(id) {
            try {
                const r = await api(
                    `/admin/tenants/${estado.seleccionada.id}/webhooks/${id}/prueba`,
                    { method: "POST" });

                avisar("Aviso de prueba encolado", r.mensaje, "ok");

                // Se espera al ciclo del despachador antes de refrescar, o la entrega
                // aparecería siempre como pendiente y parecería que no funciona.
                setTimeout(() => {
                    if (estado.pestana === "webhooks") cargarPestana();
                }, 12000);

            } catch (e) { avisar(e.message, e.detalle, "mal"); }
        }

        async function alternarWebhook(id, activar) {
            try {
                await api(`/admin/tenants/${estado.seleccionada.id}/webhooks/${id}`, {
                    method: "PATCH",
                    headers: { "Content-Type": "application/json" },
                    body: JSON.stringify({ activo: activar })
                });

                avisar(activar ? "Webhook activado" : "Webhook desactivado", "", "ok");
                await cargarPestana();

            } catch (e) { avisar(e.message, e.detalle, "mal"); }
        }

        async function eliminarWebhook(id, nombre) {
            const seguro = await confirmar(
                `Eliminar el webhook ${nombre}`,
                "El cliente dejará de recibir avisos de inmediato y se borrará su " +
                "historial de entregas. Si solo quieres pausarlo, desactívalo.",
                "Eliminar");

            if (!seguro) return;

            try {
                await api(`/admin/tenants/${estado.seleccionada.id}/webhooks/${id}`,
                    { method: "DELETE" });

                avisar("Webhook eliminado", "", "ok");
                await cargarPestana();

            } catch (e) { avisar(e.message, e.detalle, "mal"); }
        }

        async function reintentarEntrega(id) {
            try {
                await api(`/admin/webhook-entregas/${id}/reintentar`, { method: "POST" });

                avisar("Entrega devuelta a la cola",
                    "Se enviará en el siguiente ciclo.", "ok");

                setTimeout(() => {
                    if (estado.pestana === "webhooks") cargarPestana();
                }, 12000);

            } catch (e) { avisar(e.message, e.detalle, "mal"); }
        }

        // LOS NUEVE TIPOS QUE EL SISTEMA EMITE.
        //
        // Faltaban seis, y el panel los enseñaba como el número crudo. Peor aún: el
        // desplegable de "agregar serie" solo ofrecía cuatro, así que una empresa
        // nueva no podía recibir su L001, su R001 ni su V001 desde aquí.
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

        // LA INICIAL DE LA SERIE LA FIJA SUNAT y no es negociable. Se usa para
        // sugerir el ejemplo correcto al cambiar de tipo, porque teclear "F001" en
        // una liquidación es el error más fácil de cometer aquí.
        const serieSugerida = t =>
        ({
            "01": "F001", "03": "B001", "04": "L001", "07": "F001", "08": "F001",
            "09": "T001", "20": "R001", "31": "V001", "40": "P001"
        }[t] || "F001");

        // ----------------------------------------------------------------- acciones

        function seleccionar(id) {
            estado.seleccionada = estado.empresas.find(e => e.id === id);

            // La primera pestaña que el usuario pueda ver, no siempre "series":
            // alguien sin empresas.ver no debería aterrizar en una pantalla vacía.
            const visibles = pestanasVisibles();
            estado.pestana = visibles[0] ?? "series";

            pintar();
        }

        async function recargar() {
            const id = estado.seleccionada?.id;
            estado.empresas = await api("/admin/tenants");
            estado.seleccionada = id ? estado.empresas.find(e => e.id === id) : null;
            pintar();
        }

        function abrirNueva() {
            ["ruc", "razon", "identificador"].forEach(c => {
                elem("e-" + c).textContent = "";
                elem("n-" + c).parentElement.classList.remove("invalido");
            });

            elem("velo-nueva").classList.add("visible");
            elem("n-ruc").focus();
        }

        elem("nv-cancelar").onclick = () =>
            elem("velo-nueva").classList.remove("visible");

        elem("nv-crear").onclick = crearEmpresa;

        async function crearEmpresa() {
            const ruc = elem("n-ruc").value.trim();
            const razon = elem("n-razon").value.trim();

            let valido = true;

            const marcar = (campo, mensaje) => {
                elem("e-" + campo).textContent = mensaje;
                elem("n-" + campo).parentElement.classList.toggle("invalido", !!mensaje);
                if (mensaje) valido = false;
            };

            // Validar antes de llamar no sustituye la validación del servidor, que es
            // la que de verdad protege. Solo evita un viaje y señala el campo exacto.
            marcar("ruc", /^\d{11}$/.test(ruc) ? "" : "Debe tener 11 dígitos.");
            marcar("razon", razon.length >= 3 ? "" : "Escribe la razón social.");

            const identificador = elem("n-identificador").value.trim().toLowerCase();
            marcar("identificador", problemaIdentificador(identificador));

            if (!valido) return;

            const boton = elem("nv-crear");
            boton.disabled = true;

            try {
                await api("/admin/tenants", {
                    method: "POST",
                    headers: { "Content-Type": "application/json" },
                    body: JSON.stringify({
                        ruc, razonSocial: razon,
                        nombreComercial: elem("n-comercial").value.trim(),
                        direccion: elem("n-direccion").value.trim(),
                        distrito: elem("n-distrito").value.trim(),
                        provincia: elem("n-provincia").value.trim(),
                        departamento: elem("n-departamento").value.trim(),
                        ubigeo: elem("n-ubigeo").value.trim(),
                        ambiente: elem("n-ambiente").value,
                        usuarioSol: elem("n-sol").value.trim(),
                        identificador: identificador || null,
                        maxConcurrencia: 1
                    })
                });

                elem("velo-nueva").classList.remove("visible");
                elem("n-ruc").value = "";
                elem("n-razon").value = "";
                elem("n-comercial").value = "";
                elem("n-direccion").value = "";
                elem("n-identificador").value = "";

                avisar("Empresa creada",
                    "Ahora hace falta el certificado, una serie y una clave.", "ok");

                await recargar();

            } catch (e) {
                avisar(e.message, e.detalle, "mal");
            } finally {
                boton.disabled = false;
            }
        }

        async function alternarActiva() {
            const t = estado.seleccionada;

            if (t.activo) {
                const seguro = await confirmar(
                    "Desactivar empresa",
                    `${t.razonSocial} dejará de poder emitir de inmediato y sus claves ` +
                    `dejarán de funcionar. Los comprobantes ya emitidos no se ven afectados.`,
                    "Desactivar");

                if (!seguro) return;
            }

            try {
                await api(`/admin/tenants/${t.id}`, {
                    method: "PATCH",
                    headers: { "Content-Type": "application/json" },
                    body: JSON.stringify({ activo: !t.activo })
                });

                avisar(t.activo ? "Empresa desactivada" : "Empresa activada", "", "ok");
                await recargar();

            } catch (e) { avisar(e.message, e.detalle, "mal"); }
        }

        /// Resalta lo recién creado y quita la marca a los pocos segundos.
        ///
        /// Dejarla fija haría que, tras varias altas, media tabla quedara marcada
        /// y la marca dejaría de significar nada.
        function marcarRecien(pestana, id) {
            estado.recien[pestana] = id;

            setTimeout(() => {
                if (estado.recien[pestana] !== id) return;

                estado.recien[pestana] = null;

                const tabla = elem("tabla-" + pestana);
                if (!tabla) return;

                if (pestana === "series") {
                    tabla.innerHTML = tablaSeries();
                    enlazarAccionesSerie();
                } else if (pestana === "claves") {
                    tabla.innerHTML = tablaClaves();
                    enlazarRevocar();
                } else {
                    tabla.innerHTML = tablaCertificados();
                    enlazarAccionesCertificado();
                }
            }, 6000);
        }

        async function crearSerie() {
            const serie = elem("s-serie").value.trim().toUpperCase();

            if (serie.length !== 4) {
                elem("e-serie").textContent = "Debe tener 4 caracteres. Ej: F001, B001.";
                elem("s-serie").parentElement.classList.add("invalido");
                return;
            }

            elem("e-serie").textContent = "";
            elem("s-serie").parentElement.classList.remove("invalido");

            const boton = elem("btn-serie");
            boton.disabled = true;

            try {
                const creada = await api(`/admin/tenants/${estado.seleccionada.id}/series`, {
                    method: "POST",
                    headers: { "Content-Type": "application/json" },
                    body: JSON.stringify({
                        tipoComprobante: elem("s-tipo").value,
                        serie,
                        correlativoInicial: parseInt(elem("s-corr").value || "0", 10)
                    })
                });

                marcarRecien("series", creada.id);

                avisar(`Serie ${serie} lista`,
                    "Si ya existía, solo se reactivó: el correlativo no cambió.", "ok");

                elem("s-serie").value = "";
                elem("s-corr").value = "0";

                await recargar();



            } catch (e) {
                avisar(e.message, e.detalle, "mal");
                boton.disabled = false;
            }
        }

        async function crearClave() {
            const boton = elem("btn-clave");
            boton.disabled = true;

            try {
                const r = await api(`/admin/tenants/${estado.seleccionada.id}/claves`, {
                    method: "POST",
                    headers: { "Content-Type": "application/json" },
                    body: JSON.stringify({
                        nombre: elem("k-nombre").value.trim() || "Sin nombre",
                        produccion: estado.seleccionada.ambiente === "produccion"
                    })
                });

                // Se muestra fija, no como aviso flotante: es la única vez que este valor
                // existe fuera del cliente. Un aviso que desaparece solo sería un error.
                elem("k-resultado").innerHTML = `
          <div class="secreto">
            <strong>Copia esta clave ahora y entrégasela al cliente.</strong>
            <code>${esc(r.clave)}</code>
            <button class="mini" id="btn-copiar">Copiar</button>
            <div class="tenue" style="font-size:12.5px;margin-top:8px">${esc(r.aviso)}</div>
          </div>`;

                elem("btn-copiar").onclick = async () => {
                    await navigator.clipboard.writeText(r.clave);
                    avisar("Clave copiada", "", "ok");
                };

                marcarRecien("claves", r.id);

                // Se actualiza la lista sin repintar el detalle, para no borrar la clave
                // que el operador todavía no ha copiado.
                estado.claves = await api(`/admin/tenants/${estado.seleccionada.id}/claves`);
                estado.empresas = await api("/admin/tenants");

                const tabla = elem("tabla-claves");
                if (tabla) { tabla.innerHTML = tablaClaves(); enlazarRevocar(); }

            } catch (e) {
                avisar(e.message, e.detalle, "mal");
            } finally {
                boton.disabled = false;
            }
        }

        async function eliminarSerie(id, nombre) {
            const seguro = await confirmar(
                `Eliminar la serie ${nombre}`,
                "Esta serie nunca emitió comprobantes, así que se puede borrar sin " +
                "consecuencias. Si después la necesitas, hay que volver a darla de alta.",
                "Eliminar");

            if (!seguro) return;

            try {
                await api(`/admin/tenants/${estado.seleccionada.id}/series/${id}`,
                    { method: "DELETE" });

                avisar(`Serie ${nombre} eliminada`, "", "ok");
                await recargar();

            } catch (e) { avisar(e.message, e.detalle, "mal"); }
        }

        async function cambiarSerie(id, activar, nombre) {
            if (!activar) {
                const seguro = await confirmar(
                    `Cerrar la serie ${nombre}`,
                    "Dejará de poder emitir comprobantes. Los que ya emitió NO se tocan: " +
                    "siguen consultándose y descargándose igual. Puedes reactivarla después.",
                    "Cerrar serie");

                if (!seguro) return;
            }

            try {
                await api(`/admin/tenants/${estado.seleccionada.id}/series/${id}`, {
                    method: "PATCH",
                    headers: { "Content-Type": "application/json" },
                    body: JSON.stringify({ activo: activar })
                });

                avisar(activar ? `Serie ${nombre} reactivada` : `Serie ${nombre} cerrada`,
                    "", "ok");

                await recargar();

            } catch (e) { avisar(e.message, e.detalle, "mal"); }
        }

        async function eliminarCertificado(id) {
            const seguro = await confirmar(
                "Eliminar certificado",
                "Este certificado nunca firmó comprobantes y no está en uso, así que se " +
                "puede borrar. Es lo que se hace cuando se cargó el archivo equivocado.",
                "Eliminar");

            if (!seguro) return;

            try {
                await api(`/admin/tenants/${estado.seleccionada.id}/certificados/${id}`,
                    { method: "DELETE" });

                avisar("Certificado eliminado", "", "ok");
                await recargar();

            } catch (e) { avisar(e.message, e.detalle, "mal"); }
        }

        async function revocar(id) {
            const seguro = await confirmar(
                "Revocar clave",
                "El sistema que la use dejará de poder emitir de inmediato. No se puede " +
                "deshacer: habría que emitir una clave nueva.",
                "Revocar");

            if (!seguro) return;

            try {
                await api(`/admin/claves/${id}`, { method: "DELETE" });
                avisar("Clave revocada", "", "ok");
                await recargar();
            } catch (e) { avisar(e.message, e.detalle, "mal"); }
        }

        async function subirCertificado() {
            const archivo = elem("c-archivo").files[0];
            const resultado = elem("c-resultado");

            if (!archivo) {
                resultado.innerHTML =
                    `<div style="color:var(--mal);margin-top:10px">Elige el archivo .pfx.</div>`;
                return;
            }

            // LA CONTRASEÑA VA EN EL CUERPO, NO EN LA DIRECCIÓN. Una dirección
            // queda escrita en los registros del proxy y de cualquier
            // intermediario; el cuerpo no.
            const datos = new FormData();
            datos.append("archivo", archivo);
            datos.append("clave", elem("c-clave").value);

            const boton = elem("btn-certificado");
            boton.disabled = true;
            resultado.innerHTML = `<div class="tenue" style="margin-top:10px">Cifrando y guardando…</div>`;

            try {
                const cargado = await api(
                    `/admin/tenants/${estado.seleccionada.id}/certificado`,
                    { method: "POST", body: datos });

                avisar("Certificado cargado y cifrado", "", "ok");

                elem("c-clave").value = "";

                await recargar();
                marcarRecien("certificado", cargado.id);

            } catch (e) {
                resultado.innerHTML =
                    `<div style="color:var(--mal);margin-top:10px">${esc(e.message)}<br>
             <span class="tenue">${esc(e.detalle || "")}</span></div>`;

                boton.disabled = false;
            }
        }

        cargarUsuario().then(ok => { if (ok) iniciar(); });
    </script>
</body>
</html>
'@

# --- Facturacion.Api\wwwroot\login.html
Planear 'Facturacion.Api\wwwroot\login.html' '25C783BD3FC383DF1E5FC552F901B45A081313BB816BAFF2924385339D470BAA' @'
<!DOCTYPE html>
<html lang="es">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Entrar · Facturación electrónica</title>
<style>
  :root {
    --fondo:#f6f7f9; --panel:#ffffff; --sutil:#f1f3f5;
    --borde:#e3e6ea; --borde-fuerte:#cfd4da;
    --texto:#1b1f24; --tenue:#5c6570;
    --acento:#2563eb; --mal:#b91c1c; --mal-fondo:#fdeded;
    --ok:#15803d; --ok-fondo:#eaf6ee;
    --radio:8px;
  }

  @media (prefers-color-scheme: dark) {
    :root {
      --fondo:#0f1115; --panel:#171a21; --sutil:#1c212b;
      --borde:#262b36; --borde-fuerte:#3a4152;
      --texto:#e6e8ec; --tenue:#98a1ae;
      --acento:#4493f8; --mal:#f85149; --mal-fondo:#2d1516;
      --ok:#3fb950; --ok-fondo:#122a18;
    }
  }

  * { box-sizing:border-box; }

  body { margin:0; min-height:100vh; background:var(--fondo); color:var(--texto);
         font:15px/1.55 ui-sans-serif, system-ui, "Segoe UI", sans-serif;
         display:flex; align-items:center; justify-content:center; padding:20px; }

  .caja { background:var(--panel); border:1px solid var(--borde);
          border-radius:14px; padding:30px 32px; width:100%; max-width:390px; }

  h1 { font-size:19px; margin:0 0 4px; font-weight:500; }
  .sub { color:var(--tenue); font-size:13.5px; margin-bottom:24px; }

  label { display:block; font-size:12.5px; color:var(--tenue);
          margin:0 0 5px; }

  input { width:100%; font:inherit; font-size:14.5px; color:var(--texto);
          background:var(--panel); border:1px solid var(--borde);
          border-radius:var(--radio); padding:9px 12px; margin-bottom:16px; }
  input:focus { outline:none; border-color:var(--acento); }

  button { width:100%; font:inherit; font-size:14.5px; font-weight:500;
           background:var(--acento); border:1px solid var(--acento);
           color:#fff; border-radius:var(--radio); padding:10px;
           cursor:pointer; }
  button:hover:not(:disabled) { filter:brightness(1.08); }
  button:disabled { opacity:.6; cursor:default; }

  .mensaje { border-radius:var(--radio); padding:11px 13px; font-size:13.5px;
             margin-bottom:18px; display:none; }
  .mensaje.visible { display:block; }
  .mensaje.mal { background:var(--mal-fondo); color:var(--mal); }
  .mensaje.ok { background:var(--ok-fondo); color:var(--ok); }

  .nota { color:var(--tenue); font-size:12.5px; margin-top:18px;
          border-top:1px solid var(--borde); padding-top:14px; }

  /* Campo de contraseña con botón para mostrarla.
     El input se envuelve para poder colocar el botón encima sin que el
     texto quede debajo. */
  .con-ojo { position:relative; }
  .con-ojo input { padding-right:42px; }
  .con-ojo button {
    position:absolute; right:6px; top:50%; transform:translateY(-50%);
    width:auto; background:none; border:none; padding:6px;
    cursor:pointer; color:var(--tenue); line-height:0; }
  .con-ojo button:hover { color:var(--texto); }
  .con-ojo svg { width:19px; height:19px; stroke:currentColor; fill:none;
                 stroke-width:1.8; stroke-linecap:round; stroke-linejoin:round; }
</style>
</head>
<body>

<div class="caja">
  <h1>Facturación electrónica</h1>
  <div class="sub" id="subtitulo">Panel de operación</div>

  <div class="mensaje" id="mensaje"></div>

  <form id="formulario">
    <div id="campos-ingreso">
      <label for="correo">Correo</label>
      <input id="correo" type="email" autocomplete="username">

      <label for="contrasena">Contraseña</label>
      <input id="contrasena" type="password" autocomplete="current-password">
    </div>

    <div id="campos-recuperar" style="display:none">
      <label for="r-correo">Correo</label>
      <input id="r-correo" type="email" autocomplete="username">
    </div>

    <div id="campos-codigo" style="display:none">
      <label for="codigo">Código de verificación</label>
      <input id="codigo" inputmode="numeric" autocomplete="one-time-code"
             placeholder="123456" maxlength="14">
    </div>

    <div id="campos-totp" style="display:none">
      <div id="totp-qr" style="text-align:center;margin-bottom:14px"></div>

      <label for="totp-secreto-visible">Si no puedes escanear, escribe esto
        en tu aplicación</label>
      <div id="totp-secreto-visible"
           style="font-family:ui-monospace,Consolas,monospace;font-size:13.5px;
                  background:var(--fondo);border-radius:var(--radio);
                  padding:10px 12px;word-break:break-all;margin-bottom:16px;
                  text-align:center"></div>

      <label for="totp-codigo">Código de seis dígitos</label>
      <input id="totp-codigo" inputmode="numeric" maxlength="6"
             placeholder="123456" autocomplete="one-time-code">
    </div>

    <div id="campos-codigos" style="display:none">
      <div id="lista-codigos"></div>
    </div>

    <div id="campos-cambio" style="display:none">
      <label for="nueva">Contraseña nueva</label>
      <input id="nueva" type="password" autocomplete="new-password">

      <label for="repetir">Repítela</label>
      <input id="repetir" type="password" autocomplete="new-password">
    </div>

    <button type="submit" id="boton">Entrar</button>
  </form>

  <div id="olvide" style="text-align:center;margin-top:16px">
    <a href="#" id="enlace-olvide"
       style="color:var(--acento);text-decoration:none;font-size:13.5px">
      Olvidé mi contraseña</a>
  </div>

  <div class="nota" id="nota">
    Las sesiones caducan tras 12 horas sin uso. Tras 5 intentos fallidos la
    cuenta se bloquea 15 minutos.
  </div>
</div>

<script>
const elem = id => document.getElementById(id);
const esc = t => String(t ?? "").replace(/[&<>"']/g,
  c => ({ "&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;" }[c]));

let modo = "ingreso";
let tokenParcial = null;

function mostrar(texto, tipo = "mal") {
  const caja = elem("mensaje");
  caja.textContent = texto;
  caja.className = "mensaje visible " + tipo;
}

function ocultar() {
  elem("mensaje").className = "mensaje";
}

elem("formulario").onsubmit = async e => {
  e.preventDefault();
  ocultar();

  const boton = elem("boton");
  boton.disabled = true;

  try {
    if (modo === "ingreso") await ingresar();
    else if (modo === "codigo") await enviarCodigo();
    else if (modo === "recuperar") await pedirRecuperacion();
    else if (modo === "totp") await confirmarTotp();
    else if (modo === "codigos") location.href = "/diagnostico.html";
    else await cambiarContrasena();
  } finally {
    boton.disabled = false;
  }
};

async function ingresar() {
  // LA VALIDACIÓN VA AQUÍ, NO EN EL ATRIBUTO required.
  //
  // El formulario cambia de paso ocultando campos, y un campo obligatorio
  // oculto impide enviarlo: el navegador intenta poner el foco en algo que
  // no se ve y cancela el envío con un error que no explica nada.
  if (!elem("correo").value.trim()) {
    mostrar("Escribe tu correo.");
    elem("correo").focus();
    return;
  }

  if (!elem("contrasena").value) {
    mostrar("Escribe tu contraseña.");
    elem("contrasena").focus();
    return;
  }

  try {
    const r = await fetch("/admin/sesion", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        correo: elem("correo").value.trim(),
        contrasena: elem("contrasena").value
      })
    });

    const cuerpo = await r.json().catch(() => ({}));

    if (!r.ok) {
      mostrar(cuerpo.error || "No se pudo entrar.");
      return;
    }

    // La contraseña era correcta pero falta el código del autenticador.
    // Todavía NO hay sesión: lo que se recibe es un identificador parcial
    // que dura cinco minutos y no sirve para nada más.
    if (cuerpo.segundoFactor) {
      modo = "codigo";
      tokenParcial = cuerpo.tokenParcial;

      elem("campos-ingreso").style.display = "none";
      elem("campos-codigo").style.display = "block";
      elem("boton").textContent = "Verificar";
      elem("subtitulo").textContent = "Verificación en dos pasos";

      elem("nota").textContent =
        "Escribe el código de seis dígitos de tu aplicación autenticadora. " +
        "Si perdiste el teléfono, puedes usar uno de tus códigos de " +
        "recuperación.";

      mostrar(cuerpo.mensaje, "ok");
      elem("codigo").focus();

      return;
    }

    // Qué falta antes de poder trabajar. El orden importa: primero la
    // contraseña, después el segundo factor.
    if (cuerpo.debeCambiar) {
      pasoCambioContrasena(cuerpo);
      return;
    }

    if (cuerpo.debeConfigurarTotp) {
      await pasoConfigurarTotp();
      return;
    }

    location.href = "/diagnostico.html";
    return;

  } catch (e) {
    mostrar("No se pudo contactar el servicio: " + e.message);
  }
}

// --------------------------------------------------- pasos obligatorios

function pasoCambioContrasena(cuerpo) {
  modo = "cambio";

  ocultarTodo();
  elem("campos-cambio").style.display = "block";
  elem("olvide").style.display = "none";

  elem("boton").textContent = "Cambiar contraseña";
  elem("subtitulo").textContent = `Hola, ${cuerpo.nombre || cuerpo.correo}`;

  elem("nota").textContent =
    "Tu contraseña es provisional y hay que cambiarla antes de continuar. " +
    "Usa al menos 10 caracteres; una frase que recuerdes va mejor que algo " +
    "corto y complicado.";

  mostrar("Elige una contraseña nueva para continuar.", "ok");
  elem("nueva").focus();
}

// SE CONFIGURA EN EL PRIMER INGRESO, no cuando el usuario se acuerde.
//
// Dejarlo a criterio de cada uno significa que casi nadie lo activa: es un
// paso extra que no da nada a cambio hoy y solo se echa en falta el día del
// incidente. Junto al cambio de contraseña, deja de ser una tarea pendiente
// y pasa a ser parte del alta.
async function pasoConfigurarTotp() {
  modo = "totp";

  ocultarTodo();
  elem("olvide").style.display = "none";
  elem("boton").disabled = true;
  elem("subtitulo").textContent = "Verificación en dos pasos";

  elem("nota").textContent =
    "Este panel da acceso a los certificados digitales de los clientes. " +
    "Con verificación en dos pasos, una contraseña robada ya no basta para " +
    "entrar.";

  mostrar("Preparando el código…", "ok");

  try {
    const r = await fetch("/admin/yo/2fa/iniciar", { method: "POST" });

    if (!r.ok) {
      mostrar("No se pudo preparar la verificación. Vuelve a entrar.");
      return;
    }

    const datos = await r.json();

    elem("totp-qr").innerHTML =
      `<img src="${datos.qr}" alt="Código QR"
            style="width:190px;height:190px;background:#fff;padding:8px;
                   border-radius:8px">`;

    elem("totp-secreto-visible").textContent = datos.secreto;

    elem("campos-totp").style.display = "block";
    elem("boton").textContent = "Activar";
    elem("boton").disabled = false;

    mostrar("Escanea el código con Google Authenticator, Authy o similar.", "ok");
    elem("totp-codigo").focus();

  } catch (e) {
    mostrar("No se pudo contactar el servicio: " + e.message);
  }
}

async function confirmarTotp() {
  const codigo = elem("totp-codigo").value.trim();

  if (codigo.length < 6) {
    mostrar("Escribe el código de seis dígitos.");
    return;
  }

  try {
    const r = await fetch("/admin/yo/2fa/confirmar", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ codigo })
    });

    const cuerpo = await r.json().catch(() => ({}));

    if (!r.ok) {
      mostrar(cuerpo.detalle || cuerpo.error || "El código no es correcto.");
      elem("totp-codigo").value = "";
      elem("totp-codigo").focus();
      return;
    }

    // Los códigos de recuperación se muestran UNA vez. Es la única forma de
    // entrar si se pierde el teléfono, así que no se pasa de aquí sin que el
    // usuario confirme que los guardó.
    modo = "codigos";

    ocultarTodo();
    elem("campos-codigos").style.display = "block";
    elem("subtitulo").textContent = "Guarda estos códigos";

    elem("lista-codigos").innerHTML = `
      <div style="background:var(--ok-fondo);border:1px solid var(--ok);
                  border-radius:var(--radio);padding:14px 16px">
        <div style="display:grid;grid-template-columns:1fr 1fr;gap:7px;
                    font-family:ui-monospace,Consolas,monospace;font-size:14px;
                    color:var(--ok)">
          ${cuerpo.codigosRecuperacion.map(c => `<span>${c}</span>`).join("")}
        </div>
      </div>`;

    elem("boton").textContent = "Ya los guardé, entrar";

    elem("nota").textContent =
      "Cada código sirve una sola vez y son la única forma de entrar si " +
      "pierdes el teléfono. Guárdalos en un lugar seguro: no se vuelven a " +
      "mostrar.";

    mostrar("Verificación activada.", "ok");

  } catch (e) {
    mostrar("No se pudo contactar el servicio: " + e.message);
  }
}

function ocultarTodo() {
  ["campos-ingreso", "campos-codigo", "campos-recuperar",
   "campos-cambio", "campos-totp", "campos-codigos"]
    .forEach(id => { if (elem(id)) elem(id).style.display = "none"; });
}

async function enviarCodigo() {
  if (!elem("codigo").value.trim()) {
    mostrar("Escribe el código de tu aplicación.");
    elem("codigo").focus();
    return;
  }

  try {
    const r = await fetch("/admin/sesion/codigo", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        tokenParcial,
        codigo: elem("codigo").value.trim()
      })
    });

    const cuerpo = await r.json().catch(() => ({}));

    if (!r.ok) {
      mostrar(cuerpo.error || "El código no es correcto.");
      elem("codigo").value = "";
      elem("codigo").focus();
      return;
    }

    if (cuerpo.debeCambiar) {
      pasoCambioContrasena(cuerpo);
      return;
    }

    location.href = "/diagnostico.html";

  } catch (e) {
    mostrar("No se pudo contactar el servicio: " + e.message);
  }
}

async function cambiarContrasena() {
  const nueva = elem("nueva").value;

  if (nueva !== elem("repetir").value) {
    mostrar("Las dos contraseñas no coinciden.");
    return;
  }

  if (nueva.length < 10) {
    mostrar("Debe tener al menos 10 caracteres.");
    return;
  }

  try {
    const r = await fetch("/admin/yo/contrasena", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        actual: elem("contrasena").value,
        nueva
      })
    });

    const cuerpo = await r.json().catch(() => ({}));

    if (!r.ok) {
      mostrar(cuerpo.detalle || cuerpo.error || "No se pudo cambiar.");
      return;
    }

    if (cuerpo.debeConfigurarTotp) {
      await pasoConfigurarTotp();
      return;
    }

    location.href = "/diagnostico.html";

  } catch (e) {
    mostrar("No se pudo contactar el servicio: " + e.message);
  }
}

elem("enlace-olvide").onclick = e => {
  e.preventDefault();
  ocultar();

  modo = "recuperar";

  elem("campos-ingreso").style.display = "none";
  elem("campos-recuperar").style.display = "block";
  elem("olvide").innerHTML =
    `<a href="/login.html" style="color:var(--acento);text-decoration:none;` +
    `font-size:13.5px">Volver al ingreso</a>`;

  elem("boton").textContent = "Enviar enlace";
  elem("subtitulo").textContent = "Recuperar contraseña";

  elem("nota").textContent =
    "Te enviaremos un enlace para elegir una contraseña nueva. Caduca en una " +
    "hora y solo sirve una vez.";

  elem("r-correo").value = elem("correo").value;
  elem("r-correo").focus();
};

async function pedirRecuperacion() {
  if (!elem("r-correo").value.trim()) {
    mostrar("Escribe tu correo.");
    elem("r-correo").focus();
    return;
  }

  try {
    const r = await fetch("/admin/sesion/recuperar", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ correo: elem("r-correo").value.trim() })
    });

    const cuerpo = await r.json().catch(() => ({}));

    // La respuesta es la misma exista o no la cuenta. Decir "ese correo no
    // está registrado" permitiría averiguar qué correos tienen cuenta
    // probándolos uno por uno.
    mostrar(cuerpo.mensaje || "Si ese correo tiene cuenta, recibirás un enlace.", "ok");

    elem("campos-recuperar").style.display = "none";
    elem("boton").style.display = "none";

  } catch (e) {
    mostrar("No se pudo contactar el servicio: " + e.message);
  }
}

// ------------------------------------------------------------------- ojitos
//
// Escribir una contraseña a ciegas es la causa más común de "mi contraseña no
// funciona": se escribió mal y no hay forma de verlo. Poder mostrarla reduce
// los intentos fallidos, que además bloquean la cuenta tras cinco.
//
// El botón dice qué hace mediante aria-label, para quien use lector de
// pantalla, y cambia de icono según el estado.

const OJO_ABIERTO = `<svg viewBox="0 0 24 24"><path d="M2 12s3.5-7 10-7 10 7 10 7-3.5 7-10 7-10-7-10-7z"/><circle cx="12" cy="12" r="3"/></svg>`;

const OJO_CERRADO = `<svg viewBox="0 0 24 24"><path d="M3 3l18 18"/><path d="M10.6 5.2A9.8 9.8 0 0112 5c6.5 0 10 7 10 7a17 17 0 01-3.2 4"/><path d="M6.2 6.2A17 17 0 002 12s3.5 7 10 7c1.6 0 3-.4 4.2-1"/><path d="M9.9 9.9a3 3 0 004.2 4.2"/></svg>`;

function ponerOjo(idCampo) {
  const campo = elem(idCampo);
  if (!campo || campo.dataset.conOjo) return;

  campo.dataset.conOjo = "1";

  const envoltura = document.createElement("span");
  envoltura.className = "con-ojo";

  campo.parentNode.insertBefore(envoltura, campo);
  envoltura.appendChild(campo);

  const boton = document.createElement("button");
  boton.type = "button";
  boton.innerHTML = OJO_ABIERTO;
  boton.setAttribute("aria-label", "Mostrar contraseña");
  boton.title = "Mostrar contraseña";

  boton.onclick = () => {
    const visible = campo.type === "text";

    campo.type = visible ? "password" : "text";
    boton.innerHTML = visible ? OJO_ABIERTO : OJO_CERRADO;

    const texto = visible ? "Mostrar contraseña" : "Ocultar contraseña";
    boton.setAttribute("aria-label", texto);
    boton.title = texto;

    // Devolver el foco al campo: si no, seguir escribiendo obliga a hacer
    // clic otra vez.
    campo.focus();
  };

  envoltura.appendChild(boton);
}

// Se aplica a todos los campos de contraseña de la página.
document.querySelectorAll('input[type=password]').forEach(c => {
  if (c.id) ponerOjo(c.id);
});

elem("correo").focus();
</script>
</body>
</html>
'@

# --- Facturacion.Persistencia\RepositorioAdmin.cs
Planear 'Facturacion.Persistencia\RepositorioAdmin.cs' '951593AB84C926A2BA44C6C758C311A9223D8F4822AB84728484900810F78A74' @'
using Dapper;
using Npgsql;

namespace Facturacion.Persistencia;

/// <summary>Una empresa vista desde el panel de administración.</summary>
public record TenantAdmin(
    Guid Id,
    string Ruc,
    string RazonSocial,
    string NombreComercial,
    string Ambiente,
    short MaxConcurrencia,
    bool Activo,
    DateTime CreadoEn,
    int Comprobantes,
    bool TieneCertificado,
    DateTime? CertificadoVence,
    int Series,
    int Claves,
    string? UsuarioSol,
    bool TieneClaveSol,
    bool GreHabilitado,
    string? GreClientId,
    bool TieneGreSecret,

    // La marca (migración 020). LogoVersion es un resumen de la ruta del
    // logo: cambia cuando se sube otro, y así el panel sabe que tiene que
    // volver a pedir la imagen en vez de enseñar la que tiene guardada. La
    // ruta en sí no sale del servicio.
    string? Identificador,
    string? ColorMarca,
    string? CorreoRespuesta,
    string? LogoVersion)
{
    public bool EsProduccion => Ambiente == "produccion";

    public bool TieneLogo => LogoVersion is not null;

    /// <summary>Puede emitir guías en producción.</summary>
    public bool GreListo =>
        GreHabilitado &&
        !string.IsNullOrWhiteSpace(GreClientId) &&
        TieneGreSecret;
}

/// <summary>Datos para dar de alta una empresa.</summary>
public class NuevoTenant
{
    public string Ruc { get; set; } = "";
    public string RazonSocial { get; set; } = "";
    public string NombreComercial { get; set; } = "";
    public string Ubigeo { get; set; } = "150101";
    public string Direccion { get; set; } = "";
    public string Distrito { get; set; } = "";
    public string Provincia { get; set; } = "";
    public string Departamento { get; set; } = "";
    public string Ambiente { get; set; } = "beta";
    public string UsuarioSol { get; set; } = "MODDATOS";
    public short MaxConcurrencia { get; set; } = 1;

    /// <summary>
    /// El {empresa} del portal. Opcional al dar de alta: se puede poner
    /// después, pero una sola vez.
    /// </summary>
    public string? Identificador { get; set; }
}

/// <summary>Cómo terminó un intento de guardar la marca.</summary>
public enum ResultadoMarca
{
    Guardada,
    NoExiste,

    /// <summary>
    /// Ya tenía otro identificador. No se guardó NADA de la petición: ni el
    /// color ni el correo. A medias sería peor, porque el panel diría
    /// "error" y la mitad sí habría cambiado.
    /// </summary>
    IdentificadorFijo
}

/// <summary>Solo para leer el identificador actual con FOR UPDATE.</summary>
public record IdentificadorTenant(Guid Id, string? Identificador);

/// <summary>Lo que hace falta para guardar o servir el logo.</summary>
public record LogoTenant(string Ruc, string? LogoRuta);

/// <summary>Una serie de numeración.</summary>
/// <param name="Comprobantes">
/// Cuántos comprobantes se emitieron con esta serie. Determina si se puede
/// eliminar: con uno solo, ya hay histórico que conservar.
/// </param>
public record SerieAdmin(
    Guid Id,
    string TipoComprobante,
    string Serie,
    int UltimoCorrelativo,
    bool Activo,
    DateTime CreadoEn,
    int Comprobantes)
{
    /// <summary>
    /// Una serie sin comprobantes se puede borrar sin consecuencias.
    /// Con comprobantes, borrarla dejaría huérfano el rastro de esa
    /// numeración, y eso es un problema tributario, no de datos.
    /// </summary>
    public bool SePuedeEliminar => Comprobantes == 0;
}

/// <summary>Una clave de acceso, sin el secreto.</summary>
public record ClaveAdmin(
    Guid Id,
    string Nombre,
    string Prefijo,
    bool Activo,
    DateTime? UltimoUso,
    DateTime CreadoEn);

/// <summary>
/// Administración de empresas, series y claves de acceso.
///
/// Usa el rol de operador porque trabaja sobre todas las empresas y porque
/// crea filas en tablas que la aplicación normal solo puede leer.
///
/// TODO lo que hay aquí se hacía hasta ahora escribiendo SQL a mano. Eso
/// funciona mientras el sistema lo maneja quien lo construyó, y deja de
/// funcionar el día que hay que delegarlo. Un alta de empresa no debería
/// requerir saber PostgreSQL.
/// </summary>
public sealed class RepositorioAdmin
{
    private readonly string _cadenaOperador;

    public RepositorioAdmin(string cadenaConexionOperador)
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

    // ------------------------------------------------------------- empresas

    public async Task<IReadOnlyList<TenantAdmin>> ListarTenantsAsync(
        CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);

        var filas = await conexion.QueryAsync<TenantAdmin>(
            new CommandDefinition(
                """
                SELECT t.id               AS "Id",
                       t.ruc              AS "Ruc",
                       t.razon_social     AS "RazonSocial",
                       t.nombre_comercial AS "NombreComercial",
                       t.ambiente         AS "Ambiente",
                       t.max_concurrencia AS "MaxConcurrencia",
                       t.activo           AS "Activo",
                       t.creado_en        AS "CreadoEn",

                       (SELECT count(*)::int FROM comprobantes c
                         WHERE c.tenant_id = t.id)              AS "Comprobantes",

                       EXISTS (SELECT 1 FROM certificados ce
                                WHERE ce.tenant_id = t.id AND ce.activo)
                                                                AS "TieneCertificado",

                       (SELECT ce.valido_hasta FROM certificados ce
                         WHERE ce.tenant_id = t.id AND ce.activo
                         LIMIT 1)                               AS "CertificadoVence",

                       (SELECT count(*)::int FROM series s
                         WHERE s.tenant_id = t.id AND s.activo)  AS "Series",

                       (SELECT count(*)::int FROM api_keys k
                         WHERE k.tenant_id = t.id AND k.activo)  AS "Claves",

                       t.usuario_sol      AS "UsuarioSol",
                       (t.clave_sol_cifrada IS NOT NULL) AS "TieneClaveSol",
                       t.gre_habilitado   AS "GreHabilitado",
                       t.gre_client_id    AS "GreClientId",
                       (t.gre_client_secret_cifrado IS NOT NULL) AS "TieneGreSecret",

                       t.identificador    AS "Identificador",
                       t.color_marca      AS "ColorMarca",
                       t.correo_respuesta AS "CorreoRespuesta",
                       md5(t.logo_ruta)   AS "LogoVersion"

                  FROM tenants t
                 -- Alfabético por razón social. Con cincuenta empresas, el
                 -- orden por fecha de alta obliga a recorrer toda la lista
                 -- para encontrar una; el alfabético permite ir directo.
                 ORDER BY t.razon_social
                """,
                cancellationToken: ct));

        return filas.ToList();
    }

    public async Task<Guid> CrearTenantAsync(
        NuevoTenant nuevo, CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);

        return await conexion.ExecuteScalarAsync<Guid>(new CommandDefinition(
            """
            INSERT INTO tenants
                (ruc, razon_social, nombre_comercial, ubigeo, direccion,
                 distrito, provincia, departamento, ambiente, usuario_sol,
                 max_concurrencia, identificador)
            VALUES
                (@Ruc, @RazonSocial, @NombreComercial, @Ubigeo, @Direccion,
                 @Distrito, @Provincia, @Departamento, @Ambiente, @UsuarioSol,
                 @MaxConcurrencia, @Identificador)
            RETURNING id
            """,
            nuevo, cancellationToken: ct));
    }

    public async Task<bool> ActualizarTenantAsync(
        Guid id, bool? activo, short? maxConcurrencia,
        CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);

        var filas = await conexion.ExecuteAsync(new CommandDefinition(
            """
            UPDATE tenants
               SET activo = COALESCE(@activo, activo),
                   max_concurrencia = COALESCE(@maxConcurrencia, max_concurrencia)
             WHERE id = @id
            """,
            new { id, activo, maxConcurrencia }, cancellationToken: ct));

        return filas > 0;
    }

    // ---------------------------------------------------------------- marca

    /// <summary>
    /// Guarda el identificador del portal, el color y el correo de respuesta.
    ///
    /// EL COLOR Y EL CORREO SE REEMPLAZAN SIEMPRE: null los quita. El panel
    /// manda los tres campos cada vez, así que lo que llega es el estado
    /// completo que se quiere.
    ///
    /// EL IDENTIFICADOR SOLO SE PONE SI NO HABÍA. Si ya había uno y llega
    /// otro, no se guarda nada y se devuelve IdentificadorFijo con el actual.
    /// La base lo impediría igual (disparador de la 020), pero aquí se
    /// detecta antes para dar un mensaje claro y no dejar nada a medias.
    ///
    /// Un identificador que ya usa otra empresa sale como PostgresException
    /// 23505: lo traduce el endpoint.
    /// </summary>
    public async Task<(ResultadoMarca Resultado, string? IdentificadorActual)> GuardarMarcaAsync(
        Guid id, string? identificador, string? colorMarca, string? correoRespuesta,
        CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);
        await using var transaccion = await conexion.BeginTransactionAsync(ct);

        // FOR UPDATE: dos pestañas guardando a la vez no pueden poner cada
        // una un identificador distinto.
        var fila = await conexion.QuerySingleOrDefaultAsync<IdentificadorTenant>(
            new CommandDefinition(
                """
                SELECT id AS "Id", identificador AS "Identificador"
                  FROM tenants
                 WHERE id = @id
                   FOR UPDATE
                """,
                new { id }, transaccion, cancellationToken: ct));

        if (fila is null)
            return (ResultadoMarca.NoExiste, null);

        if (fila.Identificador is not null &&
            identificador is not null &&
            identificador != fila.Identificador)
            return (ResultadoMarca.IdentificadorFijo, fila.Identificador);

        await conexion.ExecuteAsync(new CommandDefinition(
            """
            UPDATE tenants
               SET identificador    = COALESCE(identificador, @identificador),
                   color_marca      = @colorMarca,
                   correo_respuesta = @correoRespuesta
             WHERE id = @id
            """,
            new { id, identificador, colorMarca, correoRespuesta },
            transaccion, cancellationToken: ct));

        await transaccion.CommitAsync(ct);

        return (ResultadoMarca.Guardada, fila.Identificador ?? identificador);
    }

    /// <summary>El RUC (para la carpeta del almacén) y la ruta del logo actual.</summary>
    public async Task<LogoTenant?> ObtenerLogoAsync(Guid id, CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);

        return await conexion.QuerySingleOrDefaultAsync<LogoTenant>(new CommandDefinition(
            """
            SELECT ruc AS "Ruc", logo_ruta AS "LogoRuta"
              FROM tenants
             WHERE id = @id
            """,
            new { id }, cancellationToken: ct));
    }

    /// <summary>
    /// Apunta la empresa a un logo ya guardado en el almacén.
    ///
    /// EL LOGO ANTERIOR NO SE BORRA del almacén: solo deja de apuntarse.
    /// Pesa unos kilobytes, y así un cambio por error se deshace volviendo a
    /// apuntar la ruta vieja.
    /// </summary>
    public async Task<bool> GuardarLogoAsync(Guid id, string ruta, CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);

        var filas = await conexion.ExecuteAsync(new CommandDefinition(
            "UPDATE tenants SET logo_ruta = @ruta WHERE id = @id",
            new { id, ruta }, cancellationToken: ct));

        return filas > 0;
    }

    /// <summary>
    /// Guarda las credenciales SOL de una empresa. La clave se cifra igual
    /// que los certificados.
    ///
    /// DEBE SER EL USUARIO SOL SECUNDARIO del contribuyente, nunca el
    /// principal. El principal puede hacer todo en el portal de SUNAT:
    /// declarar, pagar, modificar datos. Ese nivel de acceso no tiene por
    /// qué vivir en la base de datos de un proveedor.
    /// </summary>
    public async Task<bool> GuardarCredencialesSolAsync(
        Guid tenantId, string usuario, string clave,
        IProtectorDeSecretos protector, CancellationToken ct = default)
    {
        if (string.IsNullOrWhiteSpace(usuario))
            throw new ArgumentException("Falta el usuario SOL.", nameof(usuario));

        if (string.IsNullOrWhiteSpace(clave))
            throw new ArgumentException("Falta la clave SOL.", nameof(clave));

        var cifrada = protector.ProtegerTexto(clave);

        await using var conexion = await AbrirAsync(ct);

        var filas = await conexion.ExecuteAsync(new CommandDefinition(
            """
            UPDATE tenants
               SET usuario_sol = @usuario,
                   clave_sol_cifrada = @cifrada
             WHERE id = @tenantId
            """,
            new { tenantId, usuario, cifrada }, cancellationToken: ct));

        return filas > 0;
    }

    /// <summary>
    /// Guarda las credenciales de la API de guías de remisión.
    ///
    /// SON DISTINTAS DE LAS CREDENCIALES SOL. El contribuyente las genera en
    /// su menú SOL, opción "Credenciales de API SUNAT", una sola vez, y solo
    /// sirven para guías.
    ///
    /// Una empresa que emita facturas y guías tendrá los dos juegos: la clave
    /// SOL para las facturas, y estas dos para las guías.
    /// </summary>
    public async Task<bool> GuardarCredencialesGreAsync(
        Guid tenantId, string clientId, string clientSecret,
        IProtectorDeSecretos protector, CancellationToken ct = default)
    {
        if (string.IsNullOrWhiteSpace(clientId))
            throw new ArgumentException("Falta el client_id.", nameof(clientId));

        if (string.IsNullOrWhiteSpace(clientSecret))
            throw new ArgumentException("Falta el client_secret.", nameof(clientSecret));

        var cifrado = protector.ProtegerTexto(clientSecret);

        await using var conexion = await AbrirAsync(ct);

        var filas = await conexion.ExecuteAsync(new CommandDefinition(
            """
            UPDATE tenants
               SET gre_client_id = @clientId,
                   gre_client_secret_cifrado = @cifrado,

                   -- Guardar las credenciales habilita las guías: no tiene
                   -- sentido tenerlas cargadas y el módulo apagado.
                   gre_habilitado = true
             WHERE id = @tenantId
            """,
            new { tenantId, clientId = clientId.Trim(), cifrado },
            cancellationToken: ct));

        return filas > 0;
    }

    /// <summary>Activa o desactiva la emisión de guías.</summary>
    public async Task<bool> CambiarGreHabilitadoAsync(
        Guid tenantId, bool habilitado, CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);

        var filas = await conexion.ExecuteAsync(new CommandDefinition(
            "UPDATE tenants SET gre_habilitado = @habilitado WHERE id = @tenantId",
            new { tenantId, habilitado }, cancellationToken: ct));

        return filas > 0;
    }

    /// <summary>
    /// Cambia el ambiente de una empresa entre beta y producción.
    ///
    /// Quien llame debe haber comprobado antes que está lista: pasar a
    /// producción sin certificado válido o sin clave SOL hace que todas sus
    /// facturas fallen desde el primer minuto.
    /// </summary>
    public async Task<bool> CambiarAmbienteAsync(
        Guid tenantId, string ambiente, CancellationToken ct = default)
    {
        if (ambiente is not ("beta" or "produccion"))
            throw new ArgumentException(
                "El ambiente solo puede ser 'beta' o 'produccion'.", nameof(ambiente));

        await using var conexion = await AbrirAsync(ct);

        var filas = await conexion.ExecuteAsync(new CommandDefinition(
            "UPDATE tenants SET ambiente = @ambiente WHERE id = @tenantId",
            new { tenantId, ambiente }, cancellationToken: ct));

        return filas > 0;
    }

    // --------------------------------------------------------------- series

    public async Task<IReadOnlyList<SerieAdmin>> ListarSeriesAsync(
        Guid tenantId, CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);

        var filas = await conexion.QueryAsync<SerieAdmin>(
            new CommandDefinition(
                """
                SELECT s.id                 AS "Id",
                       s.tipo_comprobante   AS "TipoComprobante",
                       s.serie              AS "Serie",
                       s.ultimo_correlativo AS "UltimoCorrelativo",
                       s.activo             AS "Activo",
                       s.creado_en          AS "CreadoEn",

                       (SELECT count(*)::int FROM comprobantes c
                         WHERE c.tenant_id = s.tenant_id
                           AND c.tipo_comprobante = s.tipo_comprobante
                           AND c.serie = s.serie)  AS "Comprobantes"

                  FROM series s
                 WHERE s.tenant_id = @tenantId
                 -- La más reciente primero.
                 --
                 -- El orden por tipo y serie se lee mejor, pero obliga a
                 -- buscar en toda la tabla la que acabas de crear. Como una
                 -- empresa tiene pocas series, la comodidad de verla arriba
                 -- pesa más que la prolijidad del agrupamiento.
                 ORDER BY s.creado_en DESC
                """,
                new { tenantId }, cancellationToken: ct));

        return filas.ToList();
    }

    /// <summary>
    /// Da de alta una serie.
    ///
    /// EL CORRELATIVO INICIAL PUEDE NO SER CERO, y eso importa: cuando una
    /// empresa migra desde otro sistema, ya emitió comprobantes con esa serie.
    /// Empezar de nuevo en 1 generaría duplicados que SUNAT rechazaría, y
    /// obligaría a resolverlo con la administración tributaria.
    /// </summary>
    public async Task<Guid> CrearSerieAsync(
        Guid tenantId, string tipoComprobante, string serie,
        int correlativoInicial = 0, CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);

        return await conexion.ExecuteScalarAsync<Guid>(new CommandDefinition(
            """
            INSERT INTO series (tenant_id, tipo_comprobante, serie, ultimo_correlativo)
            VALUES (@tenantId, @tipoComprobante, @serie, @correlativoInicial)
            ON CONFLICT (tenant_id, tipo_comprobante, serie)
            DO UPDATE SET activo = true
            RETURNING id
            """,
            new { tenantId, tipoComprobante, serie, correlativoInicial },
            cancellationToken: ct));
    }

    /// <summary>
    /// Elimina una serie, pero SOLO si nunca se usó.
    ///
    /// La comprobación va dentro del mismo DELETE, no en una consulta previa:
    /// entre comprobar y borrar hay una ventana en la que alguien podría
    /// emitir un comprobante con esa serie. Hacerlo en una sola sentencia
    /// cierra esa ventana.
    ///
    /// Devuelve false si la serie no existe o si ya tiene comprobantes.
    /// </summary>
    public async Task<bool> EliminarSerieAsync(
        Guid tenantId, Guid serieId, CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);

        var filas = await conexion.ExecuteAsync(new CommandDefinition(
            """
            DELETE FROM series s
             WHERE s.id = @serieId
               AND s.tenant_id = @tenantId
               AND NOT EXISTS (
                     SELECT 1 FROM comprobantes c
                      WHERE c.tenant_id = s.tenant_id
                        AND c.tipo_comprobante = s.tipo_comprobante
                        AND c.serie = s.serie)
            """,
            new { tenantId, serieId }, cancellationToken: ct));

        return filas > 0;
    }

    /// <summary>
    /// Activa o desactiva una serie.
    ///
    /// Desactivarla impide emitir con ella, pero NO toca el histórico: los
    /// comprobantes ya emitidos siguen consultándose y descargándose igual.
    /// Es lo que se hace cuando una sucursal cierra, cuando cambia el esquema
    /// de numeración, o cuando hay que cerrar una serie y abrir otra.
    /// </summary>
    public async Task<bool> CambiarEstadoSerieAsync(
        Guid tenantId, Guid serieId, bool activo, CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);

        var filas = await conexion.ExecuteAsync(new CommandDefinition(
            """
            UPDATE series SET activo = @activo
             WHERE id = @serieId AND tenant_id = @tenantId
            """,
            new { tenantId, serieId, activo }, cancellationToken: ct));

        return filas > 0;
    }

    // --------------------------------------------------------------- claves

    public async Task<IReadOnlyList<ClaveAdmin>> ListarClavesAsync(
        Guid tenantId, CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);

        var filas = await conexion.QueryAsync<ClaveAdmin>(
            new CommandDefinition(
                """
                SELECT id         AS "Id",
                       nombre     AS "Nombre",
                       prefijo    AS "Prefijo",
                       activo     AS "Activo",
                       ultimo_uso AS "UltimoUso",
                       creado_en  AS "CreadoEn"
                  FROM api_keys
                 WHERE tenant_id = @tenantId
                 ORDER BY creado_en DESC
                """,
                new { tenantId }, cancellationToken: ct));

        return filas.ToList();
    }

    /// <summary>
    /// Crea una clave de acceso y devuelve el secreto EN CLARO.
    ///
    /// ES LA ÚNICA VEZ QUE ESE VALOR EXISTE FUERA DEL CLIENTE. En la base solo
    /// queda su hash, igual que con una contraseña. Si el cliente la pierde,
    /// no hay forma de recuperarla: se revoca y se emite otra.
    ///
    /// Eso es una molestia deliberada. La alternativa —guardarla en claro para
    /// poder mostrarla después— significaría que cualquiera con acceso a la
    /// base puede suplantar a todos tus clientes.
    /// </summary>
    public async Task<(Guid Id, string Clave)> CrearClaveAsync(
        Guid tenantId, string nombre, bool produccion = false,
        CancellationToken ct = default)
    {
        var clave = RepositorioTenants.GenerarClave(produccion);
        var hash = RepositorioTenants.CalcularHash(clave);
        var prefijo = clave[..Math.Min(20, clave.Length)];

        await using var conexion = await AbrirAsync(ct);

        var id = await conexion.ExecuteScalarAsync<Guid>(new CommandDefinition(
            """
            INSERT INTO api_keys (tenant_id, nombre, prefijo, hash)
            VALUES (@tenantId, @nombre, @prefijo, @hash)
            RETURNING id
            """,
            new { tenantId, nombre, prefijo, hash }, cancellationToken: ct));

        return (id, clave);
    }

    /// <summary>
    /// Revoca una clave. No se borra: se desactiva.
    ///
    /// Borrarla dejaría sin rastro quién tenía acceso y hasta cuándo, y esa
    /// es justo la pregunta que hay que poder responder después de un
    /// incidente de seguridad.
    /// </summary>
    public async Task<bool> RevocarClaveAsync(
        Guid claveId, CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);

        var filas = await conexion.ExecuteAsync(new CommandDefinition(
            """
            UPDATE api_keys
               SET activo = false, revocado_en = now()
             WHERE id = @claveId AND activo
            """,
            new { claveId }, cancellationToken: ct));

        return filas > 0;
    }
}
'@

# --- Facturacion.Persistencia\ModelosPersistencia.cs
Planear 'Facturacion.Persistencia\ModelosPersistencia.cs' 'FA4F51DD0DE19009ADC758FF9F0FF2B8778DBAC358F993A1C210FDC030C3349B' @'
namespace Facturacion.Persistencia;

/// <summary>
/// Estados por los que pasa un comprobante en la base de datos.
///
/// NO CONFUNDIR con EstadoComprobante de Facturacion.Cpe, que es el resultado
/// de consultarle a SUNAT por un comprobante. Son cosas distintas y por eso
/// llevan nombres distintos: uno es el ciclo de vida interno, el otro es lo
/// que SUNAT responde.
///
/// Los valores deben coincidir con el CHECK de la tabla: si el código y el
/// esquema se desincronizan, el INSERT falla en producción y no en las pruebas.
/// </summary>
public static class EstadoCpe
{
    public const string Borrador   = "BORRADOR";
    public const string Firmado    = "FIRMADO";
    public const string Encolado   = "ENCOLADO";
    public const string Enviado    = "ENVIADO";
    public const string Aceptado   = "ACEPTADO";
    public const string ConObservaciones = "ACEPTADO_CON_OBSERVACIONES";
    public const string Rechazado  = "RECHAZADO";
    public const string Anulado    = "ANULADO";

    /// <summary>
    /// Estados desde los que ya no hay vuelta atrás: el comprobante llegó
    /// a SUNAT y su suerte está decidida.
    /// </summary>
    public static bool EsFinal(string estado) =>
        estado is Aceptado or ConObservaciones or Rechazado or Anulado;

    /// <summary>Estados que un worker debe seguir procesando.</summary>
    public static bool EstaPendiente(string estado) =>
        estado is Firmado or Encolado or Enviado;
}

/// <summary>Comprobante tal como quedó guardado.</summary>
/// <param name="YaExistia">
/// true cuando la petición traía una clave de idempotencia que ya se había
/// usado. En ese caso no se creó nada nuevo: se devuelve el comprobante
/// original. Es la diferencia entre un doble clic inofensivo y un duplicado
/// tributario.
/// </param>
public record ComprobanteGuardado(
    Guid Id,
    Guid TenantId,
    string TipoComprobante,
    string Serie,
    int Correlativo,
    string Estado,
    decimal ImporteTotal,
    bool YaExistia)
{
    public string NumeroCompleto => $"{Serie}-{Correlativo:D8}";
}

/// <summary>Resumen de un comprobante para listados y consultas.</summary>
public record ResumenComprobante(
    Guid Id,
    string TipoComprobante,
    string Serie,
    int Correlativo,
    DateTime FechaEmision,
    string Moneda,
    decimal ImporteTotal,
    string Estado,
    string? CodigoSunat,
    string? MensajeSunat,
    string? Ticket,
    DateTime CreadoEn)
{
    public string NumeroCompleto => $"{Serie}-{Correlativo:D8}";
}

/// <summary>Un asiento de la bitácora de envíos.</summary>
public record IntentoEnvio(
    long Id,
    Guid ComprobanteId,
    short IntentoNro,
    string? EstadoAnterior,
    string EstadoNuevo,
    string? CodigoSunat,
    string? Mensaje,
    int? DuracionMs,
    string? Worker,
    DateTime CreadoEn);

/// <summary>
/// Datos de un cambio de estado, para registrar en la bitácora.
/// </summary>
public record CambioEstado(
    string EstadoNuevo,
    string? CodigoSunat = null,
    string? Mensaje = null,
    string? RequestRaw = null,
    string? ResponseRaw = null,
    int? DuracionMs = null,
    string? Worker = null,
    string? Ticket = null);

/// <summary>
/// Dónde están los archivos de un comprobante.
///
/// Las rutas son RELATIVAS al almacén, no absolutas. Guardar rutas absolutas
/// ataría los datos a la máquina que los escribió: al mudar de servidor, o
/// al pasar de disco a S3, todas dejarían de servir.
/// </summary>
public record ArchivosComprobante(
    string Numero,
    string TipoComprobante,
    string Estado,
    string? RutaXml,
    string? RutaCdr,
    string? RutaPdf)
{
    /// <summary>Nombre con el que se ofrece la descarga al usuario.</summary>
    public string NombreDescarga(string extension) =>
        $"{Numero}.{extension}";
}

/// <summary>
/// Lo necesario para reconstruir el PDF de un comprobante.
///
/// El PDF no se guarda en el almacén: se genera cuando alguien lo pide. Es el
/// archivo más pesado de los tres y el único que se puede rehacer a partir de
/// lo que ya está en la base.
/// </summary>
public record DatosParaPdf(
    string Numero,
    string TipoComprobante,
    string Estado,
    string? CodigoSunat,
    string? MensajeSunat,
    string CpeJson,
    string? RutaXml,

    // La columna `extra` del comprobante, tal como está en la base.
    //
    // Son campos propios de la empresa —la orden de compra es el caso
    // típico— que el estándar de SUNAT no contempla y que NUNCA viajan en
    // el XML. El papel es el único sitio donde el cliente puede leerlos.
    //
    // SI SE AÑADE O SE QUITA UN CAMPO DE ESTE RECORD, hay que tocar también
    // la consulta de ObtenerParaPdfAsync: Dapper busca un constructor que
    // encaje con TODAS las columnas devueltas, y si no lo encuentra falla al
    // pedir el PDF, no al compilar.
    string? ExtraJson,

    // Dónde está el logo de la empresa en el almacén (tenants.logo_ruta,
    // migración 020). Null si no tiene: el PDF sale sin logo, como antes.
    string? LogoRuta);
'@

# --- Facturacion.Persistencia\RepositorioComprobantes.cs
Planear 'Facturacion.Persistencia\RepositorioComprobantes.cs' 'AA13E588EA0172A8B01D07C835551D3A00A4F72768569FA25ADA83618EE41F0B' @'
using System.Text.Json;
using Dapper;
using Facturacion.Cpe;

namespace Facturacion.Persistencia;

/// <summary>
/// Guarda y consulta comprobantes.
///
/// TODO lo que hace pasa por SesionTenant, así que Row Level Security está
/// siempre activo: no existe una ruta para leer o escribir sin declarar de
/// qué empresa se trata.
/// </summary>
public sealed class RepositorioComprobantes
{
    private static readonly JsonSerializerOptions OpcionesJson = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        WriteIndented = false
    };

    private readonly FabricaSesiones _sesiones;

    public RepositorioComprobantes(FabricaSesiones sesiones)
    {
        _sesiones = sesiones ?? throw new ArgumentNullException(nameof(sesiones));
    }

    /// <summary>
    /// Crea un comprobante, asignándole el correlativo que corresponda.
    ///
    /// EL COMPROBANTE ENTRA SIN CORRELATIVO. Lo asigna la base, no el llamador:
    /// permitir que venga desde afuera abriría la puerta a duplicados y saltos.
    ///
    /// Todo ocurre en una sola transacción:
    ///   1. Si hay clave de idempotencia y ya se usó, devuelve el original.
    ///   2. Reserva el siguiente correlativo de la serie.
    ///   3. Inserta el comprobante.
    ///   4. Escribe el primer asiento de la bitácora.
    ///
    /// Si algo falla, nada de eso queda: ni un correlativo quemado ni una
    /// fila a medias.
    /// </summary>
    public async Task<ComprobanteGuardado> CrearAsync(
        Guid tenantId,
        ComprobanteBase comprobante,
        string? extraJson = null,
        string? idempotencyKey = null,
        string? correoReceptor = null,
        CancellationToken ct = default)
    {
        ArgumentNullException.ThrowIfNull(comprobante);

        // HAY COMPROBANTES QUE NO TIENEN LÍNEAS, Y ESTÁ BIEN.
        //
        // El de retención y el de percepción no venden nada: su detalle son
        // las facturas de otro sobre las que se retuvo o percibió. Exigirles
        // líneas de producto sería exigirles algo que el documento no tiene.
        //
        // Se reconocen por la interfaz y no por el tipo, para que el día que
        // aparezca el cuarto documento sin líneas no haya que volver aquí.
        if (comprobante.Lineas.Count == 0 && comprobante is not IComprobanteSinLineas)
            throw new ArgumentException(
                "El comprobante no tiene líneas.", nameof(comprobante));

        await using var sesion = await _sesiones.AbrirAsync(tenantId, ct);

        // --- 1. Idempotencia --------------------------------------------------
        // Un doble clic del usuario, o un reintento del cliente tras un timeout,
        // no deben producir dos comprobantes. Se comprueba ANTES de reservar
        // correlativo: si no, cada reintento quemaría un número.

        if (!string.IsNullOrWhiteSpace(idempotencyKey))
        {
            var existente = await sesion.Conexion.QuerySingleOrDefaultAsync<ComprobanteGuardado?>(
                new CommandDefinition(
                    """
                    SELECT id               AS "Id",
                           tenant_id        AS "TenantId",
                           tipo_comprobante AS "TipoComprobante",
                           serie            AS "Serie",
                           correlativo      AS "Correlativo",
                           estado           AS "Estado",
                           importe_total    AS "ImporteTotal",
                           true             AS "YaExistia"
                      FROM comprobantes
                     WHERE tenant_id = @tenantId
                       AND idempotency_key = @idempotencyKey
                    """,
                    new { tenantId, idempotencyKey },
                    sesion.Transaccion, cancellationToken: ct));

            if (existente is not null)
            {
                await sesion.ConfirmarAsync(ct);
                return existente;
            }
        }

        // --- 2. Reservar el correlativo ---------------------------------------
        //
        // UPDATE ... RETURNING en una sola sentencia.
        //
        // POR QUÉ ASÍ Y NO CON MAX(correlativo) + 1: entre leer el máximo y
        // escribir el nuevo valor hay una ventana en la que otra transacción
        // puede leer el mismo número. Bajo carga eso pasa, y produce el error
        // más caro del sistema: dos comprobantes con el mismo número.
        //
        // El UPDATE toma el candado de la fila por sí mismo. Una transacción
        // simultánea sobre la misma serie espera hasta que esta confirme, y
        // entonces lee el valor ya incrementado. Sin ventana.

        var correlativo = await sesion.Conexion.ExecuteScalarAsync<int?>(
            new CommandDefinition(
                """
                UPDATE series
                   SET ultimo_correlativo = ultimo_correlativo + 1
                 WHERE tenant_id = @tenantId
                   AND tipo_comprobante = @tipo
                   AND serie = @serie
                   AND activo
                RETURNING ultimo_correlativo
                """,
                new
                {
                    tenantId,
                    tipo = comprobante.TipoComprobante,
                    serie = comprobante.Serie
                },
                sesion.Transaccion, cancellationToken: ct));

        if (correlativo is null)
            throw new InvalidOperationException(
                $"No existe la serie {comprobante.Serie} para el tipo " +
                $"{comprobante.TipoComprobante}, o está inactiva. " +
                "Hay que darla de alta antes de emitir.");

        comprobante.Correlativo = correlativo.Value;

        // --- 3. Insertar el comprobante ---------------------------------------

        // EL IMPORTE DE UNA LIQUIDACIÓN NO SE CALCULA COMO EL DE UNA FACTURA.
        //
        // En una factura el importe total es lo que el CLIENTE PAGA: valor de
        // venta más impuestos. En una liquidación de compra es lo que el
        // VENDEDOR COBRA, que es el valor de compra menos el IGV —que asume
        // el comprador como crédito fiscal— menos la retención de renta.
        //
        // Son dos números distintos y la diferencia es grande: en una compra
        // de 6 000 soles, 7 080 contra 5 910. Usar aquí CalculadoraTotales
        // dejaría en la base, en el panel y en los listados un importe un 20%
        // más alto que el que de verdad se pagó.

        var importeTotal = comprobante switch
        {
            LiquidacionCompra liquidacion =>
                CalculadoraLiquidacion.Calcular(liquidacion).ImporteAPagar,

            // El importe de un comprobante de retención o percepción es lo
            // retenido o percibido, no lo pagado. Cada documento sabe cuál de
            // sus números lo representa.
            IComprobanteSinLineas sinLineas => sinLineas.ImporteDeclarado,

            _ => CalculadoraTotales.Calcular(comprobante).ImporteTotal
        };

        var cpeJson = JsonSerializer.Serialize(
            comprobante, comprobante.GetType(), OpcionesJson);

        var id = await sesion.Conexion.ExecuteScalarAsync<Guid>(
            new CommandDefinition(
                """
                INSERT INTO comprobantes
                    (tenant_id, tipo_comprobante, serie, correlativo,
                     fecha_emision, moneda, importe_total, estado,
                     cpe, extra, idempotency_key, correo_receptor)
                VALUES
                    (@tenantId, @tipo, @serie, @correlativo,
                     @fechaEmision, @moneda, @importeTotal, @estado,
                     CAST(@cpe AS jsonb), CAST(@extra AS jsonb), @idempotencyKey,
                     @correoReceptor)
                RETURNING id
                """,
                new
                {
                    tenantId,
                    tipo = comprobante.TipoComprobante,
                    serie = comprobante.Serie,
                    correlativo = correlativo.Value,
                    fechaEmision = DateOnly.FromDateTime(comprobante.FechaEmision),
                    moneda = comprobante.Moneda,
                    importeTotal,
                    estado = EstadoCpe.Borrador,
                    cpe = cpeJson,
                    extra = string.IsNullOrWhiteSpace(extraJson) ? "{}" : extraJson,
                    idempotencyKey,

                    // Fuera del `cpe` a propósito: no es tributario y no se firma.
                    correoReceptor = string.IsNullOrWhiteSpace(correoReceptor)
                        ? null
                        : correoReceptor.Trim()
                },
                sesion.Transaccion, cancellationToken: ct));

        // --- 4. Primer asiento de la bitácora ---------------------------------

        await InsertarIntentoAsync(
            sesion, tenantId, id, 1, null,
            new CambioEstado(EstadoCpe.Borrador, Mensaje: "Comprobante creado."),
            ct);

        await sesion.ConfirmarAsync(ct);

        return new ComprobanteGuardado(
            id, tenantId,
            comprobante.TipoComprobante, comprobante.Serie, correlativo.Value,
            EstadoCpe.Borrador, importeTotal, YaExistia: false);
    }

    /// <summary>
    /// Registra un cambio de estado y su asiento en la bitácora.
    ///
    /// Las dos cosas van juntas a propósito: un estado que cambia sin dejar
    /// rastro es exactamente lo que no se puede explicar cuando un cliente
    /// pregunta qué pasó con su factura de hace tres meses.
    /// </summary>
    public async Task RegistrarCambioAsync(
        Guid tenantId,
        Guid comprobanteId,
        CambioEstado cambio,
        CancellationToken ct = default)
    {
        ArgumentNullException.ThrowIfNull(cambio);

        await using var sesion = await _sesiones.AbrirAsync(tenantId, ct);

        var anterior = await sesion.Conexion.QuerySingleOrDefaultAsync<string>(
            new CommandDefinition(
                "SELECT estado FROM comprobantes WHERE id = @comprobanteId FOR UPDATE",
                new { comprobanteId },
                sesion.Transaccion, cancellationToken: ct));

        if (anterior is null)
            throw new InvalidOperationException(
                $"No existe el comprobante {comprobanteId} para este tenant.");

        var intentoNro = await sesion.Conexion.ExecuteScalarAsync<short>(
            new CommandDefinition(
                """
                SELECT COALESCE(MAX(intento_nro), 0) + 1
                  FROM envio_intentos
                 WHERE comprobante_id = @comprobanteId
                """,
                new { comprobanteId },
                sesion.Transaccion, cancellationToken: ct));

        await sesion.Conexion.ExecuteAsync(new CommandDefinition(
            """
            UPDATE comprobantes
               SET estado        = @estado,
                   codigo_sunat  = COALESCE(@codigoSunat, codigo_sunat),
                   mensaje_sunat = COALESCE(@mensaje, mensaje_sunat),
                   ticket        = COALESCE(@ticket, ticket)
             WHERE id = @comprobanteId
            """,
            new
            {
                comprobanteId,
                estado = cambio.EstadoNuevo,
                codigoSunat = cambio.CodigoSunat,
                mensaje = cambio.Mensaje,
                ticket = cambio.Ticket
            },
            sesion.Transaccion, cancellationToken: ct));

        await InsertarIntentoAsync(
            sesion, tenantId, comprobanteId, intentoNro, anterior, cambio, ct);

        await sesion.ConfirmarAsync(ct);
    }

    /// <summary>Guarda las rutas de los archivos generados.</summary>
    public async Task GuardarRutasAsync(
        Guid tenantId,
        Guid comprobanteId,
        string? rutaXml = null,
        string? rutaCdr = null,
        string? rutaPdf = null,
        string? hashCpe = null,
        CancellationToken ct = default)
    {
        await using var sesion = await _sesiones.AbrirAsync(tenantId, ct);

        await sesion.Conexion.ExecuteAsync(new CommandDefinition(
            """
            UPDATE comprobantes
               SET ruta_xml = COALESCE(@rutaXml, ruta_xml),
                   ruta_cdr = COALESCE(@rutaCdr, ruta_cdr),
                   ruta_pdf = COALESCE(@rutaPdf, ruta_pdf),
                   hash_cpe = COALESCE(@hashCpe, hash_cpe)
             WHERE id = @comprobanteId
            """,
            new { comprobanteId, rutaXml, rutaCdr, rutaPdf, hashCpe },
            sesion.Transaccion, cancellationToken: ct));

        await sesion.ConfirmarAsync(ct);
    }

    public async Task<ResumenComprobante?> ObtenerAsync(
        Guid tenantId, Guid comprobanteId, CancellationToken ct = default)
    {
        await using var sesion = await _sesiones.AbrirAsync(tenantId, ct);

        var fila = await sesion.Conexion.QuerySingleOrDefaultAsync<ResumenComprobante?>(
            new CommandDefinition(ConsultaResumen + " WHERE id = @comprobanteId",
                new { comprobanteId },
                sesion.Transaccion, cancellationToken: ct));

        await sesion.ConfirmarAsync(ct);
        return fila;
    }

    public async Task<IReadOnlyList<ResumenComprobante>> ListarAsync(
        Guid tenantId, int limite = 50, CancellationToken ct = default)
    {
        await using var sesion = await _sesiones.AbrirAsync(tenantId, ct);

        var filas = await sesion.Conexion.QueryAsync<ResumenComprobante>(
            new CommandDefinition(
                ConsultaResumen + " ORDER BY creado_en DESC LIMIT @limite",
                new { limite },
                sesion.Transaccion, cancellationToken: ct));

        await sesion.ConfirmarAsync(ct);
        return filas.ToList();
    }

    /// <summary>Historial completo de intentos de un comprobante.</summary>
    public async Task<IReadOnlyList<IntentoEnvio>> HistorialAsync(
        Guid tenantId, Guid comprobanteId, CancellationToken ct = default)
    {
        await using var sesion = await _sesiones.AbrirAsync(tenantId, ct);

        var filas = await sesion.Conexion.QueryAsync<IntentoEnvio>(
            new CommandDefinition(
                """
                SELECT id              AS "Id",
                       comprobante_id  AS "ComprobanteId",
                       intento_nro     AS "IntentoNro",
                       estado_anterior AS "EstadoAnterior",
                       estado_nuevo    AS "EstadoNuevo",
                       codigo_sunat    AS "CodigoSunat",
                       mensaje         AS "Mensaje",
                       duracion_ms     AS "DuracionMs",
                       worker          AS "Worker",
                       creado_en       AS "CreadoEn"
                  FROM envio_intentos
                 WHERE comprobante_id = @comprobanteId
                 ORDER BY intento_nro
                """,
                new { comprobanteId },
                sesion.Transaccion, cancellationToken: ct));

        await sesion.ConfirmarAsync(ct);
        return filas.ToList();
    }

    /// <summary>
    /// Rutas de los archivos de un comprobante.
    ///
    /// Va por sesión de tenant, así que Row Level Security garantiza que
    /// nadie pueda pedir las rutas de otra empresa. Eso importa más de lo
    /// que parece: si este método no filtrara por tenant, bastaría adivinar
    /// un identificador para descargar la factura de un competidor.
    /// </summary>
    public async Task<ArchivosComprobante?> ObtenerRutasAsync(
        Guid tenantId, Guid comprobanteId, CancellationToken ct = default)
    {
        await using var sesion = await _sesiones.AbrirAsync(tenantId, ct);

        var fila = await sesion.Conexion.QuerySingleOrDefaultAsync<ArchivosComprobante?>(
            new CommandDefinition(
                """
                SELECT serie || '-' || lpad(correlativo::text, 8, '0') AS "Numero",
                       tipo_comprobante AS "TipoComprobante",
                       estado           AS "Estado",
                       ruta_xml         AS "RutaXml",
                       ruta_cdr         AS "RutaCdr",
                       ruta_pdf         AS "RutaPdf"
                  FROM comprobantes
                 WHERE id = @comprobanteId
                """,
                new { comprobanteId },
                sesion.Transaccion, cancellationToken: ct));

        await sesion.ConfirmarAsync(ct);
        return fila;
    }

    /// <summary>
    /// Busca un comprobante por su número. Devuelve null si no existe para
    /// este emisor.
    ///
    /// SE USA PARA VALIDAR LAS NOTAS antes de emitirlas: una nota que apunta
    /// a un comprobante inexistente la rechaza SUNAT, y para entonces ya
    /// quemaste un correlativo de la serie de notas. Comprobarlo aquí cuesta
    /// una consulta y evita ese desperdicio.
    /// </summary>
    public async Task<ResumenComprobante?> BuscarPorNumeroAsync(
        Guid tenantId,
        string tipoComprobante,
        string serie,
        int correlativo,
        CancellationToken ct = default)
    {
        await using var sesion = await _sesiones.AbrirAsync(tenantId, ct);

        var fila = await sesion.Conexion.QuerySingleOrDefaultAsync<ResumenComprobante?>(
            new CommandDefinition(
                ConsultaResumen + """
                 WHERE tipo_comprobante = @tipoComprobante
                   AND serie = @serie
                   AND correlativo = @correlativo
                """,
                new { tipoComprobante, serie, correlativo },
                sesion.Transaccion, cancellationToken: ct));

        await sesion.ConfirmarAsync(ct);
        return fila;
    }

    /// <summary>
    /// Todo lo necesario para regenerar el PDF de un comprobante.
    ///
    /// POR QUÉ EL PDF NO SE GUARDA:
    ///
    /// Es el 80% del peso del almacén y el único de los tres archivos que se
    /// puede reconstruir. El XML y el CDR son irreemplazables; el PDF sale del
    /// mismo cpe que ya está aquí.
    ///
    /// Con cien mil comprobantes diarios, guardarlo son más de dos terabytes
    /// al año. Generarlo cuando alguien lo pide reduce eso a menos de la
    /// cuarta parte, y cuesta unas décimas de segundo.
    /// </summary>
    public async Task<DatosParaPdf?> ObtenerParaPdfAsync(
        Guid tenantId, Guid comprobanteId, CancellationToken ct = default)
    {
        await using var sesion = await _sesiones.AbrirAsync(tenantId, ct);

        var fila = await sesion.Conexion.QuerySingleOrDefaultAsync<DatosParaPdf?>(
            new CommandDefinition(
                """
                SELECT serie || '-' || lpad(correlativo::text, 8, '0') AS "Numero",
                       tipo_comprobante AS "TipoComprobante",
                       estado           AS "Estado",
                       codigo_sunat     AS "CodigoSunat",
                       mensaje_sunat    AS "MensajeSunat",
                       cpe::text        AS "CpeJson",
                       ruta_xml         AS "RutaXml",
                       extra::text      AS "ExtraJson",

                       -- tenants no tiene RLS y facturacion_app puede
                       -- leerla. El filtro por tenant ya lo puso la fila
                       -- de comprobantes, que sí lo tiene.
                       (SELECT t.logo_ruta FROM tenants t
                         WHERE t.id = comprobantes.tenant_id) AS "LogoRuta"
                  FROM comprobantes
                 WHERE id = @comprobanteId
                """,
                new { comprobanteId },
                sesion.Transaccion, cancellationToken: ct));

        await sesion.ConfirmarAsync(ct);
        return fila;
    }

    /// <summary>
    /// Da de alta una serie si no existe. Pensado para el arranque y las
    /// pruebas; en producción esto lo hace el panel de administración.
    /// </summary>
    public async Task AsegurarSerieAsync(
        Guid tenantId,
        string tipoComprobante,
        string serie,
        CancellationToken ct = default)
    {
        await using var sesion = await _sesiones.AbrirAsync(tenantId, ct);

        await sesion.Conexion.ExecuteAsync(new CommandDefinition(
            """
            INSERT INTO series (tenant_id, tipo_comprobante, serie)
            VALUES (@tenantId, @tipo, @serie)
            ON CONFLICT (tenant_id, tipo_comprobante, serie) DO NOTHING
            """,
            new { tenantId, tipo = tipoComprobante, serie },
            sesion.Transaccion, cancellationToken: ct));

        await sesion.ConfirmarAsync(ct);
    }

    // ------------------------------------------------------------------ interno

    private const string ConsultaResumen =
        """
        SELECT id               AS "Id",
               tipo_comprobante AS "TipoComprobante",
               serie            AS "Serie",
               correlativo      AS "Correlativo",
               fecha_emision    AS "FechaEmision",
               moneda           AS "Moneda",
               importe_total    AS "ImporteTotal",
               estado           AS "Estado",
               codigo_sunat     AS "CodigoSunat",
               mensaje_sunat    AS "MensajeSunat",
               ticket           AS "Ticket",
               creado_en        AS "CreadoEn"
          FROM comprobantes
        """;

    private static Task InsertarIntentoAsync(
        SesionTenant sesion,
        Guid tenantId,
        Guid comprobanteId,
        short intentoNro,
        string? estadoAnterior,
        CambioEstado cambio,
        CancellationToken ct) =>
        sesion.Conexion.ExecuteAsync(new CommandDefinition(
            """
            INSERT INTO envio_intentos
                (tenant_id, comprobante_id, intento_nro,
                 estado_anterior, estado_nuevo,
                 codigo_sunat, mensaje, request_raw, response_raw,
                 duracion_ms, worker)
            VALUES
                (@tenantId, @comprobanteId, @intentoNro,
                 @estadoAnterior, @estadoNuevo,
                 @codigoSunat, @mensaje, @requestRaw, @responseRaw,
                 @duracionMs, @worker)
            """,
            new
            {
                tenantId,
                comprobanteId,
                intentoNro,
                estadoAnterior,
                estadoNuevo = cambio.EstadoNuevo,
                codigoSunat = cambio.CodigoSunat,
                mensaje = cambio.Mensaje,
                requestRaw = cambio.RequestRaw,
                responseRaw = cambio.ResponseRaw,
                duracionMs = cambio.DuracionMs,
                worker = cambio.Worker ?? Environment.MachineName
            },
            sesion.Transaccion, cancellationToken: ct));

    private static Task InsertarIntentoAsync(
        SesionTenant sesion, Guid tenantId, Guid comprobanteId,
        int intentoNro, string? estadoAnterior, CambioEstado cambio,
        CancellationToken ct) =>
        InsertarIntentoAsync(
            sesion, tenantId, comprobanteId, (short)intentoNro,
            estadoAnterior, cambio, ct);
}
'@

# --- migraciones\020_marca_empresa.sql
Planear 'migraciones\020_marca_empresa.sql' '' @'
-- ===========================================================================
-- 020 — La marca de cada empresa
--
-- POR QUÉ HACE FALTA:
--
-- El portal del receptor (comprobantes.reyban.pe/{empresa}) y el correo de
-- entrega tienen que verse DEL EMISOR, no de Reyban: su logo, su color, y
-- las respuestas del cliente tienen que llegarle a él. Nada de eso existía
-- en `tenants`.
--
--
-- LAS CUATRO COLUMNAS:
--
--   identificador     El {empresa} de la dirección pública. Minúsculas,
--                     dígitos y guiones, 3 a 40 caracteres, único.
--                     NO SE PUEDE CAMBIAR UNA VEZ PUESTO: es la dirección
--                     que va impresa en cada correo enviado. Cambiarla
--                     rompería todos los enlaces que ya están en bandejas de
--                     entrada. Lo impide el disparador de abajo, no la buena
--                     voluntad del panel.
--
--   logo_ruta         Dónde está el logo en el almacén de archivos (el mismo
--                     de los XML). Cada logo nuevo es un archivo nuevo: el
--                     anterior no se borra, solo deja de apuntarse.
--
--   color_marca       #rrggbb en minúsculas. Un solo color.
--
--   correo_respuesta  A dónde van las respuestas a los correos de entrega.
--
--
-- LAS COMPROBACIONES DE LA BASE SON LA ÚLTIMA BARRERA. Las que devuelven un
-- mensaje que se entiende están en la API (Facturacion.Api/Marca.cs). Aquí
-- se ataja lo que nunca puede ser válido, venga de donde venga.
--
-- No necesita GRANT nuevo: los permisos sobre `tenants` son de tabla entera
-- e incluyen las columnas que se añadan.
-- ===========================================================================

BEGIN;

ALTER TABLE tenants ADD COLUMN IF NOT EXISTS identificador    text;
ALTER TABLE tenants ADD COLUMN IF NOT EXISTS logo_ruta        text;
ALTER TABLE tenants ADD COLUMN IF NOT EXISTS color_marca      text;
ALTER TABLE tenants ADD COLUMN IF NOT EXISTS correo_respuesta text;

ALTER TABLE tenants DROP CONSTRAINT IF EXISTS ck_tenants_identificador;
ALTER TABLE tenants ADD CONSTRAINT ck_tenants_identificador
    CHECK (
        identificador IS NULL OR (
            identificador ~ '^[a-z0-9][a-z0-9-]{1,38}[a-z0-9]$'
            AND identificador !~ '--'
            -- Palabras que ya usa o usará la dirección del portal.
            AND identificador NOT IN ('api', 'e', 'portal', 'admin', 'www',
                                      'static', 'assets', 'health', 'docs')
        )
    );

ALTER TABLE tenants DROP CONSTRAINT IF EXISTS ck_tenants_color_marca;
ALTER TABLE tenants ADD CONSTRAINT ck_tenants_color_marca
    CHECK (color_marca IS NULL OR color_marca ~ '^#[0-9a-f]{6}$');

ALTER TABLE tenants DROP CONSTRAINT IF EXISTS ck_tenants_correo_respuesta;
ALTER TABLE tenants ADD CONSTRAINT ck_tenants_correo_respuesta
    CHECK (
        correo_respuesta IS NULL OR (
            length(correo_respuesta) BETWEEN 3 AND 254
            AND correo_respuesta !~ '\s'
            AND position('@' IN correo_respuesta) > 1
        )
    );

ALTER TABLE tenants DROP CONSTRAINT IF EXISTS ck_tenants_logo_ruta;
ALTER TABLE tenants ADD CONSTRAINT ck_tenants_logo_ruta
    CHECK (logo_ruta IS NULL OR length(logo_ruta) BETWEEN 1 AND 500);

-- Único entre las que lo tienen. Las empresas antiguas sin identificador
-- pueden ser muchas: NULL no choca con NULL.
CREATE UNIQUE INDEX IF NOT EXISTS ux_tenants_identificador
    ON tenants (identificador)
    WHERE identificador IS NOT NULL;

-- El identificador se puede poner una vez y ya no se toca: ni cambiarlo ni
-- quitarlo. Los mensajes van sin tildes porque PowerShell 5.1 manda este
-- archivo a psql en ASCII.
CREATE OR REPLACE FUNCTION tenants_identificador_inmutable()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF OLD.identificador IS NOT NULL
       AND NEW.identificador IS DISTINCT FROM OLD.identificador THEN
        RAISE EXCEPTION
            'El identificador del portal de la empresa % ya es "%" y no se puede cambiar.',
            OLD.ruc, OLD.identificador
            USING ERRCODE = 'P0001',
                  HINT = 'Es la direccion que va en los correos ya enviados.';
    END IF;

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS tr_tenants_identificador_inmutable ON tenants;

CREATE TRIGGER tr_tenants_identificador_inmutable
    BEFORE UPDATE OF identificador ON tenants
    FOR EACH ROW
    EXECUTE FUNCTION tenants_identificador_inmutable();

COMMENT ON COLUMN tenants.identificador IS
    'El {empresa} de comprobantes.reyban.pe/{empresa}. Unico. No se cambia una vez puesto.';
COMMENT ON COLUMN tenants.logo_ruta IS
    'Ruta del logo en el almacen de archivos. PNG o JPG, maximo 300 KB.';
COMMENT ON COLUMN tenants.color_marca IS
    'Color de la marca, #rrggbb en minusculas. Botones y cabecera del portal.';
COMMENT ON COLUMN tenants.correo_respuesta IS
    'Responder-a de los correos de entrega. Sin el, no se mandan correos.';

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
Write-Host 'FALTA APLICAR LA MIGRACIÓN 020 (este script NO la aplica). Desde esta carpeta:' -ForegroundColor Cyan
Write-Host ''
Write-Host '  Get-Content migraciones\020_marca_empresa.sql -Raw | docker compose exec -T postgres psql -U facturacion_owner -d facturacion -v ON_ERROR_STOP=1' -ForegroundColor White
Write-Host ''
Write-Host 'Tiene que terminar en COMMIT. Después, reinicia la API del servicio.' -ForegroundColor Cyan
Write-Host ''
