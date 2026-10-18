using Facturacion.Persistencia;

namespace Facturacion.Api;

/// <summary>
/// La sección «Prueba de madrugada» de Vigilancia SUNAT (migración 030).
///
/// Ver y «Correr ahora»: quien ve el estado del servicio (diagnostico.ver).
/// Correrla solo emite en SUNAT beta, con la empresa interna: no toca nada
/// real. Todo lo que no es GET queda en la bitácora del panel.
/// </summary>
public static class EndpointsMadrugada
{
    public static void MapearPruebaMadrugada(this WebApplication app)
    {
        var grupo = app.MapGroup("/admin/vigilancia/madrugada")
            .AddEndpointFilter<AutenticacionPanel>()
            .WithTags("Vigilancia SUNAT");

        grupo.MapGet("", async (
            RepositorioMadrugada repo, PruebaMadrugada prueba, CancellationToken ct) =>
        {
            ConfigMadrugada? cfg;

            try { cfg = await repo.ConfigAsync(ct); }
            catch (Npgsql.PostgresException ex) when (ex.SqlState == "42P01")
            {
                return Results.Json(new RespuestaError(
                    "Falta aplicar la migración 030.",
                    "Sin ella no existe la prueba de madrugada."),
                    statusCode: StatusCodes.Status503ServiceUnavailable);
            }

            var (corridas, casos) = await repo.UltimasAsync(7, ct);

            // «Empresa de control»: sus series y su certificado de prueba.
            var control = cfg is null ? default : await repo.ControlAsync(cfg.TenantId, ct);

            return Results.Ok(new
            {
                preparada = cfg is not null,
                empresa = cfg is null ? null : new { cfg.Ruc, cfg.RazonSocial, cfg.PreparadaEn, cfg.PreparadaPor },
                hora = ConfiguracionSecretos.Opcional("PRUEBA_MADRUGADA_HORA", "03:00"),
                corriendo = prueba.Corriendo,
                control = cfg is null ? null : new
                {
                    series = control.Series.Select(s => new { tipo = s.Tipo, serie = s.Serie, ultimo = s.Ultimo }),
                    certificadoVence = control.CertificadoVence
                },
                definicion = CasosMadrugada.Todos.Select(c => new { clave = c.Clave, nombre = c.Nombre }),
                corridas = corridas.Select(x => new
                {
                    x.Id, x.Origen, x.IniciadaPor, x.IniciadaEn, x.TerminadaEn, x.Error
                }),
                casos = casos.Select(k => new
                {
                    k.PruebaId, caso = k.Caso, estado = k.Estado, codigo = k.Codigo,
                    mensaje = k.ErrorApi ?? k.MensajeDoc ?? k.MensajeCaso,
                    k.Numero, k.Cambio, k.EnviadoEn
                })
            });
        })
        .AddEndpointFilter(new ExigirPermiso(Permiso.DiagnosticoVer))
        .WithSummary("La prueba de madrugada: las últimas 7 corridas, caso por caso");

        grupo.MapPost("/correr", (
            ContextoOperador operador, PruebaMadrugada prueba, IHostApplicationLifetime vida,
            ILogger<PruebaMadrugada> log) =>
        {
            if (prueba.Corriendo)
                return Results.Conflict(new RespuestaError(
                    "Ya hay una prueba corriendo.", "Espera a que termine; tarda unos minutos."));

            var quien = operador.Exigir().Correo;

            // Corre aparte: tarda minutos (espera a que SUNAT acepte la factura
            // que después se da de baja). La pantalla se va actualizando sola.
            _ = Task.Run(async () =>
            {
                try { await prueba.CorrerAsync("panel", quien, vida.ApplicationStopping); }
                catch (Exception ex) { log.LogError(ex, "Falló la prueba de madrugada pedida desde el panel."); }
            });

            return Results.Accepted(value: new
            {
                mensaje = "La prueba empezó. Los resultados van apareciendo en unos minutos; " +
                          "la boleta, al día siguiente."
            });
        })
        .AddEndpointFilter(new ExigirPermiso(Permiso.DiagnosticoVer))
        .WithSummary("Corre la prueba ahora, sin esperar a la madrugada");
    }
}