using Dapper;

namespace Facturacion.Persistencia;

/// <summary>Una empresa vista desde su portal: solo lo que se enseña.</summary>
public record EmpresaPortal(
    Guid Id,
    string Ruc,
    string RazonSocial,
    string? NombreComercial,
    string Identificador,
    string? ColorMarca,
    string? LogoRuta);

/// <summary>
/// Un comprobante visto desde el portal. Sin el cpe entero: el receptor ya
/// sabe lo que compró, y lo que no hace falta enseñar no se puede filtrar.
/// </summary>
public record ComprobantePortal(
    Guid Id,
    string TipoComprobante,
    string Serie,
    int Correlativo,
    DateTime FechaEmision,
    string Moneda,
    decimal ImporteTotal,
    string Estado,
    string? ReceptorNombre,
    bool TieneXml,
    bool TieneCdr)
{
    public string Numero => $"{Serie}-{Correlativo:D8}";
}

/// <summary>Los cinco datos de la opción A, ya limpios.</summary>
public record BusquedaPortal(
    string TipoDocumento,
    string NumeroDocumento,
    string Serie,
    int Correlativo,
    DateTime FechaEmision,
    decimal ImporteTotal);

/// <summary>Fallos recientes, para el límite de intentos.</summary>
public record FallosPortal(int PorDocumento, int PorIp);

/// <summary>
/// Lo que el portal del receptor necesita de la base.
///
/// DOS CLASES DE CONEXIÓN, Y NO SE MEZCLAN:
///
///   - Catálogo (sin RLS): empresas, accesos e intentos. Ninguna de esas
///     tablas guarda datos del comprobante.
///   - Sesión de la empresa (con RLS): todo lo que lee `comprobantes`. El
///     tenant de esa sesión sale SIEMPRE de la dirección del portal, nunca
///     de lo que manda el navegador.
///
/// Usa el rol de la aplicación, no el de operador: el portal es público y
/// tiene que poder lo justo.
/// </summary>
public sealed class RepositorioPortal
{
    // Los estados que existen para el portal. Un RECHAZADO no es un
    // comprobante, y uno que sigue en camino todavía no lo es.
    private const string EstadosVisibles =
        "('ACEPTADO', 'ACEPTADO_CON_OBSERVACIONES', 'ANULADO')";

    // Facturas, boletas y notas. Las guías, retenciones y percepciones no
    // tienen "comprador" con el mismo significado; se añaden cuando toque.
    private const string TiposVisibles = "('01', '03', '07', '08')";

    private const string ColumnasComprobante = """
        c.id                                   AS "Id",
        c.tipo_comprobante                     AS "TipoComprobante",
        c.serie                                AS "Serie",
        c.correlativo                          AS "Correlativo",
        c.fecha_emision                        AS "FechaEmision",
        c.moneda                               AS "Moneda",
        c.importe_total                        AS "ImporteTotal",
        c.estado                               AS "Estado",
        c.cpe->'receptor'->>'razonSocial'      AS "ReceptorNombre",
        (c.ruta_xml IS NOT NULL)               AS "TieneXml",
        (c.ruta_cdr IS NOT NULL)               AS "TieneCdr"
        """;

    private readonly FabricaSesiones _sesiones;

    public RepositorioPortal(FabricaSesiones sesiones)
    {
        _sesiones = sesiones ?? throw new ArgumentNullException(nameof(sesiones));
    }

    /// <summary>
    /// La empresa de la dirección, o null si no existe, está desactivada o no
    /// tiene identificador. Las tres cosas se ven igual desde fuera.
    /// </summary>
    public async Task<EmpresaPortal?> EmpresaAsync(
        string identificador, CancellationToken ct = default)
    {
        await using var conexion = await _sesiones.AbrirCatalogoAsync(ct);

        return await conexion.QuerySingleOrDefaultAsync<EmpresaPortal>(new CommandDefinition(
            """
            SELECT id               AS "Id",
                   ruc              AS "Ruc",
                   razon_social     AS "RazonSocial",
                   nombre_comercial AS "NombreComercial",
                   identificador    AS "Identificador",
                   color_marca      AS "ColorMarca",
                   logo_ruta        AS "LogoRuta"
              FROM tenants
             WHERE identificador = @identificador
               AND activo
            """,
            new { identificador }, cancellationToken: ct));
    }

    /// <summary>
    /// Los fallos de este documento en esta empresa (15 min) y los de esta IP
    /// en todas las empresas (1 hora).
    /// </summary>
    public async Task<FallosPortal> FallosRecientesAsync(
        Guid tenantId, string documentoHash, string ip, CancellationToken ct = default)
    {
        await using var conexion = await _sesiones.AbrirCatalogoAsync(ct);

        return await conexion.QuerySingleAsync<FallosPortal>(new CommandDefinition(
            """
            SELECT (SELECT count(*)::int FROM portal_intentos
                     WHERE tenant_id = @tenantId
                       AND documento = @documentoHash
                       AND NOT exito
                       AND ocurrido_en > now() - interval '15 minutes') AS "PorDocumento",

                   (SELECT count(*)::int FROM portal_intentos
                     WHERE ip = @ip
                       AND NOT exito
                       AND ocurrido_en > now() - interval '1 hour')     AS "PorIp"
            """,
            new { tenantId, documentoHash, ip }, cancellationToken: ct));
    }

