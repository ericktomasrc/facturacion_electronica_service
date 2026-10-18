using System.Text.RegularExpressions;
using Dapper;
using Npgsql;

namespace Facturacion.Persistencia;

/// <summary>Un código de SUNAT tal como se ve en el panel.</summary>
public record CodigoSunatVisto(
    string Codigo,
    string Clase,
    DateTime PrimeraVez,
    DateTime UltimaVez,
    long Veces,
    int Empresas,
    string? EjemploMensaje,
    string? EjemploEmpresa,
    string? EjemploRuc,
    string? EjemploDocumento,
    string Origen,
    DateTime? RevisadoEn,
    string? RevisadoCorreo,
    string? Nota)
{
    /// <summary>Apareció después de instalar la vigilancia y nadie lo revisó.</summary>
    public bool EsNuevoSinRevisar => Origen == "nuevo" && RevisadoEn is null;

    public string Gravedad => RepositorioVigilancia.Gravedad(Codigo, Clase);
}

/// <summary>Un correo de la lista de alertas.</summary>
public record CorreoAlerta(long Id, string Correo, string AgregadoCorreo, DateTime AgregadoEn);

/// <summary>Una alerta cuyo correo todavía no salió.</summary>
public record AlertaPendiente(
    long Id, string Tipo, string Gravedad, string Titulo, string Detalle,
    DateTime CreadaEn, short CorreoIntentos);

/// <summary>Cómo fue una vuelta de revisión.</summary>
public record ResultadoRevision(
    bool FueLaPrimera, int IntentosRevisados, int CodigosNuevos, int AlertasCreadas);

/// <summary>Hasta dónde llegó la vigilancia.</summary>
public record EstadoVigilancia(DateTime? InicializadoEn, DateTime? UltimaRevisionEn);

/// <summary>
/// LA ALARMA DE CÓDIGOS NUEVOS (migración 029, Vigilancia SUNAT parte 1).
///
/// Anota cada código que SUNAT devuelve, a cualquier empresa, y avisa cuando
/// aparece uno que nunca había salido. Con cincuenta clientes, el primero que
/// se topa con una regla nueva de SUNAT protege a los otros cuarenta y nueve.
///
/// SOLO LEE LO QUE YA PASÓ. No toca el camino de la emisión: si esto falla,
/// la facturación sigue exactamente igual. Lee tres sitios:
///
///   envio_intentos   cada respuesta a facturas, notas, liquidaciones,
///                    retenciones y percepciones. Se recorre por id, una vez.
///   resumenes        resúmenes de boletas, bajas y reversiones.
///   guias            guías de remisión.
///
/// Las observaciones (4xxx) no tienen columna propia: viajan dentro del
/// mensaje, después de «Observaciones:». Se sacan de ahí (ver Observaciones).
///
/// LA PRIMERA VUELTA anota todo lo que ya existía como 'historico' y NO avisa.
/// Así, al instalarlo, no llegan cien correos de códigos que ya se conocían.
///
/// Usa el rol de operador: mira todas las empresas, como el diagnóstico.
/// </summary>
public sealed class RepositorioVigilancia
{
    private const int Tanda = 5000;

    private readonly string _cadenaOperador;

    /// <summary>Las tablas que la última vuelta no pudo leer (sin permiso).</summary>
    public List<string> TablasSinPermiso { get; } = [];

    public RepositorioVigilancia(string cadenaConexionOperador)
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

    // ================================================================ revisión

    /// <summary>
    /// Una vuelta: lee lo nuevo, anota los códigos y crea las alertas.
    ///
    /// Todo en UNA transacción, con la fila de vigilancia_estado bloqueada:
    /// si dos vueltas coinciden (el reloj y el botón «Revisar ahora»), la
    /// segunda espera a la primera y no cuenta dos veces lo mismo.
    /// </summary>
    public async Task<ResultadoRevision> RevisarAsync(CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);
        await using var tx = await conexion.BeginTransactionAsync(ct);

        var ultimoId = await conexion.QuerySingleAsync<long?>(new CommandDefinition(
            "SELECT ultimo_intento_id FROM vigilancia_estado WHERE id = 1 FOR UPDATE",
            transaction: tx, cancellationToken: ct));

        var primera = ultimoId is null;
        var origen = primera ? "historico" : "nuevo";

