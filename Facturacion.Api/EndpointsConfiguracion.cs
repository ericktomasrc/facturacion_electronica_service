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

                // EL RUC TIENE QUE COINCIDIR, SIN EXCEPCIÓN (18 oct). Antes se
                // podía confirmar a mano; ya no: con el certificado de otra
                // empresa SUNAT rechaza todo. `confirmado` se sigue aceptando
                // para no romper a quien lo mande, pero no cambia nada.
                // Si una certificadora pone el RUC donde no lo vemos, el super
                // administrador lo carga desde el panel (empresa > Certificado).
                _ = confirmado;
                if (!coincide)
                    return Results.UnprocessableEntity(new
                    {
                        error = $"Este certificado no es del RUC {tenant.Ruc}.",
                        detalle = $"Es de «{titular}». SUNAT rechaza todo lo firmado con el certificado " +
                                  "de otra empresa. Sube el certificado de esta empresa.",
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
        // 18 OCT: RUC 10 = PERSONA NATURAL. Su certificado a veces lleva el DNI
        // (los 8 dígitos del medio del RUC) en vez del RUC; también vale.
        var buscados = ruc.StartsWith("10", StringComparison.Ordinal) && ruc.Length == 11
            ? new[] { ruc, ruc.Substring(2, 8) }
            : new[] { ruc };

        foreach (var buscado in buscados)
        {
            if (certificado.Subject.Contains(buscado, StringComparison.Ordinal)) return true;

            foreach (var extension in certificado.Extensions)
            {
                try
                {
                    if (extension.Format(false).Contains(buscado, StringComparison.Ordinal)) return true;
                }
                catch (CryptographicException) { /* una extensión que no se sabe leer */ }
            }
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