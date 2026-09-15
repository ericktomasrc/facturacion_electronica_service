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
    int Claves);

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
}

/// <summary>Una serie de numeración.</summary>
public record SerieAdmin(
    Guid Id,
    string TipoComprobante,
    string Serie,
    int UltimoCorrelativo,
    bool Activo,
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
                         WHERE k.tenant_id = t.id AND k.activo)  AS "Claves"
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
                 max_concurrencia)
            VALUES
                (@Ruc, @RazonSocial, @NombreComercial, @Ubigeo, @Direccion,
                 @Distrito, @Provincia, @Departamento, @Ambiente, @UsuarioSol,
                 @MaxConcurrencia)
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

    // --------------------------------------------------------------- series

    public async Task<IReadOnlyList<SerieAdmin>> ListarSeriesAsync(
        Guid tenantId, CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);

        var filas = await conexion.QueryAsync<SerieAdmin>(
            new CommandDefinition(
                """
                SELECT id                 AS "Id",
                       tipo_comprobante   AS "TipoComprobante",
                       serie              AS "Serie",
                       ultimo_correlativo AS "UltimoCorrelativo",
                       activo             AS "Activo",
                       creado_en          AS "CreadoEn"
                  FROM series
                 WHERE tenant_id = @tenantId
                 -- La más reciente primero.
                 --
                 -- El orden por tipo y serie se lee mejor, pero obliga a
                 -- buscar en toda la tabla la que acabas de crear. Como una
                 -- empresa tiene pocas series, la comodidad de verla arriba
                 -- pesa más que la prolijidad del agrupamiento.
                 ORDER BY creado_en DESC
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
