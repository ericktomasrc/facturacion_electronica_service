using System.Security.Cryptography;
using System.Text;
using Dapper;
using Npgsql;

namespace Facturacion.Persistencia;

/// <summary>Un usuario del panel, sin datos sensibles.</summary>
/// <param name="PermisosTexto">
/// Los permisos de su rol, separados por comas. Llegan así y no como arreglo
/// porque Dapper no materializa bien un text[] de PostgreSQL.
/// </param>
public record UsuarioPanel(
    Guid Id,
    string Correo,
    string Nombre,
    Guid RolId,
    string RolClave,
    string RolNombre,
    bool Activo,
    bool DebeCambiar,
    DateTime? UltimoIngreso,
    DateTime CreadoEn,
    bool TotpActivo = false,
    string? PermisosTexto = null,
    DateTime? ProvisionalExpira = null,
    DateTime? TotpObligatorioDesde = null)
{
    /// <summary>
    /// Tiene que configurar el segundo factor antes de poder trabajar.
    ///
    /// El panel lo lleva a hacerlo y no le deja continuar hasta terminar,
    /// igual que con la contraseña provisional.
    /// </summary>
    public bool DebeConfigurarTotp =>
        !TotpActivo &&
        TotpObligatorioDesde is not null &&
        TotpObligatorioDesde <= DateTime.UtcNow;

    /// <summary>La contraseña provisional dejó de servir.</summary>
    public bool ProvisionalCaducada =>
        DebeCambiar &&
        ProvisionalExpira is not null &&
        ProvisionalExpira < DateTime.UtcNow;

    public string[] Permisos =>
        string.IsNullOrWhiteSpace(PermisosTexto)
            ? []
            : PermisosTexto.Split(',', StringSplitOptions.RemoveEmptyEntries);

    /// <summary>
    /// Comprueba un permiso concreto.
    ///
    /// ES LA ÚNICA FORMA DE PREGUNTAR. Antes se miraba el rol —"¿es
    /// administrador?"— y eso deja de servir en cuanto los roles los define
    /// el usuario: mañana habrá un rol "Supervisor" que también debe poder
    /// cargar certificados, y ningún código debería tener que enterarse.
    /// </summary>
    public bool Puede(string permiso) => Permisos.Contains(permiso);

    /// <summary>Conserva la idea de administrador para los casos límite.</summary>
    public bool EsAdministrador => Puede(Permiso.UsuariosGestionar);
}

/// <summary>Resultado de intentar ingresar.</summary>
/// <param name="FaltaSegundoFactor">
/// La contraseña era correcta, pero el usuario tiene segundo factor activo.
/// Hay que pedirle el código antes de abrir la sesión.
/// </param>
/// <param name="TokenParcial">
/// Identificador de corta vida que acredita haber superado la contraseña.
///
/// POR QUÉ NO SE PIDE LA CONTRASEÑA OTRA VEZ junto con el código: obligaría
/// al navegador a conservarla en memoria mientras el usuario busca su
/// teléfono. Este identificador dura cinco minutos y no sirve para nada más.
/// </param>
public record ResultadoIngreso(
    bool Exitoso,
    string? Token,
    UsuarioPanel? Usuario,
    string? Motivo,
    bool FaltaSegundoFactor = false,
    string? TokenParcial = null);

/// <summary>Una entrada de la bitácora de acciones.</summary>
public record AccionAuditada(
    long Id,
    string Correo,
    string Accion,
    string Ruta,
    Guid? TenantId,
    int CodigoRespuesta,
    string? DireccionIp,
    DateTime CreadoEn);

/// <summary>
/// Usuarios, sesiones y bitácora del panel.
///
/// Reemplaza a la clave compartida. El cambio importante no es técnico sino
/// de responsabilidad: ahora cada acción tiene un nombre detrás.
/// </summary>
public sealed class RepositorioUsuarios
{
    /// <summary>Cuánto dura una sesión sin actividad.</summary>
    public static readonly TimeSpan DuracionSesion = TimeSpan.FromHours(12);

    /// <summary>
    /// Cuánto sirve una contraseña provisional antes de caducar.
    ///
    /// Dos días dan margen para que alguien la use al volver de un fin de
    /// semana, y son poco tiempo para que una contraseña olvidada en una
    /// bandeja de correo siga abriendo el panel meses después.
    /// </summary>
    public static readonly TimeSpan VigenciaProvisional = TimeSpan.FromHours(48);

    /// <summary>Intentos fallidos antes de bloquear temporalmente.</summary>
    private const int IntentosAntesDeBloquear = 5;

    private static readonly TimeSpan Bloqueo = TimeSpan.FromMinutes(15);

    private readonly string _cadenaOperador;
    private readonly IProtectorDeSecretos _protector;

    public RepositorioUsuarios(
        string cadenaConexionOperador, IProtectorDeSecretos protector)
    {
        _cadenaOperador = cadenaConexionOperador
            ?? throw new ArgumentNullException(nameof(cadenaConexionOperador));

        // El secreto del segundo factor se cifra igual que los certificados.
        // Con él en claro, cualquiera con acceso a la base podría generar
        // códigos válidos y el segundo factor no serviría para nada.
        _protector = protector ?? throw new ArgumentNullException(nameof(protector));
    }

    /// <summary>
    /// Identificadores parciales: han superado la contraseña pero falta el
    /// código del segundo factor.
    ///
    /// SE GUARDAN EN MEMORIA, NO EN LA BASE, porque duran cinco minutos y su
    /// pérdida al reiniciar no tiene consecuencias: el usuario simplemente
    /// vuelve a escribir su contraseña.
    /// </summary>
    private static readonly System.Collections.Concurrent.ConcurrentDictionary<
        string, (Guid UsuarioId, DateTime Expira)> _parciales = new();

