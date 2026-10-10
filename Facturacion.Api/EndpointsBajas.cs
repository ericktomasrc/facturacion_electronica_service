using System.ComponentModel.DataAnnotations;
using Facturacion.Cpe;
using Facturacion.Persistencia;

namespace Facturacion.Api;

/// <summary>Petición para dar de baja uno o varios comprobantes.</summary>
public class PeticionBaja
{
    /// <summary>
    /// Por qué se anulan. Lo lee una persona en SUNAT.
    ///
    /// Se puede poner uno distinto en cada comprobante; este es el que se
    /// usa para los que no traigan el suyo.
    /// </summary>
    public string Motivo { get; set; } = "";

    [Required]
    [MinLength(1, ErrorMessage = "Hay que decir qué comprobante se da de baja.")]
    public List<ComprobanteABajaDto> Comprobantes { get; set; } = [];
}

/// <summary>Un comprobante que se quiere anular.</summary>
public class ComprobanteABajaDto
{
    /// <summary>Catálogo 01. "01" factura, "07" nota de crédito, "08" nota de débito.</summary>
    public string TipoDocumento { get; set; } = TipoComprobante.Factura;

    /// <summary>Serie del comprobante. Ej: F001</summary>
    [Required]
    public string Serie { get; set; } = "";

    /// <summary>Correlativo, sin ceros a la izquierda.</summary>
    [Range(1, int.MaxValue)]
    public int Correlativo { get; set; }

    /// <summary>Motivo propio. Si se omite, se usa el de la petición.</summary>
    public string Motivo { get; set; } = "";

    public string NumeroCompleto => $"{Serie}-{Correlativo:D8}";
}

/// <summary>
/// Comunicación de baja: anular comprobantes que SUNAT ya aceptó.
///
/// POR QUÉ ESTA RUTA TENÍA QUE EXISTIR:
///
/// Un comprobante aceptado por SUNAT no se puede modificar ni borrar. Si se
/// emitió por error —al RUC equivocado, duplicado, una venta que nunca
/// ocurrió— la nota de crédito no siempre sirve: la nota corrige una
/// operación real que cambió, y aquí no hubo operación ninguna.
///
/// La comunicación de baja es la única salida, y hasta ahora el motor sabía
/// generarla (ComunicacionBaja.cs existía completo) pero no tenía por dónde
/// pedirla. El código estaba escrito y no lo llamaba nadie.
///
///
/// QUÉ NO ENTRA POR AQUÍ, y son justo los dos que la gente intenta:
///
///   BOLETAS  se anulan informándolas en el resumen diario con estado 3.
///   GUÍAS    van por el canal REST de GRE, que es otro servicio.
///
/// ReglasBaja las rechaza con un mensaje que dice adónde ir.
///
///
/// EL PLAZO SON SIETE DÍAS desde la emisión, y no es negociable: pasados,
/// SUNAT rechaza con el error 2957 y solo queda la nota de crédito.
/// </summary>
public static class EndpointsBajas
{
    public static void MapearBajas(this WebApplication app)
    {
        var grupo = app.MapGroup("/v1").WithTags("Bajas");

        grupo.MapPost("/reversiones", (
            PeticionBaja peticion, ContextoEmisor emisor,
            RepositorioComprobantes comprobantes, RepositorioBajas bajas,
            CancellationToken ct) =>
            CrearAsync(peticion, TipoComunicacionBaja.Reversion,
                emisor, comprobantes, bajas, ct))
            .WithName("ComunicarReversion")
            .WithSummary("Revierte comprobantes de retención y percepción")
            .WithDescription(
                "Responde 202: el resumen de reversiones queda registrado, " +
                "pero todavía NO fue a SUNAT. Lo envía el worker, que después " +
                "consulta el ticket.\n\n" +
                "**Solo retenciones (20) y percepciones (40).** Las facturas y " +
                "sus notas se anulan con una comunicación de baja: " +
                "`POST /v1/bajas`. Meter una en la otra se rechaza con el " +
                "error 2308.\n\n" +
                "**Todos deben ser del mismo día de emisión:** el documento " +
                "lleva una sola fecha de referencia.\n\n" +
                "**No se comprueba plazo.** La norma lo cuenta desde que se le " +
                "avisó al proveedor o al cliente, una fecha que ocurre fuera " +
                "del sistema. Lo decide SUNAT.\n\n" +
                "El comprobante queda en ANULADO solo cuando SUNAT acepta el " +
                "resumen. Si lo rechaza, sigue siendo válido y se puede " +
                "volver a intentar.")
            .Produces<RespuestaBaja>(StatusCodes.Status202Accepted)
            .Produces<RespuestaError>(StatusCodes.Status400BadRequest)
            .Produces<RespuestaError>(StatusCodes.Status401Unauthorized);

        grupo.MapPost("/bajas", (
            PeticionBaja peticion, ContextoEmisor emisor,
            RepositorioComprobantes comprobantes, RepositorioBajas bajas,
            CancellationToken ct) =>
            CrearAsync(peticion, TipoComunicacionBaja.Baja,
                emisor, comprobantes, bajas, ct))
            .WithName("ComunicarBaja")
            .WithSummary("Da de baja facturas y notas ya aceptadas")
            .WithDescription(
                "Responde 202: la comunicación queda registrada, pero todavía " +
                "NO fue a SUNAT. La envía el worker, que después consulta el " +
                "ticket.\n\n" +
                "**Solo facturas (01) y sus notas (07, 08).** Las boletas se " +
                "anulan por el resumen diario y las guías por el canal de GRE.\n\n" +
                "**Todos los comprobantes deben ser del mismo día de emisión:** " +
                "una comunicación informa una sola fecha.\n\n" +
                "**Siete días de plazo** desde la emisión. Pasados, lo que " +
                "corresponde es una nota de crédito.\n\n" +
                "El comprobante queda en ANULADO solo cuando SUNAT acepta la " +
                "comunicación. Si la rechaza, sigue siendo válido y se puede " +
                "volver a intentar.")
            .Produces<RespuestaBaja>(StatusCodes.Status202Accepted)
            .Produces<RespuestaError>(StatusCodes.Status400BadRequest)
            .Produces<RespuestaError>(StatusCodes.Status401Unauthorized);

        grupo.MapGet("/bajas/{id:guid}", ObtenerAsync)
            .WithName("ConsultarBaja")
            .WithSummary("Estado de una comunicación de baja")
            .Produces<RespuestaBaja>()
            .Produces<RespuestaError>(StatusCodes.Status404NotFound);

        grupo.MapGet("/bajas", ListarAsync)
            .WithName("ListarBajas")
            .WithSummary("Lista las comunicaciones de baja del emisor")
            .Produces<IEnumerable<RespuestaBaja>>();
    }

