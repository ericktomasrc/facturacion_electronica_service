using Dapper;
using Npgsql;

namespace Facturacion.Persistencia;

/// <summary>Filtros de búsqueda de comprobantes.</summary>
public class FiltroComprobantes
{
    /// <summary>Busca en RUC, razón social, serie y número a la vez.</summary>
    public string? Texto { get; set; }

    public Guid? TenantId { get; set; }
    public string? TipoComprobante { get; set; }
    public string? Estado { get; set; }
    public DateTime? Desde { get; set; }
    public DateTime? Hasta { get; set; }

    public int Pagina { get; set; } = 1;
    public int PorPagina { get; set; } = 25;
}

/// <summary>Un comprobante en los resultados de búsqueda.</summary>
public record ComprobanteEncontrado(
    Guid Id,
    Guid TenantId,
    string Ruc,
    string RazonSocial,
    string TipoComprobante,
    string Numero,
    DateTime FechaEmision,
    string ReceptorNombre,
    string ReceptorDocumento,
    string Moneda,
    decimal ImporteTotal,
    string Estado,
    string? CodigoSunat,
    string? MensajeSunat,
    bool TieneXml,
    bool TieneCdr,
    DateTime CreadoEn);

/// <summary>Una guía en los resultados de búsqueda.</summary>
public record GuiaEncontrada(
    Guid Id,
    Guid TenantId,
    string Ruc,
    string RazonSocial,
    string TipoGuia,
    string Numero,
    DateTime FechaEmision,
    DateTime FechaTraslado,
    string DestinatarioNombre,
    string DestinatarioDoc,
    string MotivoTraslado,
    string ModalidadTraslado,
    decimal? PesoBruto,
    string Placa,
    string DireccionLlegada,
    string Estado,
    string? CodigoSunat,
    string? MensajeSunat,
    bool TieneXml,
    bool TieneCdr,
    DateTime CreadoEn)
{
    /// <summary>Si el vehículo puede salir.</summary>
    public bool PuedeIniciarTraslado =>
        Estado is "ACEPTADO" or "ACEPTADO_CON_OBSERVACIONES";
}

/// <summary>Guías con el total, para paginar.</summary>
public record PaginaGuias(
    IReadOnlyList<GuiaEncontrada> Resultados,
    int Total,
    int Pagina,
    int PorPagina)
{
    public int Paginas => (int)Math.Ceiling(Total / (double)PorPagina);
}

/// <summary>Resultados con el total, para poder paginar.</summary>
public record PaginaComprobantes(
    IReadOnlyList<ComprobanteEncontrado> Resultados,
    int Total,
    int Pagina,
    int PorPagina)
{
    public int Paginas => (int)Math.Ceiling(Total / (double)PorPagina);
}

/// <summary>
/// Búsqueda de comprobantes desde el panel de operación.
///
/// POR QUÉ EXISTE, Y POR QUÉ ESTÁ SEPARADA DE LO DEMÁS:
///
/// El repositorio de comprobantes trabaja siempre dentro de UN tenant, con
/// Row Level Security activo. Eso es correcto para la API que usan los
/// clientes, pero inútil para dar soporte: cuando alguien llama preguntando
/// por una factura, no siempre se sabe de qué empresa es.
///
/// Esta clase usa el rol de operador, que ve todas las empresas. Por eso el
/// endpoint que la expone está protegido con la clave de operador y no con
/// la de ningún emisor.
/// </summary>
public sealed class RepositorioConsultas
{
    private readonly string _cadenaOperador;

    public RepositorioConsultas(string cadenaConexionOperador)
    {
        _cadenaOperador = cadenaConexionOperador
            ?? throw new ArgumentNullException(nameof(cadenaConexionOperador));
    }

