# =============================================================================
# Entrega 2026-10-12 - Fase 4c (1 de 2): el SERVICIO pausa al emisor y adjunta XML y CDR
#
# Se ejecuta desde la carpeta del SERVICIO (va ANTES que el de la plataforma):
#   D:\Reyban Consulting\facturacion electronica\facturacion_electronica_service
#   .\entrega-2026-10-12-fase4c-servicio.ps1
#
#   migraciones\028_pausa_de_emision.sql   NUEVO. tenants.emision_pausada_en.
#   Facturacion.Api\EndpointsConfiguracion.cs  + POST /v1/configuracion/pausa.
#   Facturacion.Api\Autenticacion.cs           emisor en pausa: solo GET (423 al resto).
#   Facturacion.Persistencia\RepositorioAdmin.cs  pausar y consultar la pausa.
#   Facturacion.Api\ServicioCorreosEntrega.cs   el correo del comprobante lleva
#        tambien el XML y el CDR (facturas y notas; la boleta, solo el PDF).
#   Facturacion.Persistencia\ServicioCorreo.cs  admite esos adjuntos.
#
# Todo o nada, con huellas y copia .bak. No pregunta nada.
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

# --- migraciones\028_pausa_de_emision.sql
Planear 'migraciones\028_pausa_de_emision.sql' '' @'
-- =============================================================================
-- 028 - PAUSA DE EMISION (fase 4c de la plataforma)
--
-- Cuando un contador quita una empresa de su cartera, la plataforma la deja
-- "en pausa". Hasta ahora eso solo cerraba la plataforma: la clave fac_ de la
-- empresa seguia pudiendo emitir desde fuera (otro sistema que la tuviera).
--
-- Con esto, la plataforma le pide al servicio que pause al emisor:
--   * mientras emision_pausada_en tenga fecha, la clave fac_ NO puede emitir
--     ni cambiar nada (todo lo que no sea GET responde 423);
--   * consultar y descargar (GET) siguen funcionando: el titular puede bajar
--     su XML y su CDR;
--   * al recuperar o reanudar la empresa, la plataforma la reactiva.
--
-- Nada se borra. Idempotente. Sin tildes a proposito: PowerShell 5.1 la manda
-- a psql en ASCII.
-- =============================================================================

BEGIN;

ALTER TABLE tenants ADD COLUMN IF NOT EXISTS emision_pausada_en timestamptz;
ALTER TABLE tenants ADD COLUMN IF NOT EXISTS motivo_pausa       text;

COMMENT ON COLUMN tenants.emision_pausada_en IS
    'Con fecha: la clave fac_ solo puede leer (GET). La pone y la quita la plataforma (POST /v1/configuracion/pausa).';

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                    WHERE table_name = 'tenants' AND column_name = 'emision_pausada_en') THEN
        RAISE EXCEPTION '028: no se creo la columna emision_pausada_en.';
    END IF;
    RAISE NOTICE '028: pausa de emision lista.';
END $$;

COMMIT;
'@

# --- Facturacion.Api\EndpointsConfiguracion.cs
Planear 'Facturacion.Api\EndpointsConfiguracion.cs' 'EDAC1E145E4EB550AE50AE87A5AAEAD790F13ABD96A0C5FC3E77837BBE3ED3B0' @'
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text.RegularExpressions;
using Facturacion.Persistencia;
using Microsoft.AspNetCore.Mvc;

namespace Facturacion.Api;

/// <summary>
/// LA CONFIGURACIÓN DEL EMISOR CON SU PROPIA CLAVE (fase 2, cartera-diseno.md).
///
/// Hasta hoy el certificado, las series, la marca y el usuario SOL solo se
/// ponían desde el panel (/admin), con la sesión del operador. Desde la fase 2
/// el cliente se configura solo, desde el asistente de la plataforma, y la
/// plataforma llama aquí con la clave fac_ de esa empresa.
///
///   POST /v1/configuracion/certificado          .pfx + contraseña (el RUC tiene que coincidir)
///   POST /v1/configuracion/certificado/prueba   uno de prueba, SOLO EN BETA
///   GET  /v1/configuracion/series               las series de la empresa
///   POST /v1/configuracion/series               dar de alta una serie
///   PUT  /v1/configuracion/marca                identificador, color, correo de respuesta, copia
///   POST /v1/configuracion/logo                 el logo (PNG o JPG)
///   PUT  /v1/configuracion/sol                  usuario SOL secundario y su clave
///
/// LA EMPRESA SALE DE LA CLAVE, NUNCA DEL CUERPO. Ninguna ruta lleva un id de
/// empresa: <see cref="ContextoEmisor"/> la da, y con ese id se llama a los
/// mismos métodos que usa el panel. Así las reglas son UNA sola: las mismas
/// validaciones de serie, de marca y de certificado que en el panel.
///
/// LO QUE NO ESTÁ AQUÍ, a propósito: cambiar el ambiente (pasar a producción
/// sigue siendo una decisión del operador), las claves de acceso y borrar
/// nada. Una clave fac_ filtrada ya podía emitir; con esto también podría
/// cambiar el certificado, y por eso cada llamada queda en la bitácora con el
/// prefijo de la clave.
/// </summary>
public static class EndpointsConfiguracion
{
    /// <summary>SUNAT numera con 8 dígitos.</summary>
    private const int CorrelativoMaximo = 99_999_999;

    /// <summary>Lo que lleva el certificado de prueba en su organización. Así se reconoce.</summary>
    public const string MarcaPrueba = "CERTIFICADO DE PRUEBA SIN VALOR";

