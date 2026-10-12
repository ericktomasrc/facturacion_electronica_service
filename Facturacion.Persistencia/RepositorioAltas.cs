using System.Security.Cryptography;
using Dapper;
using Npgsql;

namespace Facturacion.Persistencia;

/// <summary>Una clave de alta ya comprobada: quién llama a POST /alta/emisores.</summary>
public sealed record ClaveAltaResuelta(Guid Id, string Nombre, string Prefijo, short TopeDiario);

/// <summary>Una clave de alta vista desde el panel. Nunca el secreto.</summary>
public sealed record ClaveAltaAdmin(
    Guid Id,
    string Nombre,
    string Prefijo,
    short TopeDiario,
    bool Activo,
    DateTime CreadoEn,
    string? CreadaPor,
    DateTime? UltimoUso,
    DateTime? RevocadoEn,
    string? RevocadaPor,
    int AltasHoy,
    int AltasTotal,
    DateTime? UltimaAlta);

/// <summary>Los datos del emisor que manda la plataforma. Ya revisados.</summary>
public sealed record DatosAltaEmisor(
    string Ruc,
    string RazonSocial,
    string? NombreComercial,
    string Ubigeo,
    string Direccion,
    string Distrito,
    string Provincia,
    string Departamento,
    string WebhookUrl);

public enum ResultadoAlta
{
    Creado,

    /// <summary>El RUC ya tiene un emisor vigente. No se creó nada.</summary>
    YaExiste,

    /// <summary>
    /// Hay un alta «sin confirmar» de este RUC de hace menos de dos minutos:
    /// probablemente la del clic anterior, todavía en camino. No se toca.
    /// </summary>
    EnCurso,

    /// <summary>La clave llegó a su tope del día. No se creó nada.</summary>
    TopeAlcanzado
}

/// <summary>
/// Lo que devuelve un alta.
///
/// LA CLAVE Y EL SECRETO SOLO EXISTEN AQUÍ, en memoria, el tiempo de responder.
/// En la base quedan el hash de la clave y el secreto del webhook (este en
/// claro, como todos: punto 22). Quien reciba este objeto no lo registra.
/// </summary>
public sealed record AltaEmisor(
    ResultadoAlta Resultado,
    Guid? EmisorId = null,
    DateTime? CreadoEn = null,
    string? Clave = null,
    Guid? WebhookId = null,
    string? WebhookUrl = null,
    string? WebhookSecreto = null,
    Guid? Abandonado = null,
    bool AvisarTope = false)
{
    public override string ToString() =>
        // Por si alguien lo escribe en un registro: sin secretos.
        $"AltaEmisor {{ {Resultado}, {EmisorId}, abandonado {Abandonado} }}";
}

