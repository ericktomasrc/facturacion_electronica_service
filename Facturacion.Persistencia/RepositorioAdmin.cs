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
    int Claves,
    string? UsuarioSol,
    bool TieneClaveSol,
    bool GreHabilitado,
    string? GreClientId,
    bool TieneGreSecret,

    // La marca (migración 020). LogoVersion es un resumen de la ruta del
    // logo: cambia cuando se sube otro, y así el panel sabe que tiene que
    // volver a pedir la imagen en vez de enseñar la que tiene guardada. La
    // ruta en sí no sale del servicio.
    string? Identificador,
    string? ColorMarca,
    string? CorreoRespuesta,
    string? LogoVersion,

    // El alta (migración 024). DAPPER EMPAREJA POR POSICIÓN: estas columnas
    // van al final de la consulta en este mismo orden.
    string EstadoAlta,
    DateTime? AltaConfirmadaEn,
    DateTime? AbandonadaEn,
    string? ClaveAltaNombre,
    string? ClaveAltaPrefijo,

    // La dirección, para poder corregirla desde el panel, y si alguien la
    // revisó a propósito.
    string Ubigeo,
    string Direccion,
    string Distrito,
    string Provincia,
    string Departamento,
    DateTime? DireccionRevisadaEn,

    // Migración 026, AL FINAL: copia oculta al emisor de cada correo de
    // comprobante. Opcional, desactivada por defecto.
    bool CopiaAlEmisor)
{
    public bool EsProduccion => Ambiente == "produccion";

    public bool TieneLogo => LogoVersion is not null;

    /// <summary>Puede emitir guías en producción.</summary>
    public bool GreListo =>
        GreHabilitado &&
        !string.IsNullOrWhiteSpace(GreClientId) &&
        TieneGreSecret;
}

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

    /// <summary>
    /// El {empresa} del portal. Opcional al dar de alta: se puede poner
    /// después, pero una sola vez.
    /// </summary>
    public string? Identificador { get; set; }
}

/// <summary>Cómo terminó un intento de guardar la marca.</summary>
public enum ResultadoMarca
{
    Guardada,
    NoExiste,

    /// <summary>
    /// Ya tenía otro identificador. No se guardó NADA de la petición: ni el
    /// color ni el correo. A medias sería peor, porque el panel diría
    /// "error" y la mitad sí habría cambiado.
    /// </summary>
    IdentificadorFijo
}

/// <summary>Solo para leer el identificador actual con FOR UPDATE.</summary>
public record IdentificadorTenant(Guid Id, string? Identificador);

/// <summary>Lo que hace falta para guardar o servir el logo.</summary>
public record LogoTenant(string Ruc, string? LogoRuta);

/// <summary>Una serie de numeración.</summary>
/// <param name="Ajustado">
/// Migración 027: cuántos números se saltaron con «Ajustar correlativo»
/// (la suma de hasta − desde). Sirve para que «Último al crearla» siga
/// diciendo la verdad después de un ajuste.
/// </param>
/// <param name="Comprobantes">
/// Cuántos comprobantes se emitieron con esta serie. Determina si se puede
/// eliminar: con uno solo, ya hay histórico que conservar.
/// </param>
public record SerieAdmin(
    Guid Id,
    string TipoComprobante,
    string Serie,
    int UltimoCorrelativo,
    bool Activo,
    DateTime CreadoEn,
    int Comprobantes,
    int Ajustado = 0)
{
    /// <summary>
    /// Una serie sin comprobantes se puede borrar sin consecuencias.
    /// Con comprobantes, borrarla dejaría huérfano el rastro de esa
    /// numeración, y eso es un problema tributario, no de datos.
    /// </summary>
    public bool SePuedeEliminar => Comprobantes == 0;
}

/// <summary>La serie que ya existía cuando se intentó crearla otra vez.</summary>
public record SerieExistente(Guid Id, int UltimoCorrelativo, bool Activo, int Comprobantes);

/// <summary>
/// Resultado de dar de alta una serie: o el id de la nueva, o la que ya
/// existía (y entonces no se tocó nada).
/// </summary>
public record AltaSerie(Guid? Id, SerieExistente? Existente);

public enum ResultadoAjuste { Ajustado, NoExiste, NoSube }

