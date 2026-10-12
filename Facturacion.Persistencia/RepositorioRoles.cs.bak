using Dapper;
using Npgsql;

namespace Facturacion.Persistencia;

/// <summary>
/// Las claves de permiso, como constantes.
///
/// POR QUÉ CONSTANTES Y NO CADENAS SUELTAS: escribir "comprobantes.reprocesar"
/// a mano en veinte endpoints garantiza que alguno lleve una errata, y una
/// errata en una clave de permiso no falla: simplemente nadie la tiene, y el
/// endpoint queda cerrado para todos sin que nadie entienda por qué.
///
/// Con constantes, la errata la detecta el compilador.
/// </summary>
public static class Permiso
{
    public const string DiagnosticoVer = "diagnostico.ver";

    public const string ComprobantesVer = "comprobantes.ver";
    public const string ComprobantesReprocesar = "comprobantes.reprocesar";

    public const string EmpresasVer = "empresas.ver";
    public const string EmpresasEditar = "empresas.editar";
    public const string ClavesGestionar = "claves.gestionar";
    public const string WebhooksGestionar = "webhooks.gestionar";

    public const string CertificadosGestionar = "certificados.gestionar";
    public const string ProduccionCambiar = "produccion.cambiar";

    public const string UsuariosGestionar = "usuarios.gestionar";
    public const string AuditoriaVer = "auditoria.ver";

    /// <summary>
    /// Áreas del producto.
    ///
    /// NO SE LLAMAN PSE NI OSE A PROPÓSITO. Esas son figuras que define SUNAT,
    /// con requisitos legales y registro propio. Usar esos nombres para
    /// permisos internos haría creer que un usuario o la empresa tienen esa
    /// condición ante la administración tributaria.
    ///
    /// Se nombran por lo que hacen.
    /// </summary>
    public const string EmisionVer = "emision.ver";
    public const string ValidacionVer = "validacion.ver";
}

/// <summary>Un permiso del catálogo.</summary>
public record PermisoInfo(
    string Clave,
    string Area,
    string Nombre,
    string Descripcion,
    short Orden);

/// <summary>Un rol con sus permisos.</summary>
public record RolInfo(
    Guid Id,
    string Clave,
    string Nombre,
    string Descripcion,
    bool DelSistema,
    string? PermisosTexto,
    int Usuarios,
    DateTime CreadoEn)
{
    /// <summary>
    /// Los permisos llegan como texto separado por comas, no como arreglo.
    ///
    /// Dapper entrega un text[] de PostgreSQL como System.Array sin
    /// convertirlo, y falla al materializar con un mensaje que habla de
    /// constructores. Aplanar y dividir aquí cuesta menos que configurar un
    /// conversor.
    /// </summary>
    public string[] Permisos =>
        string.IsNullOrWhiteSpace(PermisosTexto)
            ? []
            : PermisosTexto.Split(',', StringSplitOptions.RemoveEmptyEntries);
}

/// <summary>
/// Roles y permisos del panel.
/// </summary>
public sealed class RepositorioRoles
{
    private readonly string _cadenaOperador;

    public RepositorioRoles(string cadenaConexionOperador)
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

    /// <summary>Catálogo completo de permisos, para las pantallas de roles.</summary>
    public async Task<IReadOnlyList<PermisoInfo>> CatalogoAsync(
        CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);

        var filas = await conexion.QueryAsync<PermisoInfo>(
            new CommandDefinition(
                """
                SELECT clave       AS "Clave",
                       area        AS "Area",
                       nombre      AS "Nombre",
                       descripcion AS "Descripcion",
                       orden       AS "Orden"
                  FROM permisos
                 ORDER BY orden, clave
                """,
                cancellationToken: ct));