    public static void MapearConfiguracion(this WebApplication app)
    {
        var grupo = app.MapGroup("/v1/configuracion")
            .WithTags("Configuración del emisor")
            .AddEndpointFilter(DejarRastro);

        // ---------------------------------------------------------- certificado

        grupo.MapPost("/certificado", async (
            IFormFile archivo,
            [FromForm] string? clave,
            [FromForm] bool? confirmado,
            ContextoEmisor emisor,
            AlmacenCertificados certificados,
            CancellationToken ct) =>
        {
            var tenant = emisor.Exigir();

            if (archivo.Length == 0)
                return Results.BadRequest(new RespuestaError("El archivo está vacío."));

            if (archivo.Length > 512 * 1024)
                return Results.BadRequest(new RespuestaError(
                    "El archivo es demasiado grande.",
                    "Un certificado .pfx pesa unos pocos kilobytes."));

            using var memoria = new MemoryStream();
            await archivo.CopyToAsync(memoria, ct);
            var bytes = memoria.ToArray();

            // SE ABRE AQUÍ PRIMERO, para mirar de quién es antes de guardar.
            // AlmacenCertificados lo vuelve a abrir y comprueba la llave privada
            // y el vencimiento.
            X509Certificate2 certificado;

            try
            {
                certificado = new X509Certificate2(bytes, clave ?? "", X509KeyStorageFlags.EphemeralKeySet);
            }
            catch (CryptographicException)
            {
                return Results.BadRequest(new RespuestaError(
                    "No se pudo abrir el certificado.",
                    "La contraseña no es la de este archivo, o el archivo no es un .pfx / .p12."));
            }

            using (certificado)
            {
                var coincide = MencionaRuc(certificado, tenant.Ruc);
                var titular = certificado.GetNameInfo(X509NameType.SimpleName, false);

                // EL RUC TIENE QUE COINCIDIR. Casi todas las certificadoras lo
                // ponen en el sujeto; si esta no, se pide confirmarlo, como el
                // correlativo de una serie.
                if (!coincide && confirmado != true)
                    return Results.UnprocessableEntity(new
                    {
                        error = $"Este certificado no menciona el RUC {tenant.Ruc}.",
                        detalle = $"Es de «{titular}». Con el certificado de otra empresa SUNAT rechaza " +
                                  "todo. Si estás seguro de que es el tuyo (algunas certificadoras ponen el " +
                                  "RUC en otro sitio), confírmalo.",
                        codigo = "ruc_no_coincide",
                        titular
                    });

                try
                {
                    var id = await certificados.GuardarAsync(tenant.Id, bytes, clave ?? "", ct);

                    return Results.Ok(new
                    {
                        id,
                        titular,
                        coincideRuc = coincide,
                        validoHasta = certificado.NotAfter.ToUniversalTime(),
                        prueba = certificado.Subject.Contains(MarcaPrueba, StringComparison.Ordinal),
                        mensaje = "Certificado guardado y cifrado. Reemplaza al anterior, si había."
                    });
                }
                catch (InvalidOperationException ex)
                {
                    // Sin llave privada o vencido: el mensaje ya dice cuál.
                    return Results.BadRequest(new RespuestaError("No se pudo guardar el certificado.", ex.Message));
                }
            }
        })
        .DisableAntiforgery()
        .WithSummary("Carga el certificado digital de la empresa de la clave")
        .WithDescription(
            "Multipart: archivo (.pfx/.p12) y clave. Si el certificado no menciona el RUC de la " +
            "empresa responde 422 (codigo ruc_no_coincide) y hay que repetir con confirmado=true. " +
            "Reemplaza al activo, que queda desactivado (no se borra).");

        grupo.MapPost("/certificado/prueba", async (
            ContextoEmisor emisor, AlmacenCertificados certificados, CancellationToken ct) =>
        {
            var tenant = emisor.Exigir();

            // SOLO EN BETA. En producción SUNAT rechazaría todo lo firmado con
            // él, y la empresa dejaría de facturar sin saber por qué.
            if (tenant.EsProduccion)
                return Results.Conflict(new RespuestaError(
                    "El certificado de prueba solo se puede usar en beta.",
                    "Esta empresa ya emite en producción: necesita su certificado real."));

            // NO PISA UNO REAL. Si ya cargó el suyo, el de prueba lo sustituiría
            // y nadie se daría cuenta hasta pasar a producción.
            var activo = (await certificados.ListarAsync(tenant.Id, ct)).FirstOrDefault(c => c.Activo);

            if (activo is not null && !activo.Subject.Contains(MarcaPrueba, StringComparison.Ordinal))
                return Results.Conflict(new RespuestaError(
                    "Ya tienes tu certificado real cargado.",
                    "No se reemplaza por uno de prueba. Si quieres cambiarlo, sube otro .pfx."));

            var (pfx, clave, validoHasta) = CrearCertificadoDePrueba(tenant.Ruc, tenant.RazonSocial);
            var id = await certificados.GuardarAsync(tenant.Id, pfx, clave, ct);

            return Results.Ok(new
            {
                id,
                titular = $"PRUEBA {tenant.RazonSocial}",
                coincideRuc = true,
                validoHasta,
                prueba = true,
                mensaje = "Certificado de prueba listo. Sirve solo en beta: para producción hace falta el real."
            });
        })
        .WithSummary("Genera y carga un certificado de prueba (solo beta)")
        .WithDescription(
            "Autofirmado, con el RUC de la empresa, válido un año. SUNAT beta lo acepta; producción no. " +
            "409 si la empresa está en producción o si ya tiene un certificado real.");

        // --------------------------------------------------------------- series

        grupo.MapGet("/series", async (
            ContextoEmisor emisor, RepositorioAdmin admin, CancellationToken ct) =>
            Results.Ok(await admin.ListarSeriesAsync(emisor.Exigir().Id, ct)))
            .WithSummary("Las series de la empresa de la clave");

        grupo.MapPost("/series", async (
            SerieDesdePlataforma nueva, ContextoEmisor emisor,
            RepositorioAdmin admin, CancellationToken ct) =>
        {
            var tenant = emisor.Exigir();
            var tipo = nueva.TipoComprobante?.Trim() ?? "";
            var serie = nueva.Serie?.Trim().ToUpperInvariant() ?? "";

            if (ProblemaSerie(tipo, serie) is { } problema)
                return Results.BadRequest(new RespuestaError("Serie inválida.", problema));

            if (nueva.UltimoCorrelativo is < 0 or > CorrelativoMaximo)
                return Results.BadRequest(new RespuestaError(
                    "Último número inválido.",
                    $"Va de 0 a {CorrelativoMaximo}. Si nunca emitiste con esta serie, es 0."));

            // Empezar en un número distinto de 0 es afirmar que la 1 a la N ya
            // existen en SUNAT. Se confirma, igual que en el panel.
            if (nueva.UltimoCorrelativo > 0 && !nueva.Confirmado)
                return Results.UnprocessableEntity(new
                {
                    error = $"Confirma que la {serie} empieza en la {nueva.UltimoCorrelativo + 1}.",
                    detalle = $"La primera saldrá {Numero(serie, nueva.UltimoCorrelativo + 1)}: la 1 a la " +
                              $"{nueva.UltimoCorrelativo} ya se emitieron en otro sistema. Si nunca emitiste " +
                              "con esta serie, pon 0.",
                    codigo = "confirmar_correlativo"
                });

            var quien = "plataforma: " + Recortar(string.IsNullOrWhiteSpace(nueva.Actor) ? "sin nombre" : nueva.Actor.Trim(), 200);

            var alta = await admin.CrearSerieAsync(
                tenant.Id, tipo, serie, nueva.UltimoCorrelativo, null, quien, ct);

            if (alta.Existente is { } e)
                return Results.Conflict(new
                {
                    error = $"La serie {serie} ya existe. No se creó otra.",
                    detalle = $"Va en la {e.UltimoCorrelativo} (la siguiente sería " +
                              $"{Numero(serie, e.UltimoCorrelativo + 1)}). " +
                              "Si emitiste fuera de aquí con ella, pide que la ajusten.",
                    codigo = "serie_existente"
                });

            return Results.Ok(new
            {
                id = alta.Id,
                siguiente = Numero(serie, nueva.UltimoCorrelativo + 1),
                mensaje = $"Serie {serie} lista. La primera saldrá {Numero(serie, nueva.UltimoCorrelativo + 1)}."
            });
        })
        .WithSummary("Da de alta una serie de la empresa de la clave")
        .WithDescription(
            "Tipos 01 (F…), 03 (B…), 07 y 08 (F… o B…). Último número distinto de 0 → hay que mandar " +
            "confirmado=true (si no, 422). Si la serie ya existe, 409 y no se toca. Las altas con " +
            "número inicial quedan en la bitácora de correlativos.");

        // ---------------------------------------------------------------- marca

        grupo.MapPut("/marca", async (
            MarcaDesdePlataforma cambio, ContextoEmisor emisor,
            RepositorioAdmin admin, CancellationToken ct) =>
        {
            var tenant = emisor.Exigir();

            var identificador = Marca.LimpiarIdentificador(cambio.Identificador);
            var color = Marca.LimpiarColor(cambio.ColorMarca);
            var correo = Marca.LimpiarCorreo(cambio.CorreoRespuesta);

            if (Marca.ProblemaIdentificador(identificador) is { } pi)
                return Results.BadRequest(new RespuestaError("La dirección de tu página no es válida.", pi));

            if (Marca.ProblemaColor(color) is { } pc)
                return Results.BadRequest(new RespuestaError("El color no es válido.", pc));

            if (Marca.ProblemaCorreo(correo) is { } pr)
                return Results.BadRequest(new RespuestaError("El correo para respuestas no es válido.", pr));

            try
            {
                var (resultado, actual) = await admin.GuardarMarcaAsync(
                    tenant.Id, identificador, color, correo, cambio.CopiaAlEmisor ?? false, ct);

                return resultado switch
                {
                    ResultadoMarca.IdentificadorFijo => Results.Conflict(new RespuestaError(
                        "La dirección de tu página ya está puesta y no se cambia.",
                        $"Es «{actual}»: va en los correos ya enviados. No se guardó nada.")),

                    ResultadoMarca.NoExiste => Results.NotFound(new RespuestaError("No se encontró la empresa.")),

                    _ => Results.Ok(new { mensaje = "Correo y marca guardados.", identificador = actual })
                };
            }
            catch (Npgsql.PostgresException ex) when (
                ex.SqlState == "23505" && ex.ConstraintName == "ux_tenants_identificador")
            {
                return Results.Conflict(new RespuestaError(
                    "Esa dirección ya la usa otra empresa.",
                    $"«{identificador}» está tomada. Prueba agregando la ciudad, por ejemplo " +
                    $"{identificador}-lima."));
            }
        })
        .WithSummary("Guarda el identificador del portal, el color, el correo de respuesta y la copia")
        .WithDescription(
            "Los cuatro campos cada vez: color y correo se reemplazan (vacío los quita). El " +
            "identificador se pone una sola vez; si ya hay otro, 409 y no se guarda nada.");

        grupo.MapPost("/logo", async (
            IFormFile archivo, ContextoEmisor emisor,
            RepositorioAdmin admin, IAlmacenArchivos archivos, CancellationToken ct) =>
        {
            var tenant = emisor.Exigir();

            if (archivo.Length == 0)
                return Results.BadRequest(new RespuestaError("El archivo está vacío."));

            if (archivo.Length > Marca.LogoMaximoBytes)
                return Results.BadRequest(new RespuestaError(
                    "El logo es demasiado grande.",
                    $"Pesa {archivo.Length / 1024} KB y el máximo es {Marca.LogoMaximoBytes / 1024} KB."));

            using var memoria = new MemoryStream();
            await archivo.CopyToAsync(memoria, ct);
            var datos = memoria.ToArray();

            if (Marca.TipoDeImagen(datos) is not { } tipo)
                return Results.BadRequest(new RespuestaError(
                    "El logo tiene que ser PNG o JPG.",
                    "Se mira el contenido del archivo, no su nombre."));

            if (Marca.ProblemaAlDibujar(datos) is { } problema)
                return Results.BadRequest(new RespuestaError("No se puede usar ese logo.", problema));

            var huella = Convert.ToHexString(SHA256.HashData(datos))[..16].ToLowerInvariant();

            var ruta = await archivos.GuardarAsync(
                tenant.Ruc, DateTime.UtcNow, $"logo-{huella}.{tipo.Extension}", datos, ct);

            await admin.GuardarLogoAsync(tenant.Id, ruta, ct);

            return Results.Ok(new { mensaje = "Logo guardado. Ya sale en los PDF y en los correos." });
        })
        .DisableAntiforgery()
        .WithSummary("Sube el logo de la empresa de la clave")
        .WithDescription("PNG o JPG. El anterior no se borra del almacén: solo deja de usarse.");

        // ------------------------------------------------------------------ SOL

        grupo.MapPut("/sol", async (
            SolDesdePlataforma sol, ContextoEmisor emisor,
            RepositorioAdmin admin, IProtectorDeSecretos protector, CancellationToken ct) =>
        {
            var tenant = emisor.Exigir();
            var usuario = sol.Usuario?.Trim().ToUpperInvariant() ?? "";

            // Si pegan el RUC delante (20610878564FACTURA1), se quita: el
            // servicio lo pone solo al hablar con SUNAT.
            if (usuario.StartsWith(tenant.Ruc, StringComparison.Ordinal))
                usuario = usuario[tenant.Ruc.Length..];

            if (usuario.Equals("MODDATOS", StringComparison.Ordinal))
                return Results.BadRequest(new RespuestaError(
                    "MODDATOS es el usuario de pruebas de SUNAT.",
                    "Aquí va tu usuario SOL secundario, el que creaste para enviar comprobantes."));

            if (!UsuarioSol().IsMatch(usuario))
                return Results.BadRequest(new RespuestaError(
                    "El usuario SOL no es válido.",
                    "Solo letras y números, de 3 a 12. Ej.: FACTURA1 (sin el RUC delante)."));

            if (string.IsNullOrWhiteSpace(sol.Clave) || sol.Clave.Length > 100)
                return Results.BadRequest(new RespuestaError("Falta la clave SOL de ese usuario."));

            var guardadas = await admin.GuardarCredencialesSolAsync(tenant.Id, usuario, sol.Clave, protector, ct);

            return guardadas
                ? Results.Ok(new
                {
                    usuario,
                    mensaje = "Usuario SOL guardado y cifrado. Se usa cuando pases a producción."
                })
                : Results.NotFound(new RespuestaError("No se encontró la empresa."));
        })
        .WithSummary("Guarda el usuario SOL secundario y su clave")
        .WithDescription(
            "Solo el usuario (FACTURA1): el RUC lo pone el servicio. La clave se cifra. Nunca el " +
            "usuario SOL principal.");


        // =====================================================================
        // PAUSA DE EMISIÓN (fase 4c, migración 028)
        //
        // La plataforma la pone cuando un contador quita la empresa de su
        // cartera, y la quita cuando el titular la recupera o se reanuda.
        // Mientras dure, esta clave solo puede LEER: el middleware de
        // autenticación responde 423 a todo lo que no sea GET, salvo a esta
        // misma ruta (si no, no se podría quitar).
        // =====================================================================
        grupo.MapPost("/pausa", async (
            PausaDesdePlataforma p, ContextoEmisor emisor, RepositorioAdmin admin, CancellationToken ct) =>
        {
            var tenant = emisor.Exigir();
            var motivo = p.Motivo?.Trim();
            if (motivo is { Length: > 500 }) motivo = motivo[..500];

            await admin.PausarEmisionAsync(tenant.Id, p.Pausar, motivo, ct);

            return Results.Ok(new
            {
                pausada = p.Pausar,
                mensaje = p.Pausar
                    ? "Emisión en pausa: esta clave solo puede consultar y descargar."
                    : "Emisión reactivada."
            });
        })
        .WithSummary("Pausa o reactiva la emisión de esta empresa")
        .WithDescription("Con la pausa puesta, la clave fac_ solo puede hacer GET (consultar y descargar).");
    }

