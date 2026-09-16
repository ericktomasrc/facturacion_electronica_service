using Facturacion.Persistencia;

namespace Facturacion.Api;

/// <summary>
/// Administración de la plataforma: empresas, certificados, series y claves.
///
/// Todo esto se hacía hasta ahora escribiendo SQL a mano, lo cual funciona
/// mientras el sistema lo maneja quien lo construyó. Deja de funcionar el día
/// que hay que delegarlo, y ese día llega antes de lo que parece.
/// </summary>
public static class EndpointsAdmin
{
    public static void MapearAdministracion(this WebApplication app)
    {
        // CADA ACCIÓN EXIGE SU PROPIO PERMISO, no un rol entero.
        //
        // Quien da de alta clientes no necesita cargar certificados, y quien
        // atiende llamadas no necesita crear empresas. Repartirlo así permite
        // dar a cada persona exactamente lo que usa.
        var grupo = app.MapGroup("/admin")
            .AddEndpointFilter<AutenticacionPanel>()
            .WithTags("Administración");

        // ------------------------------------------------------------ empresas

        grupo.MapGet("/tenants", async (
            RepositorioAdmin admin, CancellationToken ct) =>
            Results.Ok(await admin.ListarTenantsAsync(ct)))
            .AddEndpointFilter(new ExigirPermiso(Permiso.EmpresasVer))
        .WithSummary("Lista las empresas");

        grupo.MapPost("/tenants", async (
            NuevoTenant nuevo, RepositorioAdmin admin, CancellationToken ct) =>
        {
            if (nuevo.Ruc.Length != 11 || !nuevo.Ruc.All(char.IsDigit))
                return Results.BadRequest(new RespuestaError(
                    "RUC inválido.", "Debe tener exactamente 11 dígitos."));

            if (string.IsNullOrWhiteSpace(nuevo.RazonSocial))
                return Results.BadRequest(new RespuestaError(
                    "Falta la razón social."));

            try
            {
                var id = await admin.CrearTenantAsync(nuevo, ct);
                return Results.Ok(new { id, mensaje = "Empresa creada." });
            }
            catch (Npgsql.PostgresException ex) when (ex.SqlState == "23505")
            {
                // Violación de unicidad: el RUC ya existe.
                return Results.Conflict(new RespuestaError(
                    "Ese RUC ya está registrado.",
                    "Cada empresa se da de alta una sola vez."));
            }
        })
        .AddEndpointFilter(new ExigirPermiso(Permiso.EmpresasEditar))
        .WithSummary("Da de alta una empresa");

        grupo.MapPatch("/tenants/{id:guid}", async (
            Guid id, ActualizacionTenant cambios,
            RepositorioAdmin admin, CancellationToken ct) =>
        {
            var actualizado = await admin.ActualizarTenantAsync(
                id, cambios.Activo, cambios.MaxConcurrencia, ct);

            return actualizado
                ? Results.Ok(new { mensaje = "Empresa actualizada." })
                : Results.NotFound(new RespuestaError("No se encontró la empresa."));
        })
        .AddEndpointFilter(new ExigirPermiso(Permiso.EmpresasEditar))
        .WithSummary("Activa, desactiva o ajusta la concurrencia");

        // ------------------------------------------------- credenciales SOL

        grupo.MapPost("/tenants/{id:guid}/credenciales-sol", async (
            Guid id, CredencialesSol credenciales,
            RepositorioAdmin admin, IProtectorDeSecretos protector,
            CancellationToken ct) =>
        {
            if (credenciales.Usuario.Equals("MODDATOS", StringComparison.OrdinalIgnoreCase))
            {
                return Results.BadRequest(new RespuestaError(
                    "MODDATOS es el usuario del ambiente de pruebas.",
                    "Para producción hace falta el usuario SOL secundario real " +
                    "del contribuyente."));
            }

            try
            {
                var guardadas = await admin.GuardarCredencialesSolAsync(
                    id, credenciales.Usuario, credenciales.Clave, protector, ct);

                return guardadas
                    ? Results.Ok(new { mensaje = "Credenciales guardadas y cifradas." })
                    : Results.NotFound(new RespuestaError("No se encontró la empresa."));
            }
            catch (ArgumentException ex)
            {
                return Results.BadRequest(new RespuestaError("Datos inválidos.", ex.Message));
            }
        })
        .AddEndpointFilter(new ExigirPermiso(Permiso.ProduccionCambiar))
        .WithSummary("Guarda las credenciales SOL del contribuyente")
        .WithDescription(
            "La clave se cifra igual que el certificado.\n\n" +
            "Debe ser el usuario SOL SECUNDARIO, nunca el principal: el " +
            "principal puede declarar, pagar y modificar datos en el portal " +
            "de SUNAT, y ese nivel de acceso no tiene por qué vivir aquí.");

        grupo.MapGet("/tenants/{id:guid}/revision-produccion", async (
            Guid id, ProveedorCredenciales credenciales, CancellationToken ct) =>
            Results.Ok(await credenciales.RevisarAsync(id, ct)))
            .AddEndpointFilter(new ExigirPermiso(Permiso.EmpresasVer))
            .WithSummary("Comprueba si la empresa puede pasar a producción")
            .WithDescription(
                "Revisa certificado, credenciales SOL y series. Pasar a " +
                "producción sin alguno de ellos hace que todas las facturas " +
                "de esa empresa fallen desde el primer minuto.");

        grupo.MapPost("/tenants/{id:guid}/ambiente", async (
            Guid id, CambioAmbiente cambio,
            RepositorioAdmin admin, ProveedorCredenciales credenciales,
            CancellationToken ct) =>
        {
            // Volver a beta siempre se permite: es la salida cuando algo va mal.
            if (cambio.Ambiente == "beta")
            {
                var vuelto = await admin.CambiarAmbienteAsync(id, "beta", ct);

                return vuelto
                    ? Results.Ok(new { mensaje = "La empresa volvió al ambiente de pruebas." })
                    : Results.NotFound(new RespuestaError("No se encontró la empresa."));
            }

            // Pasar a producción NO. Se comprueba antes.
            var revision = await credenciales.RevisarAsync(id, ct);

            if (!revision.Listo)
            {
                return Results.BadRequest(new RespuestaError(
                    "La empresa todavía no puede pasar a producción.",
                    string.Join(" ", revision.Faltantes)));
            }

            var cambiado = await admin.CambiarAmbienteAsync(id, "produccion", ct);

            return cambiado
                ? Results.Ok(new
                {
                    mensaje = "La empresa pasó a producción.",
                    advertencias = revision.Advertencias
                })
                : Results.NotFound(new RespuestaError("No se encontró la empresa."));
        })
        .AddEndpointFilter(new ExigirPermiso(Permiso.ProduccionCambiar))
        .WithSummary("Cambia el ambiente de la empresa")
        .WithDescription(
            "Pasar a producción exige superar la revisión previa. Volver a " +
            "beta siempre se permite: es la salida cuando algo va mal.");

        // -------------------------------------------------------- certificados

        grupo.MapPost("/tenants/{id:guid}/certificado", async (
            Guid id,
            IFormFile archivo,
            string clave,
            AlmacenCertificados certificados,
            CancellationToken ct) =>
        {
            if (archivo.Length == 0)
                return Results.BadRequest(new RespuestaError("El archivo está vacío."));

            // Un PFX legítimo no llega a este tamaño. El límite evita que
            // alguien suba un archivo enorme y agote la memoria del proceso.
            if (archivo.Length > 512 * 1024)
                return Results.BadRequest(new RespuestaError(
                    "El archivo es demasiado grande.",
                    "Un certificado PFX pesa unos pocos kilobytes."));

            using var memoria = new MemoryStream();
            await archivo.CopyToAsync(memoria, ct);

            try
            {
                var certificadoId = await certificados.GuardarAsync(
                    id, memoria.ToArray(), clave, ct);

                return Results.Ok(new
                {
                    id = certificadoId,
                    mensaje = "Certificado guardado y cifrado."
                });
            }
            catch (InvalidOperationException ex)
            {
                // Contraseña incorrecta, certificado vencido, o sin llave
                // privada. El mensaje de AlmacenCertificados ya explica cuál.
                return Results.BadRequest(new RespuestaError(
                    "No se pudo guardar el certificado.", ex.Message));
            }
        })
        .DisableAntiforgery()
        .AddEndpointFilter(new ExigirPermiso(Permiso.CertificadosGestionar))
        .WithSummary("Carga el certificado digital de una empresa")
        .WithDescription(
            "El archivo .pfx se cifra antes de guardarse. Solo se descifra en " +
            "memoria y solo en el momento de firmar.\\n\\n" +
            "Reemplaza al certificado activo anterior, que queda desactivado " +
            "en la misma operación: nunca hay dos activos ni un hueco sin " +
            "ninguno.");

        grupo.MapGet("/tenants/{id:guid}/certificados", async (
            Guid id, AlmacenCertificados certificados, CancellationToken ct) =>
            Results.Ok(await certificados.ListarAsync(id, ct)))
            .AddEndpointFilter(new ExigirPermiso(Permiso.EmpresasVer))
            .WithSummary("Lista los certificados de una empresa");

        grupo.MapDelete("/tenants/{id:guid}/certificados/{certificadoId:guid}", async (
            Guid id, Guid certificadoId,
            AlmacenCertificados certificados, CancellationToken ct) =>
        {
            var eliminado = await certificados.EliminarAsync(id, certificadoId, ct);

            return eliminado
                ? Results.Ok(new { mensaje = "Certificado eliminado." })
                : Results.Conflict(new RespuestaError(
                    "No se puede eliminar este certificado.",
                    "O está activo, o ya firmó comprobantes. Un certificado " +
                    "que firmó hay que conservarlo: sin él no se puede " +
                    "verificar esas firmas durante una fiscalización."));
        })
        .AddEndpointFilter(new ExigirPermiso(Permiso.CertificadosGestionar))
        .WithSummary("Elimina un certificado nunca usado")
        .WithDescription(
            "Para el caso de haber cargado el archivo equivocado. Solo " +
            "funciona si el certificado está inactivo y nunca firmó nada.");

        // -------------------------------------------------------------- series

        grupo.MapGet("/tenants/{id:guid}/series", async (
            Guid id, RepositorioAdmin admin, CancellationToken ct) =>
            Results.Ok(await admin.ListarSeriesAsync(id, ct)))
            .AddEndpointFilter(new ExigirPermiso(Permiso.EmpresasVer))
            .WithSummary("Lista las series de una empresa");

        grupo.MapPost("/tenants/{id:guid}/series", async (
            Guid id, NuevaSerie nueva,
            RepositorioAdmin admin, CancellationToken ct) =>
        {
            if (string.IsNullOrWhiteSpace(nueva.Serie) || nueva.Serie.Length != 4)
                return Results.BadRequest(new RespuestaError(
                    "Serie inválida.",
                    "Debe tener 4 caracteres. Ej: F001 para facturas, B001 para boletas."));

            var serieId = await admin.CrearSerieAsync(
                id, nueva.TipoComprobante, nueva.Serie.ToUpperInvariant(),
                nueva.CorrelativoInicial, ct);

            return Results.Ok(new { id = serieId, mensaje = "Serie dada de alta." });
        })
        .AddEndpointFilter(new ExigirPermiso(Permiso.EmpresasEditar))
        .WithSummary("Da de alta una serie")
        .WithDescription(
            "El correlativo inicial normalmente es 0, pero si la empresa migra " +
            "desde otro sistema hay que poner el último número que ya emitió. " +
            "Empezar de nuevo en 1 generaría duplicados que SUNAT rechaza.");

        grupo.MapDelete("/tenants/{id:guid}/series/{serieId:guid}", async (
            Guid id, Guid serieId, RepositorioAdmin admin, CancellationToken ct) =>
        {
            var eliminada = await admin.EliminarSerieAsync(id, serieId, ct);

            return eliminada
                ? Results.Ok(new { mensaje = "Serie eliminada." })
                : Results.Conflict(new RespuestaError(
                    "No se puede eliminar esta serie.",
                    "Ya tiene comprobantes emitidos. Borrarla dejaría huérfano " +
                    "el rastro de esa numeración. Desactívala: deja de poder " +
                    "emitir y el histórico queda intacto."));
        })
        .AddEndpointFilter(new ExigirPermiso(Permiso.EmpresasEditar))
        .WithSummary("Elimina una serie sin usar")
        .WithDescription(
            "Solo funciona si la serie nunca emitió comprobantes. En caso " +
            "contrario hay que desactivarla.");

        grupo.MapPatch("/tenants/{id:guid}/series/{serieId:guid}", async (
            Guid id, Guid serieId, CambioEstadoSerie cambio,
            RepositorioAdmin admin, CancellationToken ct) =>
        {
            var cambiada = await admin.CambiarEstadoSerieAsync(
                id, serieId, cambio.Activo, ct);

            return cambiada
                ? Results.Ok(new { mensaje = cambio.Activo
                    ? "Serie reactivada." : "Serie desactivada." })
                : Results.NotFound(new RespuestaError("No se encontró la serie."));
        })
        .AddEndpointFilter(new ExigirPermiso(Permiso.EmpresasEditar))
        .WithSummary("Activa o desactiva una serie")
        .WithDescription(
            "Una serie desactivada no puede emitir, pero sus comprobantes " +
            "siguen consultándose y descargándose igual.");

        // -------------------------------------------------------------- claves

        grupo.MapGet("/tenants/{id:guid}/claves", async (
            Guid id, RepositorioAdmin admin, CancellationToken ct) =>
            Results.Ok(await admin.ListarClavesAsync(id, ct)))
            .AddEndpointFilter(new ExigirPermiso(Permiso.EmpresasVer))
            .WithSummary("Lista las claves de acceso de una empresa");

        grupo.MapPost("/tenants/{id:guid}/claves", async (
            Guid id, NuevaClave nueva,
            RepositorioAdmin admin, CancellationToken ct) =>
        {
            var (claveId, secreto) = await admin.CrearClaveAsync(
                id, nueva.Nombre, nueva.Produccion, ct);

            return Results.Ok(new
            {
                id = claveId,
                clave = secreto,
                aviso =
                    "Esta es la ÚNICA vez que se muestra la clave. En la base " +
                    "solo queda su hash. Si se pierde, hay que revocarla y " +
                    "emitir otra."
            });
        })
        .AddEndpointFilter(new ExigirPermiso(Permiso.ClavesGestionar))
        .WithSummary("Emite una clave de acceso")
        .WithDescription(
            "Devuelve el secreto en claro UNA sola vez. Después ya no se puede " +
            "recuperar, igual que con una contraseña.");

        grupo.MapDelete("/claves/{claveId:guid}", async (
            Guid claveId, RepositorioAdmin admin, CancellationToken ct) =>
        {
            var revocada = await admin.RevocarClaveAsync(claveId, ct);

            return revocada
                ? Results.Ok(new { mensaje = "Clave revocada." })
                : Results.NotFound(new RespuestaError(
                    "No se encontró la clave, o ya estaba revocada."));
        })
        .AddEndpointFilter(new ExigirPermiso(Permiso.ClavesGestionar))
        .WithSummary("Revoca una clave")
        .WithDescription(
            "La clave se desactiva, no se borra. Borrarla dejaría sin rastro " +
            "quién tuvo acceso y hasta cuándo, que es justo lo que hay que " +
            "poder responder después de un incidente.");
    }
}

public record ActualizacionTenant(bool? Activo, short? MaxConcurrencia);

public record NuevaSerie(
    string TipoComprobante,
    string Serie,
    int CorrelativoInicial = 0);

public record NuevaClave(string Nombre, bool Produccion = false);

public record CambioEstadoSerie(bool Activo);

public record CredencialesSol(string Usuario, string Clave);

public record CambioAmbiente(string Ambiente);