    private static readonly TimeSpan VidaParcial = TimeSpan.FromMinutes(5);

    private async Task<NpgsqlConnection> AbrirAsync(CancellationToken ct)
    {
        var conexion = new NpgsqlConnection(_cadenaOperador);
        await conexion.OpenAsync(ct);
        return conexion;
    }

    // --------------------------------------------------------------- ingreso

    /// <summary>
    /// Comprueba las credenciales y abre una sesión.
    ///
    /// EL MENSAJE DE ERROR ES SIEMPRE EL MISMO para usuario inexistente y
    /// contraseña incorrecta. Distinguirlos permitiría averiguar qué correos
    /// están registrados probando uno por uno, y esa lista es el primer paso
    /// de cualquier intento serio.
    /// </summary>
    public async Task<ResultadoIngreso> IngresarAsync(
        string correo, string contrasena,
        string? direccionIp, string? agente,
        CancellationToken ct = default)
    {
        const string generico = "Correo o contraseña incorrectos.";

        await using var conexion = await AbrirAsync(ct);

        var fila = await conexion.QuerySingleOrDefaultAsync<FilaIngreso>(
            new CommandDefinition(
                """
                SELECT u.id                AS "Id",
                       u.correo            AS "Correo",
                       u.nombre            AS "Nombre",
                       u.contrasena_hash   AS "Hash",
                       u.rol_id            AS "RolId",
                       r.clave             AS "RolClave",
                       r.nombre            AS "RolNombre",
                       u.activo            AS "Activo",
                       u.debe_cambiar      AS "DebeCambiar",
                       u.ultimo_ingreso    AS "UltimoIngreso",
                       u.intentos_fallidos AS "IntentosFallidos",
                       u.bloqueado_hasta   AS "BloqueadoHasta",
                       u.creado_en         AS "CreadoEn",
                       u.totp_activo       AS "TotpActivo",
                       u.provisional_expira AS "ProvisionalExpira",

                       (SELECT string_agg(rp.permiso, ',')
                          FROM rol_permisos rp
                         WHERE rp.rol_id = u.rol_id) AS "PermisosTexto"

                  FROM usuarios u
                  JOIN roles r ON r.id = u.rol_id
                 WHERE u.correo = @correo
                """,
                new { correo = correo.Trim() }, cancellationToken: ct));

        if (fila is null)
        {
            // Se cifra igualmente una contraseña de descarte para que el
            // tiempo de respuesta sea parecido al del caso real. Si no,
            // responder más rápido delataría que ese correo no existe.
            Contrasenas.Verificar(contrasena,
                "pbkdf2-sha256$210000$AAAAAAAAAAAAAAAAAAAAAA==$AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
                out _);

            return new ResultadoIngreso(false, null, null, generico);
        }

        var u = fila;

        if (u.BloqueadoHasta is not null && u.BloqueadoHasta > DateTime.UtcNow)
        {
            var minutos = (int)Math.Ceiling(
                (u.BloqueadoHasta.Value - DateTime.UtcNow).TotalMinutes);

            return new ResultadoIngreso(false, null, null,
                $"Demasiados intentos fallidos. Vuelve a probar en {minutos} " +
                $"minuto{(minutos == 1 ? "" : "s")}.");
        }

        if (!u.Activo)
            return new ResultadoIngreso(false, null, null,
                "Esta cuenta está desactivada.");

        if (!Contrasenas.Verificar(contrasena, u.Hash, out var recifrar))
        {
            await RegistrarFalloAsync(conexion, u.Id, u.IntentosFallidos, ct);
            return new ResultadoIngreso(false, null, null, generico);
        }

        // La contraseña es correcta, pero era provisional y caducó.
        //
        // SE COMPRUEBA DESPUÉS DE VERIFICARLA, no antes: decir "esa
        // contraseña caducó" a quien la escribió mal confirmaría que existe
        // esa cuenta y que alguien la creó recientemente.
        if (u.DebeCambiar &&
            u.ProvisionalExpira is not null &&
            u.ProvisionalExpira < DateTime.UtcNow)
        {
            return new ResultadoIngreso(false, null, null,
                "Tu contraseña provisional caducó. Pídele al administrador " +
                "que te la restablezca, o usa la opción de recuperarla.");
        }

        // --- Credenciales correctas ---

        // Si tiene segundo factor, la contraseña no basta: se entrega un
        // identificador parcial y se pide el código.
        if (u.TotpActivo)
        {
            var parcial = GenerarToken();

            _parciales[parcial] = (u.Id, DateTime.UtcNow.Add(VidaParcial));

            LimpiarParcialesCaducados();

            return new ResultadoIngreso(
                false, null, null, null,
                FaltaSegundoFactor: true, TokenParcial: parcial);
        }

        return await AbrirSesionAsync(
            conexion, u, contrasena, recifrar, direccionIp, agente, ct);
    }