    public async Task<PaginaComprobantes> BuscarAsync(
        FiltroComprobantes filtro, CancellationToken ct = default)
    {
        await using var conexion = new NpgsqlConnection(_cadenaOperador);
        await conexion.OpenAsync(ct);

        var condiciones = new List<string>();
        var parametros = new DynamicParameters();

        // BÚSQUEDA POR TEXTO EN VARIOS CAMPOS A LA VEZ.
        //
        // Quien da soporte tiene en la cabeza un dato, no un campo: puede ser
        // el RUC, el nombre de la empresa, el número de la factura o el
        // documento del cliente. Obligarle a elegir en qué campo buscar le
        // hace probar cuatro veces.
        if (!string.IsNullOrWhiteSpace(filtro.Texto))
        {
            condiciones.Add("""
                (t.ruc ILIKE @texto
                 OR t.razon_social ILIKE @texto
                 OR c.serie || '-' || lpad(c.correlativo::text, 8, '0') ILIKE @texto
                 OR c.serie ILIKE @texto
                 OR c.cpe->'receptor'->>'razonSocial' ILIKE @texto
                 OR c.cpe->'receptor'->>'numeroDocumento' ILIKE @texto)
                """);

            parametros.Add("texto", $"%{filtro.Texto.Trim()}%");
        }

        if (filtro.TenantId is not null)
        {
            condiciones.Add("c.tenant_id = @tenantId");
            parametros.Add("tenantId", filtro.TenantId);
        }

        if (!string.IsNullOrWhiteSpace(filtro.TipoComprobante))
        {
            condiciones.Add("c.tipo_comprobante = @tipo");
            parametros.Add("tipo", filtro.TipoComprobante);
        }

        if (!string.IsNullOrWhiteSpace(filtro.Estado))
        {
            condiciones.Add("c.estado = @estado");
            parametros.Add("estado", filtro.Estado);
        }

        if (filtro.Desde is not null)
        {
            condiciones.Add("c.fecha_emision >= @desde");
            parametros.Add("desde", DateOnly.FromDateTime(filtro.Desde.Value));
        }

        if (filtro.Hasta is not null)
        {
            condiciones.Add("c.fecha_emision <= @hasta");
            parametros.Add("hasta", DateOnly.FromDateTime(filtro.Hasta.Value));
        }

        var donde = condiciones.Count == 0
            ? ""
            : " WHERE " + string.Join(" AND ", condiciones);

        // El total se cuenta aparte. Sin él no se puede mostrar cuántas
        // páginas hay, y quien busca no sabe si lo que ve es todo o el
        // principio de mil resultados.
        var total = await conexion.ExecuteScalarAsync<int>(new CommandDefinition(
            $"""
            SELECT count(*)::int
              FROM comprobantes c
              JOIN tenants t ON t.id = c.tenant_id
            {donde}
            """,
            parametros, cancellationToken: ct));

        var porPagina = Math.Clamp(filtro.PorPagina, 1, 200);
        var pagina = Math.Max(1, filtro.Pagina);

        parametros.Add("limite", porPagina);
        parametros.Add("saltar", (pagina - 1) * porPagina);

        var filas = await conexion.QueryAsync<ComprobanteEncontrado>(
            new CommandDefinition(
                $"""
                SELECT c.id               AS "Id",
                       c.tenant_id        AS "TenantId",
                       t.ruc              AS "Ruc",
                       t.razon_social     AS "RazonSocial",
                       c.tipo_comprobante AS "TipoComprobante",
                       c.serie || '-' || lpad(c.correlativo::text, 8, '0') AS "Numero",
                       c.fecha_emision    AS "FechaEmision",

                       COALESCE(c.cpe->'receptor'->>'razonSocial', '')
                                          AS "ReceptorNombre",
                       COALESCE(c.cpe->'receptor'->>'numeroDocumento', '')
                                          AS "ReceptorDocumento",

                       c.moneda           AS "Moneda",
                       c.importe_total    AS "ImporteTotal",
                       c.estado           AS "Estado",
                       c.codigo_sunat     AS "CodigoSunat",
                       c.mensaje_sunat    AS "MensajeSunat",

                       (c.ruta_xml IS NOT NULL) AS "TieneXml",
                       (c.ruta_cdr IS NOT NULL) AS "TieneCdr",

                       c.creado_en        AS "CreadoEn"

                  FROM comprobantes c
                  JOIN tenants t ON t.id = c.tenant_id
                {donde}
                 ORDER BY c.creado_en DESC
                 LIMIT @limite OFFSET @saltar
                """,
                parametros, cancellationToken: ct));

        return new PaginaComprobantes(filas.ToList(), total, pagina, porPagina);
    }

    // ---------------------------------------------------------------- guías

