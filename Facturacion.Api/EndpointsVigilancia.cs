using System.Text.RegularExpressions;
using Facturacion.Persistencia;

namespace Facturacion.Api;

/// <summary>Lo que manda el panel al marcar un código como revisado.</summary>
public record PeticionRevisado(string? Codigo, string? Clase, string? Nota);

/// <summary>Lo que manda el panel al agregar un correo para alertas.</summary>
public record PeticionCorreoAlerta(string? Correo);

/// <summary>
/// La pestaña «Vigilancia SUNAT» del panel (migración 029).
///
/// Ver y revisar códigos: quien ve el estado del servicio (diagnostico.ver),
/// que es soporte. Tocar la lista de correos y mandar la prueba: solo quien
/// administra usuarios, porque decide a quién le llegan avisos.
///
/// Todo lo que no es GET queda en la bitácora del panel (AuditoriaPanel).
/// </summary>
public static class EndpointsVigilancia
{
    private static readonly Regex FormaCorreo =
        new(@"^[^@\s]+@[^@\s]+\.[^@\s]+$", RegexOptions.Compiled);

    public static void MapearVigilancia(this WebApplication app)
    {
        var grupo = app.MapGroup("/admin/vigilancia")
            .AddEndpointFilter<AutenticacionPanel>()
            .WithTags("Vigilancia SUNAT");

        grupo.MapGet("", async (
            RepositorioVigilancia repo, CancellationToken ct) =>
        {
            var estado = await repo.EstadoAsync(ct);
            var codigos = await repo.ListarCodigosAsync(ct);

            return Results.Ok(new
            {
                inicializadoEn = estado.InicializadoEn,
                ultimaRevisionEn = estado.UltimaRevisionEn,
                codigos = codigos.Select(c => new
                {
                    c.Codigo, c.Clase, c.PrimeraVez, c.UltimaVez, c.Veces, c.Empresas,
                    c.EjemploMensaje, c.EjemploEmpresa, c.EjemploRuc, c.EjemploDocumento,
                    c.Origen, c.RevisadoEn, c.RevisadoCorreo, c.Nota,
                    nuevo = c.EsNuevoSinRevisar,
                    gravedad = c.Gravedad
                }),
                administradores = await repo.CorreosAdministradoresAsync(ct),
                correos = await repo.ListarCorreosAsync(ct)
            });
        })
        .AddEndpointFilter(new ExigirPermiso(Permiso.DiagnosticoVer))
        .WithSummary("Códigos de SUNAT vistos y correos para alertas");

        grupo.MapPost("/revisar", async (
            VigilanciaSunat vigilancia, CancellationToken ct) =>
        {
            var r = await vigilancia.VueltaAsync(ct);

            return Results.Ok(new
            {
                mensaje = r.FueLaPrimera
                    ? $"Primera revisión: se anotaron {r.CodigosNuevos} códigos que ya existían, sin avisar."
                    : r.AlertasCreadas > 0
                        ? $"Hay {r.AlertasCreadas} código(s) nuevo(s). Se avisó por correo."
                        : "Revisado. No hay códigos nuevos.",
                r.IntentosRevisados,
                r.CodigosNuevos,
                r.AlertasCreadas
            });
        })
        .AddEndpointFilter(new ExigirPermiso(Permiso.DiagnosticoVer))
        .WithSummary("Revisa ahora, sin esperar al reloj de 5 minutos");

        grupo.MapPost("/revisado", async (
            PeticionRevisado peticion, ContextoOperador operador,
            RepositorioVigilancia repo, CancellationToken ct) =>
        {
            var nota = peticion.Nota?.Trim() ?? "";

            if (string.IsNullOrWhiteSpace(peticion.Codigo) ||
                peticion.Clase is not ("respuesta" or "observacion"))
                return Results.BadRequest(new RespuestaError("Falta el código o su clase."));

            if (nota.Length is < 5 or > 1000)
                return Results.BadRequest(new RespuestaError(
                    "Escribe una nota.",
                    "Entre 5 y 1000 caracteres: qué es y si hubo que hacer algo. " +
                    "La lee quien se lo vuelva a encontrar."));

            var usuario = operador.Exigir();

            var hecho = await repo.MarcarRevisadoAsync(
                peticion.Codigo.Trim(), peticion.Clase, usuario.Id, usuario.Correo, nota, ct);

            return hecho
                ? Results.Ok(new { mensaje = "Marcado como revisado." })
                : Results.Conflict(new RespuestaError(
                    "No se pudo marcar.",
                    "Ese código ya estaba revisado, o no existe. Actualiza la pantalla."));
        })
        .AddEndpointFilter(new ExigirPermiso(Permiso.DiagnosticoVer))
        .WithSummary("Marca un código como revisado, con una nota");

        grupo.MapPost("/correos", async (
            PeticionCorreoAlerta peticion, ContextoOperador operador,
            RepositorioVigilancia repo, CancellationToken ct) =>
        {
            var correo = peticion.Correo?.Trim() ?? "";

            if (correo.Length is < 6 or > 254 || !FormaCorreo.IsMatch(correo))
                return Results.BadRequest(new RespuestaError(
                    "Ese correo no tiene forma de correo.", "Ejemplo: soporte@reyban.pe"));

            var usuario = operador.Exigir();
            var problema = await repo.AgregarCorreoAsync(correo, usuario.Id, usuario.Correo, ct);

            return problema is null
                ? Results.Ok(new { mensaje = $"{correo} recibirá las alertas." })
                : Results.Conflict(new RespuestaError(problema));
        })
        .AddEndpointFilter(new ExigirPermiso(Permiso.UsuariosGestionar))
        .WithSummary("Agrega un correo a la lista de alertas");

        grupo.MapPost("/correos/{id:long}/quitar", async (
            long id, ContextoOperador operador,
            RepositorioVigilancia repo, CancellationToken ct) =>
        {
            var usuario = operador.Exigir();

            return await repo.QuitarCorreoAsync(id, usuario.Id, usuario.Correo, ct)
                ? Results.Ok(new { mensaje = "Quitado de la lista. Ya no recibirá alertas." })
                : Results.NotFound(new RespuestaError("Ese correo ya no estaba en la lista."));
        })
        .AddEndpointFilter(new ExigirPermiso(Permiso.UsuariosGestionar))
        .WithSummary("Quita un correo de la lista (no se borra: queda quién y cuándo)");

        grupo.MapPost("/probar-correo", async (
            ContextoOperador operador, VigilanciaSunat vigilancia,
            ServicioCorreo correo, CancellationToken ct) =>
        {
            if (!correo.Disponible)
                return Results.Json(new RespuestaError(
                    "El correo no está configurado.",
                    "Faltan MAIL_HOST y las demás variables MAIL_ en el .env de la API."),
                    statusCode: StatusCodes.Status503ServiceUnavailable);

            var (salieron, fallaron) = await vigilancia.ProbarCorreoAsync(operador.Exigir().Correo, ct);

            return fallaron.Count == 0
                ? Results.Ok(new { mensaje = $"Enviado a {string.Join(", ", salieron)}." })
                : Results.Json(new RespuestaError(
                    salieron.Count == 0 ? "No salió ningún correo." : "Algunos correos no salieron.",
                    $"Fallaron: {string.Join(", ", fallaron)}. Mira el log de la API."),
                    statusCode: StatusCodes.Status502BadGateway);
        })
        .AddEndpointFilter(new ExigirPermiso(Permiso.UsuariosGestionar))
        .WithSummary("Manda un correo de prueba a todos los que reciben alertas");
    }
}