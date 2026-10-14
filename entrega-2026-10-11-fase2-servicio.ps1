# =============================================================================
# Entrega 2026-10-11 - Fase 2 (1 de 2): el SERVICIO se deja configurar con la clave fac_
#
# Se ejecuta desde la carpeta del SERVICIO (va PRIMERO, antes que la plataforma):
#   D:\Reyban Consulting\facturacion electronica\facturacion_electronica_service
#   .\entrega-2026-10-11-fase2-servicio.ps1
#
#   Facturacion.Api\EndpointsConfiguracion.cs     NUEVO. /v1/configuracion/...
#        certificado (el RUC tiene que coincidir), certificado de prueba (solo
#        beta), series, marca, logo y usuario SOL. La empresa sale de la clave.
#   Facturacion.Api\Program.cs                    Registra esas rutas.
#   Facturacion.Persistencia\RepositorioAdmin.cs  Una serie creada desde la
#        plataforma queda en la bitacora como «plataforma: correo».
#
# Sin migracion. Todo o nada, con huellas y copia .bak. No pregunta nada.
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

# --- Facturacion.Api\EndpointsConfiguracion.cs
Planear 'Facturacion.Api\EndpointsConfiguracion.cs' '' @'
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
'@

# --- Facturacion.Api\Program.cs
Planear 'Facturacion.Api\Program.cs' '8FF22C40E3F43FA9D8A4D77C1B03C137DDDE6545DE36EFD4F125540DFD157825' @'
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

// El webhook de la propia empresa (POST/GET /v1/webhook). Este NO usa el rol
// de operador: va con facturacion_app y RLS, con la empresa de la clave.
builder.Services.AddSingleton<RepositorioWebhookApi>();

// A dónde se pueden registrar webhooks: https y direcciones públicas, salvo
// en Development con FACTURACION_WEBHOOKS_LOCALES=true. El worker aplica la
// misma regla al despachar.
builder.Services.AddSingleton(
    ReglasDestinoWebhook.Resolver(builder.Environment.IsDevelopment()));
builder.Services.AddSingleton(new RepositorioConsultas(cadenaOperador));

// El alta de emisores desde la plataforma y las claves de alta (024). Con el
// rol de operador, como el panel: crea filas que la aplicación solo lee. Lo
// que la acota está en RepositorioAltas (y el rol propio es el punto 23).
builder.Services.AddSingleton(new RepositorioAltas(cadenaOperador));
builder.Services.AddScoped<ContextoClaveAlta>();
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

// Se dice al arrancar qué destinos de webhook se aceptan. El modo de fallo
// sería el silencio: rechazar el localhost de la plataforma sin saber por qué.
app.Logger.LogInformation("{Diagnostico}",
    ReglasDestinoWebhook.Diagnostico(app.Environment.IsDevelopment()));

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
app.MapearWebhookApi();
app.MapearAlta();
app.MapearConfiguracion();
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
    ContextoEmisor emisor, AlmacenCertificados certificados,
    RepositorioAltas altas, CancellationToken ct) =>
{
    var tenant = emisor.Exigir();

    // EL VENCIMIENTO DEL CERTIFICADO, para que quien integra avise antes.
    //
    // El dato existía, pero solo en `/admin/tenants/{id}/certificados`, que va
    // con la sesión del panel y cruza empresas: nadie de fuera puede ni debe
    // usar esa ruta. Aquí sale solo la fecha del activo de ESTA empresa.
    // Null si no tiene certificado cargado.
    var validoHasta = await certificados.VencimientoActivoAsync(tenant.Id, ct);

    // LO QUE LA PLATAFORMA REFLEJA (diseño §13.4): si el alta está confirmada,
    // la marca, y qué falta para poder emitir. Solo «está o no está» y datos
    // de esta misma empresa: ningún secreto.
    var e = await altas.EstadoAsync(tenant.Id, ct);

    return Results.Ok(new
    {
        ruc = tenant.Ruc,
        razonSocial = tenant.RazonSocial,
        nombreComercial = tenant.NombreComercial,
        ambiente = tenant.Ambiente,
        certificadoValidoHasta = validoHasta,
        certificadoDiasParaVencer = validoHasta is { } h
            ? (int?)Math.Ceiling((h - DateTime.UtcNow).TotalDays)
            : null,

        alta = new
        {
            estado = e.EstadoAlta,
            creadoEn = e.CreadoEn,
            confirmadaEn = e.AltaConfirmadaEn
        },

        // Sin los dos, NINGÚN receptor recibe su correo: el disparador de la
        // 022 se lo salta sin avisar, y lo aceptado mientras tanto no lo
        // recibe nunca.
        portal = new
        {
            identificador = e.Identificador,
            correoRespuesta = e.CorreoRespuesta,
            tieneLogo = e.TieneLogo,
            correosAlReceptor = e.CorreosAlReceptor
        },

        direccion = new
        {
            ubigeo = e.Ubigeo,
            direccion = e.Direccion,
            distrito = e.Distrito,
            provincia = e.Provincia,
            departamento = e.Departamento,
            revisadaEn = e.DireccionRevisadaEn
        },

        listo = new
        {
            paraEmitir = e.ListoParaEmitir,
            certificado = e.CertificadoListo,
            sol = e.SolListo,
            series = e.Series,
            direccion = e.DireccionLista,
            faltan = e.Faltan()
        }
    });
})
.WithName("Emisor")
.WithTags("Servicio")
.WithSummary("Datos del emisor autenticado")
.WithDescription(
    "Sirve para verificar que una clave de acceso funciona, y para saber qué le " +
    "falta a la empresa: «listo» dice si puede emitir (certificado vigente, usuario " +
    "SOL secundario, al menos una serie y la dirección revisada) y «portal» si sus " +
    "receptores van a recibir el correo de entrega (identificador y correo de respuesta).");

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

# --- Facturacion.Persistencia\RepositorioAdmin.cs
Planear 'Facturacion.Persistencia\RepositorioAdmin.cs' '081B9663ED374A0BB8E0AE51E61D8AD4398043AC4EE2440367EAAF7A720E7A13' @'
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
Write-Host 'SIGUIENTE: reinicia la API del servicio (la de https://localhost:7295).' -ForegroundColor Yellow
Write-Host 'Despues corre el script de la plataforma.' -ForegroundColor Cyan
Write-Host ''