    // =========================================================================

    /// <summary>
    /// Cada llamada a la bitácora del panel: qué clave (su prefijo), qué ruta,
    /// qué empresa y cómo terminó. Nunca el cuerpo: lleva contraseñas.
    /// </summary>
    private static async ValueTask<object?> DejarRastro(
        EndpointFilterInvocationContext contexto, EndpointFilterDelegate siguiente)
    {
        var resultado = await siguiente(contexto);
        var http = contexto.HttpContext;

        try
        {
            var emisor = http.RequestServices.GetRequiredService<ContextoEmisor>();

            if (!HttpMethods.IsGet(http.Request.Method) && emisor.Tenant is { } tenant)
            {
                var codigo = resultado is IStatusCodeHttpResult { StatusCode: { } c } ? c : 200;

                await http.RequestServices.GetRequiredService<RepositorioUsuarios>().RegistrarAccionAsync(
                    null, $"clave:{emisor.PrefijoClave}", http.Request.Method, http.Request.Path.Value ?? "",
                    tenant.Id, codigo, http.Connection.RemoteIpAddress?.ToString(),
                    http.Request.Headers.UserAgent.ToString(), CancellationToken.None);
            }
        }
        catch (Exception ex)
        {
            http.RequestServices.GetRequiredService<ILoggerFactory>()
                .CreateLogger("Facturacion.Api.Configuracion")
                .LogError(ex, "No se pudo anotar en la bitácora {Ruta}.", http.Request.Path.Value);
        }

        return resultado;
    }