/// <summary>
/// Lo que el emisor de una clave sabe de sí mismo para GET /v1/emisor: si su
/// alta está confirmada, su marca, y si está listo para emitir.
///
/// SOLO «ESTÁ O NO ESTÁ», y datos de la propia empresa. Ningún secreto: ni la
/// clave SOL, ni el certificado. El correo de respuesta y el identificador sí
/// salen: son de la empresa y la plataforma los necesita para avisar.
/// </summary>
public sealed record EstadoEmisor(
    string EstadoAlta,
    DateTime CreadoEn,
    DateTime? AltaConfirmadaEn,
    string? Identificador,
    string? CorreoRespuesta,
    bool TieneLogo,
    string? UsuarioSol,
    bool TieneClaveSol,
    string Ubigeo,
    string Direccion,
    string Distrito,
    string Provincia,
    string Departamento,
    DateTime? DireccionRevisadaEn,
    DateTime? CertificadoValidoHasta,
    string? SeriesTexto,

    // AL FINAL a propósito: Dapper empareja el constructor por posición.
    string Ambiente)
{
    public string[] Series =>
        string.IsNullOrWhiteSpace(SeriesTexto)
            ? []
            : SeriesTexto.Split(',', StringSplitOptions.RemoveEmptyEntries);

    public bool CertificadoListo =>
        CertificadoValidoHasta is { } h && h > DateTime.UtcNow;

    /// <summary>
    /// El usuario SOL secundario de verdad. MODDATOS es el de pruebas de SUNAT:
    /// sirve en beta, pero el día de pasar a producción no hay con qué entrar.
    /// </summary>
    public bool SolListo =>
        !string.IsNullOrWhiteSpace(UsuarioSol) &&
        !UsuarioSol.Equals("MODDATOS", StringComparison.OrdinalIgnoreCase) &&
        TieneClaveSol;

    public bool SeriesListas => Series.Length > 0;

    /// <summary>
    /// Revisada a propósito, y con todo. Una dirección con los valores por
    /// defecto (LIMA) no se distingue de una revisada: por eso cuenta la fecha,
    /// no solo que los campos tengan algo.
    /// </summary>
    public bool DireccionLista =>
        DireccionRevisadaEn is not null &&
        !string.IsNullOrWhiteSpace(Direccion) &&
        !string.IsNullOrWhiteSpace(Distrito) &&
        !string.IsNullOrWhiteSpace(Provincia) &&
        !string.IsNullOrWhiteSpace(Departamento) &&
        Ubigeo.Length == 6 && Ubigeo.All(char.IsDigit);

    /// <summary>
    /// EL SOL REAL SOLO SE EXIGE EN PRODUCCIÓN (decisión del 11 de octubre,
    /// 10:46). En beta el servicio firma con las credenciales públicas de
    /// pruebas de SUNAT (ProveedorCredenciales) y el SOL guardado no se usa:
    /// exigirlo solo impedía probar. Pasar a producción lo sigue exigiendo
    /// (la revisión previa de la pestaña Producción).
    /// </summary>
    public bool SolRequerido => Ambiente == "produccion";

    public bool ListoParaEmitir =>
        CertificadoListo && (SolListo || !SolRequerido) && SeriesListas && DireccionLista;

    /// <summary>Sin estos dos, ningún receptor recibe nunca su correo (migración 022).</summary>
    public bool CorreosAlReceptor =>
        !string.IsNullOrWhiteSpace(Identificador) && !string.IsNullOrWhiteSpace(CorreoRespuesta);

    /// <summary>Lo que falta para emitir, en palabras. En el orden en que se hace.</summary>
    public IReadOnlyList<string> Faltan()
    {
        var faltan = new List<string>();

        if (!DireccionLista)
            faltan.Add(DireccionRevisadaEn is null
                ? "Revisar la dirección (nadie la confirmó: puede tener los valores por defecto)."
                : "Completar la dirección.");

        if (CertificadoValidoHasta is null)
            faltan.Add("Cargar el certificado digital.");
        else if (!CertificadoListo)
            faltan.Add("El certificado venció: cargar uno vigente.");

        if (!SolListo && SolRequerido)
            faltan.Add("Guardar el usuario SOL secundario y su clave.");

        if (!SeriesListas)
            faltan.Add("Crear al menos una serie.");

        return faltan;
    }
}

/// <summary>
/// El alta de emisores desde la plataforma, y las claves de alta.
///
/// Diseño: alta-empresa-diseno.md §13.
///
/// LO ESTRECHO DE LA CLAVE DE ALTA ESTÁ EN ESTE ARCHIVO. Usa la conexión de
/// operador, igual que el panel, porque crea filas en tablas que la aplicación
/// solo puede leer. Lo que la acota es que el único método que una clave de
/// alta puede disparar es <see cref="CrearEmisorAsync"/>, y ese método solo
/// inserta —salvo dar por abandonado un «sin confirmar» que creó otra clave de
/// alta—. La segunda barrera, un rol de base propio que solo pueda insertar en
/// estas tablas, es el punto 23, para antes de producción.
/// </summary>
public sealed class RepositorioAltas
{
    /// <summary>
    /// Cuánto tiene que llevar un alta «sin confirmar» para que otra la pueda
    /// dar por abandonada. Menos que esto es casi seguro el clic anterior, que
    /// todavía va por el camino.
    /// </summary>
    public static readonly TimeSpan EsperaAntesDeAbandonar = TimeSpan.FromMinutes(2);

    public const string NombreClaveEmisor = "Plataforma (creada por el alta)";

    // El día de Lima, no el del servidor: «20 al día» lo cuenta una persona
    // que está en Perú.
    private const string InicioDelDia =
        "(date_trunc('day', now() AT TIME ZONE 'America/Lima') AT TIME ZONE 'America/Lima')";

    private readonly string _cadenaOperador;

    public RepositorioAltas(string cadenaConexionOperador)
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

