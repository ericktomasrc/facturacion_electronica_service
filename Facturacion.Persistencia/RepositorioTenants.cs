using System.Security.Cryptography;
using System.Text;
using Dapper;

namespace Facturacion.Persistencia;

/// <summary>Datos del emisor, resueltos desde la clave de acceso.</summary>
public record TenantResuelto(
    Guid Id,
    string Ruc,
    string RazonSocial,
    string NombreComercial,
    string Ubigeo,
    string Direccion,
    string Distrito,
    string Provincia,
    string Departamento,
    string Ambiente,
    string? UsuarioSol,
    short MaxConcurrencia,
    bool Activo)
{
    public bool EsProduccion => Ambiente == "produccion";
}

/// <summary>
/// Resuelve tenants y valida claves de acceso.
///
/// Esta clase trabaja SIN contexto de tenant, porque es la que lo determina.
/// Es la única excepción a la regla de que todo pasa por SesionTenant, y por
/// eso conviene que sea pequeña y que no haga nada más.
/// </summary>
public sealed class RepositorioTenants
{
    private readonly FabricaSesiones _sesiones;

    public RepositorioTenants(FabricaSesiones sesiones)
    {
        _sesiones = sesiones ?? throw new ArgumentNullException(nameof(sesiones));
    }

    /// <summary>
    /// Calcula el hash de una clave. SHA-256 en hexadecimal minúsculo.
    ///
    /// POR QUÉ SHA-256 A SECAS Y NO BCRYPT O ARGON2, que sería lo correcto
    /// para contraseñas de personas: una clave de API es un valor aleatorio
    /// largo generado por el sistema, no algo que alguien eligió. No hay
    /// diccionario que probar contra ella, así que el coste computacional
    /// de un algoritmo lento no aporta nada y sí encarece cada petición.
    ///
    /// Esto deja de ser cierto si alguna vez permites claves elegidas por
    /// el usuario. No lo permitas.
    /// </summary>
    public static string CalcularHash(string clave)
    {
        var bytes = SHA256.HashData(Encoding.UTF8.GetBytes(clave));
        return Convert.ToHexString(bytes).ToLowerInvariant();
    }

    /// <summary>Genera una clave nueva, legible y con prefijo reconocible.</summary>
    public static string GenerarClave(bool produccion = false)
    {
        var aleatorio = Convert.ToBase64String(RandomNumberGenerator.GetBytes(32))
            .Replace("+", "").Replace("/", "").Replace("=", "");

        return $"fac_{(produccion ? "live" : "test")}_{aleatorio}";
    }

    /// <summary>
    /// Resuelve el tenant a partir de una clave de acceso.
    /// Devuelve null si la clave no existe, está revocada, o el tenant
    /// está desactivado.
    /// </summary>
    public async Task<TenantResuelto?> ResolverPorClaveAsync(
        string clave, CancellationToken ct = default)
    {
        if (string.IsNullOrWhiteSpace(clave)) return null;

        var hash = CalcularHash(clave);

        await using var conexion = await _sesiones.AbrirCatalogoAsync(ct);

        // Una sola consulta que resuelve el tenant Y registra el uso de la clave.
        //
        // POR QUÉ EN UNA SOLA SENTENCIA Y NO EN DOS:
        //
        // La versión anterior lanzaba el UPDATE sin esperarlo, con un
        // descarte (_ = ...), pensando que así no retrasaba la petición.
        // Eso era un error grave: la conexión se liberaba al salir del
        // 'await using' con el comando todavía en vuelo, volvía al pool en
        // mal estado, y la siguiente petición se quedaba esperando una
        // conexión que nunca se recuperaba. El síntoma no era un error:
        // era un cuelgue silencioso.
        //
        // La lección general: nunca lances trabajo sin esperar sobre un
        // recurso que estás a punto de liberar. Si de verdad debe ser en
        // segundo plano, el trabajo necesita su propia conexión y su propio
        // ciclo de vida.
        //
        // Aquí ni siquiera hace falta: un CTE hace ambas cosas en un viaje.
        // El UPDATE solo ocurre si la clave existe y está activa.

        var tenant = await conexion.QuerySingleOrDefaultAsync<TenantResuelto?>(
            new CommandDefinition(
                """
                WITH clave_usada AS (
                    UPDATE api_keys
                       SET ultimo_uso = now()
                     WHERE hash = @hash
                       AND activo
                    RETURNING tenant_id
                )
                SELECT t.id               AS "Id",
                       t.ruc              AS "Ruc",
                       t.razon_social     AS "RazonSocial",
                       t.nombre_comercial AS "NombreComercial",
                       t.ubigeo           AS "Ubigeo",
                       t.direccion        AS "Direccion",
                       t.distrito         AS "Distrito",
                       t.provincia        AS "Provincia",
                       t.departamento     AS "Departamento",
                       t.ambiente         AS "Ambiente",
                       t.usuario_sol      AS "UsuarioSol",
                       t.max_concurrencia AS "MaxConcurrencia",
                       t.activo           AS "Activo"
                  FROM clave_usada k
                  JOIN tenants     t ON t.id = k.tenant_id
                 WHERE t.activo
                """,
                new { hash }, cancellationToken: ct));

        return tenant;
    }

    public async Task<TenantResuelto?> ObtenerPorRucAsync(
        string ruc, CancellationToken ct = default)
    {
        await using var conexion = await _sesiones.AbrirCatalogoAsync(ct);

        return await conexion.QuerySingleOrDefaultAsync<TenantResuelto?>(
            new CommandDefinition(
                """
                SELECT id               AS "Id",
                       ruc              AS "Ruc",
                       razon_social     AS "RazonSocial",
                       nombre_comercial AS "NombreComercial",
                       ubigeo           AS "Ubigeo",
                       direccion        AS "Direccion",
                       distrito         AS "Distrito",
                       provincia        AS "Provincia",
                       departamento     AS "Departamento",
                       ambiente         AS "Ambiente",
                       usuario_sol      AS "UsuarioSol",
                       max_concurrencia AS "MaxConcurrencia",
                       activo           AS "Activo"
                  FROM tenants
                 WHERE ruc = @ruc
                """,
                new { ruc }, cancellationToken: ct));
    }
}
