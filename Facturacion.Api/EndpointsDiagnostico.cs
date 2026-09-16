using Facturacion.Persistencia;

namespace Facturacion.Api;

/// <summary>
/// Endpoints de operación del servicio.
///
/// ESTÁN PROTEGIDOS CON UNA CLAVE DISTINTA a la de los emisores, y la razón
/// importa: estos endpoints muestran datos de TODAS las empresas. Una clave
/// de emisor jamás debe abrir esta puerta, porque entonces cualquier cliente
/// vería la actividad de sus competidores.
///
/// La separación entre "mi empresa" y "la plataforma" no es solo de permisos:
/// son dos sistemas de autenticación distintos.
/// </summary>
public static class EndpointsDiagnostico
{
    public static void MapearDiagnostico(this WebApplication app)
    {
        // El diagnóstico y el reproceso los puede usar soporte: son las dos
        // cosas que necesita quien atiende a un cliente que llama porque su
        // factura no salió.
        var grupo = app.MapGroup("/admin")
            .AddEndpointFilter<AutenticacionPanel>()
            .WithTags("Operación");

        grupo.MapGet("/salud", async (
            RepositorioDiagnostico diagnostico,
            CancellationToken ct) =>
        {
            var salud = await diagnostico.RevisarAsync(ct);

            return Results.Ok(new
            {
                nivel = salud.Nivel.ToString(),
                alertas = salud.Alertas,

                cola = new
                {
                    pendientes = salud.Pendientes,
                    enProceso = salud.EnCola,
                    esperandoReintento = salud.ConFallos,
                    requierenRevision = salud.AgotaronIntentos
                },

                hoy = new
                {
                    aceptados = salud.AceptadosHoy,
                    rechazados = salud.RechazadosHoy,
                    tasaExito = Math.Round(salud.TasaExitoHoy * 100, 1)
                },

                ultimoEnvioExitoso = salud.UltimoEnvioExitoso,
                minutosDesdeUltimoExito = salud.MinutosDesdeUltimoExito,

                erroresFrecuentes = salud.ErroresFrecuentes,
                certificados = salud.Certificados,
                atascados = salud.Atascados
            });
        })
        .AddEndpointFilter(new ExigirPermiso(Permiso.DiagnosticoVer))
        .WithSummary("Estado de salud del servicio")
        .WithDescription(
            "Responde en una sola llamada si el sistema está sano. " +
            "El campo 'alertas' explica en texto qué requiere atención.");

        grupo.MapPost("/comprobantes/{id:guid}/reprocesar", async (
            Guid id,
            RepositorioDiagnostico diagnostico,
            CancellationToken ct) =>
        {
            var reprocesado = await diagnostico.ReprocesarAsync(id, ct);

            return reprocesado
                ? Results.Ok(new { mensaje = "Devuelto a la cola." })
                : Results.NotFound(new RespuestaError(
                    "No se pudo reprocesar.",
                    "O no existe, o ya fue aceptado. Un comprobante aceptado " +
                    "no se reenvía: si hay que corregirlo, se emite una nota."));
        })
        .AddEndpointFilter(new ExigirPermiso(Permiso.ComprobantesReprocesar))
        .WithSummary("Devuelve un comprobante a la cola")
        .WithDescription(
            "Para los que agotaron reintentos: se corrige la causa y se " +
            "reprocesa desde aquí.\\n\\n" +
            "NO sirve para los rechazados por datos: esos necesitan un " +
            "comprobante nuevo, porque el XML está mal y reenviarlo daría " +
            "exactamente el mismo resultado.");

        // El panel visual. Es una sola página sin dependencias.
        app.MapGet("/admin", () => Results.Redirect("/diagnostico.html"))
           .ExcludeFromDescription();
    }
}