    /// <summary>
    /// Una clave de alta nueva. Prefijo propio para que no se confunda con una
    /// fac_ ni en un registro ni a la vista.
    /// </summary>
    public static string GenerarClave() =>
        "alt_" + Convert.ToBase64String(RandomNumberGenerator.GetBytes(32))
            .Replace("+", "").Replace("/", "").Replace("=", "");

    // ------------------------------------------------------ claves (panel)

    public async Task<IReadOnlyList<ClaveAltaAdmin>> ListarClavesAsync(CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);

        var filas = await conexion.QueryAsync<ClaveAltaAdmin>(new CommandDefinition(
            $"""
            SELECT k.id          AS "Id",
                   k.nombre      AS "Nombre",
                   k.prefijo     AS "Prefijo",
                   k.tope_diario AS "TopeDiario",
                   k.activo      AS "Activo",
                   k.creado_en   AS "CreadoEn",
                   uc.correo::text AS "CreadaPor",
                   k.ultimo_uso  AS "UltimoUso",
                   k.revocado_en AS "RevocadoEn",
                   ur.correo::text AS "RevocadaPor",

                   (SELECT count(*)::int FROM tenants t
                     WHERE t.creado_por_clave_alta = k.id
                       AND t.creado_en >= {InicioDelDia})        AS "AltasHoy",

                   (SELECT count(*)::int FROM tenants t
                     WHERE t.creado_por_clave_alta = k.id)       AS "AltasTotal",

                   (SELECT max(t.creado_en) FROM tenants t
                     WHERE t.creado_por_clave_alta = k.id)       AS "UltimaAlta"

              FROM claves_alta k
              LEFT JOIN usuarios uc ON uc.id = k.creado_por
              LEFT JOIN usuarios ur ON ur.id = k.revocado_por
             ORDER BY k.activo DESC, k.creado_en DESC
            """,
            cancellationToken: ct));

