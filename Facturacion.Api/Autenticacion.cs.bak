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
