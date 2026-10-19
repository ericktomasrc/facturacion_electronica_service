using Facturacion.Cpe;
using Facturacion.Persistencia;

namespace Facturacion.Api;

/// <summary>
/// Preguntarle a SUNAT qué sabe de un comprobante nuestro.
///
/// EL PROBLEMA QUE RESUELVE, Y QUE TARDE O TEMPRANO APARECE:
///
/// Se envía una factura, SUNAT la recibe y la procesa, y la respuesta se
/// pierde: se corta la red, vence el tiempo de espera, se reinicia el
/// contenedor. El comprobante queda aquí como pendiente y nadie sabe si allí
/// existe.
///
/// Las dos salidas son malas. Reenviarlo, si ya existía, produce un
/// duplicado. No reenviarlo, si no existía, deja una venta sin declarar.
///
/// Con esta consulta se deja de adivinar: se le pregunta a SUNAT.
///
///
/// Y NO SOLO PREGUNTA: RECONCILIA.
///
/// Si SUNAT dice que el comprobante está aceptado y aquí figura pendiente,
/// el endpoint guarda el CDR que SUNAT devuelve y corrige el estado. Ese es
/// el caso entero: no es un informe, es la reparación.
///
/// Al revés no hace nada. Si aquí consta ACEPTADO, no se toca: ese estado se
/// escribió con un CDR en la mano.
///
///
/// SOLO FUNCIONA EN PRODUCCIÓN. SUNAT no publica el servicio de consulta en
/// beta, y ConsultorCpeSunat lo dice antes de intentarlo. En beta este
/// endpoint responde explicando eso, no un error de red confuso.
///
/// Es la razón de que esta ruta llegue sin probar contra SUNAT: no hay dónde
/// probarla hasta que la primera empresa pase a producción.
/// </summary>
public static class EndpointsEstadoSunat
{
    public static void MapearEstadoSunat(this WebApplication app)
    {
        app.MapPost("/v1/comprobantes/{id:guid}/consultar-sunat", ConsultarAsync)
            .WithName("ConsultarEstadoEnSunat")
            .WithTags("Comprobantes")
            .WithSummary("Le pregunta a SUNAT qué sabe de este comprobante")
            .WithDescription(
                "Sirve para salir de la duda cuando un envío se queda sin " +
                "respuesta: un timeout, un corte de red, un reinicio.\n\n" +
                "Si SUNAT responde que el comprobante está aceptado y aquí " +
                "figuraba pendiente, **se corrige el estado y se guarda el " +
                "CDR** que SUNAT devuelve. Deja de hacer falta reenviarlo, " +
                "que es lo que produce duplicados.\n\n" +
                "Si aquí ya constaba aceptado, no se toca nada: ese estado se " +
                "escribió con un CDR en la mano.\n\n" +
                "**Solo funciona en producción.** SUNAT no publica el " +
                "servicio de consulta en el ambiente de pruebas.")
            .Produces<RespuestaEstadoSunat>()
            .Produces<RespuestaError>(StatusCodes.Status404NotFound)
            .Produces<RespuestaError>(StatusCodes.Status400BadRequest);
    }

