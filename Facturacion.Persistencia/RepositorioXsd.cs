using System.Security.Cryptography;
using Dapper;
using Npgsql;

namespace Facturacion.Persistencia;

/// <summary>Lo que el Worker tiene cargado de verdad (una sola fila).</summary>
public record EstadoXsd(string Maquina, DateTime InformadoEn, string MoldesJson, bool Bloquea, string? Huella);

/// <summary>Un archivo subido: su ruta (maindoc/… o common/…) y su contenido.</summary>
public record ArchivoXsd(string Ruta, byte[] Contenido);

/// <summary>Lo subido, sin el contenido: para la pantalla.</summary>
public record SubidaXsd(int Archivos, DateTime? UltimaEn, string? UltimaPor);

/// <summary>Un error de un XML contra su molde, para guardar.</summary>
public record ErrorXsdNuevo(int Linea, int Posicion, string Mensaje, string Original);

/// <summary>Un error guardado, para la pantalla.</summary>
public record AvisoXsd(
    long Id, DateTime CreadoEn, string? Ruc, string Documento, string? Raiz, string? Esquema,
    int Linea, int Posicion, string Mensaje, string Original);

/// <summary>
/// LOS ESQUEMAS XSD (migración 033): los archivos que se suben desde el panel,
/// lo que el Worker tiene cargado y los XML que no cumplieron su molde.
///
/// Con la conexión del operador, como el resto de Vigilancia SUNAT: son de la
/// plataforma entera, no de una empresa.
/// </summary>
public sealed class RepositorioXsd
{
    private readonly string _cadenaOperador;

    public RepositorioXsd(string cadenaConexionOperador)
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

    // ------------------------------------------------------------ archivos

    /// <summary>
    /// Guarda los archivos subidos. Uno con la misma ruta REEMPLAZA al anterior
    /// (es la forma de actualizar un molde). Todo o nada.
    /// </summary>
    public async Task<int> GuardarAsync(IReadOnlyList<ArchivoXsd> archivos, string quien, CancellationToken ct)
    {
        await using var c = await AbrirAsync(ct);
        await using var tx = await c.BeginTransactionAsync(ct);

        foreach (var a in archivos)
        {
            await c.ExecuteAsync(new CommandDefinition(
                """
                INSERT INTO xsd_esquemas (ruta, contenido, sha256, tamano, subido_por)
                VALUES (@ruta, @contenido, @sha256, @tamano, @quien)
                ON CONFLICT (ruta) DO UPDATE
                   SET contenido = EXCLUDED.contenido,
                       sha256 = EXCLUDED.sha256,
                       tamano = EXCLUDED.tamano,
                       subido_en = now(),
                       subido_por = EXCLUDED.subido_por
                 WHERE xsd_esquemas.sha256 <> EXCLUDED.sha256
                """,
                new
                {
                    ruta = a.Ruta,
                    contenido = a.Contenido,
                    sha256 = Convert.ToHexString(SHA256.HashData(a.Contenido)).ToLowerInvariant(),
                    tamano = a.Contenido.Length,
                    quien
                },
                tx, cancellationToken: ct));
        }

        await tx.CommitAsync(ct);
        return archivos.Count;
    }

    /// <summary>
    /// Una huella de todo lo subido: si cambia, el Worker vuelve a copiar.
    /// Vacía si no se subió nada.
    /// </summary>
    public async Task<string> HuellaAsync(CancellationToken ct)
    {
        await using var c = await AbrirAsync(ct);
        return await c.ExecuteScalarAsync<string>(new CommandDefinition(
            "SELECT COALESCE(md5(string_agg(ruta || ':' || sha256, ',' ORDER BY ruta)), '') FROM xsd_esquemas",
            cancellationToken: ct)) ?? "";
    }

    public async Task<IReadOnlyList<ArchivoXsd>> LeerTodosAsync(CancellationToken ct)
    {
        await using var c = await AbrirAsync(ct);
        var filas = await c.QueryAsync<ArchivoXsd>(new CommandDefinition(
            """SELECT ruta AS "Ruta", contenido AS "Contenido" FROM xsd_esquemas ORDER BY ruta""",
            cancellationToken: ct));
        return filas.ToList();
    }

