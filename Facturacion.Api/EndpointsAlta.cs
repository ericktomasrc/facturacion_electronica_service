using Facturacion.Persistencia;

namespace Facturacion.Api;

/// <summary>La clave de alta de la petición en curso. Con ámbito de petición.</summary>
public sealed class ContextoClaveAlta
{
    public ClaveAltaResuelta? Clave { get; private set; }

    public ClaveAltaResuelta Exigir() =>
        Clave ?? throw new InvalidOperationException(
            "No hay clave de alta en el contexto. El endpoint debería estar protegido.");

    internal void Establecer(ClaveAltaResuelta clave) => Clave = clave;
}

/// <summary>
/// Exige una clave de alta (alt_) en las rutas de /alta.
///
/// SOLO ESTA RUTA LA ACEPTA, y por eso la clave es estrecha sin tener que
/// restringirla en ningún otro sitio:
///
///   /v1/*     la autentica AutenticacionApiKey contra api_keys: una alt_ no
///             está ahí, da 401.
///   /admin/*  va con la sesión del panel (cookie): una cabecera no abre nada.
///   /alta/*   este filtro, contra claves_alta. Una fac_ no está ahí: 401.
///
/// Se lee de «Authorization: Bearer alt_…» o de «X-Clave-Alta: alt_…».
/// </summary>
public sealed class AutenticacionClaveAlta : IEndpointFilter
{
    public const string Cabecera = "X-Clave-Alta";

    public async ValueTask<object?> InvokeAsync(
        EndpointFilterInvocationContext contexto, EndpointFilterDelegate siguiente)
    {
        var http = contexto.HttpContext;

        var autorizacion = http.Request.Headers.Authorization.ToString();
        var clave = autorizacion.StartsWith("Bearer ", StringComparison.OrdinalIgnoreCase)
            ? autorizacion["Bearer ".Length..].Trim()
            : http.Request.Headers[Cabecera].ToString().Trim();

        var resuelta = await http.RequestServices.GetRequiredService<RepositorioAltas>()
            .ResolverClaveAsync(clave, http.RequestAborted);

        if (resuelta is null)
        {
            // Un solo mensaje para «no hay», «no existe» y «revocada»:
            // distinguirlos le diría a quien prueba cuáles existen.
            return Results.Json(
                new RespuestaError("Clave de alta no válida.",
                    $"Envíala en la cabecera Authorization: Bearer <clave> o {Cabecera}: <clave>."),
                statusCode: StatusCodes.Status401Unauthorized);
        }

        http.RequestServices.GetRequiredService<ContextoClaveAlta>().Establecer(resuelta);

        return await siguiente(contexto);
    }
}

