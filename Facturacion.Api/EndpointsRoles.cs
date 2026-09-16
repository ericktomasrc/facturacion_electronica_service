using Facturacion.Persistencia;

namespace Facturacion.Api;

/// <summary>
/// Gestión de roles y consulta del catálogo de permisos.
///
/// Todo aquí exige el permiso de gestionar usuarios: quien puede definir qué
/// hace cada rol puede, en la práctica, darse a sí mismo cualquier permiso.
/// </summary>
public static class EndpointsRoles
{
    public static void MapearRoles(this WebApplication app)
    {
        var grupo = app.MapGroup("/admin/roles")
            .AddEndpointFilter<AutenticacionPanel>()
            .AddEndpointFilter(new ExigirPermiso(Permiso.UsuariosGestionar))
            .WithTags("Roles y permisos");

        grupo.MapGet("", async (RepositorioRoles roles, CancellationToken ct) =>
            Results.Ok(await roles.ListarAsync(ct)))
            .WithSummary("Lista los roles con sus permisos");

        grupo.MapGet("/permisos", async (
            RepositorioRoles roles, CancellationToken ct) =>
            Results.Ok(await roles.CatalogoAsync(ct)))
            .WithSummary("Catálogo de permisos disponibles")
            .WithDescription(
                "El catálogo es fijo y solo crece con el sistema: un permiso " +
                "sin código que lo compruebe no protegería nada.");

        grupo.MapPost("", async (
            NuevoRol nuevo, RepositorioRoles roles, CancellationToken ct) =>
        {
            if (string.IsNullOrWhiteSpace(nuevo.Nombre))
                return Results.BadRequest(new RespuestaError(
                    "Escribe un nombre para el rol."));

            if (nuevo.Permisos is null || nuevo.Permisos.Length == 0)
                return Results.BadRequest(new RespuestaError(
                    "El rol no tiene ningún permiso.",
                    "Un rol sin permisos deja a quien lo tenga sin poder " +
                    "hacer nada, y sin entender por qué."));

            try
            {
                var id = await roles.CrearAsync(
                    nuevo.Nombre, nuevo.Descripcion ?? "", nuevo.Permisos, ct);

                return Results.Ok(new { id, mensaje = "Rol creado." });
            }
            catch (Npgsql.PostgresException ex) when (ex.SqlState == "23505")
            {
                return Results.Conflict(new RespuestaError(
                    "Ya existe un rol con ese nombre."));
            }
        })
        .WithSummary("Crea un rol");

        grupo.MapPut("/{id:guid}", async (
            Guid id, NuevoRol cambios, RepositorioRoles roles,
            CancellationToken ct) =>
        {
            if (cambios.Permisos is null || cambios.Permisos.Length == 0)
                return Results.BadRequest(new RespuestaError(
                    "El rol no tiene ningún permiso."));

            var (exitoso, motivo) = await roles.ActualizarAsync(
                id, cambios.Nombre, cambios.Descripcion ?? "", cambios.Permisos, ct);

            return exitoso
                ? Results.Ok(new
                {
                    mensaje =
                        "Rol actualizado. Los cambios se aplican en la " +
                        "siguiente petición de cada usuario que lo tenga."
                })
                : Results.BadRequest(new RespuestaError("No se pudo actualizar.", motivo));
        })
        .WithSummary("Cambia el nombre, la descripción y los permisos de un rol")
        .WithDescription(
            "Los roles del sistema no se pueden modificar. Si necesitas algo " +
            "parecido, crea uno nuevo.");

        grupo.MapDelete("/{id:guid}", async (
            Guid id, RepositorioRoles roles, CancellationToken ct) =>
        {
            var (exitoso, motivo) = await roles.EliminarAsync(id, ct);

            return exitoso
                ? Results.Ok(new { mensaje = "Rol eliminado." })
                : Results.BadRequest(new RespuestaError("No se pudo eliminar.", motivo));
        })
        .WithSummary("Elimina un rol")
        .WithDescription(
            "Solo si no es del sistema y nadie lo tiene asignado.");
    }
}

public record NuevoRol(string Nombre, string? Descripcion, string[]? Permisos);
