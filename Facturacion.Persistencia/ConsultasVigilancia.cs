using Dapper;
using Npgsql;

namespace Facturacion.Persistencia;

/// <summary>Una página de resultados, contada en la base.</summary>
public record PaginaDe<T>(int Total, int Pagina, int Tamano, IReadOnlyList<T> Items)
{
    public int Paginas => Total == 0 ? 1 : (Total + Tamano - 1) / Tamano;
}

/// <summary>Cuántos hay de cada cosa: los números de las pestañas.</summary>
public record ConteoVigilancia(int CodigosNuevos, int CodigosTotal, int Correos);

/// <summary>
/// LAS LISTAS DE VIGILANCIA SUNAT, PAGINADAS EN LA BASE (14 de octubre de 2026).
///
/// Antes la pantalla traía todos los códigos de golpe (hasta mil) y los
/// pintaba uno debajo de otro. Con cientos, la página era interminable y los
/// correos quedaban al fondo. Ahora la base cuenta, filtra, busca y devuelve
/// una página; la pantalla muestra pestañas y un paginador.
///
/// Solo lee, con la conexión del operador, las mismas tablas de la 029. No
/// hace falta migración.
/// </summary>
public sealed class ConsultasVigilancia
{
    public const int TamanoMaximo = 100;

    private readonly string _cadenaOperador;

    public ConsultasVigilancia(string cadenaConexionOperador)
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

    // El número del código, sin prefijos («ERR-3496» → 3496). NULL si no tiene.
    private const string Numero = "NULLIF(substring(c.codigo from '([0-9]+)$'), '')::int";

    /// <summary>
    /// Los filtros de la pestaña de códigos. Lo mismo que pinta la pantalla:
    /// 0 aceptado; 100–3999 rechazo o error del envío; observación o 4000+.
    /// </summary>
    private static string Filtro(string filtro) => filtro switch
    {
        "nuevos"        => "c.origen = 'nuevo' AND c.revisado_en IS NULL",
        "rechazos"      => $"c.clase = 'respuesta' AND {Numero} BETWEEN 100 AND 3999",
        "observaciones" => $"(c.clase = 'observacion' OR {Numero} >= 4000)",
        "aceptados"     => $"c.clase = 'respuesta' AND {Numero} = 0",
        _               => "true"
    };

    public static readonly string[] Filtros = ["nuevos", "todos", "rechazos", "observaciones", "aceptados"];

    public async Task<ConteoVigilancia> ContarAsync(CancellationToken ct)
    {
        await using var c = await AbrirAsync(ct);
        return await c.QuerySingleAsync<ConteoVigilancia>(new CommandDefinition(
            """
            SELECT (SELECT count(*)::int FROM codigos_sunat
                     WHERE origen = 'nuevo' AND revisado_en IS NULL) AS "CodigosNuevos",
                   (SELECT count(*)::int FROM codigos_sunat)          AS "CodigosTotal",
                   (SELECT count(*)::int FROM vigilancia_correos
                     WHERE quitado_en IS NULL)                         AS "Correos"
            """,
            cancellationToken: ct));
    }

    /// <summary>
    /// Una página de códigos. <paramref name="q"/> busca en el código, en lo
    /// que dijo SUNAT y en la nota de quien lo revisó.
    /// </summary>
    public async Task<PaginaDe<CodigoSunatVisto>> CodigosAsync(
        string filtro, string? q, int pagina, int tamano, CancellationToken ct)
    {
        tamano = Math.Clamp(tamano, 5, TamanoMaximo);
        pagina = Math.Max(1, pagina);

        var donde = Filtro(filtro);
        string? patron = null;

        if (!string.IsNullOrWhiteSpace(q))
        {
            // %, _ y \ se buscan tal cual, no como comodines.
            patron = "%" + q.Trim().Replace("\\", "\\\\").Replace("%", "\\%").Replace("_", "\\_") + "%";
            donde += " AND (c.codigo ILIKE @patron OR c.ejemplo_mensaje ILIKE @patron OR c.nota ILIKE @patron)";
        }

        await using var conexion = await AbrirAsync(ct);

        var total = await conexion.ExecuteScalarAsync<int>(new CommandDefinition(
            $"SELECT count(*)::int FROM codigos_sunat c WHERE {donde}",
            new { patron }, cancellationToken: ct));

        var items = (await conexion.QueryAsync<CodigoSunatVisto>(new CommandDefinition(
            $"""
            SELECT c.codigo            AS "Codigo",
                   c.clase             AS "Clase",
                   c.primera_vez       AS "PrimeraVez",
                   c.ultima_vez        AS "UltimaVez",
                   c.veces             AS "Veces",
                   (SELECT count(*)::int FROM codigos_sunat_empresas e
                     WHERE e.codigo = c.codigo AND e.clase = c.clase) AS "Empresas",
                   c.ejemplo_mensaje   AS "EjemploMensaje",
                   t.razon_social      AS "EjemploEmpresa",
                   t.ruc               AS "EjemploRuc",
                   c.ejemplo_documento AS "EjemploDocumento",
                   c.origen            AS "Origen",
                   c.revisado_en       AS "RevisadoEn",
                   c.revisado_correo   AS "RevisadoCorreo",
                   c.nota              AS "Nota"
              FROM codigos_sunat c
              LEFT JOIN tenants t ON t.id = c.ejemplo_tenant_id
             WHERE {donde}
             ORDER BY (c.origen = 'nuevo' AND c.revisado_en IS NULL) DESC,
                      c.ultima_vez DESC, c.codigo, c.clase
             LIMIT @tamano OFFSET @desde
            """,
            new { patron, tamano, desde = (pagina - 1) * tamano },
            cancellationToken: ct))).ToList();

        return new PaginaDe<CodigoSunatVisto>(total, pagina, tamano, items);
    }

    /// <summary>Una página de la lista de correos para alertas (los vigentes).</summary>
    public async Task<PaginaDe<CorreoAlerta>> CorreosAsync(int pagina, int tamano, CancellationToken ct)
    {
        tamano = Math.Clamp(tamano, 5, TamanoMaximo);
        pagina = Math.Max(1, pagina);

        await using var conexion = await AbrirAsync(ct);

        var total = await conexion.ExecuteScalarAsync<int>(new CommandDefinition(
            "SELECT count(*)::int FROM vigilancia_correos WHERE quitado_en IS NULL",
            cancellationToken: ct));

        var items = (await conexion.QueryAsync<CorreoAlerta>(new CommandDefinition(
            """
            SELECT id              AS "Id",
                   correo          AS "Correo",
                   agregado_correo AS "AgregadoCorreo",
                   agregado_en     AS "AgregadoEn"
              FROM vigilancia_correos
             WHERE quitado_en IS NULL
             ORDER BY agregado_en, id
             LIMIT @tamano OFFSET @desde
            """,
            new { tamano, desde = (pagina - 1) * tamano },
            cancellationToken: ct))).ToList();

        return new PaginaDe<CorreoAlerta>(total, pagina, tamano, items);
    }
}