/// <summary>
/// El alta de un emisor desde la plataforma, y lo que la rodea.
/// Diseño: alta-empresa-diseno.md §13.
///
///   POST   /alta/emisores                 clave alt_   crea emisor + fac_ + webhook
///   POST   /v1/alta/confirmar             clave fac_   la plataforma ya guardó lo suyo
///   GET    /admin/claves-alta             panel        las claves de alta
///   POST   /admin/claves-alta             panel        emitir una (se ve una vez)
///   DELETE /admin/claves-alta/{id}        panel        revocar
///   PUT    /admin/tenants/{id}/direccion  panel        corregir la dirección
/// </summary>
public static class EndpointsAlta
{
    public static void MapearAlta(this WebApplication app)
    {
        // ------------------------------------------------- POST /alta/emisores

        app.MapPost("/alta/emisores", async (
            PeticionAltaEmisor p,
            HttpContext http,
            ContextoClaveAlta contexto,
            RepositorioAltas altas,
            RepositorioUsuarios usuarios,
            ReglasDestinoWebhook reglas,
            ServicioCorreo correo,
            OpcionesCorreo opcionesCorreo,
            ILoggerFactory registros,
            CancellationToken ct) =>
        {
            var clave = contexto.Exigir();
            var log = registros.CreateLogger("Facturacion.Api.Alta");

            // La respuesta lleva la fac_ y el whsec_: que nada la guarde.
            http.Response.Headers.CacheControl = "no-store";

            var ruc = p.Ruc?.Trim() ?? "";

            var (resultado, emisorId) = await Procesar();

            async Task<(IResult, Guid?)> Procesar()
            {
                if (Direccion.ProblemaRuc(ruc) is { } problemaRuc)
                    return (Results.BadRequest(new RespuestaError("RUC inválido.", problemaRuc)), null);

                var razon = p.RazonSocial?.Trim() ?? "";

                if (razon.Length is < 3 or > 300)
                    return (Results.BadRequest(new RespuestaError(
                        "Falta la razón social.", "Tal como sale en la ficha RUC.")), null);

                var (dir, problemaDir) = Direccion.Revisar(
                    p.Ubigeo, p.Direccion, p.Distrito, p.Provincia, p.Departamento);

                if (dir is null)
                    return (Results.BadRequest(new RespuestaError("La dirección no es válida.", problemaDir)), null);

                // Las mismas reglas que POST /v1/webhook y que el worker al
                // despachar: https y dirección pública (salvo desarrollo).
                if (await DestinoWebhook.RevisarAsync(p.WebhookUrl, reglas.PermitirLocales, ct) is { } problemaUrl)
                    return (Results.BadRequest(new RespuestaError("La URL del webhook no es válida.", problemaUrl)), null);

                var datos = new DatosAltaEmisor(
                    ruc, razon,
                    string.IsNullOrWhiteSpace(p.NombreComercial) ? null : p.NombreComercial.Trim(),
                    dir.Ubigeo, dir.Direccion, dir.Distrito, dir.Provincia, dir.Departamento,
                    p.WebhookUrl!.Trim());

                AltaEmisor alta;

                try
                {
                    alta = await altas.CrearEmisorAsync(clave, datos, ct);
                }
                catch (Npgsql.PostgresException ex) when (
                    ex.SqlState == "23505" && ex.ConstraintName == "ux_tenants_ruc_vigente")
                {
                    // Alguien lo dio de alta en el panel en el mismo instante.
                    alta = new AltaEmisor(ResultadoAlta.YaExiste);
                }

                return (await Responder(alta, clave, ruc, correo, opcionesCorreo, altas, log, ct), alta.EmisorId);
            }

            // EL RASTRO, SIEMPRE: quién (la clave), qué ruta, qué empresa y cómo
            // terminó. Nunca la clave ni el secreto. Que falle no tumba el alta.
            try
            {
                await usuarios.RegistrarAccionAsync(
                    null, $"clave-alta:{clave.Prefijo}", "POST", "/alta/emisores", emisorId,
                    CodigoDe(resultado),
                    http.Connection.RemoteIpAddress?.ToString(),
                    http.Request.Headers.UserAgent.ToString(), CancellationToken.None);
            }
            catch (Exception ex)
            {
                log.LogError(ex, "No se pudo anotar en la bitácora el alta del RUC {Ruc}.", ruc);
            }

            return resultado;
        })
        .AddEndpointFilter<AutenticacionClaveAlta>()
        .WithTags("Alta de emisores")
        .WithSummary("Crea un emisor con su clave y su webhook (clave de alta)")
        .WithDescription(
            "Solo con una clave de alta (alt_), en Authorization: Bearer o en X-Clave-Alta. " +
            "Crea, en una sola transacción, el emisor (siempre en beta), su clave fac_ y su " +
            "webhook de la API, y lo deja «sin confirmar»: quien llama guarda lo suyo y " +
            "después confirma con POST /v1/alta/confirmar usando la fac_ recibida. " +
            "409 si el RUC ya existe; 429 si la clave llegó a su tope del día. " +
            "La clave y el secreto se devuelven solo aquí.");

        // --------------------------------------------- POST /v1/alta/confirmar

        app.MapPost("/v1/alta/confirmar", async (
            ContextoEmisor emisor, RepositorioAltas altas, CancellationToken ct) =>
        {
            var tenant = emisor.Exigir();
            var (estado, confirmadaEn) = await altas.ConfirmarAsync(tenant.Id, ct);

            return Results.Ok(new
            {
                estado,
                confirmadaEn,
                mensaje = estado == "confirmada"
                    ? "Alta confirmada."
                    : $"El alta está «{estado}»."
            });
        })
        .WithTags("Alta de emisores")
        .WithSummary("Confirma el alta de la empresa de la clave")
        .WithDescription(
            "La llama la plataforma cuando ya guardó la empresa. Se puede llamar de más: " +
            "si ya estaba confirmada, no cambia nada. Una empresa creada en el panel ya " +
            "está confirmada.");

        // ---------------------------------------------- las claves, en el panel

        var claves = app.MapGroup("/admin/claves-alta")
            .AddEndpointFilter<AutenticacionPanel>()
            .AddEndpointFilter(new ExigirPermiso(Permiso.AltasGestionar))
            .WithTags("Alta de emisores");

        claves.MapGet("", async (RepositorioAltas altas, CancellationToken ct) =>
            Results.Ok(await altas.ListarClavesAsync(ct)))
            .WithSummary("Las claves de alta, con su uso");

        claves.MapPost("", async (
            NuevaClaveAlta nueva, ContextoOperador operador,
            RepositorioAltas altas, CancellationToken ct) =>
        {
            var nombre = nueva.Nombre?.Trim() ?? "";

            if (nombre.Length is < 1 or > 100)
                return Results.BadRequest(new RespuestaError(
                    "Ponle un nombre a la clave.",
                    "Dónde se va a usar: «Plataforma producción», por ejemplo. Máximo 100 caracteres."));

            var tope = nueva.TopeDiario ?? 20;

            if (tope is < 1 or > 100)
                return Results.BadRequest(new RespuestaError(
                    "El tope diario va de 1 a 100.",
                    "Es cuántas empresas puede crear al día. Bajo a propósito: si se filtra, " +
                    "es todo lo que puede hacer."));

            var (id, clave, prefijo) = await altas.CrearClaveAsync(
                nombre, (short)tope, operador.Exigir().Id, ct);

            return Results.Ok(new
            {
                id,
                prefijo,
                clave,
                aviso =
                    "Esta es la ÚNICA vez que se muestra. Va en el .env de la plataforma " +
                    "(FACTURACION_CLAVE_ALTA). No la pegues en ningún chat ni correo."
            });
        })
        .WithSummary("Emite una clave de alta")
        .WithDescription("Devuelve el secreto en claro UNA sola vez. En la base solo queda su hash.");

        claves.MapDelete("/{id:guid}", async (
            Guid id, ContextoOperador operador, RepositorioAltas altas, CancellationToken ct) =>
        {
            var revocada = await altas.RevocarClaveAsync(id, operador.Exigir().Id, ct);

            return revocada
                ? Results.Ok(new { mensaje = "Clave de alta revocada. La plataforma ya no puede crear emisores con ella." })
                : Results.NotFound(new RespuestaError("No se encontró la clave, o ya estaba revocada."));
        })
        .WithSummary("Revoca una clave de alta")
        .WithDescription("No se borra: queda quién la revocó y cuándo.");

        // ------------------------------------- PUT /admin/tenants/{id}/direccion

        app.MapPut("/admin/tenants/{id:guid}/direccion", async (
            Guid id, CambioDireccion cambio, RepositorioAdmin admin, CancellationToken ct) =>
        {
            var (dir, problema) = Direccion.Revisar(
                cambio.Ubigeo, cambio.Direccion, cambio.Distrito, cambio.Provincia, cambio.Departamento);

            if (dir is null)
                return Results.BadRequest(new RespuestaError("La dirección no es válida.", problema));

            var guardada = await admin.GuardarDireccionAsync(
                id, dir.Ubigeo, dir.Direccion, dir.Distrito, dir.Provincia, dir.Departamento, ct);

            return guardada
                ? Results.Ok(new { mensaje = "Dirección guardada. Sale así en los próximos comprobantes." })
                : Results.NotFound(new RespuestaError("No se encontró la empresa."));
        })
        .AddEndpointFilter<AutenticacionPanel>()
        .AddEndpointFilter(new ExigirPermiso(Permiso.EmpresasEditar))
        .WithTags("Administración")
        .WithSummary("Corrige la dirección de la empresa")
        .WithDescription(
            "Los comprobantes ya emitidos no cambian: llevan la dirección que tenían. " +
            "Guardarla la marca como revisada.");
    }