    /// <summary>
    /// Busca guías de remisión de todas las empresas.
    ///
    /// SEPARADO DE LA BÚSQUEDA DE COMPROBANTES porque son tablas distintas
    /// con campos distintos. Unirlas con un UNION obligaría a inventar
    /// columnas vacías: una guía no tiene importe ni moneda, y un comprobante
    /// no tiene destino ni vehículo.
    ///
    /// Quien da soporte tampoco las busca igual: en un comprobante busca por
    /// importe o cliente; en una guía, por destino o placa.
    /// </summary>
    public async Task<PaginaGuias> BuscarGuiasAsync(
        FiltroComprobantes filtro, CancellationToken ct = default)
    {
        await using var conexion = new NpgsqlConnection(_cadenaOperador);
        await conexion.OpenAsync(ct);

        var condiciones = new List<string>();
        var parametros = new DynamicParameters();

        if (!string.IsNullOrWhiteSpace(filtro.Texto))
        {
            condiciones.Add("""
                (t.ruc ILIKE @texto
                 OR t.razon_social ILIKE @texto
                 OR g.serie || '-' || lpad(g.correlativo::text, 8, '0') ILIKE @texto
                 OR g.destinatario_nombre ILIKE @texto
                 OR g.destinatario_doc ILIKE @texto
                 OR g.gre->'vehiculo'->>'placa' ILIKE @texto)
                """);

            parametros.Add("texto", $"%{filtro.Texto.Trim()}%");
        }

        if (filtro.TenantId is not null)
        {
            condiciones.Add("g.tenant_id = @tenantId");
            parametros.Add("tenantId", filtro.TenantId);
        }

        if (!string.IsNullOrWhiteSpace(filtro.Estado))
        {
            condiciones.Add("g.estado = @estado");
            parametros.Add("estado", filtro.Estado);
        }

        if (filtro.Desde is not null)
        {
            condiciones.Add("g.fecha_emision >= @desde");
            parametros.Add("desde", DateOnly.FromDateTime(filtro.Desde.Value));
        }

        if (filtro.Hasta is not null)
        {
            condiciones.Add("g.fecha_emision <= @hasta");
            parametros.Add("hasta", DateOnly.FromDateTime(filtro.Hasta.Value));
        }

        var donde = condiciones.Count == 0
            ? ""
            : " WHERE " + string.Join(" AND ", condiciones);

        var total = await conexion.ExecuteScalarAsync<int>(new CommandDefinition(
            $"""
            SELECT count(*)::int
              FROM guias g
              JOIN tenants t ON t.id = g.tenant_id
            {donde}
            """,
            parametros, cancellationToken: ct));

        var porPagina = Math.Clamp(filtro.PorPagina, 1, 200);
        var pagina = Math.Max(1, filtro.Pagina);

        parametros.Add("limite", porPagina);
        parametros.Add("saltar", (pagina - 1) * porPagina);

        var filas = await conexion.QueryAsync<GuiaEncontrada>(
            new CommandDefinition(
                $"""
                SELECT g.id            AS "Id",
                       g.tenant_id     AS "TenantId",
                       t.ruc           AS "Ruc",
                       t.razon_social  AS "RazonSocial",
                       g.tipo_guia     AS "TipoGuia",
                       g.serie || '-' || lpad(g.correlativo::text, 8, '0') AS "Numero",
                       g.fecha_emision AS "FechaEmision",
                       g.fecha_traslado AS "FechaTraslado",
                       g.destinatario_nombre AS "DestinatarioNombre",
                       g.destinatario_doc    AS "DestinatarioDoc",
                       g.motivo_traslado     AS "MotivoTraslado",
                       g.modalidad_traslado  AS "ModalidadTraslado",
                       g.peso_bruto    AS "PesoBruto",

                       COALESCE(g.gre->'vehiculo'->>'placa', '') AS "Placa",

                       -- El punto de llegada es lo que busca quien da
                       -- soporte: "¿a dónde iba ese camión?"
                       COALESCE(g.gre->'puntoLlegada'->>'direccion', '')
                                       AS "DireccionLlegada",

                       g.estado        AS "Estado",
                       g.codigo_sunat  AS "CodigoSunat",
                       g.mensaje_sunat AS "MensajeSunat",

                       (g.ruta_xml IS NOT NULL) AS "TieneXml",
                       (g.ruta_cdr IS NOT NULL) AS "TieneCdr",

                       g.creado_en     AS "CreadoEn"

                  FROM guias g
                  JOIN tenants t ON t.id = g.tenant_id
                {donde}
                 ORDER BY g.creado_en DESC
                 LIMIT @limite OFFSET @saltar
                """,
                parametros, cancellationToken: ct));

        return new PaginaGuias(filas.ToList(), total, pagina, porPagina);
    }

