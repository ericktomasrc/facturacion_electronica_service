using Dapper;
using Npgsql;

namespace Facturacion.Persistencia;

/// <summary>El estado de la vigilancia del catálogo (una sola fila).</summary>
public record EstadoCatalogo(
    DateTime CreadoEn, DateTime? UltimoIntentoEn, DateTime? UltimoExitoEn,
    string? UltimoError, bool FallaAvisada);

/// <summary>Una lista de códigos que SUNAT publicó, comparada con la nuestra.</summary>
public record VersionCatalogo(
    string Huella, int Codigos, int Agregados, int Quitados,
    string? AgregadosMuestra, string? QuitadosMuestra,
    string Sha256Archivo, long Tamano, string? Publicado,
    DateTime VistoPrimera, DateTime VistoUltima);

/// <summary>
/// La vigilancia del catálogo de códigos de producto de SUNAT (migración 031).
/// Usa la conexión del operador, como el resto de Vigilancia SUNAT.
/// </summary>
public sealed class RepositorioCatalogoSunat
{
    private readonly string _cadenaOperador;

    public RepositorioCatalogoSunat(string cadenaConexionOperador)
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

    private const string ColumnasEstado = """
        creado_en AS "CreadoEn", ultimo_intento_en AS "UltimoIntentoEn",
        ultimo_exito_en AS "UltimoExitoEn", ultimo_error AS "UltimoError",
        falla_avisada AS "FallaAvisada"
        """;

    /// <summary>El estado, o null si nunca se intentó.</summary>
    public async Task<EstadoCatalogo?> EstadoAsync(CancellationToken ct)
    {
        await using var c = await AbrirAsync(ct);
        return await c.QuerySingleOrDefaultAsync<EstadoCatalogo>(new CommandDefinition(
            $"SELECT {ColumnasEstado} FROM vigilancia_catalogo WHERE id = 1",
            cancellationToken: ct));
    }

    /// <summary>Las versiones vistas, la más reciente primero.</summary>
    public async Task<IReadOnlyList<VersionCatalogo>> VersionesAsync(int cuantas, CancellationToken ct)
    {
        await using var c = await AbrirAsync(ct);
        var filas = await c.QueryAsync<VersionCatalogo>(new CommandDefinition(
            """
            SELECT huella AS "Huella", codigos AS "Codigos", agregados AS "Agregados",
                   quitados AS "Quitados", agregados_muestra AS "AgregadosMuestra",
                   quitados_muestra AS "QuitadosMuestra", sha256_archivo AS "Sha256Archivo",
                   tamano AS "Tamano", publicado AS "Publicado",
                   visto_primera AS "VistoPrimera", visto_ultima AS "VistoUltima"
            FROM vigilancia_catalogo_versiones
            ORDER BY visto_ultima DESC
            LIMIT @cuantas
            """,
            new { cuantas }, cancellationToken: ct));
        return filas.ToList();
    }

    /// <summary>
    /// Anota una revisión que salió bien. Devuelve true si esa lista de
    /// códigos es NUEVA (nunca vista): es la que puede merecer un aviso.
    /// </summary>
    public async Task<bool> RegistrarExitoAsync(
        string huella, int codigos, int agregados, int quitados,
        string? agregadosMuestra, string? quitadosMuestra,
        string sha256Archivo, long tamano, string? publicado, CancellationToken ct)
    {
        await using var c = await AbrirAsync(ct);
        await using var tx = await c.BeginTransactionAsync(ct);

        // (xmax = 0) es cierto solo si la fila se acaba de insertar.
        var nueva = await c.ExecuteScalarAsync<bool>(new CommandDefinition(
            """
            INSERT INTO vigilancia_catalogo_versiones
                (huella, codigos, agregados, quitados, agregados_muestra, quitados_muestra,
                 sha256_archivo, tamano, publicado)
            VALUES (@huella, @codigos, @agregados, @quitados, @agregadosMuestra, @quitadosMuestra,
                    @sha256Archivo, @tamano, @publicado)
            ON CONFLICT (huella) DO UPDATE
               SET visto_ultima = now(),
                   sha256_archivo = EXCLUDED.sha256_archivo,
                   tamano = EXCLUDED.tamano,
                   publicado = EXCLUDED.publicado
            RETURNING (xmax = 0)
            """,
            new { huella, codigos, agregados, quitados, agregadosMuestra, quitadosMuestra,
                  sha256Archivo, tamano, publicado },
            tx, cancellationToken: ct));

        await c.ExecuteAsync(new CommandDefinition(
            """
            INSERT INTO vigilancia_catalogo (id, ultimo_intento_en, ultimo_exito_en, ultimo_error, falla_avisada)
            VALUES (1, now(), now(), NULL, false)
            ON CONFLICT (id) DO UPDATE
               SET ultimo_intento_en = now(), ultimo_exito_en = now(),
                   ultimo_error = NULL, falla_avisada = false
            """,
            transaction: tx, cancellationToken: ct));

        await tx.CommitAsync(ct);
        return nueva;
    }