    public async Task RegistrarIntentoAsync(
        Guid tenantId, string documentoHash, string ip, bool exito,
        CancellationToken ct = default)
    {
        await using var conexion = await _sesiones.AbrirCatalogoAsync(ct);

        await conexion.ExecuteAsync(new CommandDefinition(
            """
            INSERT INTO portal_intentos (tenant_id, documento, ip, exito)
            VALUES (@tenantId, @documentoHash, @ip, @exito)
            """,
            new { tenantId, documentoHash, ip, exito }, cancellationToken: ct));
    }

    /// <summary>
    /// Opción A: el comprobante que cuadra con los cinco datos, o null.
    ///
    /// Si dos cuadraran a la vez (una factura y una nota con la misma serie,
    /// número, fecha, importe y cliente), se devuelve la factura. Que pase es
    /// casi imposible, y aun así el cliente ve un comprobante suyo.
    /// </summary>
    public async Task<ComprobantePortal?> BuscarAsync(
        Guid tenantId, BusquedaPortal b, CancellationToken ct = default)
    {
        await using var sesion = await _sesiones.AbrirAsync(tenantId, ct);

        var fila = await sesion.Conexion.QueryFirstOrDefaultAsync<ComprobantePortal>(
            new CommandDefinition(
                $"""
                SELECT {ColumnasComprobante}
                  FROM comprobantes c
                 WHERE c.tenant_id     = @tenantId
                   AND c.serie         = @Serie
                   AND c.correlativo   = @Correlativo
                   AND c.fecha_emision = @FechaEmision::date
                   AND c.importe_total = @ImporteTotal
                   AND c.tipo_comprobante IN {TiposVisibles}
                   AND c.estado IN {EstadosVisibles}
                   AND c.cpe->'receptor'->>'tipoDocumento'   = @TipoDocumento
                   AND c.cpe->'receptor'->>'numeroDocumento' = @NumeroDocumento
                 ORDER BY c.tipo_comprobante
                 LIMIT 1
                """,
                new
                {
                    tenantId,
                    b.Serie,
                    b.Correlativo,
                    FechaEmision = b.FechaEmision.Date,
                    b.ImporteTotal,
                    b.TipoDocumento,
                    b.NumeroDocumento
                },
                sesion.Transaccion, cancellationToken: ct));

        await sesion.ConfirmarAsync(ct);
        return fila;
    }

    /// <summary>
    /// Un comprobante por id, dentro de la sesión de su empresa. Con los
    /// mismos filtros que la búsqueda: un acceso no abre lo que el portal no
    /// enseña.
    /// </summary>
    public async Task<ComprobantePortal?> ObtenerAsync(
        Guid tenantId, Guid comprobanteId, CancellationToken ct = default)
    {
        await using var sesion = await _sesiones.AbrirAsync(tenantId, ct);

        var fila = await sesion.Conexion.QuerySingleOrDefaultAsync<ComprobantePortal>(
            new CommandDefinition(
                $"""
                SELECT {ColumnasComprobante}
                  FROM comprobantes c
                 WHERE c.id = @comprobanteId
                   AND c.tipo_comprobante IN {TiposVisibles}
                   AND c.estado IN {EstadosVisibles}
                """,
                new { comprobanteId },
                sesion.Transaccion, cancellationToken: ct));

        await sesion.ConfirmarAsync(ct);
        return fila;
    }

    /// <summary>Crea un acceso. Se guarda el hash, nunca el identificador.</summary>
    public async Task CrearAccesoAsync(
        Guid tenantId, Guid comprobanteId, string hash, string origen, TimeSpan duracion,
        CancellationToken ct = default)
    {
        await using var conexion = await _sesiones.AbrirCatalogoAsync(ct);

        await conexion.ExecuteAsync(new CommandDefinition(
            """
            INSERT INTO portal_accesos (tenant_id, comprobante_id, hash, origen, expira_en)
            VALUES (@tenantId, @comprobanteId, @hash, @origen,
                    now() + make_interval(secs => @segundos))
            """,
            new { tenantId, comprobanteId, hash, origen, segundos = duracion.TotalSeconds },
            cancellationToken: ct));
    }

    /// <summary>
    /// El comprobante de un acceso vigente DE ESTA EMPRESA, y anota el uso.
    /// Null si no existe, es de otra empresa, caducó o se anuló: las cuatro
    /// cosas se ven igual desde fuera.
    /// </summary>
    public async Task<Guid?> ResolverAccesoAsync(
        Guid tenantId, string hash, CancellationToken ct = default)
    {
        await using var conexion = await _sesiones.AbrirCatalogoAsync(ct);

        return await conexion.QuerySingleOrDefaultAsync<Guid?>(new CommandDefinition(
            """
            UPDATE portal_accesos
               SET usos = usos + 1,
                   ultimo_uso_en = now()
             WHERE hash = @hash
               AND tenant_id = @tenantId
               AND anulado_en IS NULL
               AND expira_en > now()
            RETURNING comprobante_id
            """,
            new { tenantId, hash }, cancellationToken: ct));
    }
}