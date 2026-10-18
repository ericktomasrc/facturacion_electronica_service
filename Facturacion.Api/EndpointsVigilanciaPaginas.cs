using Facturacion.Persistencia;

namespace Facturacion.Api;

/// <summary>
/// Las listas de Vigilancia SUNAT por páginas, para la pantalla con pestañas
/// (14 de octubre de 2026). Mismo permiso que el resto de la pestaña.
///
///   GET /admin/vigilancia/resumen    los números de las pestañas
///   GET /admin/vigilancia/codigos    ?filtro=nuevos|todos|rechazos|observaciones|aceptados&q=&pagina=&tamano=
///   GET /admin/vigilancia/correos    ?pagina=&tamano=
///
/// El GET /admin/vigilancia de siempre sigue igual: lo usa quien ya lo usaba.
/// </summary>
public static class EndpointsVigilanciaPaginas
{
    public static void MapearVigilanciaPaginas(this WebApplication app)
    {
        var grupo = app.MapGroup("/admin/vigilancia")
            .AddEndpointFilter<AutenticacionPanel>()
            .WithTags("Vigilancia SUNAT");

        grupo.MapGet("/resumen", async (
            RepositorioVigilancia repo, ConsultasVigilancia consultas, CancellationToken ct) =>
        {
            var estado = await repo.EstadoAsync(ct);
            var conteo = await consultas.ContarAsync(ct);
            var administradores = await repo.CorreosAdministradoresAsync(ct);

            return Results.Ok(new
            {
                inicializadoEn = estado.InicializadoEn,
                ultimaRevisionEn = estado.UltimaRevisionEn,
                codigos = new { nuevos = conteo.CodigosNuevos, total = conteo.CodigosTotal },
                correos = new { administradores = administradores.Count, lista = conteo.Correos }
            });
        })
        .AddEndpointFilter(new ExigirPermiso(Permiso.DiagnosticoVer))
        .WithSummary("Los números de las pestañas de Vigilancia SUNAT");

        grupo.MapGet("/codigos", async (
            string? filtro, string? q, int? pagina, int? tamano,
            ConsultasVigilancia consultas, CancellationToken ct) =>
        {
            var f = filtro is not null && ConsultasVigilancia.Filtros.Contains(filtro) ? filtro : "nuevos";
            var p = await consultas.CodigosAsync(f, q, pagina ?? 1, tamano ?? 25, ct);

            return Results.Ok(new
            {
                filtro = f,
                p.Total, p.Pagina, p.Tamano, p.Paginas,
                items = p.Items.Select(c => new
                {
                    c.Codigo, c.Clase, c.PrimeraVez, c.UltimaVez, c.Veces, c.Empresas,
                    c.EjemploMensaje, c.EjemploEmpresa, c.EjemploRuc, c.EjemploDocumento,
                    c.Origen, c.RevisadoEn, c.RevisadoCorreo, c.Nota,
                    nuevo = c.EsNuevoSinRevisar,
                    gravedad = c.Gravedad
                })
            });
        })
        .AddEndpointFilter(new ExigirPermiso(Permiso.DiagnosticoVer))
        .WithSummary("Los códigos de SUNAT vistos, por páginas, con filtro y búsqueda");

        grupo.MapGet("/correos", async (
            int? pagina, int? tamano,
            RepositorioVigilancia repo, ConsultasVigilancia consultas, CancellationToken ct) =>
        {
            var p = await consultas.CorreosAsync(pagina ?? 1, tamano ?? 10, ct);

            return Results.Ok(new
            {
                p.Total, p.Pagina, p.Tamano, p.Paginas,
                items = p.Items,
                administradores = await repo.CorreosAdministradoresAsync(ct)
            });
        })
        .AddEndpointFilter(new ExigirPermiso(Permiso.DiagnosticoVer))
        .WithSummary("La lista de correos para alertas, por páginas, y los administradores");
    }
}