    /// <summary>Ruta de un archivo de guía, para descargarlo como operador.</summary>
    public async Task<(Guid TenantId, string Numero, string? Ruta)?>
        RutaArchivoGuiaAsync(Guid guiaId, string tipo, CancellationToken ct = default)
    {
        var columna = tipo switch
        {
            "xml" => "g.ruta_xml",
            "cdr" => "g.ruta_cdr",
            _ => throw new ArgumentException(
                "Solo se pueden descargar 'xml' y 'cdr'.", nameof(tipo))
        };

        await using var conexion = new NpgsqlConnection(_cadenaOperador);
        await conexion.OpenAsync(ct);

        return await conexion.QuerySingleOrDefaultAsync<
            (Guid TenantId, string Numero, string? Ruta)?>(
            new CommandDefinition(
                $"""
                SELECT g.tenant_id AS "TenantId",
                       g.serie || '-' || lpad(g.correlativo::text, 8, '0') AS "Numero",
                       {columna}   AS "Ruta"
                  FROM guias g
                 WHERE g.id = @guiaId
                """,
                new { guiaId }, cancellationToken: ct));
    }

    /// <summary>Historial de intentos de un comprobante, sin filtro de tenant.</summary>
    public async Task<IReadOnlyList<IntentoEnvio>> HistorialAsync(
        Guid comprobanteId, CancellationToken ct = default)
    {
        await using var conexion = new NpgsqlConnection(_cadenaOperador);
        await conexion.OpenAsync(ct);

        var filas = await conexion.QueryAsync<IntentoEnvio>(
            new CommandDefinition(
                """
                SELECT id              AS "Id",
                       comprobante_id  AS "ComprobanteId",
                       intento_nro     AS "IntentoNro",
                       estado_anterior AS "EstadoAnterior",
                       estado_nuevo    AS "EstadoNuevo",
                       codigo_sunat    AS "CodigoSunat",
                       mensaje         AS "Mensaje",
                       duracion_ms     AS "DuracionMs",
                       worker          AS "Worker",
                       creado_en       AS "CreadoEn"
                  FROM envio_intentos
                 WHERE comprobante_id = @comprobanteId
                 ORDER BY intento_nro
                """,
                new { comprobanteId }, cancellationToken: ct));

        return filas.ToList();
    }

    /// <summary>
    /// Devuelve el tenant y la ruta de un archivo, para que el operador pueda
    /// descargarlo sin conocer la clave del emisor.
    /// </summary>
    public async Task<(Guid TenantId, string Ruc, string Numero, string? Ruta)?>
        RutaArchivoAsync(Guid comprobanteId, string tipo, CancellationToken ct = default)
    {
        var columna = tipo switch
        {
            "xml" => "c.ruta_xml",
            "cdr" => "c.ruta_cdr",
            _ => throw new ArgumentException(
                "Solo se pueden descargar 'xml' y 'cdr'. El PDF se genera " +
                "bajo demanda y no tiene ruta.", nameof(tipo))
        };

        await using var conexion = new NpgsqlConnection(_cadenaOperador);
        await conexion.OpenAsync(ct);

        var fila = await conexion.QuerySingleOrDefaultAsync<
            (Guid TenantId, string Ruc, string Numero, string? Ruta)?>(
            new CommandDefinition(
                $"""
                SELECT c.tenant_id AS "TenantId",
                       t.ruc       AS "Ruc",
                       c.serie || '-' || lpad(c.correlativo::text, 8, '0') AS "Numero",
                       {columna}   AS "Ruta"
                  FROM comprobantes c
                  JOIN tenants t ON t.id = c.tenant_id
                 WHERE c.id = @comprobanteId
                """,
                new { comprobanteId }, cancellationToken: ct));

        return fila;
    }
}