        TablasSinPermiso.Clear();
        var vistos = new Dictionary<(string Codigo, string Clase), Acumulado>();
        var revisados = 0;
        var hasta = ultimoId ?? 0;

        // --- 1. envio_intentos, por id, en tandas ----------------------------
        while (true)
        {
            var filas = (await conexion.QueryAsync<FilaIntento>(new CommandDefinition(
                """
                SELECT e.id              AS "Id",
                       e.tenant_id       AS "TenantId",
                       e.codigo_sunat    AS "Codigo",
                       e.mensaje         AS "Mensaje",
                       e.creado_en       AS "CreadoEn",
                       c.serie || '-' || lpad(c.correlativo::text, 8, '0') AS "Documento"
                  FROM envio_intentos e
                  LEFT JOIN comprobantes c ON c.id = e.comprobante_id
                 WHERE e.id > @hasta
                   AND (e.codigo_sunat IS NOT NULL OR e.mensaje LIKE '%Observaciones:%')
                 ORDER BY e.id
                 LIMIT @tanda
                """,
                new { hasta, tanda = Tanda }, tx, cancellationToken: ct))).ToList();

            foreach (var f in filas)
                Anotar(vistos, f.TenantId, f.Codigo, f.Mensaje, f.CreadoEn, f.Documento);

            revisados += filas.Count;

            if (filas.Count < Tanda) break;
            hasta = filas[^1].Id;
        }

        // El tope de verdad, no el de las filas con código: así la próxima
        // vuelta no vuelve a leer intentos sin código.
        var maximo = await conexion.QuerySingleAsync<long?>(new CommandDefinition(
            "SELECT max(id) FROM envio_intentos", transaction: tx, cancellationToken: ct));

        // --- 2. resúmenes y guías --------------------------------------------
        //
        // No tienen un id que crezca, y su código se escribe días después de
        // crearse. Se mira:
        //   - la respuesta, si su código todavía no está anotado (es barato:
        //     son pocas filas por empresa y por día);
        //   - las observaciones, solo de los últimos 15 días (la primera vez,
        //     de todos).
        foreach (var tabla in new[] { "resumenes", "guias" })
        {
            // Si el operador no puede leer la tabla, se salta (y se dice en
            // el log de la API): mejor vigilar dos de tres que ninguna.
            var puedeLeer = await conexion.ExecuteScalarAsync<bool>(new CommandDefinition(
                "SELECT has_table_privilege(current_user, @tabla, 'SELECT')",
                new { tabla }, tx, cancellationToken: ct));

            if (!puedeLeer) { TablasSinPermiso.Add(tabla); continue; }

            var documento = tabla == "resumenes"
                ? "r.identificador"
                : "r.serie || '-' || lpad(r.correlativo::text, 8, '0')";

            var filas = await conexion.QueryAsync<FilaIntento>(new CommandDefinition(
                $"""
                SELECT 0::bigint         AS "Id",
                       r.tenant_id       AS "TenantId",
                       r.codigo_sunat    AS "Codigo",
                       r.mensaje_sunat   AS "Mensaje",
                       r.creado_en       AS "CreadoEn",
                       {documento}       AS "Documento"
                  FROM {tabla} r
                 WHERE (r.codigo_sunat IS NOT NULL
                        AND NOT EXISTS (SELECT 1 FROM codigos_sunat v
                                         WHERE v.codigo = btrim(r.codigo_sunat)
                                           AND v.clase = 'respuesta'))
                    OR (r.mensaje_sunat LIKE '%Observaciones:%'
                        AND (@primera OR r.creado_en >= now() - interval '15 days'))
                """,
                new { primera }, tx, cancellationToken: ct));

            foreach (var f in filas)
            {
                // De estas solo cuentan los códigos que todavía no existen:
                // las observaciones de los últimos 15 días se leen en cada
                // vuelta, y sumarlas cada vez inflaría las «veces».
                Anotar(vistos, f.TenantId, f.Codigo, f.Mensaje, f.CreadoEn, f.Documento,
                       soloSiEsNuevo: true);
            }
        }

        // --- 3. guardar -------------------------------------------------------
        var nuevos = 0;
        var alertas = 0;