    /// <summary>
    /// Segundo paso del ingreso: comprueba el código del autenticador o un
    /// código de recuperación.
    /// </summary>
    public async Task<ResultadoIngreso> CompletarIngresoAsync(
        string tokenParcial, string codigo,
        string? direccionIp, string? agente,
        CancellationToken ct = default)
    {
        LimpiarParcialesCaducados();

        if (!_parciales.TryGetValue(tokenParcial, out var pendiente) ||
            pendiente.Expira < DateTime.UtcNow)
        {
            _parciales.TryRemove(tokenParcial, out _);

            return new ResultadoIngreso(false, null, null,
                "El ingreso caducó. Vuelve a escribir tu correo y contraseña.");
        }

        await using var conexion = await AbrirAsync(ct);

        var fila = await conexion.QuerySingleOrDefaultAsync<FilaTotp>(
            new CommandDefinition(
                """
                SELECT u.id                   AS "Id",
                       u.correo               AS "Correo",
                       u.nombre               AS "Nombre",
                       u.rol_id               AS "RolId",
                       r.clave                AS "RolClave",
                       r.nombre               AS "RolNombre",
                       u.activo               AS "Activo",
                       u.debe_cambiar         AS "DebeCambiar",
                       u.ultimo_ingreso       AS "UltimoIngreso",
                       u.creado_en            AS "CreadoEn",
                       u.totp_secreto_cifrado AS "SecretoCifrado",
                       u.totp_ultimo_periodo  AS "UltimoPeriodo",

                       (SELECT string_agg(rp.permiso, ',')
                          FROM rol_permisos rp
                         WHERE rp.rol_id = u.rol_id) AS "PermisosTexto"

                  FROM usuarios u
                  JOIN roles r ON r.id = u.rol_id
                 WHERE u.id = @usuarioId AND u.activo
                """,
                new { usuarioId = pendiente.UsuarioId }, cancellationToken: ct));

        if (fila is null || fila.SecretoCifrado is null)
            return new ResultadoIngreso(false, null, null,
                "No se pudo completar el ingreso.");

        var secreto = _protector.DesprotegerTexto(fila.SecretoCifrado);

        var valido = false;

        if (Totp.Verificar(secreto, codigo, out var periodo))
        {
            // UN CÓDIGO NO SE PUEDE USAR DOS VECES.
            //
            // Sin esta comprobación, quien viera el código por encima del
            // hombro tendría hasta noventa segundos para usarlo.
            if (fila.UltimoPeriodo is not null && periodo <= fila.UltimoPeriodo)
            {
                return new ResultadoIngreso(false, null, null,
                    "Ese código ya se usó. Espera al siguiente.");
            }

            await conexion.ExecuteAsync(new CommandDefinition(
                "UPDATE usuarios SET totp_ultimo_periodo = @periodo WHERE id = @id",
                new { periodo, id = fila.Id }, cancellationToken: ct));

            valido = true;
        }
        else
        {
            // Si no es un código del autenticador, puede ser uno de
            // recuperación.
            valido = await ConsumirCodigoRecuperacionAsync(
                conexion, fila.Id, codigo, ct);
        }

        if (!valido)
            return new ResultadoIngreso(false, null, null,
                "El código no es correcto.");

        _parciales.TryRemove(tokenParcial, out _);

        var usuario = new UsuarioPanel(
            fila.Id, fila.Correo, fila.Nombre,
            fila.RolId, fila.RolClave, fila.RolNombre, fila.Activo,
            fila.DebeCambiar, fila.UltimoIngreso, fila.CreadoEn,
            true, fila.PermisosTexto);

        var token = GenerarToken();

        await conexion.ExecuteAsync(new CommandDefinition(
            """
            INSERT INTO sesiones
                (usuario_id, token_hash, direccion_ip, agente, expira_en)
            VALUES
                (@usuarioId, @hash, @ip::inet, @agente, @expira)
            """,
            new
            {
                usuarioId = fila.Id,
                hash = HashToken(token),
                ip = direccionIp,
                agente = agente?.Length > 400 ? agente[..400] : agente,
                expira = DateTime.UtcNow.Add(DuracionSesion)
            },
            cancellationToken: ct));

        await conexion.ExecuteAsync(new CommandDefinition(
            """
            UPDATE usuarios
               SET ultimo_ingreso = now(), intentos_fallidos = 0,
                   bloqueado_hasta = NULL
             WHERE id = @usuarioId
            """,
            new { usuarioId = fila.Id }, cancellationToken: ct));

        return new ResultadoIngreso(true, token, usuario, null);
    }

    private static void LimpiarParcialesCaducados()
    {
        foreach (var par in _parciales)
            if (par.Value.Expira < DateTime.UtcNow)
                _parciales.TryRemove(par.Key, out _);
    }

    private async Task<ResultadoIngreso> AbrirSesionAsync(
        NpgsqlConnection conexion, FilaIngreso u, string contrasena,
        bool recifrar, string? direccionIp, string? agente, CancellationToken ct)
    {
        // El identificador de sesión es aleatorio y se guarda solo su hash.
        // Si alguien obtiene una copia de la base, no puede suplantar a nadie.
        var token = GenerarToken();

        await using var transaccion = await conexion.BeginTransactionAsync(ct);

        await conexion.ExecuteAsync(new CommandDefinition(
            """
            INSERT INTO sesiones
                (usuario_id, token_hash, direccion_ip, agente, expira_en)
            VALUES
                (@usuarioId, @hash, @ip::inet, @agente, @expira)
            """,
            new
            {
                usuarioId = u.Id,
                hash = HashToken(token),
                ip = direccionIp,
                agente = agente?.Length > 400 ? agente[..400] : agente,
                expira = DateTime.UtcNow.Add(DuracionSesion)
            },
            transaccion, cancellationToken: ct));

        await conexion.ExecuteAsync(new CommandDefinition(
            """
            UPDATE usuarios
               SET ultimo_ingreso = now(),
                   intentos_fallidos = 0,
                   bloqueado_hasta = NULL,
                   contrasena_hash = COALESCE(@nuevoHash, contrasena_hash)
             WHERE id = @usuarioId
            """,
            new
            {
                usuarioId = u.Id,
                // Si el hash se hizo con menos iteraciones de las actuales,
                // este es el único momento en que tenemos la contraseña en
                // claro para recifrarla.
                nuevoHash = recifrar ? Contrasenas.Cifrar(contrasena) : null
            },
            transaccion, cancellationToken: ct));

        await transaccion.CommitAsync(ct);

        var usuario = new UsuarioPanel(
            u.Id, u.Correo, u.Nombre, u.RolId, u.RolClave, u.RolNombre,
            u.Activo, u.DebeCambiar, u.UltimoIngreso, u.CreadoEn,
            u.TotpActivo, u.PermisosTexto, u.ProvisionalExpira);

        return new ResultadoIngreso(true, token, usuario, null);
    }