        return filas.ToList();
    }

    public async Task<IReadOnlyList<RolInfo>> ListarAsync(
        CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);

        var filas = await conexion.QueryAsync<RolInfo>(
            new CommandDefinition(
                """
                SELECT r.id          AS "Id",
                       r.clave       AS "Clave",
                       r.nombre      AS "Nombre",
                       r.descripcion AS "Descripcion",
                       r.del_sistema AS "DelSistema",

                       (SELECT string_agg(rp.permiso, ',' ORDER BY rp.permiso)
                          FROM rol_permisos rp
                         WHERE rp.rol_id = r.id)      AS "PermisosTexto",

                       (SELECT count(*)::int FROM usuarios u
                         WHERE u.rol_id = r.id)       AS "Usuarios",

                       r.creado_en   AS "CreadoEn"
                  FROM roles r
                 ORDER BY r.del_sistema DESC, r.nombre
                """,
                cancellationToken: ct));

        return filas.ToList();
    }

    public async Task<Guid> CrearAsync(
        string nombre, string descripcion, string[] permisos,
        CancellationToken ct = default)
    {
        // La clave sale del nombre: es lo que aparece en la configuración y
        // conviene que sea legible, no un identificador al azar.
        var clave = AClave(nombre);

        await using var conexion = await AbrirAsync(ct);
        await using var transaccion = await conexion.BeginTransactionAsync(ct);

        var id = await conexion.ExecuteScalarAsync<Guid>(new CommandDefinition(
            """
            INSERT INTO roles (clave, nombre, descripcion)
            VALUES (@clave, @nombre, @descripcion)
            RETURNING id
            """,
            new { clave, nombre = nombre.Trim(), descripcion = descripcion.Trim() },
            transaccion, cancellationToken: ct));

        await AsignarAsync(conexion, transaccion, id, permisos, ct);

        await transaccion.CommitAsync(ct);

        return id;
    }

    /// <summary>
    /// Cambia el nombre, la descripción y los permisos de un rol.
    ///
    /// Los roles del sistema no se tocan: dejar que alguien le quite permisos
    /// a 'administrador' permitiría bloquear el panel sin forma de recuperarlo
    /// desde dentro.
    /// </summary>
    public async Task<(bool Exitoso, string? Motivo)> ActualizarAsync(
        Guid rolId, string nombre, string descripcion, string[] permisos,
        CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);

        var delSistema = await conexion.ExecuteScalarAsync<bool?>(
            new CommandDefinition(
                "SELECT del_sistema FROM roles WHERE id = @rolId",
                new { rolId }, cancellationToken: ct));

        if (delSistema is null)
            return (false, "No se encontró el rol.");

        if (delSistema.Value)
            return (false,
                "Este rol es del sistema y no se puede modificar. " +
                "Si necesitas algo parecido, crea uno nuevo.");

        await using var transaccion = await conexion.BeginTransactionAsync(ct);

        await conexion.ExecuteAsync(new CommandDefinition(
            """
            UPDATE roles SET nombre = @nombre, descripcion = @descripcion
             WHERE id = @rolId
            """,
            new { rolId, nombre = nombre.Trim(), descripcion = descripcion.Trim() },
            transaccion, cancellationToken: ct));

        // Se reemplazan todos: borrar y volver a insertar es más simple que
        // calcular qué cambió, y a esta escala no tiene ningún coste.
        await conexion.ExecuteAsync(new CommandDefinition(
            "DELETE FROM rol_permisos WHERE rol_id = @rolId",
            new { rolId }, transaccion, cancellationToken: ct));

        await AsignarAsync(conexion, transaccion, rolId, permisos, ct);

        await transaccion.CommitAsync(ct);

        return (true, null);
    }

    /// <summary>
    /// Elimina un rol, siempre que no sea del sistema y nadie lo tenga.
    /// </summary>
    public async Task<(bool Exitoso, string? Motivo)> EliminarAsync(
        Guid rolId, CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);

        var datos = await conexion.QuerySingleOrDefaultAsync<FilaBorrado>(
            new CommandDefinition(
                """
                SELECT r.del_sistema AS "DelSistema",
                       r.nombre      AS "Nombre",
                       (SELECT count(*)::int FROM usuarios u
                         WHERE u.rol_id = r.id) AS "Usuarios"
                  FROM roles r
                 WHERE r.id = @rolId
                """,
                new { rolId }, cancellationToken: ct));

        if (datos is null)
            return (false, "No se encontró el rol.");

        if (datos.DelSistema)
            return (false, "Los roles del sistema no se pueden eliminar.");

        if (datos.Usuarios > 0)
            return (false,
                $"Hay {datos.Usuarios} usuario(s) con este rol. " +
                "Cámbiales el rol antes de eliminarlo: si desapareciera, " +
                "quedarían sin permisos y sin saber por qué.");

        await conexion.ExecuteAsync(new CommandDefinition(
            "DELETE FROM roles WHERE id = @rolId",
            new { rolId }, cancellationToken: ct));

        return (true, null);
    }

    /// <summary>Los permisos de un usuario, por su rol.</summary>
    public async Task<string[]> PermisosDeUsuarioAsync(
        Guid usuarioId, CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);

        var texto = await conexion.ExecuteScalarAsync<string?>(
            new CommandDefinition(
                """
                SELECT string_agg(rp.permiso, ',')
                  FROM usuarios u
                  JOIN rol_permisos rp ON rp.rol_id = u.rol_id
                 WHERE u.id = @usuarioId AND u.activo
                """,
                new { usuarioId }, cancellationToken: ct));

        return string.IsNullOrWhiteSpace(texto)
            ? []
            : texto.Split(',', StringSplitOptions.RemoveEmptyEntries);
    }

    /// <summary>Cuántos usuarios activos tienen un permiso concreto.</summary>
    public async Task<int> ContarConPermisoAsync(
        string permiso, CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);

        return await conexion.ExecuteScalarAsync<int>(new CommandDefinition(
            """
            SELECT count(DISTINCT u.id)::int
              FROM usuarios u
              JOIN rol_permisos rp ON rp.rol_id = u.rol_id
             WHERE u.activo AND rp.permiso = @permiso
            """,
            new { permiso }, cancellationToken: ct));
    }

    public async Task<Guid?> BuscarPorClaveAsync(
        string clave, CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);

        return await conexion.ExecuteScalarAsync<Guid?>(new CommandDefinition(
            "SELECT id FROM roles WHERE clave = @clave",
            new { clave }, cancellationToken: ct));
    }

    // ----------------------------------------------------------------- apoyo

    private static async Task AsignarAsync(
        NpgsqlConnection conexion, NpgsqlTransaction transaccion,
        Guid rolId, string[] permisos, CancellationToken ct)
    {
        foreach (var permiso in permisos.Distinct())
        {
            // Se ignoran los permisos que no existen en el catálogo en vez de
            // fallar: si el panel manda uno viejo tras una actualización, es
            // mejor guardar el resto que rechazar la operación entera.
            await conexion.ExecuteAsync(new CommandDefinition(
                """
                INSERT INTO rol_permisos (rol_id, permiso)
                SELECT @rolId, @permiso
                 WHERE EXISTS (SELECT 1 FROM permisos WHERE clave = @permiso)
                ON CONFLICT DO NOTHING
                """,
                new { rolId, permiso },
                transaccion, cancellationToken: ct));
        }
    }

    private static string AClave(string nombre)
    {
        var limpio = nombre.Trim().ToLowerInvariant()
            .Replace('á', 'a').Replace('é', 'e').Replace('í', 'i')
            .Replace('ó', 'o').Replace('ú', 'u').Replace('ñ', 'n');

        var clave = new string(limpio
            .Select(c => char.IsLetterOrDigit(c) ? c : '_')
            .ToArray());

        while (clave.Contains("__")) clave = clave.Replace("__", "_");

        clave = clave.Trim('_');

        return clave.Length == 0
            ? "rol_" + Guid.NewGuid().ToString("N")[..8]
            : clave[..Math.Min(40, clave.Length)];
    }

    private sealed record FilaBorrado(bool DelSistema, string Nombre, int Usuarios);
}
