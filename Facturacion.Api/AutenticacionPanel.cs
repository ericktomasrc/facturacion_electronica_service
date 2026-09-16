using Facturacion.Persistencia;

namespace Facturacion.Api;

/// <summary>El usuario que está usando el panel en esta petición.</summary>
public sealed class ContextoOperador
{
    public UsuarioPanel? Usuario { get; private set; }
    public string? Token { get; private set; }

    public bool Autenticado => Usuario is not null;

    public UsuarioPanel Exigir() =>
        Usuario ?? throw new InvalidOperationException(
            "No hay operador en el contexto. El endpoint debería estar protegido.");

    internal void Establecer(UsuarioPanel usuario, string token)
    {
        Usuario = usuario;
        Token = token;
    }
}

/// <summary>
/// Exige una sesión válida en los endpoints del panel.
///
/// QUÉ CAMBIÓ RESPECTO A LA CLAVE COMPARTIDA:
///
/// Antes, quien tuviera la clave era "el operador", sin más. Ahora cada
/// petición sabe qué persona la hizo y qué puede hacer esa persona. Eso
/// permite tres cosas que antes eran imposibles: saber quién hizo qué,
/// quitarle el acceso a una sola persona, y limitar lo que cada una puede
/// tocar.
/// </summary>
public sealed class AutenticacionPanel : IEndpointFilter
{
    /// <summary>Nombre de la cookie de sesión.</summary>
    public const string Cookie = "fe_sesion";

    private readonly RepositorioUsuarios _usuarios;
    private readonly ContextoOperador _contexto;

    public AutenticacionPanel(
        RepositorioUsuarios usuarios, ContextoOperador contexto)
    {
        _usuarios = usuarios;
        _contexto = contexto;
    }

    public async ValueTask<object?> InvokeAsync(
        EndpointFilterInvocationContext contexto,
        EndpointFilterDelegate siguiente)
    {
        var http = contexto.HttpContext;

        var token = http.Request.Cookies[Cookie];

        if (string.IsNullOrWhiteSpace(token))
        {
            return Results.Json(
                new RespuestaError(
                    "No has iniciado sesión.",
                    "Entra en /login.html con tu correo y contraseña."),
                statusCode: StatusCodes.Status401Unauthorized);
        }

        var usuario = await _usuarios.ResolverSesionAsync(token, http.RequestAborted);

        if (usuario is null)
        {
            // La cookie ya no sirve: se borra para que el navegador no la
            // siga enviando en cada petición.
            http.Response.Cookies.Delete(Cookie);

            return Results.Json(
                new RespuestaError(
                    "Tu sesión caducó.",
                    "Vuelve a entrar. Las sesiones expiran tras 12 horas sin uso."),
                statusCode: StatusCodes.Status401Unauthorized);
        }

        _contexto.Establecer(usuario, token);

        return await siguiente(contexto);
    }
}

/// <summary>
/// Exige un permiso concreto.
///
/// POR QUÉ POR PERMISO Y NO POR ROL:
///
/// Antes esto comprobaba "¿es administrador?". Eso deja de servir en cuanto
/// los roles los define el usuario: mañana habrá un rol "Supervisor" que
/// también debe poder cargar certificados, y ningún endpoint debería tener
/// que enterarse de que ese rol existe.
///
/// Preguntando por el permiso, el código dice QUÉ hace falta y el panel
/// decide QUIÉN lo tiene.
///
/// Se usa así:
///
///     .AddEndpointFilter(new ExigirPermiso(Permiso.CertificadosGestionar))
/// </summary>
public sealed class ExigirPermiso : IEndpointFilter
{
    private readonly string _permiso;

    public ExigirPermiso(string permiso) => _permiso = permiso;

    public async ValueTask<object?> InvokeAsync(
        EndpointFilterInvocationContext contexto,
        EndpointFilterDelegate siguiente)
    {
        var operador = contexto.HttpContext.RequestServices
            .GetRequiredService<ContextoOperador>();

        var usuario = operador.Exigir();

        if (!usuario.Puede(_permiso))
        {
            // El mensaje dice qué permiso falta y con qué rol se entró.
            //
            // Sin eso, quien lo recibe solo sabe que no puede, y termina
            // preguntándole al administrador, que tampoco lo sabe sin mirar
            // la configuración.
            return Results.Json(
                new RespuestaError(
                    "No tienes permiso para esta acción.",
                    $"Hace falta el permiso '{_permiso}', y tu rol " +
                    $"'{usuario.RolNombre}' no lo tiene. Si lo necesitas, " +
                    "pídeselo a un administrador."),
                statusCode: StatusCodes.Status403Forbidden);
        }

        return await siguiente(contexto);
    }
}

/// <summary>
/// Registra en la bitácora toda acción que modifique algo.
///
/// POR QUÉ ES UN MIDDLEWARE Y NO UNA LLAMADA EN CADA ENDPOINT:
///
/// Hay más de veinte endpoints que modifican cosas, y mañana habrá treinta.
/// Si cada uno tuviera que acordarse de registrar, alguno se olvidaría, y
/// justo esa acción sería la que hubiera que rastrear.
///
/// Aquí se registra por el método HTTP: todo lo que no sea GET deja rastro.
/// </summary>
public sealed class AuditoriaPanel
{
    private readonly RequestDelegate _siguiente;

    public AuditoriaPanel(RequestDelegate siguiente) => _siguiente = siguiente;

    public async Task InvokeAsync(
        HttpContext contexto,
        RepositorioUsuarios usuarios,
        ContextoOperador operador)
    {
        await _siguiente(contexto);

        // Solo las acciones que cambian algo. Registrar cada consulta llenaría
        // la bitácora de ruido y haría más difícil encontrar lo que importa.
        if (HttpMethods.IsGet(contexto.Request.Method)) return;

        if (!contexto.Request.Path.StartsWithSegments("/admin")) return;

        // El ingreso se registra aparte, porque ahí todavía no hay operador.
        if (contexto.Request.Path.StartsWithSegments("/admin/sesion")) return;

        if (!operador.Autenticado) return;

        var usuario = operador.Exigir();

        try
        {
            await usuarios.RegistrarAccionAsync(
                usuario.Id,
                usuario.Correo,
                contexto.Request.Method,
                contexto.Request.Path + contexto.Request.QueryString,
                ExtraerTenant(contexto.Request.Path),
                contexto.Response.StatusCode,
                contexto.Connection.RemoteIpAddress?.ToString(),
                contexto.Request.Headers.UserAgent.ToString());
        }
        catch (Exception)
        {
            // Que falle la bitácora no debe tumbar la petición, que ya se
            // completó. Pero tampoco se silencia del todo: queda en el log
            // del proceso.
            contexto.RequestServices
                .GetService<ILogger<AuditoriaPanel>>()?
                .LogError("No se pudo registrar la acción en la bitácora.");
        }
    }

    /// <summary>
    /// Saca el identificador de empresa de rutas como
    /// /admin/tenants/{id}/certificado.
    ///
    /// Sirve para poder responder "¿quién tocó los datos de esta empresa?",
    /// que es la pregunta que hace un cliente cuando algo cambió sin aviso.
    /// </summary>
    private static Guid? ExtraerTenant(PathString ruta)
    {
        var partes = ruta.Value?.Split('/', StringSplitOptions.RemoveEmptyEntries);

        if (partes is null) return null;

        for (var i = 0; i < partes.Length - 1; i++)
        {
            if (partes[i] == "tenants" && Guid.TryParse(partes[i + 1], out var id))
                return id;
        }

        return null;
    }
}