    private static async Task<IResult> Responder(
        AltaEmisor alta, ClaveAltaResuelta clave, string ruc,
        ServicioCorreo correo, OpcionesCorreo opcionesCorreo,
        RepositorioAltas altas, ILogger log, CancellationToken ct)
    {
        switch (alta.Resultado)
        {
            case ResultadoAlta.Creado:
                // Al registro va QUÉ pasó. Nunca la clave ni el secreto.
                log.LogInformation(
                    "Emisor {Ruc} creado por la clave de alta {Prefijo}… ({Emisor}){Abandonado}",
                    ruc, clave.Prefijo, alta.EmisorId,
                    alta.Abandonado is { } a ? $"; el alta anterior sin confirmar ({a}) quedó abandonada" : "");

                return Results.Ok(new
                {
                    emisorId = alta.EmisorId,
                    estado = "sin_confirmar",
                    creadoEn = alta.CreadoEn,
                    ambiente = "beta",
                    clave = alta.Clave,
                    webhook = new
                    {
                        id = alta.WebhookId,
                        url = alta.WebhookUrl,
                        secreto = alta.WebhookSecreto
                    },
                    abandonado = alta.Abandonado,
                    siguiente = "POST /v1/alta/confirmar con la clave recibida, en cuanto lo hayas guardado.",
                    aviso =
                        "La clave y el secreto solo se muestran aquí. Mientras no se confirme, " +
                        "el emisor queda «sin confirmar», y otro alta del mismo RUC lo dará por abandonado."
                });

            case ResultadoAlta.YaExiste:
                return Results.Conflict(new RespuestaError(
                    "Ese RUC ya está registrado en el servicio.",
                    "No se creó nada. Si es la misma empresa, conéctala con su clave " +
                    "(«Comprobar» y «Conectar»)."));

            case ResultadoAlta.EnCurso:
                return Results.Conflict(new RespuestaError(
                    "Hay un alta de este RUC en curso.",
                    "Empezó hace menos de " +
                    $"{(int)RepositorioAltas.EsperaAntesDeAbandonar.TotalMinutes} minutos y todavía " +
                    "no se confirmó. No se creó nada: espera un poco y vuelve a intentarlo."));

            default:
                log.LogWarning(
                    "La clave de alta {Prefijo}… llegó a su tope de {Tope} altas hoy.",
                    clave.Prefijo, clave.TopeDiario);

                if (alta.AvisarTope)
                    await AvisarTopeAsync(clave, correo, opcionesCorreo, altas, log, ct);

                return Results.Json(new RespuestaError(
                    $"La clave de alta llegó a su tope de {clave.TopeDiario} empresas por hoy.",
                    "No se creó nada. Si no esperabas tantas altas, revisa en el panel del " +
                    "servicio quién las hizo y revoca la clave."),
                    statusCode: StatusCodes.Status429TooManyRequests);
        }
    }