    private static async Task RegistrarFalloAsync(
        NpgsqlConnection conexion, Guid usuarioId, short fallosPrevios,
        CancellationToken ct)
    {
        var fallos = fallosPrevios + 1;

        // Bloqueo temporal, no permanente.
        //
        // Un bloqueo permanente convierte un ataque en una forma de dejar
        // fuera al usuario legítimo: basta fallar cinco veces con su correo
        // para que no pueda entrar nunca más.
        var bloquear = fallos >= IntentosAntesDeBloquear;

        await conexion.ExecuteAsync(new CommandDefinition(
            """
            UPDATE usuarios
               SET intentos_fallidos = @fallos,
                   bloqueado_hasta = CASE WHEN @bloquear
                       THEN now() + @duracion::interval
                       ELSE bloqueado_hasta END
             WHERE id = @usuarioId
            """,
            new
            {
                usuarioId,
                fallos,
                bloquear,
                duracion = $"{(int)Bloqueo.TotalSeconds} seconds"
            },
            cancellationToken: ct));
    }

    /// <summary>Resuelve el usuario a partir del identificador de sesión.</summary>
    public async Task<UsuarioPanel?> ResolverSesionAsync(
        string token, CancellationToken ct = default)
    {
        if (string.IsNullOrWhiteSpace(token)) return null;

        await using var conexion = await AbrirAsync(ct);

        // Una sola consulta que valida la sesión Y registra su uso. El uso
        // sirve para el tiempo de inactividad: una sesión que nadie toca
        // durante doce horas caduca.
        var usuario = await conexion.QuerySingleOrDefaultAsync<UsuarioPanel?>(
            new CommandDefinition(
                """
                WITH sesion_usada AS (
                    UPDATE sesiones
                       SET ultimo_uso = now(),
                           expira_en = now() + @duracion::interval
                     WHERE token_hash = @hash
                       AND revocada_en IS NULL
                       AND expira_en > now()
                    RETURNING usuario_id
                )
                SELECT u.id             AS "Id",
                       u.correo         AS "Correo",
                       u.nombre         AS "Nombre",
                       u.rol_id         AS "RolId",
                       r.clave          AS "RolClave",
                       r.nombre         AS "RolNombre",
                       u.activo         AS "Activo",
                       u.debe_cambiar   AS "DebeCambiar",
                       u.ultimo_ingreso AS "UltimoIngreso",
                       u.creado_en      AS "CreadoEn",
                       u.totp_activo    AS "TotpActivo",

                       (SELECT string_agg(rp.permiso, ',')
                          FROM rol_permisos rp
                         WHERE rp.rol_id = u.rol_id) AS "PermisosTexto",

                       -- DAPPER NO USA LOS VALORES POR DEFECTO del record.
                       --
                       -- Busca un constructor cuyos parámetros encajen con las
                       -- columnas devueltas. Si el record tiene trece
                       -- parámetros y la consulta trae doce columnas, no
                       -- encuentra ninguno y falla, aunque el que falta tenga
                       -- valor por defecto.
                       --
                       -- Por eso TODAS las consultas que devuelven un
                       -- UsuarioPanel tienen que traer las mismas columnas.
                       u.provisional_expira AS "ProvisionalExpira",
                       u.totp_obligatorio_desde AS "TotpObligatorioDesde"

                  FROM sesion_usada s
                  JOIN usuarios u ON u.id = s.usuario_id
                  JOIN roles r ON r.id = u.rol_id
                 WHERE u.activo
                """,
                new
                {
                    hash = HashToken(token),
                    duracion = $"{(int)DuracionSesion.TotalSeconds} seconds"
                },
                cancellationToken: ct));

        return usuario;
    }

    public async Task CerrarSesionAsync(string token, CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);