    /// <summary>¿El RUC sale en el sujeto o en alguna extensión del certificado?</summary>
    private static bool MencionaRuc(X509Certificate2 certificado, string ruc)
    {
        if (certificado.Subject.Contains(ruc, StringComparison.Ordinal)) return true;

        foreach (var extension in certificado.Extensions)
        {
            try
            {
                if (extension.Format(false).Contains(ruc, StringComparison.Ordinal)) return true;
            }
            catch (CryptographicException) { /* una extensión que no se sabe leer */ }
        }

        return false;
    }

    /// <summary>
    /// Un certificado autofirmado con el RUC y la razón social, válido un año.
    /// SUNAT beta no comprueba quién lo emitió; producción sí, y lo rechaza.
    /// La contraseña es aleatoria y solo vive cifrada en la base.
    /// </summary>
    internal static (byte[] Pfx, string Clave, DateTime ValidoHasta) CrearCertificadoDePrueba(
        string ruc, string razonSocial)
    {
        using var rsa = RSA.Create(2048);

        var nombre = new X500DistinguishedNameBuilder();
        nombre.AddCountryOrRegion("PE");
        nombre.AddOrganizationName(MarcaPrueba);
        nombre.AddOrganizationalUnitName(ruc);
        nombre.AddCommonName(Recortar("PRUEBA " + razonSocial, 64));

        var pedido = new CertificateRequest(nombre.Build(), rsa, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);

        pedido.CertificateExtensions.Add(new X509BasicConstraintsExtension(false, false, 0, false));
        pedido.CertificateExtensions.Add(new X509KeyUsageExtension(
            X509KeyUsageFlags.DigitalSignature | X509KeyUsageFlags.NonRepudiation, true));

        var desde = DateTimeOffset.UtcNow.AddDays(-1);
        var hasta = DateTimeOffset.UtcNow.AddYears(1);

        using var certificado = pedido.CreateSelfSigned(desde, hasta);

        var clave = Convert.ToHexString(RandomNumberGenerator.GetBytes(16));

        return (certificado.Export(X509ContentType.Pfx, clave), clave, hasta.UtcDateTime);
    }