    public async Task<SubidaXsd> SubidaAsync(CancellationToken ct)
    {
        await using var c = await AbrirAsync(ct);
        return await c.QuerySingleAsync<SubidaXsd>(new CommandDefinition(
            """
            SELECT count(*)::int AS "Archivos",
                   max(subido_en) AS "UltimaEn",
                   (SELECT subido_por FROM xsd_esquemas ORDER BY subido_en DESC LIMIT 1) AS "UltimaPor"
              FROM xsd_esquemas
            """,
            cancellationToken: ct));
    }

    // -------------------------------------------------------------- estado

    public async Task InformarEstadoAsync(
        string maquina, string moldesJson, bool bloquea, string? huella, CancellationToken ct)
    {
        await using var c = await AbrirAsync(ct);
        await c.ExecuteAsync(new CommandDefinition(
            """
            INSERT INTO xsd_estado (id, maquina, informado_en, moldes, bloquea, huella)
            VALUES (1, @maquina, now(), @moldes::jsonb, @bloquea, @huella)
            ON CONFLICT (id) DO UPDATE
               SET maquina = EXCLUDED.maquina, informado_en = now(), moldes = EXCLUDED.moldes,
                   bloquea = EXCLUDED.bloquea, huella = EXCLUDED.huella
            """,
            new { maquina, moldes = moldesJson, bloquea, huella }, cancellationToken: ct));
    }

    public async Task<EstadoXsd?> EstadoAsync(CancellationToken ct)
    {
        await using var c = await AbrirAsync(ct);
        return await c.QuerySingleOrDefaultAsync<EstadoXsd>(new CommandDefinition(
            """
            SELECT maquina AS "Maquina", informado_en AS "InformadoEn", moldes::text AS "MoldesJson",
                   bloquea AS "Bloquea", huella AS "Huella"
              FROM xsd_estado WHERE id = 1
            """,
            cancellationToken: ct));
    }

    // -------------------------------------------------------------- avisos

    /// <summary>Anota los errores de un XML contra su molde. Si no hay errores, nada.</summary>
    public async Task AnotarAsync(
        Guid? tenantId, string? ruc, string documento, string? raiz, string? esquema,
        IReadOnlyList<ErrorXsdNuevo> errores, CancellationToken ct)
    {
        if (errores.Count == 0) return;

        await using var c = await AbrirAsync(ct);

        // Un XML muy roto puede dar cientos de errores; con los 20 primeros
        // ya se ve qué pasa.
        foreach (var e in errores.Take(20))
        {
            await c.ExecuteAsync(new CommandDefinition(
                """
                INSERT INTO xsd_avisos (tenant_id, ruc, documento, raiz, esquema, linea, posicion, mensaje, original)
                VALUES (@tenantId, @ruc, @documento, @raiz, @esquema, @linea, @posicion, @mensaje, @original)
                """,
                new
                {
                    tenantId, ruc, documento, raiz, esquema,
                    linea = e.Linea, posicion = e.Posicion,
                    mensaje = Cortar(e.Mensaje), original = Cortar(e.Original)
                },
                cancellationToken: ct));
        }
    }

    /// <summary>Los avisos de los últimos <paramref name="dias"/> días, el más reciente primero.</summary>
    public async Task<(IReadOnlyList<AvisoXsd> Filas, int Total)> AvisosAsync(
        int pagina, int tamano, int dias, CancellationToken ct)
    {
        await using var c = await AbrirAsync(ct);

        var total = await c.ExecuteScalarAsync<int>(new CommandDefinition(
            "SELECT count(*)::int FROM xsd_avisos WHERE creado_en >= now() - make_interval(days => @dias)",
            new { dias }, cancellationToken: ct));

        var filas = await c.QueryAsync<AvisoXsd>(new CommandDefinition(
            """
            SELECT id AS "Id", creado_en AS "CreadoEn", ruc AS "Ruc", documento AS "Documento",
                   raiz AS "Raiz", esquema AS "Esquema", linea AS "Linea", posicion AS "Posicion",
                   mensaje AS "Mensaje", original AS "Original"
              FROM xsd_avisos
             WHERE creado_en >= now() - make_interval(days => @dias)
             ORDER BY creado_en DESC, id DESC
             LIMIT @tamano OFFSET @desde
            """,
            new { dias, tamano, desde = (pagina - 1) * tamano }, cancellationToken: ct));

        return (filas.ToList(), total);
    }

    private static string Cortar(string s) => s.Length > 2000 ? s[..2000] : s;
}