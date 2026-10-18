using Facturacion.Cpe;
using Facturacion.Persistencia;

namespace Facturacion.Api;

/// <summary>
/// La pestaña «Catálogo de productos SUNAT» de Vigilancia SUNAT (migración 031).
/// Ver y subir el Excel: quien ve el estado del servicio (diagnostico.ver).
///
/// EL EXCEL SE SUBE A MANO: el portal de SUNAT responde 403 a todo lo que no
/// sea un navegador. Ver VigilanciaCatalogo.
/// </summary>
public static class EndpointsCatalogoSunat
{
    public static void MapearVigilanciaCatalogo(this WebApplication app)
    {
        var grupo = app.MapGroup("/admin/vigilancia/catalogo")
            .AddEndpointFilter<AutenticacionPanel>()
            .WithTags("Vigilancia SUNAT");

        grupo.MapGet("", async (RepositorioCatalogoSunat repo, CancellationToken ct) =>
        {
            EstadoCatalogo estado;
            IReadOnlyList<VersionCatalogo> versiones;

            try
            {
                estado = await repo.IniciarAsync(ct);
                versiones = await repo.VersionesAsync(5, ct);
            }
            catch (Npgsql.PostgresException ex) when (ex.SqlState == "42P01")
            {
                return Results.Json(new RespuestaError(
                    "Falta aplicar la migración 031.",
                    "Sin ella no se vigila el catálogo de códigos de producto."),
                    statusCode: StatusCodes.Status503ServiceUnavailable);
            }

            var actual = versiones.FirstOrDefault();
            var desde = estado.UltimoExitoEn ?? estado.CreadoEn;

            return Results.Ok(new
            {
                urlPagina = CatalogoProductosSunat.UrlPagina,
                urlArchivo = CatalogoProductosSunat.UrlArchivo,
                enUso = new
                {
                    codigos = CatalogoProductosSunat.CantidadEnUso,
                    version = CatalogoProductosSunat.VersionEnUso
                },
                recordarCadaDias = (int)VigilanciaCatalogo.RecordarCada.TotalDays,
                ultimaComparacionEn = estado.UltimoExitoEn,
                proximoRecordatorioEn = desde + VigilanciaCatalogo.RecordarCada,
                tocaComparar = DateTime.UtcNow - desde.ToUniversalTime() >= VigilanciaCatalogo.RecordarCada,
                actual = actual is null ? null : new
                {
                    actual.Codigos, actual.Agregados, actual.Quitados,
                    actual.AgregadosMuestra, actual.QuitadosMuestra,
                    origen = actual.Publicado, actual.VistoPrimera, actual.VistoUltima,
                    igual = actual.Huella == CatalogoProductosSunat.HuellaEnUso
                }
            });
        })
        .AddEndpointFilter(new ExigirPermiso(Permiso.DiagnosticoVer))
        .WithSummary("El catálogo de códigos de producto de SUNAT: si cambió respecto al de la plataforma");

        // El cuerpo ES el archivo (application/octet-stream), sin formulario.
        grupo.MapPost("/subir", async (
            HttpRequest peticion, ContextoOperador operador, VigilanciaCatalogo vigilancia,
            CancellationToken ct) =>
        {
            if (peticion.ContentLength is > VigilanciaCatalogo.MaximoBytes)
                return Results.BadRequest(new RespuestaError(
                    "El archivo es demasiado grande.", "El catálogo de SUNAT pesa unos 4 MB."));

            using var memoria = new MemoryStream();
            var bufer = new byte[81920];
            int leidos;
            while ((leidos = await peticion.Body.ReadAsync(bufer, ct)) > 0)
            {
                memoria.Write(bufer, 0, leidos);
                if (memoria.Length > VigilanciaCatalogo.MaximoBytes)
                    return Results.BadRequest(new RespuestaError(
                        "El archivo es demasiado grande.", "El catálogo de SUNAT pesa unos 4 MB."));
            }

            if (memoria.Length == 0)
                return Results.BadRequest(new RespuestaError("No llegó ningún archivo."));

            try
            {
                var r = await vigilancia.CompararAsync(memoria.ToArray(), operador.Exigir().Correo, ct);
                return r.Exito
                    ? Results.Ok(new { r.Exito, r.Igual, r.Agregados, r.Quitados, mensaje = r.Mensaje })
                    : Results.BadRequest(new RespuestaError("No se pudo comparar.", r.Mensaje));
            }
            catch (Npgsql.PostgresException ex) when (ex.SqlState == "42P01")
            {
                return Results.Json(new RespuestaError(
                    "Falta aplicar la migración 031.", "Sin ella no se vigila el catálogo."),
                    statusCode: StatusCodes.Status503ServiceUnavailable);
            }
        })
        .AddEndpointFilter(new ExigirPermiso(Permiso.DiagnosticoVer))
        .WithSummary("Compara con la plataforma el Excel del catálogo 25 que se bajó de SUNAT");
    }
}