    /// <summary>
    /// 01 factura → F…, 03 boleta → B…, 07 y 08 (notas) → F… o B…, según a
    /// qué comprobante afecten. Cuatro caracteres: letra y tres letras o números.
    /// </summary>
    internal static string? ProblemaSerie(string tipo, string serie)
    {
        if (tipo is not ("01" or "03" or "07" or "08"))
            return "El tipo va 01 (factura), 03 (boleta), 07 (nota de crédito) o 08 (nota de débito).";

        if (!FormaSerie().IsMatch(serie))
            return "Cuatro caracteres: una letra y tres letras o números. Ej.: F001, B001, FC01.";

        return (tipo, serie[0]) switch
        {
            ("01", not 'F') => "Las facturas usan series que empiezan con F. Ej.: F001.",
            ("03", not 'B') => "Las boletas usan series que empiezan con B. Ej.: B001.",
            ("07" or "08", not ('F' or 'B')) =>
                "Las notas empiezan con F (si corrigen facturas) o con B (si corrigen boletas). Ej.: FC01.",
            _ => null
        };
    }

    private static string Numero(string serie, int correlativo) => $"{serie}-{correlativo:D8}";

    private static string Recortar(string texto, int largo) =>
        texto.Length <= largo ? texto : texto[..largo];

    private static readonly Regex FormaSerieRegex = new("^[A-Z][A-Z0-9]{3}$", RegexOptions.Compiled);
    private static Regex FormaSerie() => FormaSerieRegex;

    private static readonly Regex UsuarioSolRegex = new("^[A-Z0-9]{3,12}$", RegexOptions.Compiled);
    private static Regex UsuarioSol() => UsuarioSolRegex;
}

/// <param name="UltimoCorrelativo">El último número ya emitido con esta serie en otro sistema; 0 si ninguno.</param>
/// <param name="Actor">Quién lo hace en la plataforma (su correo o alias). Solo para la bitácora.</param>
public record SerieDesdePlataforma(
    string? TipoComprobante, string? Serie, int UltimoCorrelativo, bool Confirmado, string? Actor);

public record MarcaDesdePlataforma(
    string? Identificador, string? ColorMarca, string? CorreoRespuesta, bool? CopiaAlEmisor);

public record SolDesdePlataforma(string? Usuario, string? Clave);

/// <summary>Fase 4c: pausar o reactivar la emisión de esta clave.</summary>
public record PausaDesdePlataforma(bool Pausar, string? Motivo);
'@

# --- Facturacion.Api\Autenticacion.cs
Planear 'Facturacion.Api\Autenticacion.cs' 'A0E5EC5BB8C1AC8A2B132F6F081A3CD9D8BE81822B6BBD764F380468ABD69E39' @'
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

    /// <summary>
    /// El prefijo de la clave con la que se llamó: sus primeros 20
    /// caracteres, los mismos que guarda api_keys.prefijo y que enseña la
    /// pestaña Claves de acceso del panel.
    ///
    /// Solo para dejar rastro de QUÉ clave hizo un cambio (POST /v1/webhook
    /// lo guarda en webhook_cambios) y poder encontrarla en esa pestaña para
    /// revocarla. No es secreto: ya está a la vista en el panel, y con él
    /// no se reconstruye la clave.
    /// </summary>
    public string? PrefijoClave { get; private set; }

    public TenantResuelto Exigir() =>
        Tenant ?? throw new InvalidOperationException(
            "No hay emisor en el contexto. El endpoint debería estar protegido.");

    internal void Establecer(TenantResuelto tenant, string clave)
    {
        Tenant = tenant;
        PrefijoClave = clave[..Math.Min(20, clave.Length)];
    }
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

        emisor.Establecer(tenant, clave);

        // FASE 4c (migración 028): un emisor en pausa solo puede LEER. Todo lo
        // que no sea GET responde 423, salvo la ruta que quita la pausa.
        if (!HttpMethods.IsGet(contexto.Request.Method) &&
            !HttpMethods.IsHead(contexto.Request.Method) &&
            !contexto.Request.Path.StartsWithSegments("/v1/configuracion/pausa"))
        {
            var admin = contexto.RequestServices.GetRequiredService<RepositorioAdmin>();
            if (await admin.EmisionPausadaAsync(tenant.Id, contexto.RequestAborted))
            {
                await Responder(contexto, StatusCodes.Status423Locked,
                    "Esta empresa está en pausa: no puede emitir.",
                    "Consultar y descargar siguen funcionando. La pausa la quita el titular al recuperar su empresa.");
                return;
            }
        }

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

        // El alta de emisores tampoco: va con la CLAVE DE ALTA (alt_), que
        // comprueba su propio filtro contra claves_alta (EndpointsAlta). Una
        // fac_ no abre esta ruta, y una alt_ no abre ninguna de /v1.
        ruta.StartsWithSegments("/alta") ||

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