    /// <summary>Anota una revisión que falló y devuelve el estado que queda.</summary>
    public async Task<EstadoCatalogo> RegistrarFallaAsync(string error, CancellationToken ct)
    {
        await using var c = await AbrirAsync(ct);
        return await c.QuerySingleAsync<EstadoCatalogo>(new CommandDefinition(
            $"""
            INSERT INTO vigilancia_catalogo (id, ultimo_intento_en, ultimo_error)
            VALUES (1, now(), @error)
            ON CONFLICT (id) DO UPDATE
               SET ultimo_intento_en = now(), ultimo_error = EXCLUDED.ultimo_error
            RETURNING {ColumnasEstado}
            """,
            new { error = error.Length > 1000 ? error[..1000] : error },
            cancellationToken: ct));
    }

    /// <summary>Crea la alerta (la manda por correo la vuelta de 5 minutos) y, si es de falla, la marca avisada.</summary>
    public async Task CrearAlertaAsync(
        string tipo, string gravedad, string titulo, string detalle, bool esFalla, CancellationToken ct)
    {
        await using var c = await AbrirAsync(ct);
        await using var tx = await c.BeginTransactionAsync(ct);

        await c.ExecuteAsync(new CommandDefinition(
            """
            INSERT INTO vigilancia_alertas (tipo, gravedad, titulo, detalle)
            VALUES (@tipo, @gravedad, @titulo, @detalle)
            """,
            new { tipo, gravedad, titulo, detalle = detalle.Length > 3000 ? detalle[..3000] : detalle },
            tx, cancellationToken: ct));

        if (esFalla)
            await c.ExecuteAsync(new CommandDefinition(
                "UPDATE vigilancia_catalogo SET falla_avisada = true WHERE id = 1",
                transaction: tx, cancellationToken: ct));

        await tx.CommitAsync(ct);
    }

    /// <summary>
    /// El estado, creándolo si no existe: su fecha de creación es desde
    /// cuándo se cuenta el primer recordatorio.
    /// </summary>
    public async Task<EstadoCatalogo> IniciarAsync(CancellationToken ct)
    {
        await using var c = await AbrirAsync(ct);
        await c.ExecuteAsync(new CommandDefinition(
            "INSERT INTO vigilancia_catalogo (id) VALUES (1) ON CONFLICT (id) DO NOTHING",
            cancellationToken: ct));
        return await c.QuerySingleAsync<EstadoCatalogo>(new CommandDefinition(
            $"SELECT {ColumnasEstado} FROM vigilancia_catalogo WHERE id = 1",
            cancellationToken: ct));
    }

    /// <summary>Cuándo se mandó el último recordatorio de comparar el catálogo.</summary>
    public async Task<DateTime?> UltimoRecordatorioAsync(CancellationToken ct)
    {
        await using var c = await AbrirAsync(ct);
        return await c.ExecuteScalarAsync<DateTime?>(new CommandDefinition(
            "SELECT max(creada_en) FROM vigilancia_alertas WHERE tipo = 'catalogo_recordatorio'",
            cancellationToken: ct));
    }
}