        foreach (var ((codigo, clase), a) in vistos)
        {
            var existia = await conexion.ExecuteScalarAsync<bool>(new CommandDefinition(
                "SELECT EXISTS (SELECT 1 FROM codigos_sunat WHERE codigo = @codigo AND clase = @clase)",
                new { codigo, clase }, tx, cancellationToken: ct));

            if (existia)
            {
                if (a.Veces > 0)
                {
                    await conexion.ExecuteAsync(new CommandDefinition(
                        """
                        UPDATE codigos_sunat
                           SET veces = veces + @veces,
                               ultima_vez = greatest(ultima_vez, @ultima)
                         WHERE codigo = @codigo AND clase = @clase
                        """,
                        new { codigo, clase, veces = a.Veces, ultima = a.Ultima },
                        tx, cancellationToken: ct));
                }
            }
            else
            {
                await conexion.ExecuteAsync(new CommandDefinition(
                    """
                    INSERT INTO codigos_sunat
                        (codigo, clase, primera_vez, ultima_vez, veces,
                         ejemplo_mensaje, ejemplo_tenant_id, ejemplo_documento, origen)
                    VALUES
                        (@codigo, @clase, @primera, @ultima, @veces,
                         @mensaje, @tenantId, @documento, @origen)
                    """,
                    new
                    {
                        codigo, clase,
                        primera = a.Primera, ultima = a.Ultima,
                        veces = Math.Max(1, a.Veces),
                        mensaje = Recortar(a.Mensaje, 1000),
                        tenantId = a.TenantId,
                        documento = Recortar(a.Documento, 60),
                        // El 0 es «aceptado»: nunca es una regla nueva. Se anota
                        // como conocido, sin «nuevo» ni número rojo (17 oct).
                        origen = clase == "respuesta" && codigo == "0" ? "historico" : origen
                    },
                    tx, cancellationToken: ct));

                nuevos++;

                // El 0 es «aceptado»: no es una regla nueva, no avisa nunca.
                if (!primera && !(clase == "respuesta" && codigo == "0"))
                {
                    await CrearAlertaCodigoAsync(conexion, tx, codigo, clase, a, ct);
                    alertas++;
                }
            }

            foreach (var tenantId in a.Empresas)
            {
                await conexion.ExecuteAsync(new CommandDefinition(
                    """
                    INSERT INTO codigos_sunat_empresas (codigo, clase, tenant_id, primera_vez)
                    VALUES (@codigo, @clase, @tenantId, @cuando)
                    ON CONFLICT DO NOTHING
                    """,
                    new { codigo, clase, tenantId, cuando = a.Primera },
                    tx, cancellationToken: ct));
            }
        }

        await conexion.ExecuteAsync(new CommandDefinition(
            """
            UPDATE vigilancia_estado
               SET ultimo_intento_id  = greatest(coalesce(ultimo_intento_id, 0), @maximo),
                   inicializado_en    = coalesce(inicializado_en, now()),
                   ultima_revision_en = now()
             WHERE id = 1
            """,
            new { maximo = maximo ?? 0 }, tx, cancellationToken: ct));

        await tx.CommitAsync(ct);