        await conexion.ExecuteAsync(new CommandDefinition(
            """
            UPDATE sesiones SET revocada_en = now()
             WHERE token_hash = @hash AND revocada_en IS NULL
            """,
            new { hash = HashToken(token) }, cancellationToken: ct));
    }

    /// <summary>Cierra TODAS las sesiones de un usuario.</summary>
    public async Task CerrarTodasAsync(Guid usuarioId, CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);

        await conexion.ExecuteAsync(new CommandDefinition(
            """
            UPDATE sesiones SET revocada_en = now()
             WHERE usuario_id = @usuarioId AND revocada_en IS NULL
            """,
            new { usuarioId }, cancellationToken: ct));
    }

    // -------------------------------------------------------------- usuarios

    public async Task<IReadOnlyList<UsuarioPanel>> ListarAsync(
        CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);

        var filas = await conexion.QueryAsync<UsuarioPanel>(
            new CommandDefinition(
                """
                -- EL ORDEN DE LAS COLUMNAS IMPORTA.
                --
                -- Dapper empareja los parámetros del constructor con las
                -- columnas POR POSICIÓN, no por nombre. Si el record declara
                -- PermisosTexto antes que ProvisionalExpira, la consulta debe
                -- devolverlas en ese mismo orden.
                --
                -- Cuando no coinciden, el error habla de constructores y no
                -- menciona el orden, así que cuesta encontrarlo.
                SELECT u.id             AS "Id",
                       u.correo         AS "Correo",
                       u.nombre         AS "Nombre",
                       u.rol_id         AS "RolId",
                       r.clave          AS "RolClave",
                       r.nombre         AS "RolNombre",
                       u.activo         AS "Activo",
                       u.debe_cambiar   AS "DebeCambiar",
                       u.ultimo_ingreso AS "UltimoIngreso",
                       u.creado_en      AS "CreadoEn",
                       u.totp_activo    AS "TotpActivo",

                       (SELECT string_agg(rp.permiso, ',')
                          FROM rol_permisos rp
                         WHERE rp.rol_id = u.rol_id) AS "PermisosTexto",

                       u.provisional_expira AS "ProvisionalExpira",
                       u.totp_obligatorio_desde AS "TotpObligatorioDesde"

                  FROM usuarios u
                  JOIN roles r ON r.id = u.rol_id
                 ORDER BY u.correo
                """,
                cancellationToken: ct));

        return filas.ToList();
    }

    /// <summary>
    /// Crea un usuario con contraseña provisional, que devuelve en claro.
    ///
    /// Se marca para que la cambie al ingresar: esa contraseña viaja por
    /// correo o por chat, así que no debe quedarse.
    /// </summary>
    public async Task<(Guid Id, string Provisional)> CrearAsync(
        string correo, string nombre, Guid rolId, CancellationToken ct = default)
    {
        var provisional = Contrasenas.GenerarProvisional();

        await using var conexion = await AbrirAsync(ct);

        var id = await conexion.ExecuteScalarAsync<Guid>(new CommandDefinition(
            """
            INSERT INTO usuarios
                (correo, nombre, contrasena_hash, rol_id,
                 debe_cambiar, provisional_expira, totp_obligatorio_desde)
            VALUES
                (@correo, @nombre, @hash, @rolId,
                 true, now() + @vigencia::interval, now())
            RETURNING id
            """,
            new
            {
                correo = correo.Trim(),
                nombre = nombre.Trim(),
                hash = Contrasenas.Cifrar(provisional),
                rolId,
                vigencia = $"{(int)VigenciaProvisional.TotalSeconds} seconds"
            },
            cancellationToken: ct));

        return (id, provisional);
    }

    /// <summary>Cambia la contraseña del propio usuario.</summary>
    public async Task<bool> CambiarContrasenaAsync(
        Guid usuarioId, string actual, string nueva, CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);

        var hash = await conexion.ExecuteScalarAsync<string?>(new CommandDefinition(
            "SELECT contrasena_hash FROM usuarios WHERE id = @usuarioId AND activo",
            new { usuarioId }, cancellationToken: ct));

        if (hash is null) return false;

        // Se exige la contraseña actual aunque la sesión esté abierta: si
        // alguien deja el equipo desbloqueado, no debe poder quedarse con la
        // cuenta cambiando la contraseña.
        if (!Contrasenas.Verificar(actual, hash, out _)) return false;

        await conexion.ExecuteAsync(new CommandDefinition(
            """
            UPDATE usuarios
               SET contrasena_hash = @nuevo,
                   debe_cambiar = false,
                   provisional_expira = NULL
             WHERE id = @usuarioId
            """,
            new { usuarioId, nuevo = Contrasenas.Cifrar(nueva) },
            cancellationToken: ct));

        return true;
    }

    /// <summary>Restablece la contraseña de otro usuario. Solo administradores.</summary>
    public async Task<string?> RestablecerAsync(
        Guid usuarioId, CancellationToken ct = default)
    {
        var provisional = Contrasenas.GenerarProvisional();

        await using var conexion = await AbrirAsync(ct);

        var filas = await conexion.ExecuteAsync(new CommandDefinition(
            """
            UPDATE usuarios
               SET contrasena_hash = @hash,
                   debe_cambiar = true,
                   provisional_expira = now() + @vigencia::interval,
                   intentos_fallidos = 0,
                   bloqueado_hasta = NULL
             WHERE id = @usuarioId
            """,
            new
            {
                usuarioId,
                hash = Contrasenas.Cifrar(provisional),
                vigencia = $"{(int)VigenciaProvisional.TotalSeconds} seconds"
            },
            cancellationToken: ct));

        if (filas == 0) return null;

        // Al restablecer se cierran sus sesiones: si la cuenta estaba
        // comprometida, dejar las sesiones abiertas haría inútil el cambio.
        await CerrarTodasAsync(usuarioId, ct);

        return provisional;
    }

    public async Task<bool> ActualizarAsync(
        Guid usuarioId, Guid? rolId, bool? activo, CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);

        var filas = await conexion.ExecuteAsync(new CommandDefinition(
            """
            UPDATE usuarios
               SET rol_id = COALESCE(@rolId, rol_id),
                   activo = COALESCE(@activo, activo)
             WHERE id = @usuarioId
            """,
            new { usuarioId, rolId, activo }, cancellationToken: ct));

        // Desactivar a alguien debe cortarle el acceso ya, no cuando caduque
        // su sesión doce horas después.
        if (filas > 0 && activo == false)
            await CerrarTodasAsync(usuarioId, ct);

        return filas > 0;
    }

    /// <summary>
    /// Cuántos usuarios activos pueden gestionar usuarios.
    ///
    /// SE CUENTA POR PERMISO, NO POR ROL. Con roles editables, "administrador"
    /// deja de ser el único que administra: mañana habrá un rol "Supervisor"
    /// que también puede. Lo que hay que garantizar es que quede alguien
    /// capaz de entrar y arreglar las cosas, sea cual sea su rol.
    /// </summary>
    public async Task<int> ContarAdministradoresAsync(CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);

        return await conexion.ExecuteScalarAsync<int>(new CommandDefinition(
            """
            SELECT count(DISTINCT u.id)::int
              FROM usuarios u
              JOIN rol_permisos rp ON rp.rol_id = u.rol_id
             WHERE u.activo AND rp.permiso = 'usuarios.gestionar'
            """,
            cancellationToken: ct));
    }

    // -------------------------------------------------------- segundo factor

    /// <summary>
    /// Empieza la activación: genera un secreto y lo devuelve sin guardarlo
    /// todavía como activo.
    ///
    /// POR QUÉ NO SE ACTIVA DE UNA VEZ: hay que comprobar antes que el
    /// usuario configuró bien su aplicación. Si se activara al generar el
    /// secreto y el escaneo hubiera fallado, quedaría fuera del sistema sin
    /// haber hecho nada mal.
    /// </summary>
    public async Task<(string Secreto, string Uri)> IniciarSegundoFactorAsync(
        Guid usuarioId, string correo, CancellationToken ct = default)
    {
        var secreto = Totp.GenerarSecreto();

        await using var conexion = await AbrirAsync(ct);

        await conexion.ExecuteAsync(new CommandDefinition(
            """
            UPDATE usuarios
               SET totp_secreto_cifrado = @cifrado, totp_activo = false
             WHERE id = @usuarioId
            """,
            new
            {
                usuarioId,
                cifrado = _protector.ProtegerTexto(secreto)
            },
            cancellationToken: ct));

        return (secreto, Totp.ArmarUri(secreto, correo, "Facturación electrónica"));
    }

    /// <summary>
    /// Confirma la activación comprobando un código, y devuelve los códigos
    /// de recuperación.
    /// </summary>
    public async Task<IReadOnlyList<string>?> ConfirmarSegundoFactorAsync(
        Guid usuarioId, string codigo, CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);

        var cifrado = await conexion.ExecuteScalarAsync<byte[]?>(
            new CommandDefinition(
                "SELECT totp_secreto_cifrado FROM usuarios WHERE id = @usuarioId",
                new { usuarioId }, cancellationToken: ct));

        if (cifrado is null || cifrado.Length == 0) return null;

        var secreto = _protector.DesprotegerTexto(cifrado);

        if (!Totp.Verificar(secreto, codigo, out var periodo)) return null;

        // Códigos de recuperación: ocho, de un solo uso.
        //
        // Sin ellos, perder el teléfono significaría quedarse fuera del
        // sistema para siempre, y en un panel de administración eso puede
        // significar no poder atender a un cliente el día que más falta hace.
        var codigos = Enumerable.Range(0, 8)
            .Select(_ => Contrasenas.GenerarProvisional())
            .ToList();

        await using var transaccion = await conexion.BeginTransactionAsync(ct);

        await conexion.ExecuteAsync(new CommandDefinition(
            """
            UPDATE usuarios
               SET totp_activo = true,
                   totp_ultimo_periodo = @periodo,
                   totp_obligatorio_desde = NULL
             WHERE id = @usuarioId
            """,
            new { usuarioId, periodo },
            transaccion, cancellationToken: ct));

        // Se borran los códigos anteriores: si alguien reactiva el segundo
        // factor, los viejos no deben seguir sirviendo.
        await conexion.ExecuteAsync(new CommandDefinition(
            "DELETE FROM codigos_recuperacion WHERE usuario_id = @usuarioId",
            new { usuarioId },
            transaccion, cancellationToken: ct));

        foreach (var c in codigos)
        {
            await conexion.ExecuteAsync(new CommandDefinition(
                """
                INSERT INTO codigos_recuperacion (usuario_id, codigo_hash)
                VALUES (@usuarioId, @hash)
                """,
                new { usuarioId, hash = HashToken(c) },
                transaccion, cancellationToken: ct));
        }

        await transaccion.CommitAsync(ct);

        return codigos;
    }

    /// <summary>Desactiva el segundo factor. Exige la contraseña actual.</summary>
    public async Task<bool> DesactivarSegundoFactorAsync(
        Guid usuarioId, string contrasena, CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);

        var hash = await conexion.ExecuteScalarAsync<string?>(new CommandDefinition(
            "SELECT contrasena_hash FROM usuarios WHERE id = @usuarioId AND activo",
            new { usuarioId }, cancellationToken: ct));

        if (hash is null || !Contrasenas.Verificar(contrasena, hash, out _))
            return false;

        await using var transaccion = await conexion.BeginTransactionAsync(ct);

        await conexion.ExecuteAsync(new CommandDefinition(
            """
            UPDATE usuarios
               SET totp_activo = false,
                   totp_secreto_cifrado = NULL,
                   totp_ultimo_periodo = NULL,
                   -- Se vuelve a exigir: desactivarlo no debe ser una forma
                   -- de librarse de él, solo de reconfigurarlo.
                   totp_obligatorio_desde = now()
             WHERE id = @usuarioId
            """,
            new { usuarioId }, transaccion, cancellationToken: ct));

        await conexion.ExecuteAsync(new CommandDefinition(
            "DELETE FROM codigos_recuperacion WHERE usuario_id = @usuarioId",
            new { usuarioId }, transaccion, cancellationToken: ct));

        await transaccion.CommitAsync(ct);

        return true;
    }

    /// <summary>Cuántos códigos de recuperación quedan sin usar.</summary>
    public async Task<int> CodigosRestantesAsync(
        Guid usuarioId, CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);

        return await conexion.ExecuteScalarAsync<int>(new CommandDefinition(
            """
            SELECT count(*)::int FROM codigos_recuperacion
             WHERE usuario_id = @usuarioId AND usado_en IS NULL
            """,
            new { usuarioId }, cancellationToken: ct));
    }

    private static async Task<bool> ConsumirCodigoRecuperacionAsync(
        NpgsqlConnection conexion, Guid usuarioId, string codigo,
        CancellationToken ct)
    {
        var limpio = codigo.Trim().ToLowerInvariant();

        // Marcar y comprobar en una sola sentencia: entre leer y marcar
        // habría una ventana en la que el mismo código serviría dos veces.
        var filas = await conexion.ExecuteAsync(new CommandDefinition(
            """
            UPDATE codigos_recuperacion
               SET usado_en = now()
             WHERE usuario_id = @usuarioId
               AND codigo_hash = @hash
               AND usado_en IS NULL
            """,
            new { usuarioId, hash = HashToken(limpio) }, cancellationToken: ct));

        return filas > 0;
    }

    private sealed record FilaTotp(
        Guid Id, string Correo, string Nombre,
        Guid RolId, string RolClave, string RolNombre, bool Activo,
        bool DebeCambiar, DateTime? UltimoIngreso, DateTime CreadoEn,
        byte[]? SecretoCifrado, long? UltimoPeriodo, string? PermisosTexto);

    // --------------------------------------------------------- recuperación

    /// <summary>
    /// Crea un enlace de recuperación y devuelve el token, o null si el
    /// correo no corresponde a ninguna cuenta activa.
    ///
    /// QUIEN LLAME NO DEBE REVELAR ESA DIFERENCIA. La respuesta al usuario
    /// tiene que ser la misma exista o no la cuenta: si fuera distinta,
    /// cualquiera podría averiguar qué correos están registrados probando
    /// uno por uno, y esa lista es el primer paso de cualquier intento serio.
    /// </summary>
    public async Task<(string Token, string Correo, string Nombre)?>
        CrearRecuperacionAsync(
            string correo, string? direccionIp, CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);

        var usuario = await conexion.QuerySingleOrDefaultAsync<FilaRecuperacion>(
            new CommandDefinition(
                """
                SELECT id AS "Id", correo AS "Correo", nombre AS "Nombre"
                  FROM usuarios
                 WHERE correo = @correo AND activo
                """,
                new { correo = correo.Trim() }, cancellationToken: ct));

        if (usuario is null) return null;

        // Se anulan las recuperaciones anteriores del mismo usuario.
        //
        // Si alguien pide el enlace tres veces, solo el último debe servir.
        // Dejar varios vivos multiplica las oportunidades de que uno se filtre.
        await conexion.ExecuteAsync(new CommandDefinition(
            """
            UPDATE recuperaciones SET usado_en = now()
             WHERE usuario_id = @usuarioId AND usado_en IS NULL
            """,
            new { usuarioId = usuario.Id }, cancellationToken: ct));

        var token = GenerarToken();

        await conexion.ExecuteAsync(new CommandDefinition(
            """
            INSERT INTO recuperaciones
                (usuario_id, token_hash, expira_en, solicitado_desde)
            VALUES
                (@usuarioId, @hash, now() + interval '1 hour', @ip::inet)
            """,
            new
            {
                usuarioId = usuario.Id,
                hash = HashToken(token),
                ip = direccionIp
            },
            cancellationToken: ct));

        return (token, usuario.Correo, usuario.Nombre);
    }

    /// <summary>
    /// Cambia la contraseña usando un enlace de recuperación.
    /// </summary>
    public async Task<(bool Exitoso, string? Correo, string? Nombre, string? Motivo)>
        RestablecerConTokenAsync(
            string token, string nueva, CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);

        var fila = await conexion.QuerySingleOrDefaultAsync<FilaTokenRecuperacion>(
            new CommandDefinition(
                """
                SELECT r.id         AS "RecuperacionId",
                       u.id         AS "UsuarioId",
                       u.correo     AS "Correo",
                       u.nombre     AS "Nombre",
                       r.expira_en  AS "ExpiraEn",
                       r.usado_en   AS "UsadoEn"
                  FROM recuperaciones r
                  JOIN usuarios u ON u.id = r.usuario_id
                 WHERE r.token_hash = @hash AND u.activo
                """,
                new { hash = HashToken(token) }, cancellationToken: ct));

        if (fila is null)
            return (false, null, null,
                "El enlace no es válido. Pide uno nuevo.");

        if (fila.UsadoEn is not null)
            return (false, null, null,
                "Ese enlace ya se usó. Pide uno nuevo.");

        if (fila.ExpiraEn < DateTime.UtcNow)
            return (false, null, null,
                "El enlace caducó. Los enlaces duran una hora; pide uno nuevo.");

        await using var transaccion = await conexion.BeginTransactionAsync(ct);

        await conexion.ExecuteAsync(new CommandDefinition(
            """
            UPDATE usuarios
               SET contrasena_hash = @hash,
                   debe_cambiar = false,
                   provisional_expira = NULL,
                   intentos_fallidos = 0,
                   bloqueado_hasta = NULL
             WHERE id = @usuarioId
            """,
            new { usuarioId = fila.UsuarioId, hash = Contrasenas.Cifrar(nueva) },
            transaccion, cancellationToken: ct));

        await conexion.ExecuteAsync(new CommandDefinition(
            "UPDATE recuperaciones SET usado_en = now() WHERE id = @id",
            new { id = fila.RecuperacionId },
            transaccion, cancellationToken: ct));

        // Se cierran todas sus sesiones.
        //
        // Quien recupera una contraseña suele hacerlo porque sospecha que
        // alguien entró. Dejar las sesiones abiertas haría inútil el cambio.
        await conexion.ExecuteAsync(new CommandDefinition(
            """
            UPDATE sesiones SET revocada_en = now()
             WHERE usuario_id = @usuarioId AND revocada_en IS NULL
            """,
            new { usuarioId = fila.UsuarioId },
            transaccion, cancellationToken: ct));

        await transaccion.CommitAsync(ct);

        return (true, fila.Correo, fila.Nombre, null);
    }

    private sealed record FilaRecuperacion(Guid Id, string Correo, string Nombre);

    private sealed record FilaTokenRecuperacion(
        Guid RecuperacionId, Guid UsuarioId, string Correo, string Nombre,
        DateTime ExpiraEn, DateTime? UsadoEn);

    // ------------------------------------------------------------- auditoría

    public async Task RegistrarAccionAsync(
        Guid? usuarioId, string correo, string accion, string ruta,
        Guid? tenantId, int codigoRespuesta,
        string? direccionIp, string? agente,
        CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);

        await conexion.ExecuteAsync(new CommandDefinition(
            """
            INSERT INTO auditoria
                (usuario_id, correo, accion, ruta, tenant_id,
                 codigo_respuesta, direccion_ip, agente)
            VALUES
                (@usuarioId, @correo, @accion, @ruta, @tenantId,
                 @codigoRespuesta, @ip::inet, @agente)
            """,
            new
            {
                usuarioId,
                correo,

                // Se recorta por si acaso. La columna admite 30 caracteres y
                // ninguna acción actual llega, pero registrar una acción NO
                // debe poder tumbar la operación que la originó: ya pasó una
                // vez, con RESTABLECER y una columna de diez.
                accion = accion.Length > 30 ? accion[..30] : accion,

                ruta = ruta.Length > 500 ? ruta[..500] : ruta,
                tenantId, codigoRespuesta,
                ip = direccionIp,
                agente = agente?.Length > 400 ? agente[..400] : agente
            },
            cancellationToken: ct));
    }

    public async Task<IReadOnlyList<AccionAuditada>> AuditoriaAsync(
        int limite = 100, CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);

        var filas = await conexion.QueryAsync<AccionAuditada>(
            new CommandDefinition(
                """
                SELECT id               AS "Id",
                       correo           AS "Correo",
                       accion           AS "Accion",
                       ruta             AS "Ruta",
                       tenant_id        AS "TenantId",
                       codigo_respuesta AS "CodigoRespuesta",
                       host(direccion_ip) AS "DireccionIp",
                       creado_en        AS "CreadoEn"
                  FROM auditoria
                 ORDER BY creado_en DESC
                 LIMIT @limite
                """,
                new { limite }, cancellationToken: ct));

        return filas.ToList();
    }

    // ------------------------------------------------------------- arranque

    /// <summary>
    /// Crea el primer administrador si no hay ninguno.
    ///
    /// POR QUÉ HACE FALTA: sin usuarios no se puede entrar al panel, y sin
    /// entrar al panel no se pueden crear usuarios. Alguien tiene que romper
    /// ese círculo.
    ///
    /// Se toma de variables de entorno y solo actúa la primera vez.
    /// </summary>
    public async Task<string?> AsegurarPrimerAdministradorAsync(
        string correo, string? contrasena, CancellationToken ct = default)
    {
        if (await ContarAdministradoresAsync(ct) > 0) return null;

        var clave = string.IsNullOrWhiteSpace(contrasena)
            ? Contrasenas.GenerarProvisional()
            : contrasena;

        await using var conexion = await AbrirAsync(ct);

        await conexion.ExecuteAsync(new CommandDefinition(
            """
            INSERT INTO usuarios (correo, nombre, contrasena_hash, rol_id, debe_cambiar)
            SELECT @correo, 'Administrador', @hash, r.id, @debeCambiar
              FROM roles r WHERE r.clave = 'administrador'
            ON CONFLICT (correo) DO UPDATE
               SET rol_id = (SELECT id FROM roles WHERE clave = 'administrador'),
                   activo = true
            """,
            new
            {
                correo = correo.Trim(),
                hash = Contrasenas.Cifrar(clave),
                // Si la contraseña se generó sola, hay que cambiarla; si la
                // puso el operador en su .env, ya es suya.
                debeCambiar = string.IsNullOrWhiteSpace(contrasena)
            },
            cancellationToken: ct));

        return string.IsNullOrWhiteSpace(contrasena) ? clave : null;
    }

    // ----------------------------------------------------------------- apoyo

    private static string GenerarToken() =>
        Convert.ToBase64String(RandomNumberGenerator.GetBytes(32))
            .Replace("+", "-").Replace("/", "_").Replace("=", "");

    private static string HashToken(string token) =>
        Convert.ToHexString(
            SHA256.HashData(Encoding.UTF8.GetBytes(token))).ToLowerInvariant();

    /// <summary>
    /// Fila de la consulta de ingreso.
    ///
    /// ES UNA CLASE, NO UN record struct, y eso importa.
    ///
    /// Dapper no materializa bien un struct envuelto en Nullable: devuelve
    /// null aunque la fila exista, sin lanzar ningún error. El síntoma era
    /// desconcertante: el ingreso fallaba con "correo o contraseña
    /// incorrectos" y el contador de intentos fallidos se quedaba en cero,
    /// porque el código creía que el usuario no existía.
    ///
    /// Es el mismo tipo de problema que con count(*) devolviendo bigint y
    /// con las columnas date: un desajuste entre lo que entrega el driver y
    /// lo que declara el tipo. La diferencia es que este no da error, y por
    /// eso cuesta más encontrarlo.
    /// </summary>
    private sealed record FilaIngreso(
        Guid Id, string Correo, string Nombre, string Hash,
        Guid RolId, string RolClave, string RolNombre,
        bool Activo, bool DebeCambiar, DateTime? UltimoIngreso,
        short IntentosFallidos, DateTime? BloqueadoHasta, DateTime CreadoEn,
        bool TotpActivo, DateTime? ProvisionalExpira, string? PermisosTexto);
}