    private static async Task<IResult> ConsultarAsync(
        Guid id,
        ContextoEmisor emisor,
        RepositorioComprobantes comprobantes,
        ProveedorCredenciales credenciales,
        IAlmacenArchivos archivos,
        ILogger<Program> registro,
        CancellationToken ct)
    {
        var tenant = emisor.Exigir();

        var comprobante = await comprobantes.ObtenerAsync(tenant.Id, id, ct);

        if (comprobante is null)
        {
            return Results.NotFound(new RespuestaError(
                "No se encontro el comprobante."));
        }

        // UNA BOLETA NO SE PUEDE CONSULTAR ASÍ.
        //
        // El servicio pregunta por comprobantes enviados de uno en uno, y las
        // boletas viajan dentro de un resumen. Lo que hay que consultar en su
        // caso es el ticket de ese resumen, que es otro servicio.
        if (comprobante.TipoComprobante == TipoComprobante.Boleta)
        {
            return Results.BadRequest(new RespuestaError(
                "Las boletas no se consultan de una en una.",
                "Viajan dentro de un resumen diario. Lo que dice si esa boleta " +
                "llego es el estado de su resumen, no esta consulta."));
        }

        // 036: se pregunta al SUNAT donde nació el comprobante.
        var configuracion = await credenciales.ObtenerAsync(tenant.Id,
            await credenciales.AmbienteDeComprobanteAsync(id, ct), ct);

        using var consultor = new ConsultorCpeSunat(configuracion);

        var estado = await consultor.ConsultarAsync(
            tenant.Ruc,
            comprobante.TipoComprobante,
            comprobante.Serie,
            comprobante.Correlativo,
            ct);

        // --- Reconciliar ------------------------------------------------------
        //
        // Solo en una dirección: cuando SUNAT sabe más que nosotros.
        //
        // El caso inverso —aquí ACEPTADO y allí no— no se toca desde aquí. Si
        // eso pasara sería un problema serio que merece que lo mire una
        // persona, no una corrección automática que lo tape.

        var eraPendiente = comprobante.Estado is not
            ("ACEPTADO" or "ACEPTADO_CON_OBSERVACIONES" or "ANULADO");

        var reconciliado = false;

        if (estado.Aceptado && eraPendiente)
        {
            var nombre = $"{tenant.Ruc}-{comprobante.TipoComprobante}-" +
                         $"{comprobante.Serie}-{comprobante.Correlativo:D8}";

            if (estado.CdrZip is not null)
            {
                var rutaCdr = await archivos.GuardarAsync(
                    tenant.Ruc, comprobante.FechaEmision,
                    $"{LectorCdr.NombreArchivoCdr(nombre)}.zip",
                    estado.CdrZip, ct);

                await comprobantes.GuardarRutasAsync(
                    tenant.Id, id, rutaCdr: rutaCdr, ct: ct);
            }

            await comprobantes.RegistrarCambioAsync(tenant.Id, id,
                new CambioEstado(
                    EstadoCpe.Aceptado,
                    CodigoSunat: estado.Codigo,
                    Mensaje:
                        "Reconciliado con SUNAT: el comprobante si habia " +
                        "llegado. " + estado.Mensaje,
                    Worker: Environment.MachineName), ct);

            reconciliado = true;

            registro.LogWarning(
                "{Numero} estaba en {Estado} y SUNAT lo tiene aceptado. " +
                "Corregido. La respuesta del envio se habia perdido.",
                comprobante.NumeroCompleto, comprobante.Estado);
        }

        return Results.Ok(new RespuestaEstadoSunat(
            Numero: comprobante.NumeroCompleto,
            EstadoAqui: reconciliado ? "ACEPTADO" : comprobante.Estado,
            ExisteEnSunat: estado.Existe,
            AceptadoEnSunat: estado.Aceptado,
            CodigoSunat: estado.Codigo,
            MensajeSunat: estado.Mensaje,
            Reconciliado: reconciliado,
            Detalle: Explicar(comprobante.Estado, estado, reconciliado)));
    }

    /// <summary>
    /// Qué significa todo esto junto, en una frase.
    ///
    /// SE ESCRIBE AQUÍ Y NO SE DEJA AL QUE LLAMA porque el cruce de dos
    /// estados tiene cuatro desenlaces y tres de ellos piden hacer algo
    /// distinto. Devolver dos banderas y que cada integrador saque sus
    /// conclusiones garantiza que alguien las saque mal.
    /// </summary>
    private static string Explicar(
        string estadoAqui, EstadoComprobante sunat, bool reconciliado)
    {
        if (reconciliado)
        {
            return "El comprobante si habia llegado a SUNAT: la respuesta del " +
                   "envio se perdio. Se corrigio el estado y se guardo el CDR. " +
                   "NO lo reenvies.";
        }

        if (!sunat.Existe)
        {
            return estadoAqui is "ACEPTADO" or "ACEPTADO_CON_OBSERVACIONES"
                ? "AQUI CONSTA ACEPTADO Y SUNAT DICE QUE NO EXISTE. Esto no " +
                  "deberia pasar y no se corrige solo: revisa que el RUC y el " +
                  "ambiente sean los que crees antes de tocar nada."
                : "SUNAT no tiene este comprobante. No llego, asi que se puede " +
                  "reenviar sin riesgo de duplicarlo.";
        }

        if (sunat.Aceptado)
        {
            return "SUNAT lo tiene aceptado y aqui ya constaba asi. Todo " +
                   "cuadra, no hay nada que hacer.";
        }

        return $"SUNAT tiene el comprobante pero no esta aceptado: " +
               $"{sunat.Mensaje} Reenviarlo no cambiaria nada; lo que " +
               $"corresponde depende del motivo.";
    }
}

/// <summary>Lo que SUNAT sabe de un comprobante, y si cuadra con lo de aquí.</summary>
public record RespuestaEstadoSunat(
    string Numero,
    string EstadoAqui,
    bool ExisteEnSunat,
    bool AceptadoEnSunat,
    string CodigoSunat,
    string MensajeSunat,
    bool Reconciliado,
    string Detalle);