        return new ResultadoRevision(primera, revisados, nuevos, alertas);
    }

    private static async Task CrearAlertaCodigoAsync(
        NpgsqlConnection conexion, NpgsqlTransaction tx,
        string codigo, string clase, Acumulado a, CancellationToken ct)
    {
        var empresa = a.TenantId is null ? null : await conexion.QuerySingleOrDefaultAsync<FilaEmpresa>(
            new CommandDefinition(
                """SELECT razon_social AS "RazonSocial", ruc AS "Ruc" FROM tenants WHERE id = @id""",
                new { id = a.TenantId }, tx, cancellationToken: ct));

        var gravedad = Gravedad(codigo, clase);
        var que = clase == "observacion" ? "observación" : "respuesta";

        var titulo = $"Código de SUNAT nunca visto: {codigo} ({que})";

        var detalle =
            $"SUNAT dijo: {a.Mensaje ?? "(sin mensaje)"}\n" +
            $"Empresa: {(empresa is null ? "—" : $"{empresa.RazonSocial} ({empresa.Ruc})")}\n" +
            $"Documento: {a.Documento ?? "—"}\n" +
            $"Cuándo: {a.Primera:yyyy-MM-dd HH:mm} (hora del servidor)";

        await conexion.ExecuteAsync(new CommandDefinition(
            """
            INSERT INTO vigilancia_alertas (tipo, gravedad, titulo, detalle, codigo, clase)
            VALUES ('codigo_nuevo', @gravedad, @titulo, @detalle, @codigo, @clase)
            """,
            new { gravedad, titulo, detalle = Recortar(detalle, 3000), codigo, clase },
            tx, cancellationToken: ct));
    }

    // ============================================================ observaciones

    private static readonly Regex CodigoAlInicio =
        new(@"^\W*(\d{3,4})\b", RegexOptions.Compiled);

    /// <summary>
    /// Saca las observaciones de un mensaje guardado.
    ///
    /// El worker escribe «… Observaciones: A | B» (comprobantes y resúmenes)
    /// o «… | Observaciones: A; B» (guías). Cada observación de SUNAT empieza
    /// por su código («4287 - El precio…»). La que no empiece por un código
    /// de 3 o 4 cifras se ignora: mejor no anotar nada que anotar basura.
    /// </summary>
    public static IEnumerable<(string Codigo, string Texto)> Observaciones(string? mensaje)
    {
        if (string.IsNullOrEmpty(mensaje)) yield break;

        var i = mensaje.IndexOf("Observaciones:", StringComparison.Ordinal);
        if (i < 0) yield break;

        var resto = mensaje[(i + "Observaciones:".Length)..];

        foreach (var trozo in resto.Split(new[] { '|', ';' }, StringSplitOptions.RemoveEmptyEntries))
        {
            var texto = trozo.Trim();
            var m = CodigoAlInicio.Match(texto);
            if (m.Success) yield return (m.Groups[1].Value, texto);
        }
    }

    /// <summary>
    /// Qué tan grave es un código nuevo.
    ///
    /// Respuestas: 0100–1999 son excepciones (SUNAT ni siquiera lo recibió) y
    /// 2000–3999 son rechazos: «problema», porque un cliente no puede emitir.
    /// Las observaciones (4000 en adelante) dejan pasar el comprobante:
    /// «atención». Lo que no sea un número también es «atención».
    /// </summary>
    public static string Gravedad(string codigo, string clase)
    {
        if (clase == "observacion") return "atencion";

        var digitos = new string(codigo.Reverse().TakeWhile(char.IsDigit).Reverse().ToArray());

        return int.TryParse(digitos, out var n) && n is >= 100 and < 4000
            ? "problema"
            : "atencion";
    }

    private static void Anotar(
        Dictionary<(string, string), Acumulado> vistos,
        Guid? tenantId, string? codigo, string? mensaje, DateTime cuando, string? documento,
        bool soloSiEsNuevo = false)
    {
        var codigoLimpio = codigo?.Trim();

        // «RED» NO ES UN CÓDIGO DE SUNAT: lo pone nuestro enviador cuando no
        // llegó a hablar con SUNAT (sin internet, DNS, tiempo agotado). No dice
        // nada de sus reglas y ya se reintenta solo; anotarlo como código nuevo
        // solo manda falsas alarmas cada vez que se corta la red (16 oct).
        if (string.Equals(codigoLimpio, "RED", StringComparison.OrdinalIgnoreCase))
            codigoLimpio = null;

        if (!string.IsNullOrEmpty(codigoLimpio))
        {
            // El mensaje de ejemplo es lo que SUNAT dijo, sin las observaciones.
            var i = mensaje?.IndexOf(" Observaciones:", StringComparison.Ordinal) ?? -1;
            var propio = i > 0 ? mensaje![..i] : mensaje;

            Sumar(vistos, (Recortar(codigoLimpio, 20)!, "respuesta"),
                  tenantId, propio, cuando, documento, soloSiEsNuevo);
        }

        foreach (var (cod, texto) in Observaciones(mensaje))
            Sumar(vistos, (cod, "observacion"), tenantId, texto, cuando, documento, soloSiEsNuevo);
    }

    private static void Sumar(
        Dictionary<(string, string), Acumulado> vistos, (string, string) clave,
        Guid? tenantId, string? mensaje, DateTime cuando, string? documento, bool soloSiEsNuevo)
    {
        if (!vistos.TryGetValue(clave, out var a))
        {
            a = new Acumulado { Primera = cuando, Ultima = cuando, Mensaje = mensaje,
                                TenantId = tenantId, Documento = documento };
            vistos[clave] = a;
        }

        if (!soloSiEsNuevo) a.Veces++;

        if (cuando < a.Primera)
        {
            a.Primera = cuando; a.Mensaje = mensaje; a.TenantId = tenantId; a.Documento = documento;
        }
        if (cuando > a.Ultima) a.Ultima = cuando;
        if (tenantId is { } t) a.Empresas.Add(t);
    }

    private static string? Recortar(string? t, int largo) =>
        t is null ? null : t.Length <= largo ? t : t[..largo];

    private sealed class Acumulado
    {
        public DateTime Primera;
        public DateTime Ultima;
        public long Veces;
        public string? Mensaje;
        public Guid? TenantId;
        public string? Documento;
        public HashSet<Guid> Empresas { get; } = [];
    }

    private sealed record FilaIntento(
        long Id, Guid? TenantId, string? Codigo, string? Mensaje, DateTime CreadoEn, string? Documento);

    private sealed record FilaEmpresa(string RazonSocial, string Ruc);

    // ================================================================= panel

    public async Task<EstadoVigilancia> EstadoAsync(CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);

        return await conexion.QuerySingleAsync<EstadoVigilancia>(new CommandDefinition(
            """
            SELECT inicializado_en    AS "InicializadoEn",
                   ultima_revision_en AS "UltimaRevisionEn"
              FROM vigilancia_estado WHERE id = 1
            """,
            cancellationToken: ct));
    }

    /// <summary>Los códigos: primero los nuevos sin revisar, después el resto.</summary>
    public async Task<IReadOnlyList<CodigoSunatVisto>> ListarCodigosAsync(CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);

        return (await conexion.QueryAsync<CodigoSunatVisto>(new CommandDefinition(
            """
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
             ORDER BY (c.origen = 'nuevo' AND c.revisado_en IS NULL) DESC,
                      c.ultima_vez DESC
             LIMIT 1000
            """,
            cancellationToken: ct))).ToList();
    }

    /// <summary>
    /// Deja dicho quién revisó un código, cuándo y qué es. Una sola vez: la
    /// revisión no se sobrescribe (nada se borra). Devuelve false si el código
    /// no existe o ya estaba revisado.
    /// </summary>
    public async Task<bool> MarcarRevisadoAsync(
        string codigo, string clase, Guid usuarioId, string correo, string nota,
        CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);

        var filas = await conexion.ExecuteAsync(new CommandDefinition(
            """
            UPDATE codigos_sunat
               SET revisado_en = now(),
                   revisado_por = @usuarioId,
                   revisado_correo = @correo,
                   nota = @nota
             WHERE codigo = @codigo AND clase = @clase AND revisado_en IS NULL
            """,
            new { codigo, clase, usuarioId, correo, nota },
            cancellationToken: ct));

        return filas > 0;
    }

    /// <summary>Para el semáforo de «Estado del servicio».</summary>
    public async Task<IReadOnlyList<CodigoSunatVisto>> NuevosSinRevisarAsync(CancellationToken ct = default)
    {
        var todos = await ListarCodigosAsync(ct);
        return todos.Where(c => c.EsNuevoSinRevisar).ToList();
    }

    // ================================================================ correos

    public async Task<IReadOnlyList<CorreoAlerta>> ListarCorreosAsync(CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);

        return (await conexion.QueryAsync<CorreoAlerta>(new CommandDefinition(
            """
            SELECT id              AS "Id",
                   correo          AS "Correo",
                   agregado_correo AS "AgregadoCorreo",
                   agregado_en     AS "AgregadoEn"
              FROM vigilancia_correos
             WHERE quitado_en IS NULL
             ORDER BY agregado_en
            """,
            cancellationToken: ct))).ToList();
    }

    /// <summary>Los administradores del panel: los que pueden gestionar usuarios.</summary>
    public async Task<IReadOnlyList<string>> CorreosAdministradoresAsync(CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);

        return (await conexion.QueryAsync<string>(new CommandDefinition(
            """
            SELECT DISTINCT u.correo
              FROM usuarios u
              JOIN rol_permisos rp ON rp.rol_id = u.rol_id
             WHERE u.activo AND rp.permiso = 'usuarios.gestionar'
             ORDER BY u.correo
            """,
            cancellationToken: ct))).ToList();
    }

    /// <summary>
    /// A quién le llega una alerta: los administradores y la lista. Sin
    /// repetidos. Si la lista está vacía, igual llega a los administradores.
    /// </summary>
    public async Task<IReadOnlyList<string>> DestinatariosAsync(CancellationToken ct = default)
    {
        var admins = await CorreosAdministradoresAsync(ct);
        var lista = await ListarCorreosAsync(ct);

        return admins.Concat(lista.Select(c => c.Correo))
            .GroupBy(c => c.Trim().ToLowerInvariant())
            .Select(g => g.First().Trim())
            .ToList();
    }

    /// <summary>Devuelve null si se agregó, o el motivo si no.</summary>
    public async Task<string?> AgregarCorreoAsync(
        string correo, Guid usuarioId, string correoUsuario, CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);

        try
        {
            await conexion.ExecuteAsync(new CommandDefinition(
                """
                INSERT INTO vigilancia_correos (correo, agregado_por, agregado_correo)
                VALUES (@correo, @usuarioId, @correoUsuario)
                """,
                new { correo, usuarioId, correoUsuario },
                cancellationToken: ct));

            return null;
        }
        catch (PostgresException ex) when (ex.SqlState == "23505")
        {
            return "Ese correo ya está en la lista.";
        }
        catch (PostgresException ex) when (ex.SqlState == "23514")
        {
            return "Ese correo no tiene forma de correo.";
        }
    }

    /// <summary>Lo quita de la lista sin borrarlo: queda quién y cuándo.</summary>
    public async Task<bool> QuitarCorreoAsync(
        long id, Guid usuarioId, string correoUsuario, CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);

        return await conexion.ExecuteAsync(new CommandDefinition(
            """
            UPDATE vigilancia_correos
               SET quitado_en = now(), quitado_por = @usuarioId, quitado_correo = @correoUsuario
             WHERE id = @id AND quitado_en IS NULL
            """,
            new { id, usuarioId, correoUsuario },
            cancellationToken: ct)) > 0;
    }

    // ================================================================ alertas

    /// <summary>
    /// Las alertas cuyo correo toca mandar ahora. SKIP LOCKED: si algún día
    /// corren dos API, no mandan el mismo correo dos veces.
    /// </summary>
    public async Task<(NpgsqlConnection Conexion, NpgsqlTransaction Tx, IReadOnlyList<AlertaPendiente> Alertas)>
        TomarPendientesAsync(int maximo, CancellationToken ct = default)
    {
        var conexion = await AbrirAsync(ct);
        var tx = await conexion.BeginTransactionAsync(ct);

        var alertas = (await conexion.QueryAsync<AlertaPendiente>(new CommandDefinition(
            """
            SELECT id              AS "Id",
                   tipo            AS "Tipo",
                   gravedad        AS "Gravedad",
                   titulo          AS "Titulo",
                   detalle         AS "Detalle",
                   creada_en       AS "CreadaEn",
                   correo_intentos AS "CorreoIntentos"
              FROM vigilancia_alertas
             WHERE correo_enviado_en IS NULL
               AND correo_intentos < 6
               AND proximo_intento_en <= now()
             ORDER BY creada_en
             LIMIT @maximo
             FOR UPDATE SKIP LOCKED
            """,
            new { maximo }, tx, cancellationToken: ct))).ToList();

        return (conexion, tx, alertas);
    }

    public static Task MarcarEnviadasAsync(
        NpgsqlConnection conexion, NpgsqlTransaction tx,
        IEnumerable<long> ids, string enviadoA, CancellationToken ct) =>
        conexion.ExecuteAsync(new CommandDefinition(
            """
            UPDATE vigilancia_alertas
               SET correo_enviado_en = now(),
                   enviado_a = @enviadoA,
                   correo_intentos = correo_intentos + 1,
                   correo_error = NULL
             WHERE id = ANY(@ids)
            """,
            new { ids = ids.ToArray(), enviadoA }, tx, cancellationToken: ct));

    public static Task MarcarFalloAsync(
        NpgsqlConnection conexion, NpgsqlTransaction tx,
        IEnumerable<long> ids, string error, TimeSpan espera, CancellationToken ct) =>
        conexion.ExecuteAsync(new CommandDefinition(
            """
            UPDATE vigilancia_alertas
               SET correo_intentos = correo_intentos + 1,
                   correo_error = @error,
                   proximo_intento_en = now() + @espera
             WHERE id = ANY(@ids)
            """,
            new { ids = ids.ToArray(), error, espera }, tx, cancellationToken: ct));
}