        return filas.ToList();
    }

    /// <summary>Emite una clave de alta y devuelve el secreto EN CLARO, una sola vez.</summary>
    public async Task<(Guid Id, string Clave, string Prefijo)> CrearClaveAsync(
        string nombre, short topeDiario, Guid usuarioId, CancellationToken ct = default)
    {
        var clave = GenerarClave();
        var prefijo = clave[..20];

        await using var conexion = await AbrirAsync(ct);

        var id = await conexion.ExecuteScalarAsync<Guid>(new CommandDefinition(
            """
            INSERT INTO claves_alta (nombre, prefijo, hash, tope_diario, creado_por)
            VALUES (@nombre, @prefijo, @hash, @topeDiario, @usuarioId)
            RETURNING id
            """,
            new
            {
                nombre = nombre.Trim(),
                prefijo,
                hash = RepositorioTenants.CalcularHash(clave),
                topeDiario,
                usuarioId
            },
            cancellationToken: ct));

        return (id, clave, prefijo);
    }

    /// <summary>Revoca una clave de alta. No se borra: queda quién y cuándo.</summary>
    public async Task<bool> RevocarClaveAsync(Guid id, Guid usuarioId, CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);

        var filas = await conexion.ExecuteAsync(new CommandDefinition(
            """
            UPDATE claves_alta
               SET activo = false, revocado_en = now(), revocado_por = @usuarioId
             WHERE id = @id AND activo
            """,
            new { id, usuarioId }, cancellationToken: ct));

        return filas > 0;
    }

    /// <summary>
    /// Comprueba una clave de alta y anota su uso. Null si no existe o está
    /// revocada: quien llama responde lo mismo en los dos casos.
    /// </summary>
    public async Task<ClaveAltaResuelta?> ResolverClaveAsync(string clave, CancellationToken ct = default)
    {
        if (string.IsNullOrWhiteSpace(clave) || !clave.StartsWith("alt_", StringComparison.Ordinal))
            return null;

        await using var conexion = await AbrirAsync(ct);

        return await conexion.QuerySingleOrDefaultAsync<ClaveAltaResuelta>(new CommandDefinition(
            """
            UPDATE claves_alta
               SET ultimo_uso = now()
             WHERE hash = @hash AND activo
            RETURNING id          AS "Id",
                      nombre      AS "Nombre",
                      prefijo     AS "Prefijo",
                      tope_diario AS "TopeDiario"
            """,
            new { hash = RepositorioTenants.CalcularHash(clave) }, cancellationToken: ct));
    }

    /// <summary>
    /// Los correos de quienes pueden gestionar claves de alta: a ellos va el
    /// aviso de «tope alcanzado».
    /// </summary>
    public async Task<IReadOnlyList<string>> DestinatariosAvisoAsync(CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);

        var filas = await conexion.QueryAsync<string>(new CommandDefinition(
            """
            SELECT DISTINCT u.correo::text
              FROM usuarios u
              JOIN rol_permisos rp ON rp.rol_id = u.rol_id
             WHERE u.activo AND rp.permiso = 'altas.gestionar'
            """,
            cancellationToken: ct));

        return filas.ToList();
    }

    // ------------------------------------------------------- el alta en sí

    /// <summary>
    /// Crea el emisor, su clave fac_ y su webhook, EN UNA SOLA TRANSACCIÓN, y
    /// lo deja «sin confirmar». O todo o nada.
    ///
    /// Los datos tienen que venir ya revisados (Direccion.Revisar y
    /// DestinoWebhook). Aquí solo se decide si se puede crear.
    /// </summary>
    public async Task<AltaEmisor> CrearEmisorAsync(
        ClaveAltaResuelta clave, DatosAltaEmisor datos, CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);
        await using var transaccion = await conexion.BeginTransactionAsync(ct);

        // --- 1. El tope del día --------------------------------------------
        //
        // Con el candado de la clave, dos altas a la vez con la misma clave no
        // pueden contarse las dos por debajo del tope.
        await conexion.ExecuteAsync(new CommandDefinition(
            "SELECT pg_advisory_xact_lock(hashtextextended('clave_alta:' || @id::text, 0))",
            new { id = clave.Id }, transaccion, cancellationToken: ct));

        var hoy = await conexion.ExecuteScalarAsync<int>(new CommandDefinition(
            $"""
            SELECT count(*)::int FROM tenants
             WHERE creado_por_clave_alta = @id
               AND creado_en >= {InicioDelDia}
            """,
            new { id = clave.Id }, transaccion, cancellationToken: ct));

        if (hoy >= clave.TopeDiario)
        {
            // Se marca el aviso una vez al día: si esto lo provoca una clave
            // filtrada, el correo llega una vez, no veinte.
            var avisar = await conexion.ExecuteScalarAsync<bool?>(new CommandDefinition(
                $"""
                UPDATE claves_alta
                   SET tope_avisado_en = now()
                 WHERE id = @id
                   AND (tope_avisado_en IS NULL OR tope_avisado_en < {InicioDelDia})
                RETURNING true
                """,
                new { id = clave.Id }, transaccion, cancellationToken: ct));

            await transaccion.CommitAsync(ct);

            return new AltaEmisor(ResultadoAlta.TopeAlcanzado, AvisarTope: avisar == true);
        }

        // --- 2. ¿Existe ya ese RUC? -----------------------------------------
        //
        // El candado por RUC hace que dos altas del mismo RUC vayan en fila: la
        // segunda ve lo que dejó la primera.
        await conexion.ExecuteAsync(new CommandDefinition(
            "SELECT pg_advisory_xact_lock(hashtextextended('alta_ruc:' || @ruc, 0))",
            new { ruc = datos.Ruc }, transaccion, cancellationToken: ct));

        var existente = await conexion.QuerySingleOrDefaultAsync<FilaExistente>(new CommandDefinition(
            """
            SELECT id                    AS "Id",
                   estado_alta           AS "EstadoAlta",
                   creado_por_clave_alta AS "ClaveAlta",
                   creado_en             AS "CreadoEn"
              FROM tenants
             WHERE ruc = @ruc
               AND estado_alta <> 'abandonada'
               FOR UPDATE
            """,
            new { ruc = datos.Ruc }, transaccion, cancellationToken: ct));

        Guid? abandonado = null;

        if (existente is not null)
        {
            // Solo se abandona lo que nadie confirmó y creó una clave de alta.
            // Una empresa del panel, o una confirmada, NUNCA.
            var abandonable = existente.EstadoAlta == "sin_confirmar" && existente.ClaveAlta is not null;

            if (!abandonable)
                return new AltaEmisor(ResultadoAlta.YaExiste);

            if (existente.CreadoEn > DateTime.UtcNow - EsperaAntesDeAbandonar)
                return new AltaEmisor(ResultadoAlta.EnCurso);

            await AbandonarAsync(conexion, transaccion, existente.Id, clave.Prefijo, ct);
            abandonado = existente.Id;
        }

        // --- 3. El emisor ----------------------------------------------------
        //
        // Siempre en beta y con MODDATOS: producción es una decisión humana, en
        // el panel, con su revisión. La dirección cuenta como revisada: la
        // tecleó una persona en el alta de la plataforma.
        var creado = await conexion.QuerySingleAsync<FilaCreada>(new CommandDefinition(
            """
            INSERT INTO tenants
                (ruc, razon_social, nombre_comercial, ubigeo, direccion,
                 distrito, provincia, departamento, ambiente, usuario_sol,
                 max_concurrencia, estado_alta, creado_por_clave_alta,
                 direccion_revisada_en)
            VALUES
                (@Ruc, @RazonSocial, @NombreComercial, @Ubigeo, @Direccion,
                 @Distrito, @Provincia, @Departamento, 'beta', 'MODDATOS',
                 1, 'sin_confirmar', @ClaveAlta,
                 now())
            RETURNING id AS "Id", creado_en AS "CreadoEn"
            """,
            new
            {
                datos.Ruc, datos.RazonSocial, datos.NombreComercial, datos.Ubigeo,
                datos.Direccion, datos.Distrito, datos.Provincia, datos.Departamento,
                ClaveAlta = clave.Id
            },
            transaccion, cancellationToken: ct));

        // --- 4. Su clave fac_ (de pruebas: nace en beta) ---------------------
        var fac = RepositorioTenants.GenerarClave(produccion: false);

        await conexion.ExecuteAsync(new CommandDefinition(
            """
            INSERT INTO api_keys (tenant_id, nombre, prefijo, hash)
            VALUES (@tenantId, @nombre, @prefijo, @hash)
            """,
            new
            {
                tenantId = creado.Id,
                nombre = NombreClaveEmisor,
                prefijo = fac[..20],
                hash = RepositorioTenants.CalcularHash(fac)
            },
            transaccion, cancellationToken: ct));

        // --- 5. Su webhook de la API, como el de POST /v1/webhook -----------
        var secreto = RepositorioWebhooks.GenerarSecreto();

        var webhookId = await conexion.ExecuteScalarAsync<Guid>(new CommandDefinition(
            """
            INSERT INTO webhooks
                   (tenant_id, nombre, url, secreto, eventos, origen, secreto_cambiado_en)
            VALUES (@tenantId, @nombre, @url, @secreto, '{}', 'api', now())
            RETURNING id
            """,
            new
            {
                tenantId = creado.Id,
                nombre = RepositorioWebhookApi.NombreWebhook,
                url = datos.WebhookUrl,
                secreto
            },
            transaccion, cancellationToken: ct));

        // El rastro: quién lo creó es la clave de alta (su prefijo). Sin secreto.
        await conexion.ExecuteAsync(new CommandDefinition(
            """
            INSERT INTO webhook_cambios
                   (webhook_id, tenant_id, accion, url_antes, url_despues, hecho_desde, prefijo_clave)
            VALUES (@webhookId, @tenantId, 'alta', NULL, @url, 'alta', @prefijo)
            """,
            new { webhookId, tenantId = creado.Id, url = datos.WebhookUrl, prefijo = clave.Prefijo },
            transaccion, cancellationToken: ct));

        await transaccion.CommitAsync(ct);

        return new AltaEmisor(
            ResultadoAlta.Creado,
            EmisorId: creado.Id,
            CreadoEn: creado.CreadoEn,
            Clave: fac,
            WebhookId: webhookId,
            WebhookUrl: datos.WebhookUrl,
            WebhookSecreto: secreto,
            Abandonado: abandonado);
    }

    /// <summary>
    /// Da por abandonado un alta sin confirmar: se desactiva, su clave se
    /// revoca y su webhook se apaga. NADA SE BORRA: la fila queda con la fecha,
    /// y su RUC queda libre para el alta nueva.
    /// </summary>
    private static async Task AbandonarAsync(
        NpgsqlConnection conexion, NpgsqlTransaction transaccion,
        Guid tenantId, string prefijoClaveAlta, CancellationToken ct)
    {
        await conexion.ExecuteAsync(new CommandDefinition(
            """
            INSERT INTO webhook_cambios
                   (webhook_id, tenant_id, accion, url_antes, url_despues, hecho_desde, prefijo_clave)
            SELECT id, tenant_id, 'desactivado', url, url, 'alta', @prefijo
              FROM webhooks
             WHERE tenant_id = @tenantId AND activo
            """,
            new { tenantId, prefijo = prefijoClaveAlta }, transaccion, cancellationToken: ct));

        await conexion.ExecuteAsync(new CommandDefinition(
            "UPDATE webhooks SET activo = false WHERE tenant_id = @tenantId AND activo",
            new { tenantId }, transaccion, cancellationToken: ct));

        await conexion.ExecuteAsync(new CommandDefinition(
            """
            UPDATE api_keys SET activo = false, revocado_en = now()
             WHERE tenant_id = @tenantId AND activo
            """,
            new { tenantId }, transaccion, cancellationToken: ct));

        await conexion.ExecuteAsync(new CommandDefinition(
            """
            UPDATE tenants
               SET estado_alta = 'abandonada', activo = false, abandonada_en = now()
             WHERE id = @tenantId AND estado_alta = 'sin_confirmar'
            """,
            new { tenantId }, transaccion, cancellationToken: ct));
    }

    /// <summary>
    /// La plataforma confirma que guardó lo suyo. Se puede llamar de más: si
    /// ya estaba confirmada, no cambia nada. Devuelve el estado y la fecha.
    /// </summary>
    public async Task<(string Estado, DateTime? ConfirmadaEn)> ConfirmarAsync(
        Guid tenantId, CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);

        await conexion.ExecuteAsync(new CommandDefinition(
            """
            UPDATE tenants
               SET estado_alta = 'confirmada', alta_confirmada_en = now()
             WHERE id = @tenantId AND estado_alta = 'sin_confirmar'
            """,
            new { tenantId }, cancellationToken: ct));

        var fila = await conexion.QuerySingleAsync<FilaConfirmada>(new CommandDefinition(
            """
            SELECT estado_alta AS "Estado", alta_confirmada_en AS "ConfirmadaEn"
              FROM tenants WHERE id = @tenantId
            """,
            new { tenantId }, cancellationToken: ct));

        return (fila.Estado, fila.ConfirmadaEn);
    }

    // ----------------------------------------------------- lo que refleja

    /// <summary>Para GET /v1/emisor: el alta, la marca y lo que falta para emitir.</summary>
    public async Task<EstadoEmisor> EstadoAsync(Guid tenantId, CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);

        return await conexion.QuerySingleAsync<EstadoEmisor>(new CommandDefinition(
            """
            SELECT t.estado_alta           AS "EstadoAlta",
                   t.creado_en             AS "CreadoEn",
                   t.alta_confirmada_en    AS "AltaConfirmadaEn",
                   t.identificador         AS "Identificador",
                   t.correo_respuesta      AS "CorreoRespuesta",
                   (t.logo_ruta IS NOT NULL) AS "TieneLogo",
                   t.usuario_sol           AS "UsuarioSol",
                   (t.clave_sol_cifrada IS NOT NULL) AS "TieneClaveSol",
                   t.ubigeo::text          AS "Ubigeo",
                   t.direccion             AS "Direccion",
                   t.distrito              AS "Distrito",
                   t.provincia             AS "Provincia",
                   t.departamento          AS "Departamento",
                   t.direccion_revisada_en AS "DireccionRevisadaEn",

                   (SELECT c.valido_hasta FROM certificados c
                     WHERE c.tenant_id = t.id AND c.activo
                     LIMIT 1)              AS "CertificadoValidoHasta",

                   (SELECT string_agg(s.serie::text, ',' ORDER BY s.tipo_comprobante, s.serie)
                      FROM series s
                     WHERE s.tenant_id = t.id AND s.activo) AS "SeriesTexto",

                   t.ambiente::text        AS "Ambiente"

              FROM tenants t
             WHERE t.id = @tenantId
            """,
            new { tenantId }, cancellationToken: ct));
    }

    // ----------------------------------------------------------- filas

    // CLASES Y NO record struct: Dapper no materializa bien un struct envuelto
    // en Nullable (ver ProveedorCredenciales).
    private sealed record FilaExistente(Guid Id, string EstadoAlta, Guid? ClaveAlta, DateTime CreadoEn);

    private sealed record FilaCreada(Guid Id, DateTime CreadoEn);

    private sealed record FilaConfirmada(string Estado, DateTime? ConfirmadaEn);
}