# --- Facturacion.Api\ServicioCorreosEntrega.cs
Planear 'Facturacion.Api\ServicioCorreosEntrega.cs' '1CD6F99B4BE0D33EB61DC58F8E8904E7FE5DC114BF5AEF3AD4036276600E3CF4' @'
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
'@

# --- Facturacion.Persistencia\RepositorioAdmin.cs
Planear 'Facturacion.Persistencia\RepositorioAdmin.cs' '2736E80678DF21BE28E5C1CBE44160AAE4E9AE72E2CD9C56E4D8EB2FB5272A57' @'
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
    string? LogoVersion,

    // El alta (migración 024). DAPPER EMPAREJA POR POSICIÓN: estas columnas
    // van al final de la consulta en este mismo orden.
    string EstadoAlta,
    DateTime? AltaConfirmadaEn,
    DateTime? AbandonadaEn,
    string? ClaveAltaNombre,
    string? ClaveAltaPrefijo,

    // La dirección, para poder corregirla desde el panel, y si alguien la
    // revisó a propósito.
    string Ubigeo,
    string Direccion,
    string Distrito,
    string Provincia,
    string Departamento,
    DateTime? DireccionRevisadaEn,

    // Migración 026, AL FINAL: copia oculta al emisor de cada correo de
    // comprobante. Opcional, desactivada por defecto.
    bool CopiaAlEmisor)
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
/// <param name="Ajustado">
/// Migración 027: cuántos números se saltaron con «Ajustar correlativo»
/// (la suma de hasta − desde). Sirve para que «Último al crearla» siga
/// diciendo la verdad después de un ajuste.
/// </param>
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
    int Comprobantes,
    int Ajustado = 0)
{
    /// <summary>
    /// Una serie sin comprobantes se puede borrar sin consecuencias.
    /// Con comprobantes, borrarla dejaría huérfano el rastro de esa
    /// numeración, y eso es un problema tributario, no de datos.
    /// </summary>
    public bool SePuedeEliminar => Comprobantes == 0;
}

/// <summary>La serie que ya existía cuando se intentó crearla otra vez.</summary>
public record SerieExistente(Guid Id, int UltimoCorrelativo, bool Activo, int Comprobantes);

/// <summary>
/// Resultado de dar de alta una serie: o el id de la nueva, o la que ya
/// existía (y entonces no se tocó nada).
/// </summary>
public record AltaSerie(Guid? Id, SerieExistente? Existente);

public enum ResultadoAjuste { Ajustado, NoExiste, NoSube }

/// <summary>Resultado de «Ajustar correlativo».</summary>
/// <param name="Desde">El último correlativo que tenía (o el actual, si no sube).</param>
public record AjusteSerie(ResultadoAjuste Resultado, int Desde, int Hasta, string Serie);

/// <summary>La fila de la serie, leída con su candado, para ajustarla.</summary>
public record SerieBloqueada(string TipoComprobante, string Serie, int UltimoCorrelativo);