    // ------------------------------------------------------------------ crear

    /// <summary>
    /// Las dos rutas entran aquí. Lo único que las separa es el tipo, y ese
    /// tipo decide qué documentos se admiten, qué serie les toca y si hay
    /// plazo — pero de eso ya se ocupa ReglasBaja, no este método.
    /// </summary>
    private static async Task<IResult> CrearAsync(
        PeticionBaja peticion,
        string tipo,
        ContextoEmisor emisor,
        RepositorioComprobantes comprobantes,
        RepositorioBajas bajas,
        CancellationToken ct)
    {
        var tenant = emisor.Exigir();

        // Con artículo, porque uno es femenino y el otro masculino: sin esto
        // salen frases como "esta resumen de reversiones".
        var queEs = TipoComunicacionBaja.ConArticulo(tipo);

        if (peticion.Comprobantes.Count == 0)
        {
            return Results.BadRequest(new RespuestaError(
                "Hay que decir qué comprobante se da de baja."));
        }

        // --- Buscar cada comprobante ------------------------------------------
        //
        // SE COMPRUEBA UNO A UNO Y SE INFORMA DE TODOS LOS QUE FALLEN, no del
        // primero. Quien manda cinco comprobantes y recibe "el F001-00000012
        // no existe" corrige ese, reenvía, y descubre que el siguiente
        // tampoco. Decirlo todo de una vez ahorra cuatro viajes.

        var encontrados = new List<(ResumenComprobante Comprobante, string Motivo)>();
        var problemas = new List<string>();

        foreach (var pedido in peticion.Comprobantes)
        {
            var motivo = string.IsNullOrWhiteSpace(pedido.Motivo)
                ? peticion.Motivo
                : pedido.Motivo;

            var encontrado = await comprobantes.BuscarPorNumeroAsync(
                tenant.Id, pedido.TipoDocumento, pedido.Serie, pedido.Correlativo, ct);

            if (encontrado is null)
            {
                problemas.Add(
                    $"{pedido.NumeroCompleto} no existe entre los comprobantes " +
                    $"de este emisor.");

                continue;
            }

            if (encontrado.Estado == "ANULADO")
            {
                problemas.Add($"{pedido.NumeroCompleto} ya esta anulado.");
                continue;
            }

            // NO SE PUEDE DAR DE BAJA LO QUE SUNAT NO ACEPTÓ.
            //
            // Un comprobante rechazado no existe para SUNAT: no hay nada que
            // anular. Y uno que todavía no viajó se corrige sin papeleo,
            // porque nadie fuera lo ha visto.
            if (encontrado.Estado is not ("ACEPTADO" or "ACEPTADO_CON_OBSERVACIONES"))
            {
                problemas.Add(
                    $"{pedido.NumeroCompleto} esta en estado {encontrado.Estado}. " +
                    $"Solo se anula lo que SUNAT acepto: si todavia no " +
                    $"viajo, corrigelo sin mas; si lo rechazo, no existe para " +
                    $"SUNAT y no hay nada que anular.");

                continue;
            }

            encontrados.Add((encontrado, motivo));
        }

        if (problemas.Count > 0)
        {
            return Results.BadRequest(new RespuestaError(
                $"No se puede emitir {queEs}.", string.Join(" ", problemas)));
        }

        // --- Una comunicación informa UNA SOLA FECHA --------------------------
        //
        // El XML lleva un único ReferenceDate, que es el día en que se
        // emitieron los comprobantes que anula. Mezclar dos días haría que
        // uno de ellos viajara con una fecha que no es la suya.

        // UNA COMUNICACION INFORMA UNA SOLA FECHA, sea RA o RR: el XML lleva
        // un unico ReferenceDate.
        var fechas = encontrados
            .Select(e => e.Comprobante.FechaEmision.Date)
            .Distinct()
            .OrderBy(f => f)
            .ToList();

        if (fechas.Count > 1)
        {
            return Results.BadRequest(new RespuestaError(
                "Los comprobantes son de dias distintos.",
                $"Este documento informa una sola fecha de emision, " +
                $"y aqui llegan {fechas.Count}: " +
                $"{string.Join(", ", fechas.Select(f => f.ToString("yyyy-MM-dd")))}. " +
                $"Manda una por cada dia."));
        }

        // --- Las reglas de SUNAT, antes de tocar la base ----------------------
        //
        // Se arma el documento de verdad y se le pasan las reglas que ya
        // existen: tipos admitidos, series, motivos y el plazo de siete días.
        // Validarlo aquí en vez de al generar el XML significa que el error
        // llega en la respuesta del POST, no en un log del worker media hora
        // después.

        var comunicacion = new ComunicacionBaja
        {
            Tipo = tipo,
            Emisor = new Emisor
            {
                Ruc = tenant.Ruc,
                RazonSocial = tenant.RazonSocial,
                NombreComercial = tenant.NombreComercial,
                Ubigeo = tenant.Ubigeo,
                Direccion = tenant.Direccion,
                Distrito = tenant.Distrito,
                Provincia = tenant.Provincia,
                Departamento = tenant.Departamento
            },
            FechaReferencia = fechas[0],
            FechaGeneracion = RelojPeru.Hoy,
            Lineas = encontrados.Select((e, indice) => new LineaBaja
            {
                Orden = indice + 1,
                TipoComprobante = e.Comprobante.TipoComprobante,
                Serie = e.Comprobante.Serie,
                Numero = e.Comprobante.Correlativo,
                Motivo = e.Motivo
            }).ToList()
        };

        var errores = ReglasBaja.Errores(comunicacion);

        if (errores.Count > 0)
        {
            return Results.BadRequest(new RespuestaError(
                $"SUNAT rechazaria {queEs}.",
                string.Join(" ", errores)));
        }

        // --- Guardar ----------------------------------------------------------

        var guardada = await bajas.CrearAsync(
            tenant.Id,
            tipo,
            fechas[0],
            encontrados.Select(e => (e.Comprobante.Id, e.Motivo)).ToList(),
            ct);

        if (guardada is null)
        {
            // Entre la comprobación y el guardado, algo cambió. Es raro y es
            // real: dos peticiones a la vez, o el worker terminando un envío.
            return Results.Conflict(new RespuestaError(
                "Los comprobantes ya no estan disponibles.",
                "Alguno cambio de estado o ya tiene una baja pedida mientras " +
                "se preparaba esta. Vuelve a consultarlos y reintenta."));
        }

        return Results.Accepted(
            $"/v1/bajas/{guardada.Id}", RespuestaBaja.Desde(guardada));
    }

