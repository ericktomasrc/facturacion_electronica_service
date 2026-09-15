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
        var grupo = app.MapGroup("/admin")
            .AddEndpointFilter<FiltroClaveOperador>()
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

/// <summary>
/// Exige la clave de operador en los endpoints de administración.
///
/// Es un mecanismo provisional y conviene decirlo: en producción esto debería
/// ser autenticación real con usuarios, roles y registro de quién hizo qué.
/// Una clave compartida no permite saber quién reprocesó un comprobante.
/// </summary>
public sealed class FiltroClaveOperador : IEndpointFilter
{
    private readonly string _clave;

    public FiltroClaveOperador()
    {
        // Del entorno, no de appsettings.json: es un secreto, y ese archivo
        // se versiona. Si falta, el proceso no arranca. La alternativa —dejar
        // los endpoints abiertos— expondría los datos de todas las empresas.
        _clave = ConfiguracionSecretos.Exigir(
            "ADMIN_CLAVE",
            "proteger los endpoints de operación, que ven todas las empresas");
    }

    public async ValueTask<object?> InvokeAsync(
        EndpointFilterInvocationContext contexto,
        EndpointFilterDelegate siguiente)
    {
        var recibida = contexto.HttpContext.Request.Headers["X-Admin-Key"].ToString();

        // COMPARACIÓN EN TIEMPO CONSTANTE.
        //
        // Comparar con != se detiene en el primer carácter distinto, así que
        // el tiempo de respuesta revela cuántos caracteres se acertaron.
        // Midiendo esas diferencias se puede deducir la clave carácter a
        // carácter, sin necesidad de adivinarla entera.
        if (string.IsNullOrWhiteSpace(recibida) || !SonIguales(recibida, _clave))
        {
            return Results.Json(
                new RespuestaError(
                    "Clave de operador no válida.",
                    "Envíala en la cabecera X-Admin-Key."),
                statusCode: StatusCodes.Status401Unauthorized);
        }

        return await siguiente(contexto);
    }

    private static bool SonIguales(string a, string b) =>
        System.Security.Cryptography.CryptographicOperations.FixedTimeEquals(
            System.Text.Encoding.UTF8.GetBytes(a),
            System.Text.Encoding.UTF8.GetBytes(b));
}