/// <summary>Una línea de la bitácora de correlativos (migración 027).</summary>
public record AjusteSerieAdmin(
    long Id,
    Guid SerieId,
    string TipoComprobante,
    string Serie,
    string Accion,
    int Desde,
    int Hasta,
    string Motivo,
    string Correo,
    DateTime CreadoEn);

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
                       md5(t.logo_ruta)   AS "LogoVersion",

                       t.estado_alta        AS "EstadoAlta",
                       t.alta_confirmada_en AS "AltaConfirmadaEn",
                       t.abandonada_en      AS "AbandonadaEn",
                       ka.nombre            AS "ClaveAltaNombre",
                       ka.prefijo::text     AS "ClaveAltaPrefijo",

                       t.ubigeo::text       AS "Ubigeo",
                       t.direccion          AS "Direccion",
                       t.distrito           AS "Distrito",
                       t.provincia          AS "Provincia",
                       t.departamento       AS "Departamento",
                       t.direccion_revisada_en AS "DireccionRevisadaEn",

                       t.copia_al_emisor    AS "CopiaAlEmisor"

                  FROM tenants t
                  LEFT JOIN claves_alta ka ON ka.id = t.creado_por_clave_alta
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
                 max_concurrencia, identificador, direccion_revisada_en)
            VALUES
                (@Ruc, @RazonSocial, @NombreComercial, @Ubigeo, @Direccion,
                 @Distrito, @Provincia, @Departamento, @Ambiente, @UsuarioSol,
                 @MaxConcurrencia, @Identificador,
                 -- El panel ya no trae LIMA por defecto y exige la
                 -- dirección: quien la escribió la revisó.
                 now())
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

    /// <summary>
    /// Corrige la dirección y la marca como revisada.
    ///
    /// LOS COMPROBANTES YA EMITIDOS NO CAMBIAN: su XML se firmó con la que
    /// tenían. Esto vale para los siguientes.
    /// </summary>
    public async Task<bool> GuardarDireccionAsync(
        Guid id, string ubigeo, string direccion, string distrito,
        string provincia, string departamento, CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);

        var filas = await conexion.ExecuteAsync(new CommandDefinition(
            """
            UPDATE tenants
               SET ubigeo = @ubigeo,
                   direccion = @direccion,
                   distrito = @distrito,
                   provincia = @provincia,
                   departamento = @departamento,
                   direccion_revisada_en = now()
             WHERE id = @id
            """,
            new { id, ubigeo, direccion, distrito, provincia, departamento },
            cancellationToken: ct));

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
        bool copiaAlEmisor, CancellationToken ct = default)
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
                   correo_respuesta = @correoRespuesta,
                   -- Sin correo de respuesta no hay a dónde mandar la copia.
                   copia_al_emisor  = @copiaAlEmisor AND @correoRespuesta::text IS NOT NULL
             WHERE id = @id
            """,
            new { id, identificador, colorMarca, correoRespuesta, copiaAlEmisor },
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
    /// <summary>
    /// Fase 4c (migración 028): pausa o reactiva la emisión de un emisor. Con
    /// la pausa, su clave fac_ solo puede leer.
    /// </summary>
    public async Task PausarEmisionAsync(Guid tenantId, bool pausar, string? motivo, CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);
        await conexion.ExecuteAsync(new CommandDefinition(
            """
            UPDATE tenants
               SET emision_pausada_en = CASE WHEN @pausar THEN COALESCE(emision_pausada_en, now()) END,
                   motivo_pausa       = CASE WHEN @pausar THEN @motivo END
             WHERE id = @tenantId
            """,
            new { tenantId, pausar, motivo }, cancellationToken: ct));
    }

    /// <summary>¿Está en pausa la emisión de este emisor? (fase 4c)</summary>
    public async Task<bool> EmisionPausadaAsync(Guid tenantId, CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);
        return await conexion.ExecuteScalarAsync<bool>(new CommandDefinition(
            "SELECT emision_pausada_en IS NOT NULL FROM tenants WHERE id = @tenantId",
            new { tenantId }, cancellationToken: ct));
    }

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
                           AND c.serie = s.serie)  AS "Comprobantes",

                       (SELECT coalesce(sum(a.hasta - a.desde), 0)::int
                          FROM serie_ajustes a
                         WHERE a.serie_id = s.id
                           AND a.accion = 'ajuste')  AS "Ajustado"

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
    /// obligaría a resolverlo con la administración tributaria. Si no es cero,
    /// queda anotado en la bitácora (serie_ajustes, acción «alta»).
    ///
    /// usuarioId NULO = no lo hizo una persona del panel sino la configuración
    /// desde la plataforma (/v1/configuracion/series). Entonces «correo» dice
    /// quién fue allí, con el prefijo «plataforma:».
    ///
    /// SI LA SERIE YA EXISTE, NO HACE NADA y devuelve la que existe. Antes la
    /// reactivaba en silencio y pasaba por alto el correlativo nuevo, así que
    /// el operador creía haber puesto la 780 y la serie seguía en la 600. Ahora
    /// quien llama decide: ajustarla (hacia arriba) o reactivarla.
    /// </summary>
    public async Task<AltaSerie> CrearSerieAsync(
        Guid tenantId, string tipoComprobante, string serie,
        int correlativoInicial, Guid? usuarioId, string correo,
        CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);
        await using var tx = await conexion.BeginTransactionAsync(ct);

        var id = await conexion.ExecuteScalarAsync<Guid?>(new CommandDefinition(
            """
            INSERT INTO series (tenant_id, tipo_comprobante, serie, ultimo_correlativo)
            VALUES (@tenantId, @tipoComprobante, @serie, @correlativoInicial)
            ON CONFLICT (tenant_id, tipo_comprobante, serie) DO NOTHING
            RETURNING id
            """,
            new { tenantId, tipoComprobante, serie, correlativoInicial },
            tx, cancellationToken: ct));

        if (id is null)
        {
            var existente = await conexion.QuerySingleOrDefaultAsync<SerieExistente>(
                new CommandDefinition(
                    """
                    SELECT s.id                 AS "Id",
                           s.ultimo_correlativo AS "UltimoCorrelativo",
                           s.activo             AS "Activo",
                           (SELECT count(*)::int FROM comprobantes c
                             WHERE c.tenant_id = s.tenant_id
                               AND c.tipo_comprobante = s.tipo_comprobante
                               AND c.serie = s.serie) AS "Comprobantes"
                      FROM series s
                     WHERE s.tenant_id = @tenantId
                       AND s.tipo_comprobante = @tipoComprobante
                       AND s.serie = @serie
                    """,
                    new { tenantId, tipoComprobante, serie },
                    tx, cancellationToken: ct));

            await tx.RollbackAsync(ct);

            return new AltaSerie(null, existente
                ?? throw new InvalidOperationException(
                    "La serie choca con una existente que ya no se encuentra. Vuelve a intentarlo."));
        }

        if (correlativoInicial > 0)
            await AnotarAsync(conexion, tx, tenantId, id.Value, tipoComprobante, serie,
                "alta", 0, correlativoInicial,
                "Alta de la serie con correlativo inicial (ya emitidos en otro sistema).",
                usuarioId, correo, ct);

        await tx.CommitAsync(ct);

        return new AltaSerie(id, null);
    }

    /// <summary>
    /// «Ajustar correlativo»: SOLO HACIA ARRIBA.
    ///
    /// Es el caso del cliente que se fue con la F001 en la 600, siguió
    /// emitiendo fuera hasta la 780 y vuelve: se sube a 780 y la siguiente
    /// sale 781. Bajarlo nunca: volvería a dar números que ya existen en SUNAT.
    ///
    /// SELECT ... FOR UPDATE: la emisión toma el mismo candado de la fila
    /// (UPDATE series ... RETURNING), así que un comprobante que se esté
    /// emitiendo en ese momento termina antes o espera, y no hay número
    /// repetido ni salto perdido. El ajuste y su anotación van en la misma
    /// transacción: o quedan los dos o ninguno.
    /// </summary>
    public async Task<AjusteSerie> AjustarCorrelativoAsync(
        Guid tenantId, Guid serieId, int hasta, string motivo,
        Guid usuarioId, string correo, CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);
        await using var tx = await conexion.BeginTransactionAsync(ct);

        var actual = await conexion.QuerySingleOrDefaultAsync<SerieBloqueada>(
            new CommandDefinition(
                """
                SELECT tipo_comprobante   AS "TipoComprobante",
                       serie              AS "Serie",
                       ultimo_correlativo AS "UltimoCorrelativo"
                  FROM series
                 WHERE id = @serieId AND tenant_id = @tenantId
                   FOR UPDATE
                """,
                new { tenantId, serieId }, tx, cancellationToken: ct));

        if (actual is null)
        {
            await tx.RollbackAsync(ct);
            return new AjusteSerie(ResultadoAjuste.NoExiste, 0, hasta, "");
        }

        if (hasta <= actual.UltimoCorrelativo)
        {
            await tx.RollbackAsync(ct);
            return new AjusteSerie(ResultadoAjuste.NoSube,
                actual.UltimoCorrelativo, hasta, actual.Serie);
        }

        await conexion.ExecuteAsync(new CommandDefinition(
            """
            UPDATE series SET ultimo_correlativo = @hasta
             WHERE id = @serieId AND tenant_id = @tenantId
            """,
            new { tenantId, serieId, hasta }, tx, cancellationToken: ct));

        await AnotarAsync(conexion, tx, tenantId, serieId, actual.TipoComprobante,
            actual.Serie, "ajuste", actual.UltimoCorrelativo, hasta, motivo,
            usuarioId, correo, ct);

        await tx.CommitAsync(ct);

        return new AjusteSerie(ResultadoAjuste.Ajustado,
            actual.UltimoCorrelativo, hasta, actual.Serie);
    }

    /// <summary>La bitácora de correlativos de una empresa, lo último primero.</summary>
    public async Task<IReadOnlyList<AjusteSerieAdmin>> ListarAjustesSerieAsync(
        Guid tenantId, CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);

        var filas = await conexion.QueryAsync<AjusteSerieAdmin>(new CommandDefinition(
            """
            SELECT id               AS "Id",
                   serie_id         AS "SerieId",
                   tipo_comprobante AS "TipoComprobante",
                   serie            AS "Serie",
                   accion           AS "Accion",
                   desde            AS "Desde",
                   hasta            AS "Hasta",
                   motivo           AS "Motivo",
                   correo           AS "Correo",
                   creado_en        AS "CreadoEn"
              FROM serie_ajustes
             WHERE tenant_id = @tenantId
             ORDER BY creado_en DESC, id DESC
             LIMIT 200
            """,
            new { tenantId }, cancellationToken: ct));

        return filas.ToList();
    }

    private static Task<int> AnotarAsync(
        NpgsqlConnection conexion, NpgsqlTransaction tx,
        Guid tenantId, Guid serieId, string tipoComprobante, string serie,
        string accion, int desde, int hasta, string motivo,
        Guid? usuarioId, string correo, CancellationToken ct) =>
        conexion.ExecuteAsync(new CommandDefinition(
            """
            INSERT INTO serie_ajustes
                   (tenant_id, serie_id, tipo_comprobante, serie, accion,
                    desde, hasta, motivo, usuario_id, correo)
            VALUES (@tenantId, @serieId, @tipoComprobante, @serie, @accion,
                    @desde, @hasta, @motivo, @usuarioId, @correo)
            """,
            new
            {
                tenantId, serieId, tipoComprobante, serie, accion,
                desde, hasta, motivo, usuarioId, correo
            },
            tx, cancellationToken: ct));

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

# --- Facturacion.Persistencia\ServicioCorreo.cs
Planear 'Facturacion.Persistencia\ServicioCorreo.cs' 'C2624B6351300D7A0225EF2890735A60BB2828E5AB8F803F171FF380C6E2CC9B' @'
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
    ///   - Puede llevar COPIA OCULTA al emisor (migración 026, opcional y
    ///     desactivada por defecto): el receptor no la ve. Va DESPUÉS de `ct`
    ///     para no romper a quien ya llama pasando `ct` por posición.
    ///
    /// Devuelve null si salió, o el motivo si no. No lanza: quien llama
    /// decide si reintenta.
    /// </summary>
    public async Task<string?> EnviarEntregaAsync(
        string para, string nombreRemitente, string responderA,
        string asunto, string html, string texto,
        AdjuntoCorreo? adjunto, AdjuntoCorreo? logo,
        CancellationToken ct = default,
        string? copiaOculta = null,
        IReadOnlyList<AdjuntoCorreo>? otrosAdjuntos = null)
    {
        if (!Disponible)
            return "El correo no está configurado (MAIL_HOST, MAIL_DESDE).";

        try
        {
            var mensaje = new MimeMessage();

            mensaje.From.Add(new MailboxAddress(nombreRemitente, _opciones.Desde));
            mensaje.ReplyTo.Add(MailboxAddress.Parse(responderA));
            mensaje.To.Add(MailboxAddress.Parse(para));

            // La copia al emisor, OCULTA. No si es la misma dirección que el
            // receptor (el emisor facturándose a sí mismo): llegaría dos veces.
            if (!string.IsNullOrWhiteSpace(copiaOculta) &&
                !string.Equals(copiaOculta.Trim(), para.Trim(), StringComparison.OrdinalIgnoreCase))
                mensaje.Bcc.Add(MailboxAddress.Parse(copiaOculta.Trim()));

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

            // El XML y el CDR (fase 4c), detrás del PDF.
            foreach (var otro in otrosAdjuntos ?? [])
                cuerpo.Attachments.Add(otro.Nombre, otro.Datos, ContentType.Parse(otro.TipoMime));

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
Write-Host 'SIGUIENTE (en esta carpeta): aplica la 028 en la base del servicio:' -ForegroundColor Yellow
Write-Host '  Get-Content migraciones\028_pausa_de_emision.sql -Raw | docker compose exec -T postgres psql -U facturacion_owner -d facturacion -v ON_ERROR_STOP=1' -ForegroundColor Yellow
Write-Host 'Despues reinicia la API del servicio y corre el script de la plataforma.' -ForegroundColor Cyan
Write-Host ''