/// <summary>Resultado de «Ajustar correlativo».</summary>
/// <param name="Desde">El último correlativo que tenía (o el actual, si no sube).</param>
public record AjusteSerie(ResultadoAjuste Resultado, int Desde, int Hasta, string Serie);

/// <summary>La fila de la serie, leída con su candado, para ajustarla.</summary>
public record SerieBloqueada(string TipoComprobante, string Serie, int UltimoCorrelativo);

/// <summary>Una línea de la bitácora de correlativos (migración 027).</summary>
public record AjusteSerieAdmin(
    long Id,
    Guid SerieId,
    string TipoComprobante,
    string Serie,
    string Accion,
    int Desde,
    int Hasta,
    string Motivo,
    string Correo,
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
                         WHERE k.tenant_id = t.id AND k.activo)  AS "Claves",

                       t.usuario_sol      AS "UsuarioSol",
                       (t.clave_sol_cifrada IS NOT NULL) AS "TieneClaveSol",
                       t.gre_habilitado   AS "GreHabilitado",
                       t.gre_client_id    AS "GreClientId",
                       (t.gre_client_secret_cifrado IS NOT NULL) AS "TieneGreSecret",

                       t.identificador    AS "Identificador",
                       t.color_marca      AS "ColorMarca",
                       t.correo_respuesta AS "CorreoRespuesta",
                       md5(t.logo_ruta)   AS "LogoVersion",

                       t.estado_alta        AS "EstadoAlta",
                       t.alta_confirmada_en AS "AltaConfirmadaEn",
                       t.abandonada_en      AS "AbandonadaEn",
                       ka.nombre            AS "ClaveAltaNombre",
                       ka.prefijo::text     AS "ClaveAltaPrefijo",

                       t.ubigeo::text       AS "Ubigeo",
                       t.direccion          AS "Direccion",
                       t.distrito           AS "Distrito",
                       t.provincia          AS "Provincia",
                       t.departamento       AS "Departamento",
                       t.direccion_revisada_en AS "DireccionRevisadaEn",

                       t.copia_al_emisor    AS "CopiaAlEmisor"

                  FROM tenants t
                  LEFT JOIN claves_alta ka ON ka.id = t.creado_por_clave_alta
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
                 max_concurrencia, identificador, direccion_revisada_en)
            VALUES
                (@Ruc, @RazonSocial, @NombreComercial, @Ubigeo, @Direccion,
                 @Distrito, @Provincia, @Departamento, @Ambiente, @UsuarioSol,
                 @MaxConcurrencia, @Identificador,
                 -- El panel ya no trae LIMA por defecto y exige la
                 -- dirección: quien la escribió la revisó.
                 now())
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

    /// <summary>
    /// Corrige la dirección y la marca como revisada.
    ///
    /// LOS COMPROBANTES YA EMITIDOS NO CAMBIAN: su XML se firmó con la que
    /// tenían. Esto vale para los siguientes.
    /// </summary>
    public async Task<bool> GuardarDireccionAsync(
        Guid id, string ubigeo, string direccion, string distrito,
        string provincia, string departamento, CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);

        var filas = await conexion.ExecuteAsync(new CommandDefinition(
            """
            UPDATE tenants
               SET ubigeo = @ubigeo,
                   direccion = @direccion,
                   distrito = @distrito,
                   provincia = @provincia,
                   departamento = @departamento,
                   direccion_revisada_en = now()
             WHERE id = @id
            """,
            new { id, ubigeo, direccion, distrito, provincia, departamento },
            cancellationToken: ct));

        return filas > 0;
    }

    // ---------------------------------------------------------------- marca

    /// <summary>
    /// Guarda el identificador del portal, el color y el correo de respuesta.
    ///
    /// EL COLOR Y EL CORREO SE REEMPLAZAN SIEMPRE: null los quita. El panel
    /// manda los tres campos cada vez, así que lo que llega es el estado
    /// completo que se quiere.
    ///
    /// EL IDENTIFICADOR SOLO SE PONE SI NO HABÍA. Si ya había uno y llega
    /// otro, no se guarda nada y se devuelve IdentificadorFijo con el actual.
    /// La base lo impediría igual (disparador de la 020), pero aquí se
    /// detecta antes para dar un mensaje claro y no dejar nada a medias.
    ///
    /// Un identificador que ya usa otra empresa sale como PostgresException
    /// 23505: lo traduce el endpoint.
    /// </summary>
    public async Task<(ResultadoMarca Resultado, string? IdentificadorActual)> GuardarMarcaAsync(
        Guid id, string? identificador, string? colorMarca, string? correoRespuesta,
        bool copiaAlEmisor, CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);
        await using var transaccion = await conexion.BeginTransactionAsync(ct);

        // FOR UPDATE: dos pestañas guardando a la vez no pueden poner cada
        // una un identificador distinto.
        var fila = await conexion.QuerySingleOrDefaultAsync<IdentificadorTenant>(
            new CommandDefinition(
                """
                SELECT id AS "Id", identificador AS "Identificador"
                  FROM tenants
                 WHERE id = @id
                   FOR UPDATE
                """,
                new { id }, transaccion, cancellationToken: ct));

        if (fila is null)
            return (ResultadoMarca.NoExiste, null);

        if (fila.Identificador is not null &&
            identificador is not null &&
            identificador != fila.Identificador)
            return (ResultadoMarca.IdentificadorFijo, fila.Identificador);

        await conexion.ExecuteAsync(new CommandDefinition(
            """
            UPDATE tenants
               SET identificador    = COALESCE(identificador, @identificador),
                   color_marca      = @colorMarca,
                   correo_respuesta = @correoRespuesta,
                   -- Sin correo de respuesta no hay a dónde mandar la copia.
                   copia_al_emisor  = @copiaAlEmisor AND @correoRespuesta::text IS NOT NULL
             WHERE id = @id
            """,
            new { id, identificador, colorMarca, correoRespuesta, copiaAlEmisor },
            transaccion, cancellationToken: ct));

        await transaccion.CommitAsync(ct);

        return (ResultadoMarca.Guardada, fila.Identificador ?? identificador);
    }

    /// <summary>El RUC (para la carpeta del almacén) y la ruta del logo actual.</summary>
    public async Task<LogoTenant?> ObtenerLogoAsync(Guid id, CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);

        return await conexion.QuerySingleOrDefaultAsync<LogoTenant>(new CommandDefinition(
            """
            SELECT ruc AS "Ruc", logo_ruta AS "LogoRuta"
              FROM tenants
             WHERE id = @id
            """,
            new { id }, cancellationToken: ct));
    }

    /// <summary>
    /// Apunta la empresa a un logo ya guardado en el almacén.
    ///
    /// EL LOGO ANTERIOR NO SE BORRA del almacén: solo deja de apuntarse.
    /// Pesa unos kilobytes, y así un cambio por error se deshace volviendo a
    /// apuntar la ruta vieja.
    /// </summary>
    public async Task<bool> GuardarLogoAsync(Guid id, string ruta, CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);

        var filas = await conexion.ExecuteAsync(new CommandDefinition(
            "UPDATE tenants SET logo_ruta = @ruta WHERE id = @id",
            new { id, ruta }, cancellationToken: ct));

        return filas > 0;
    }

    /// <summary>
    /// Guarda las credenciales SOL de una empresa. La clave se cifra igual
    /// que los certificados.
    ///
    /// DEBE SER EL USUARIO SOL SECUNDARIO del contribuyente, nunca el
    /// principal. El principal puede hacer todo en el portal de SUNAT:
    /// declarar, pagar, modificar datos. Ese nivel de acceso no tiene por
    /// qué vivir en la base de datos de un proveedor.
    /// </summary>
    /// <summary>
    /// Fase 4c (migración 028): pausa o reactiva la emisión de un emisor. Con
    /// la pausa, su clave fac_ solo puede leer.
    /// </summary>
    public async Task PausarEmisionAsync(Guid tenantId, bool pausar, string? motivo, CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);
        await conexion.ExecuteAsync(new CommandDefinition(
            """
            UPDATE tenants
               SET emision_pausada_en = CASE WHEN @pausar THEN COALESCE(emision_pausada_en, now()) END,
                   motivo_pausa       = CASE WHEN @pausar THEN @motivo END
             WHERE id = @tenantId
            """,
            new { tenantId, pausar, motivo }, cancellationToken: ct));
    }

    /// <summary>¿Está en pausa la emisión de este emisor? (fase 4c)</summary>
    public async Task<bool> EmisionPausadaAsync(Guid tenantId, CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);
        return await conexion.ExecuteScalarAsync<bool>(new CommandDefinition(
            "SELECT emision_pausada_en IS NOT NULL FROM tenants WHERE id = @tenantId",
            new { tenantId }, cancellationToken: ct));
    }

    public async Task<bool> GuardarCredencialesSolAsync(
        Guid tenantId, string usuario, string clave,
        IProtectorDeSecretos protector, CancellationToken ct = default)
    {
        if (string.IsNullOrWhiteSpace(usuario))
            throw new ArgumentException("Falta el usuario SOL.", nameof(usuario));

        if (string.IsNullOrWhiteSpace(clave))
            throw new ArgumentException("Falta la clave SOL.", nameof(clave));

        var cifrada = protector.ProtegerTexto(clave);

        await using var conexion = await AbrirAsync(ct);

        var filas = await conexion.ExecuteAsync(new CommandDefinition(
            """
            UPDATE tenants
               SET usuario_sol = @usuario,
                   clave_sol_cifrada = @cifrada
             WHERE id = @tenantId
            """,
            new { tenantId, usuario, cifrada }, cancellationToken: ct));

        return filas > 0;
    }

    /// <summary>
    /// Guarda las credenciales de la API de guías de remisión.
    ///
    /// SON DISTINTAS DE LAS CREDENCIALES SOL. El contribuyente las genera en
    /// su menú SOL, opción "Credenciales de API SUNAT", una sola vez, y solo
    /// sirven para guías.
    ///
    /// Una empresa que emita facturas y guías tendrá los dos juegos: la clave
    /// SOL para las facturas, y estas dos para las guías.
    /// </summary>
    public async Task<bool> GuardarCredencialesGreAsync(
        Guid tenantId, string clientId, string clientSecret,
        IProtectorDeSecretos protector, CancellationToken ct = default)
    {
        if (string.IsNullOrWhiteSpace(clientId))
            throw new ArgumentException("Falta el client_id.", nameof(clientId));

        if (string.IsNullOrWhiteSpace(clientSecret))
            throw new ArgumentException("Falta el client_secret.", nameof(clientSecret));

        var cifrado = protector.ProtegerTexto(clientSecret);

        await using var conexion = await AbrirAsync(ct);

        var filas = await conexion.ExecuteAsync(new CommandDefinition(
            """
            UPDATE tenants
               SET gre_client_id = @clientId,
                   gre_client_secret_cifrado = @cifrado,

                   -- Guardar las credenciales habilita las guías: no tiene
                   -- sentido tenerlas cargadas y el módulo apagado.
                   gre_habilitado = true
             WHERE id = @tenantId
            """,
            new { tenantId, clientId = clientId.Trim(), cifrado },
            cancellationToken: ct));

        return filas > 0;
    }

    /// <summary>Activa o desactiva la emisión de guías.</summary>
    public async Task<bool> CambiarGreHabilitadoAsync(
        Guid tenantId, bool habilitado, CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);

        var filas = await conexion.ExecuteAsync(new CommandDefinition(
            "UPDATE tenants SET gre_habilitado = @habilitado WHERE id = @tenantId",
            new { tenantId, habilitado }, cancellationToken: ct));

        return filas > 0;
    }

    /// <summary>
    /// Cambia el ambiente de una empresa entre beta y producción.
    ///
    /// Quien llame debe haber comprobado antes que está lista: pasar a
    /// producción sin certificado válido o sin clave SOL hace que todas sus
    /// facturas fallen desde el primer minuto.
    /// </summary>
    public Task<bool> CambiarAmbienteAsync(
        Guid tenantId, string ambiente, CancellationToken ct = default) =>
        CambiarAmbienteAsync(tenantId, ambiente, "panel", null, ct);

    /// <summary>
    /// 036: el cambio queda en `ambiente_cambios` con su origen (panel o
    /// plataforma). Al pasar a producción por primera vez, cada serie activa
    /// de prueba se crea también en real, EMPEZANDO EN 0: los números de
    /// prueba no cuentan. Si ya existía en real, sigue donde iba. Si la
    /// empresa ya emitía con esa serie en otro sistema, se ajusta después
    /// («Ajustar la serie», solo hacia arriba).
    /// </summary>
    public async Task<bool> CambiarAmbienteAsync(
        Guid tenantId, string ambiente, string origen, string? detalle,
        CancellationToken ct = default)
    {
        if (ambiente is not ("beta" or "produccion"))
            throw new ArgumentException(
                "El ambiente solo puede ser 'beta' o 'produccion'.", nameof(ambiente));

        await using var conexion = await AbrirAsync(ct);
        await using var tx = await conexion.BeginTransactionAsync(ct);

        await conexion.ExecuteAsync(new CommandDefinition(
            """
            SELECT set_config('app.origen_cambio', @origen, true),
                   set_config('app.detalle_cambio', @detalle, true)
            """,
            new { origen, detalle = detalle ?? "" }, tx, cancellationToken: ct));

        var filas = await conexion.ExecuteAsync(new CommandDefinition(
            "UPDATE tenants SET ambiente = @ambiente WHERE id = @tenantId",
            new { tenantId, ambiente }, tx, cancellationToken: ct));

        if (filas > 0 && ambiente == "produccion")
        {
            await conexion.ExecuteAsync(new CommandDefinition(
                """
                INSERT INTO series_por_ambiente
                       (tenant_id, tipo_comprobante, serie, ultimo_correlativo, activo, ambiente)
                SELECT tenant_id, tipo_comprobante, serie, 0, true, 'produccion'
                  FROM series_por_ambiente
                 WHERE tenant_id = @tenantId
                   AND ambiente = 'beta'
                   AND activo
                ON CONFLICT DO NOTHING
                """,
                new { tenantId }, tx, cancellationToken: ct));
        }

        await tx.CommitAsync(ct);
        return filas > 0;
    }

    /// <summary>036: la serie del ambiente actual de la empresa, por tipo y nombre.</summary>
    public async Task<Guid?> SerieIdAsync(
        Guid tenantId, string tipoComprobante, string serie, CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);
        return await conexion.ExecuteScalarAsync<Guid?>(new CommandDefinition(
            """
            SELECT id FROM series
             WHERE tenant_id = @tenantId
               AND tipo_comprobante = @tipoComprobante
               AND serie = @serie
            """,
            new { tenantId, tipoComprobante, serie }, cancellationToken: ct));
    }

    // --------------------------------------------------------------- series

    public async Task<IReadOnlyList<SerieAdmin>> ListarSeriesAsync(
        Guid tenantId, CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);

        var filas = await conexion.QueryAsync<SerieAdmin>(
            new CommandDefinition(
                """
                SELECT s.id                 AS "Id",
                       s.tipo_comprobante   AS "TipoComprobante",
                       s.serie              AS "Serie",
                       s.ultimo_correlativo AS "UltimoCorrelativo",
                       s.activo             AS "Activo",
                       s.creado_en          AS "CreadoEn",

                       (SELECT count(*)::int FROM comprobantes c
                         WHERE c.tenant_id = s.tenant_id
                           AND c.tipo_comprobante = s.tipo_comprobante
                           AND c.serie = s.serie)  AS "Comprobantes",

                       (SELECT coalesce(sum(a.hasta - a.desde), 0)::int
                          FROM serie_ajustes a
                         WHERE a.serie_id = s.id
                           AND a.accion = 'ajuste')  AS "Ajustado"

                  FROM series s
                 WHERE s.tenant_id = @tenantId
                 -- La más reciente primero.
                 --
                 -- El orden por tipo y serie se lee mejor, pero obliga a
                 -- buscar en toda la tabla la que acabas de crear. Como una
                 -- empresa tiene pocas series, la comodidad de verla arriba
                 -- pesa más que la prolijidad del agrupamiento.
                 ORDER BY s.creado_en DESC
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
    /// obligaría a resolverlo con la administración tributaria. Si no es cero,
    /// queda anotado en la bitácora (serie_ajustes, acción «alta»).
    ///
    /// usuarioId NULO = no lo hizo una persona del panel sino la configuración
    /// desde la plataforma (/v1/configuracion/series). Entonces «correo» dice
    /// quién fue allí, con el prefijo «plataforma:».
    ///
    /// SI LA SERIE YA EXISTE, NO HACE NADA y devuelve la que existe. Antes la
    /// reactivaba en silencio y pasaba por alto el correlativo nuevo, así que
    /// el operador creía haber puesto la 780 y la serie seguía en la 600. Ahora
    /// quien llama decide: ajustarla (hacia arriba) o reactivarla.
    /// </summary>
    public async Task<AltaSerie> CrearSerieAsync(
        Guid tenantId, string tipoComprobante, string serie,
        int correlativoInicial, Guid? usuarioId, string correo,
        CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);
        await using var tx = await conexion.BeginTransactionAsync(ct);

        var id = await conexion.ExecuteScalarAsync<Guid?>(new CommandDefinition(
            """
            INSERT INTO series (tenant_id, tipo_comprobante, serie, ultimo_correlativo)
            VALUES (@tenantId, @tipoComprobante, @serie, @correlativoInicial)
            ON CONFLICT DO NOTHING   -- 036: el candado ahora incluye el ambiente
            RETURNING id
            """,
            new { tenantId, tipoComprobante, serie, correlativoInicial },
            tx, cancellationToken: ct));

        if (id is null)
        {
            var existente = await conexion.QuerySingleOrDefaultAsync<SerieExistente>(
                new CommandDefinition(
                    """
                    SELECT s.id                 AS "Id",
                           s.ultimo_correlativo AS "UltimoCorrelativo",
                           s.activo             AS "Activo",
                           (SELECT count(*)::int FROM comprobantes c
                             WHERE c.tenant_id = s.tenant_id
                               AND c.tipo_comprobante = s.tipo_comprobante
                               AND c.serie = s.serie
                               AND c.ambiente = s.ambiente) AS "Comprobantes"
                      FROM series s
                     WHERE s.tenant_id = @tenantId
                       AND s.tipo_comprobante = @tipoComprobante
                       AND s.serie = @serie
                    """,
                    new { tenantId, tipoComprobante, serie },
                    tx, cancellationToken: ct));

            await tx.RollbackAsync(ct);

            return new AltaSerie(null, existente
                ?? throw new InvalidOperationException(
                    "La serie choca con una existente que ya no se encuentra. Vuelve a intentarlo."));
        }

        if (correlativoInicial > 0)
            await AnotarAsync(conexion, tx, tenantId, id.Value, tipoComprobante, serie,
                "alta", 0, correlativoInicial,
                "Alta de la serie con correlativo inicial (ya emitidos en otro sistema).",
                usuarioId, correo, ct);

        await tx.CommitAsync(ct);

        return new AltaSerie(id, null);
    }

    /// <summary>
    /// «Ajustar correlativo»: SOLO HACIA ARRIBA.
    ///
    /// Es el caso del cliente que se fue con la F001 en la 600, siguió
    /// emitiendo fuera hasta la 780 y vuelve: se sube a 780 y la siguiente
    /// sale 781. Bajarlo nunca: volvería a dar números que ya existen en SUNAT.
    ///
    /// SELECT ... FOR UPDATE: la emisión toma el mismo candado de la fila
    /// (UPDATE series ... RETURNING), así que un comprobante que se esté
    /// emitiendo en ese momento termina antes o espera, y no hay número
    /// repetido ni salto perdido. El ajuste y su anotación van en la misma
    /// transacción: o quedan los dos o ninguno.
    /// </summary>
    public async Task<AjusteSerie> AjustarCorrelativoAsync(
        Guid tenantId, Guid serieId, int hasta, string motivo,
        Guid? usuarioId, string correo, CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);
        await using var tx = await conexion.BeginTransactionAsync(ct);

        var actual = await conexion.QuerySingleOrDefaultAsync<SerieBloqueada>(
            new CommandDefinition(
                """
                SELECT tipo_comprobante   AS "TipoComprobante",
                       serie              AS "Serie",
                       ultimo_correlativo AS "UltimoCorrelativo"
                  FROM series
                 WHERE id = @serieId AND tenant_id = @tenantId
                   FOR UPDATE
                """,
                new { tenantId, serieId }, tx, cancellationToken: ct));

        if (actual is null)
        {
            await tx.RollbackAsync(ct);
            return new AjusteSerie(ResultadoAjuste.NoExiste, 0, hasta, "");
        }

        if (hasta <= actual.UltimoCorrelativo)
        {
            await tx.RollbackAsync(ct);
            return new AjusteSerie(ResultadoAjuste.NoSube,
                actual.UltimoCorrelativo, hasta, actual.Serie);
        }

        await conexion.ExecuteAsync(new CommandDefinition(
            """
            UPDATE series SET ultimo_correlativo = @hasta
             WHERE id = @serieId AND tenant_id = @tenantId
            """,
            new { tenantId, serieId, hasta }, tx, cancellationToken: ct));

        await AnotarAsync(conexion, tx, tenantId, serieId, actual.TipoComprobante,
            actual.Serie, "ajuste", actual.UltimoCorrelativo, hasta, motivo,
            usuarioId, correo, ct);

        await tx.CommitAsync(ct);

        return new AjusteSerie(ResultadoAjuste.Ajustado,
            actual.UltimoCorrelativo, hasta, actual.Serie);
    }

    /// <summary>La bitácora de correlativos de una empresa, lo último primero.</summary>
    public async Task<IReadOnlyList<AjusteSerieAdmin>> ListarAjustesSerieAsync(
        Guid tenantId, CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);

        var filas = await conexion.QueryAsync<AjusteSerieAdmin>(new CommandDefinition(
            """
            SELECT id               AS "Id",
                   serie_id         AS "SerieId",
                   tipo_comprobante AS "TipoComprobante",
                   serie            AS "Serie",
                   accion           AS "Accion",
                   desde            AS "Desde",
                   hasta            AS "Hasta",
                   motivo           AS "Motivo",
                   correo           AS "Correo",
                   creado_en        AS "CreadoEn"
              FROM serie_ajustes
             WHERE tenant_id = @tenantId
             ORDER BY creado_en DESC, id DESC
             LIMIT 200
            """,
            new { tenantId }, cancellationToken: ct));

        return filas.ToList();
    }

    private static Task<int> AnotarAsync(
        NpgsqlConnection conexion, NpgsqlTransaction tx,
        Guid tenantId, Guid serieId, string tipoComprobante, string serie,
        string accion, int desde, int hasta, string motivo,
        Guid? usuarioId, string correo, CancellationToken ct) =>
        conexion.ExecuteAsync(new CommandDefinition(
            """
            INSERT INTO serie_ajustes
                   (tenant_id, serie_id, tipo_comprobante, serie, accion,
                    desde, hasta, motivo, usuario_id, correo)
            VALUES (@tenantId, @serieId, @tipoComprobante, @serie, @accion,
                    @desde, @hasta, @motivo, @usuarioId, @correo)
            """,
            new
            {
                tenantId, serieId, tipoComprobante, serie, accion,
                desde, hasta, motivo, usuarioId, correo
            },
            tx, cancellationToken: ct));

    /// <summary>
    /// Elimina una serie, pero SOLO si nunca se usó.
    ///
    /// La comprobación va dentro del mismo DELETE, no en una consulta previa:
    /// entre comprobar y borrar hay una ventana en la que alguien podría
    /// emitir un comprobante con esa serie. Hacerlo en una sola sentencia
    /// cierra esa ventana.
    ///
    /// Devuelve false si la serie no existe o si ya tiene comprobantes.
    /// </summary>
    public async Task<bool> EliminarSerieAsync(
        Guid tenantId, Guid serieId, CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);

        var filas = await conexion.ExecuteAsync(new CommandDefinition(
            """
            DELETE FROM series s
             WHERE s.id = @serieId
               AND s.tenant_id = @tenantId
               AND NOT EXISTS (
                     SELECT 1 FROM comprobantes c
                      WHERE c.tenant_id = s.tenant_id
                        AND c.tipo_comprobante = s.tipo_comprobante
                        AND c.serie = s.serie
                        AND c.ambiente = s.ambiente)
            """,
            new { tenantId, serieId }, cancellationToken: ct));

        return filas > 0;
    }

    /// <summary>
    /// Activa o desactiva una serie.
    ///
    /// Desactivarla impide emitir con ella, pero NO toca el histórico: los
    /// comprobantes ya emitidos siguen consultándose y descargándose igual.
    /// Es lo que se hace cuando una sucursal cierra, cuando cambia el esquema
    /// de numeración, o cuando hay que cerrar una serie y abrir otra.
    /// </summary>
    public async Task<bool> CambiarEstadoSerieAsync(
        Guid tenantId, Guid serieId, bool activo, CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);

        var filas = await conexion.ExecuteAsync(new CommandDefinition(
            """
            UPDATE series SET activo = @activo
             WHERE id = @serieId AND tenant_id = @tenantId
            """,
            new { tenantId, serieId, activo }, cancellationToken: ct));

        return filas > 0;
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