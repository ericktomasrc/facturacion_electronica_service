using Facturacion.Persistencia;

namespace Facturacion.Api;

/// <summary>
/// Ingreso, salida, gestión de usuarios y bitácora del panel.
/// </summary>
public static class EndpointsSesion
{
    public static void MapearSesion(this WebApplication app)
    {
        // --- Ingreso y salida: sin autenticación previa, por razones obvias ---

        app.MapPost("/admin/sesion", async (
            Credenciales credenciales,
            HttpContext http,
            RepositorioUsuarios usuarios,
            CancellationToken ct) =>
        {
            var resultado = await usuarios.IngresarAsync(
                credenciales.Correo,
                credenciales.Contrasena,
                http.Connection.RemoteIpAddress?.ToString(),
                http.Request.Headers.UserAgent.ToString(),
                ct);

            // La contraseña era correcta pero falta el código del
            // autenticador. Se devuelve un identificador parcial, no una
            // sesión: todavía no está autenticado.
            if (resultado.FaltaSegundoFactor)
            {
                return Results.Ok(new
                {
                    segundoFactor = true,
                    tokenParcial = resultado.TokenParcial,
                    mensaje = "Escribe el código de tu aplicación autenticadora."
                });
            }

            if (!resultado.Exitoso)
            {
                // El ingreso fallido se registra aunque no haya usuario: es
                // justo lo que hay que poder mirar tras un incidente.
                await usuarios.RegistrarAccionAsync(
                    null, credenciales.Correo, "LOGIN", "/admin/sesion",
                    null, StatusCodes.Status401Unauthorized,
                    http.Connection.RemoteIpAddress?.ToString(),
                    http.Request.Headers.UserAgent.ToString(), ct);

                return Results.Json(
                    new RespuestaError(resultado.Motivo!),
                    statusCode: StatusCodes.Status401Unauthorized);
            }

            // LA COOKIE ES HttpOnly A PROPÓSITO.
            //
            // Así el JavaScript de la página no puede leerla. Si algún día se
            // cuela un script malicioso —en una dependencia, en un campo de
            // texto mal escapado— no podrá robar la sesión.
            //
            // SameSite=Strict impide que otro sitio provoque peticiones
            // autenticadas desde el navegador del operador.
            http.Response.Cookies.Append(
                AutenticacionPanel.Cookie,
                resultado.Token!,
                new CookieOptions
                {
                    HttpOnly = true,
                    Secure = http.Request.IsHttps,
                    SameSite = SameSiteMode.Strict,
                    Expires = DateTimeOffset.UtcNow.Add(RepositorioUsuarios.DuracionSesion),
                    Path = "/"
                });

            await usuarios.RegistrarAccionAsync(
                resultado.Usuario!.Id, resultado.Usuario.Correo,
                "LOGIN", "/admin/sesion", null, StatusCodes.Status200OK,
                http.Connection.RemoteIpAddress?.ToString(),
                http.Request.Headers.UserAgent.ToString(), ct);

            return Results.Ok(new
            {
                correo = resultado.Usuario.Correo,
                nombre = resultado.Usuario.Nombre,
                rol = resultado.Usuario.RolNombre,
                debeCambiar = resultado.Usuario.DebeCambiar,

                // Si hay que configurar el segundo factor, el panel lo lleva
                // a hacerlo antes de dejarle nada más.
                debeConfigurarTotp = resultado.Usuario.DebeConfigurarTotp
            });
        })
        .WithTags("Sesión")
        .WithSummary("Inicia sesión en el panel")
        .WithDescription(
            "Si el usuario tiene segundo factor, responde con " +
            "segundoFactor=true y un identificador parcial que hay que " +
            "enviar a /admin/sesion/codigo junto con el código.");

        app.MapPost("/admin/sesion/codigo", async (
            SegundoFactor datos,
            HttpContext http,
            RepositorioUsuarios usuarios,
            CancellationToken ct) =>
        {
            var resultado = await usuarios.CompletarIngresoAsync(
                datos.TokenParcial,
                datos.Codigo,
                http.Connection.RemoteIpAddress?.ToString(),
                http.Request.Headers.UserAgent.ToString(),
                ct);

            if (!resultado.Exitoso)
            {
                await usuarios.RegistrarAccionAsync(
                    null, "(segundo factor)", "LOGIN_2FA", "/admin/sesion/codigo",
                    null, StatusCodes.Status401Unauthorized,
                    http.Connection.RemoteIpAddress?.ToString(),
                    http.Request.Headers.UserAgent.ToString(), ct);

                return Results.Json(
                    new RespuestaError(resultado.Motivo!),
                    statusCode: StatusCodes.Status401Unauthorized);
            }

            http.Response.Cookies.Append(
                AutenticacionPanel.Cookie,
                resultado.Token!,
                new CookieOptions
                {
                    HttpOnly = true,
                    Secure = http.Request.IsHttps,
                    SameSite = SameSiteMode.Strict,
                    Expires = DateTimeOffset.UtcNow.Add(RepositorioUsuarios.DuracionSesion),
                    Path = "/"
                });

            await usuarios.RegistrarAccionAsync(
                resultado.Usuario!.Id, resultado.Usuario.Correo,
                "LOGIN_2FA", "/admin/sesion/codigo", null, StatusCodes.Status200OK,
                http.Connection.RemoteIpAddress?.ToString(),
                http.Request.Headers.UserAgent.ToString(), ct);

            return Results.Ok(new
            {
                correo = resultado.Usuario.Correo,
                nombre = resultado.Usuario.Nombre,
                rol = resultado.Usuario.RolNombre,
                debeCambiar = resultado.Usuario.DebeCambiar,
                debeConfigurarTotp = false
            });
        })
        .WithTags("Sesión")
        .WithSummary("Completa el ingreso con el código del segundo factor")
        .WithDescription(
            "Acepta tanto un código del autenticador como uno de " +
            "recuperación. Los de recuperación son de un solo uso.");

        app.MapDelete("/admin/sesion", async (
            HttpContext http, RepositorioUsuarios usuarios, CancellationToken ct) =>
        {
            var token = http.Request.Cookies[AutenticacionPanel.Cookie];

            if (!string.IsNullOrWhiteSpace(token))
                await usuarios.CerrarSesionAsync(token, ct);

            http.Response.Cookies.Delete(AutenticacionPanel.Cookie);

            return Results.Ok(new { mensaje = "Sesión cerrada." });
        })
        .WithTags("Sesión")
        .WithSummary("Cierra la sesión");

        // --- Recuperación de contraseña: sin sesión, por definición ---

        app.MapPost("/admin/sesion/recuperar", async (
            SolicitudRecuperacion datos,
            HttpContext http,
            RepositorioUsuarios usuarios,
            ServicioCorreo correo,
            CancellationToken ct) =>
        {
            var resultado = await usuarios.CrearRecuperacionAsync(
                datos.Correo,
                http.Connection.RemoteIpAddress?.ToString(),
                ct);

            if (resultado is not null)
            {
                // El envío NO se espera. Si el servidor de correo tarda tres
                // segundos, el usuario no tiene por qué esperarlos, y el
                // resultado es el mismo para él.
                _ = correo.EnviarRecuperacionAsync(
                    resultado.Value.Correo,
                    resultado.Value.Nombre,
                    resultado.Value.Token);

                await usuarios.RegistrarAccionAsync(
                    null, datos.Correo, "RECUPERAR", "/admin/sesion/recuperar",
                    null, StatusCodes.Status200OK,
                    http.Connection.RemoteIpAddress?.ToString(),
                    http.Request.Headers.UserAgent.ToString(), ct);
            }

            // LA RESPUESTA ES LA MISMA EXISTA O NO LA CUENTA.
            //
            // Si dijéramos "ese correo no está registrado", cualquiera podría
            // averiguar qué correos tienen cuenta probando uno por uno. Esa
            // lista es el primer paso de cualquier intento serio.
            return Results.Ok(new
            {
                mensaje =
                    "Si ese correo tiene una cuenta activa, le llegará un " +
                    "enlace en unos minutos. Revisa también la carpeta de " +
                    "correo no deseado."
            });
        })
        .WithTags("Sesión")
        .WithSummary("Pide un enlace para restablecer la contraseña");

        app.MapPost("/admin/sesion/restablecer", async (
            RestablecerContrasena datos,
            HttpContext http,
            RepositorioUsuarios usuarios,
            ServicioCorreo correo,
            CancellationToken ct) =>
        {
            var problema = Contrasenas.Revisar(datos.Nueva);

            if (problema is not null)
                return Results.BadRequest(new RespuestaError(
                    "La contraseña no sirve.", problema));

            var (exitoso, correoUsuario, nombre, motivo) =
                await usuarios.RestablecerConTokenAsync(datos.Token, datos.Nueva, ct);

            if (!exitoso)
                return Results.BadRequest(new RespuestaError(
                    "No se pudo restablecer.", motivo));

            // Se avisa al dueño de la cuenta. Si el cambio no fue cosa suya,
            // este correo es lo único que lo alerta.
            _ = correo.EnviarAvisoContrasenaCambiadaAsync(correoUsuario!, nombre!);

            // LA BITÁCORA NO DEBE TUMBAR LA OPERACIÓN QUE REGISTRA.
            //
            // Aquí la contraseña YA se cambió y el correo YA salió. Si el
            // registro falla y la excepción sube, el usuario ve un error y
            // cree que no funcionó, cuando sí funcionó. Eso es exactamente
            // lo que ocurrió con una columna demasiado corta.
            try
            {
                await usuarios.RegistrarAccionAsync(
                    null, correoUsuario!, "RESTABLECER", "/admin/sesion/restablecer",
                    null, StatusCodes.Status200OK,
                    http.Connection.RemoteIpAddress?.ToString(),
                    http.Request.Headers.UserAgent.ToString(), ct);
            }
            catch (Exception) { /* queda en el log del proceso */ }

            return Results.Ok(new
            {
                mensaje =
                    "Contraseña cambiada. Se cerraron todas tus sesiones " +
                    "abiertas: entra de nuevo."
            });
        })
        .WithTags("Sesión")
        .WithSummary("Cambia la contraseña con el enlace recibido")
        .WithDescription(
            "Cierra todas las sesiones del usuario. Quien recupera una " +
            "contraseña suele hacerlo porque sospecha que alguien entró.");

        // --- Todo lo demás exige sesión ---

        var grupo = app.MapGroup("/admin")
            .AddEndpointFilter<AutenticacionPanel>()
            .WithTags("Sesión");

        grupo.MapGet("/yo", (ContextoOperador operador) =>
        {
            var u = operador.Exigir();

            return Results.Ok(new
            {
                correo = u.Correo,
                nombre = u.Nombre,
                rol = u.RolNombre,
                rolClave = u.RolClave,

                // El panel usa esta lista para mostrar solo las pestañas y
                // botones que el usuario puede usar.
                //
                // OCULTAR NO ES PROTEGER: el servidor comprueba el permiso en
                // cada petición. Esto solo evita que alguien vea opciones que
                // le darían un error al pulsarlas.
                permisos = u.Permisos,

                esAdministrador = u.EsAdministrador,
                debeCambiar = u.DebeCambiar,
                segundoFactorActivo = u.TotpActivo,
                debeConfigurarTotp = u.DebeConfigurarTotp,
                ultimoIngreso = u.UltimoIngreso
            });
        })
        .WithSummary("Datos del usuario en sesión");

        // ------------------------------------------------------ segundo factor

        grupo.MapPost("/yo/2fa/iniciar", async (
            ContextoOperador operador,
            RepositorioUsuarios usuarios,
            CancellationToken ct) =>
        {
            var u = operador.Exigir();

            var (secreto, uri) = await usuarios.IniciarSegundoFactorAsync(
                u.Id, u.Correo, ct);

            // El QR se genera aquí y viaja como imagen embebida: así el
            // secreto no pasa por ningún servicio externo de generación de
            // códigos, que es como se filtran estas cosas.
            var png = Facturacion.Pdf.CodigoQr.GenerarPng(uri, 6);

            return Results.Ok(new
            {
                secreto,
                qr = "data:image/png;base64," + Convert.ToBase64String(png),
                instrucciones =
                    "Escanea el código con Google Authenticator, Authy o " +
                    "cualquier aplicación parecida. Si no puedes escanear, " +
                    "escribe el secreto a mano. Después confirma con el " +
                    "código de seis dígitos que muestre.",
                aviso =
                    "El segundo factor NO se activa hasta que confirmes con " +
                    "un código. Así, si el escaneo falla, no te quedas fuera."
            });
        })
        .WithSummary("Empieza a activar el segundo factor");

        grupo.MapPost("/yo/2fa/confirmar", async (
            CodigoVerificacion datos,
            ContextoOperador operador,
            RepositorioUsuarios usuarios,
            CancellationToken ct) =>
        {
            var u = operador.Exigir();

            var codigos = await usuarios.ConfirmarSegundoFactorAsync(
                u.Id, datos.Codigo, ct);

            if (codigos is null)
                return Results.BadRequest(new RespuestaError(
                    "El código no es correcto.",
                    "Comprueba que la hora de tu teléfono esté bien: si va " +
                    "desfasada más de un minuto, los códigos no coinciden."));

            return Results.Ok(new
            {
                mensaje = "Segundo factor activado.",
                codigosRecuperacion = codigos,
                aviso =
                    "Guarda estos códigos en un lugar seguro. Cada uno sirve " +
                    "una sola vez y son la única forma de entrar si pierdes " +
                    "el teléfono. No se vuelven a mostrar."
            });
        })
        .WithSummary("Confirma y activa el segundo factor")
        .WithDescription("Devuelve los códigos de recuperación una sola vez.");

        grupo.MapPost("/yo/2fa/desactivar", async (
            ConfirmarContrasena datos,
            ContextoOperador operador,
            RepositorioUsuarios usuarios,
            CancellationToken ct) =>
        {
            var u = operador.Exigir();

            var desactivado = await usuarios.DesactivarSegundoFactorAsync(
                u.Id, datos.Contrasena, ct);

            return desactivado
                ? Results.Ok(new { mensaje = "Segundo factor desactivado." })
                : Results.BadRequest(new RespuestaError(
                    "La contraseña no es correcta.",
                    "Se pide para que nadie pueda quitarte la protección " +
                    "aprovechando un equipo desbloqueado."));
        })
        .WithSummary("Desactiva el segundo factor");

        grupo.MapGet("/yo/2fa/codigos", async (
            ContextoOperador operador,
            RepositorioUsuarios usuarios,
            CancellationToken ct) =>
        {
            var u = operador.Exigir();

            return Results.Ok(new
            {
                activo = u.TotpActivo,
                restantes = await usuarios.CodigosRestantesAsync(u.Id, ct)
            });
        })
        .WithSummary("Cuántos códigos de recuperación quedan");

        grupo.MapPost("/yo/contrasena", async (
            CambioContrasena cambio,
            ContextoOperador operador,
            RepositorioUsuarios usuarios,
            ServicioCorreo correo,
            CancellationToken ct) =>
        {
            var problema = Contrasenas.Revisar(cambio.Nueva);

            if (problema is not null)
                return Results.BadRequest(new RespuestaError(
                    "La contraseña no sirve.", problema));

            var u = operador.Exigir();

            var cambiada = await usuarios.CambiarContrasenaAsync(
                u.Id, cambio.Actual, cambio.Nueva, ct);

            if (cambiada)
                _ = correo.EnviarAvisoContrasenaCambiadaAsync(u.Correo, u.Nombre);

            return cambiada
                ? Results.Ok(new
                {
                    mensaje = "Contraseña cambiada.",
                    debeConfigurarTotp = u.DebeConfigurarTotp
                })
                : Results.BadRequest(new RespuestaError(
                    "La contraseña actual no es correcta.",
                    "Se pide aunque tengas la sesión abierta: si alguien " +
                    "encontrara tu equipo desbloqueado, no debería poder " +
                    "quedarse con la cuenta."));
        })
        .WithSummary("Cambia tu propia contraseña");

        // --- Gestión de usuarios: solo administradores ---

        var admin = app.MapGroup("/admin/usuarios")
            .AddEndpointFilter<AutenticacionPanel>()
            .AddEndpointFilter(new ExigirPermiso(Permiso.UsuariosGestionar))
            .WithTags("Usuarios del panel");

        admin.MapGet("", async (RepositorioUsuarios usuarios, CancellationToken ct) =>
            Results.Ok(await usuarios.ListarAsync(ct)))
            .WithSummary("Lista los usuarios del panel");

        admin.MapPost("", async (
            NuevoUsuario nuevo, RepositorioUsuarios usuarios,
            ServicioCorreo correo, CancellationToken ct) =>
        {
            if (!nuevo.Correo.Contains('@'))
                return Results.BadRequest(new RespuestaError("El correo no es válido."));

            try
            {
                var (id, provisional) = await usuarios.CrearAsync(
                    nuevo.Correo, nuevo.Nombre, nuevo.RolId, ct);

                var enviado = correo.Disponible;

                if (enviado)
                    _ = correo.EnviarBienvenidaAsync(
                        nuevo.Correo, nuevo.Nombre, provisional,
                        (int)RepositorioUsuarios.VigenciaProvisional.TotalHours);

                return Results.Ok(new
                {
                    id,
                    contrasenaProvisional = provisional,
                    correoEnviado = enviado,
                    horasVigencia = (int)RepositorioUsuarios.VigenciaProvisional.TotalHours,
                    aviso = enviado
                        ? $"Se le envió un correo con la contraseña provisional. " +
                          $"Caduca en {(int)RepositorioUsuarios.VigenciaProvisional.TotalHours} " +
                          "horas. Aquí la tienes también por si no le llega."
                        : $"El correo no está configurado, así que hay que " +
                          "entregársela a mano por un canal seguro. Caduca en " +
                          $"{(int)RepositorioUsuarios.VigenciaProvisional.TotalHours} horas " +
                          "y tendrá que cambiarla en su primer ingreso."
                });
            }
            catch (Npgsql.PostgresException ex) when (ex.SqlState == "23505")
            {
                return Results.Conflict(new RespuestaError(
                    "Ese correo ya está registrado."));
            }
            catch (Npgsql.PostgresException ex) when (ex.SqlState == "23503")
            {
                // Violación de clave foránea: el rol no existe.
                return Results.BadRequest(new RespuestaError(
                    "El rol indicado no existe."));
            }
        })
        .WithSummary("Crea un usuario")
        .WithDescription(
            "Devuelve una contraseña provisional que el usuario deberá " +
            "cambiar al entrar.");

        admin.MapPatch("/{id:guid}", async (
            Guid id, ActualizacionUsuario cambios,
            ContextoOperador operador, RepositorioUsuarios usuarios,
            CancellationToken ct) =>
        {
            var actual = operador.Exigir();

            // NO PUEDES DESACTIVARTE NI QUITARTE PERMISOS A TI MISMO.
            //
            // Es fácil de hacer por descuido y deja el panel sin quien lo
            // administre. Que otro lo haga, si de verdad toca.
            if (id == actual.Id && cambios.Activo == false)
                return Results.BadRequest(new RespuestaError(
                    "No puedes desactivar tu propia cuenta.",
                    "Pídeselo a otro administrador."));

            // Y tampoco se puede dejar el sistema sin nadie capaz de
            // administrarlo.
            //
            // SE COMPRUEBA POR PERMISO, NO POR ROL: lo que importa no es que
            // quede alguien llamado "administrador", sino que quede alguien
            // que pueda entrar y arreglar las cosas.
            var lista = await usuarios.ListarAsync(ct);
            var objetivo = lista.FirstOrDefault(u => u.Id == id);

            if (objetivo is not null &&
                objetivo.Activo &&
                objetivo.Puede(Permiso.UsuariosGestionar))
            {
                var pierdeElPermiso =
                    cambios.Activo == false ||
                    (cambios.RolId is not null && cambios.RolId != objetivo.RolId);

                if (pierdeElPermiso &&
                    await usuarios.ContarAdministradoresAsync(ct) <= 1)
                {
                    return Results.BadRequest(new RespuestaError(
                        "Es el único usuario que puede gestionar el panel.",
                        "Dejarlo sin nadie capaz de administrarlo lo haría " +
                        "irrecuperable: nadie podría crear usuarios ni " +
                        "reasignar roles. Crea antes otro con ese permiso."));
                }
            }

            var actualizado = await usuarios.ActualizarAsync(
                id, cambios.RolId, cambios.Activo, ct);

            return actualizado
                ? Results.Ok(new { mensaje = "Usuario actualizado." })
                : Results.NotFound(new RespuestaError("No se encontró el usuario."));
        })
        .WithSummary("Cambia el rol o desactiva un usuario");

        admin.MapPost("/{id:guid}/restablecer", async (
            Guid id, RepositorioUsuarios usuarios, CancellationToken ct) =>
        {
            var provisional = await usuarios.RestablecerAsync(id, ct);

            return provisional is null
                ? Results.NotFound(new RespuestaError("No se encontró el usuario."))
                : Results.Ok(new
                {
                    contrasenaProvisional = provisional,
                    aviso =
                        "Se cerraron todas sus sesiones. Caduca en " +
                        $"{(int)RepositorioUsuarios.VigenciaProvisional.TotalHours} " +
                        "horas y tendrá que cambiarla al entrar."
                });
        })
        .WithSummary("Restablece la contraseña de un usuario")
        .WithDescription(
            "Cierra todas sus sesiones abiertas: si la cuenta estaba " +
            "comprometida, dejarlas vivas haría inútil el cambio.");

        // --- Bitácora ---

        app.MapGet("/admin/auditoria", async (
            RepositorioUsuarios usuarios, int? limite, CancellationToken ct) =>
            Results.Ok(await usuarios.AuditoriaAsync(
                Math.Clamp(limite ?? 100, 1, 500), ct)))
            .AddEndpointFilter<AutenticacionPanel>()
            .AddEndpointFilter(new ExigirPermiso(Permiso.AuditoriaVer))
            .WithTags("Usuarios del panel")
            .WithSummary("Bitácora de acciones del panel")
            .WithDescription(
                "Quién hizo qué, cuándo y desde dónde. Es append-only: no se " +
                "puede editar ni borrar, porque una bitácora que el propio " +
                "responsable puede alterar no sirve como bitácora.");
    }
}

public record Credenciales(string Correo, string Contrasena);
public record SolicitudRecuperacion(string Correo);
public record RestablecerContrasena(string Token, string Nueva);
public record SegundoFactor(string TokenParcial, string Codigo);
public record CodigoVerificacion(string Codigo);
public record ConfirmarContrasena(string Contrasena);
public record CambioContrasena(string Actual, string Nueva);
public record NuevoUsuario(string Correo, string Nombre, Guid RolId);
public record ActualizacionUsuario(Guid? RolId, bool? Activo);