    // --------------------------------------------------------------- consulta

    private static async Task<IResult> ObtenerAsync(
        Guid id,
        ContextoEmisor emisor,
        RepositorioBajas bajas,
        CancellationToken ct)
    {
        var tenant = emisor.Exigir();

        var baja = await bajas.ObtenerAsync(tenant.Id, id, ct);

        return baja is null
            ? Results.NotFound(new RespuestaError("No se encontro la comunicacion."))
            : Results.Ok(RespuestaBaja.Desde(baja));
    }

    private static async Task<IResult> ListarAsync(
        ContextoEmisor emisor,
        RepositorioBajas bajas,
        int? limite,
        CancellationToken ct)
    {
        var tenant = emisor.Exigir();

        var filas = await bajas.ListarAsync(
            tenant.Id, Math.Clamp(limite ?? 50, 1, 200), ct);

        return Results.Ok(filas.Select(RespuestaBaja.Desde));
    }
}

/// <summary>Lo que el emisor ve de una comunicación de baja.</summary>
public record RespuestaBaja(
    Guid Id,
    string Identificador,
    string Estado,
    int Comprobantes,
    DateTime FechaReferencia,
    string? Ticket,
    string? CodigoSunat,
    string? MensajeSunat)
{
    public static RespuestaBaja Desde(ResumenGuardado r) => new(
        r.Id, r.Identificador, r.Estado, r.Comprobantes,
        r.FechaReferencia, r.Ticket, r.CodigoSunat, r.MensajeSunat);
}