    /// <summary>
    /// Un correo, una vez al día, a quienes pueden revocar la clave. Si la
    /// clave se filtró, es el aviso que llega antes que el cliente molesto.
    /// </summary>
    private static async Task AvisarTopeAsync(
        ClaveAltaResuelta clave, ServicioCorreo correo, OpcionesCorreo opciones,
        RepositorioAltas altas, ILogger log, CancellationToken ct)
    {
        try
        {
            var para = await altas.DestinatariosAvisoAsync(ct);

            var nombre = System.Net.WebUtility.HtmlEncode(clave.Nombre);
            var prefijo = System.Net.WebUtility.HtmlEncode(clave.Prefijo);
            var panel = System.Net.WebUtility.HtmlEncode(opciones.UrlPanel.TrimEnd('/') + "/admin.html");

            var cuerpo =
                $"<p>La clave de alta <strong>{nombre}</strong> (<code>{prefijo}…</code>) " +
                $"llegó hoy a su tope de <strong>{clave.TopeDiario}</strong> empresas.</p>" +
                "<p>Desde ahora y hasta mañana, las altas con esa clave se rechazan.</p>" +
                "<p><strong>Si no esperabas tantas altas, la clave puede haberse filtrado.</strong> " +
                $"Revisa las empresas creadas hoy y revócala en <a href=\"{panel}\">el panel</a> " +
                "(bloque «Claves de alta»).</p>";

            foreach (var destino in para)
                await correo.EnviarAsync(destino, "Tope de altas alcanzado: revisa la clave de alta", cuerpo, ct);

            if (para.Count == 0)
                log.LogWarning("Nadie tiene el permiso altas.gestionar: el aviso del tope no se mandó.");
        }
        catch (Exception ex)
        {
            log.LogError(ex, "No se pudo mandar el aviso del tope de la clave de alta {Prefijo}…", clave.Prefijo);
        }
    }

    private static int CodigoDe(IResult resultado) =>
        resultado is IStatusCodeHttpResult { StatusCode: { } codigo } ? codigo : 200;
}

/// <summary>Cuerpo de POST /alta/emisores. Ni ambiente ni SOL: eso es del panel.</summary>
public record PeticionAltaEmisor(
    string? Ruc,
    string? RazonSocial,
    string? NombreComercial,
    string? Direccion,
    string? Ubigeo,
    string? Distrito,
    string? Provincia,
    string? Departamento,
    string? WebhookUrl);

public record NuevaClaveAlta(string? Nombre, int? TopeDiario);

public record CambioDireccion(
    string? Ubigeo, string? Direccion, string? Distrito, string? Provincia, string? Departamento);