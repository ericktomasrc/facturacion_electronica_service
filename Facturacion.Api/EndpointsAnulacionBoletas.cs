using Facturacion.Cpe;
using Facturacion.Persistencia;

namespace Facturacion.Api;

/// <summary>Petición para anular una boleta.</summary>
public class PeticionAnularBoleta
{
    /// <summary>
    /// Por qué se anula.
    ///
    /// SUNAT no lo exige en el resumen —el estado 3 no lleva campo de
    /// motivo—, pero se guarda igual: dentro de un año, cuando alguien
    /// pregunte por qué esa boleta desapareció, el número de estado no va a
    /// explicárselo.
    /// </summary>
    public string Motivo { get; set; } = "";
}

/// <summary>
/// Anulación de boletas.
///
/// POR QUÉ NO VALE LA COMUNICACIÓN DE BAJA, que es lo primero que uno
/// intenta: SUNAT no admite boletas en una RA (error 2308). Las boletas no
/// se comunican de una en una, así que tampoco se anulan de una en una.
///
/// Se anulan VOLVIENDO A INFORMARLAS en un resumen diario, esta vez con el
/// estado 3 del catálogo 19. Es el mismo documento que las declaró, con otra
/// intención dentro.
///
/// Eso hace que esta ruta funcione distinto a todas las demás: no envía
/// nada. Solo deja la boleta marcada. El worker la recoge en el siguiente
/// ciclo, la mete en un resumen propio y ese resumen es el que viaja.
///
/// La respuesta es 202 y no 200 por eso mismo: queda pedido, no hecho.
///
///
/// EL PLAZO SON SIETE DÍAS desde la emisión de la boleta.
///
/// Es el mismo que tiene el resumen para comunicarla, y la razón es la
/// misma: pasado ese plazo SUNAT ya no admite un resumen que hable de ese
/// día. Una anulación tardía se rechazaría, y al viajar en grupo se llevaría
/// por delante las demás anulaciones del mismo envío.
/// </summary>
public static class EndpointsAnulacionBoletas
{
    /// <summary>Días desde la emisión para poder anular una boleta.</summary>
    private const int DiasParaAnular = 7;

    public static void MapearAnulacionBoletas(this WebApplication app)
    {
        app.MapPost("/v1/comprobantes/{id:guid}/anular", AnularAsync)
            .WithName("AnularBoleta")
            .WithTags("Comprobantes")
            .WithSummary("Anula una boleta ya comunicada")
            .WithDescription(
                "Responde 202: la boleta queda MARCADA para anularse, pero " +
                "todavía no fue a SUNAT.\n\n" +
                "El worker la recoge en el siguiente ciclo y la informa en un " +
                "resumen diario con estado 3, que es el único mecanismo que " +
                "SUNAT admite para anular una boleta. La boleta pasa a " +
                "ANULADO cuando ese resumen es aceptado.\n\n" +
                "**Solo boletas y sus notas** (serie que empieza por B). Las " +
                "facturas se anulan con una comunicación de baja: " +
                "`POST /v1/bajas`.\n\n" +
                "**Siete días de plazo** desde la emisión de la boleta.\n\n" +
                "Si SUNAT rechaza el resumen, la boleta sigue siendo válida y " +
                "la anulación se cancela: hay que volver a pedirla.")
            .Produces<RespuestaAnulacion>(StatusCodes.Status202Accepted)
            .Produces<RespuestaError>(StatusCodes.Status400BadRequest)
            .Produces<RespuestaError>(StatusCodes.Status404NotFound)
            .Produces<RespuestaError>(StatusCodes.Status401Unauthorized);
    }

    private static async Task<IResult> AnularAsync(
        Guid id,
        PeticionAnularBoleta peticion,
        ContextoEmisor emisor,
        RepositorioComprobantes comprobantes,
        RepositorioBajas bajas,
        CancellationToken ct)
    {
        var tenant = emisor.Exigir();

        var comprobante = await comprobantes.ObtenerAsync(tenant.Id, id, ct);

        if (comprobante is null)
        {
            return Results.NotFound(new RespuestaError(
                "No se encontro el comprobante."));
        }

        // --- Tiene que ser de las que viajan por resumen ----------------------
        //
        // LA SERIE ES LO QUE MANDA, no el tipo. Una nota de crédito es "07"
        // tanto si corrige una factura como si corrige una boleta, y cada una
        // se anula por un camino distinto. Lo que las separa es la letra de
        // la serie: F para las de factura, B para las de boleta.

        var serie = comprobante.Serie ?? "";

        if (serie.Length == 0 || char.ToUpperInvariant(serie[0]) != 'B')
        {
            return Results.BadRequest(new RespuestaError(
                "Esta ruta es solo para boletas.",
                $"{comprobante.NumeroCompleto} no lleva serie de boleta. Las " +
                $"facturas y sus notas se anulan con una comunicacion de baja: " +
                $"POST /v1/bajas. SUNAT no admite boletas ahi, ni facturas aqui."));
        }

        if (comprobante.Estado == "ANULADO")
        {
            return Results.BadRequest(new RespuestaError(
                "Ya esta anulado.",
                $"{comprobante.NumeroCompleto} ya figura como ANULADO."));
        }

        // --- Solo se anula lo que SUNAT aceptó --------------------------------
        //
        // Una boleta que todavía no viajó no hace falta anularla: no ha
        // salido de aquí y nadie la ha visto. Y una rechazada no existe para
        // SUNAT, así que no hay nada que deshacer.

        if (comprobante.Estado is not ("ACEPTADO" or "ACEPTADO_CON_OBSERVACIONES"))
        {
            return Results.BadRequest(new RespuestaError(
                "La boleta todavia no esta comunicada.",
                $"{comprobante.NumeroCompleto} esta en estado " +
                $"{comprobante.Estado}. Solo se anula lo que SUNAT acepto: si " +
                $"aun no viajo, espera a que su resumen se cierre; si lo " +
                $"rechazo, no existe para SUNAT y no hay nada que anular."));
        }

        // --- El plazo ---------------------------------------------------------

        var limite = comprobante.FechaEmision.Date.AddDays(DiasParaAnular);
        var hoy = RelojPeru.Hoy;

        if (hoy > limite)
        {
            return Results.BadRequest(new RespuestaError(
                "Se paso el plazo para anular.",
                $"{comprobante.NumeroCompleto} se emitio el " +
                $"{comprobante.FechaEmision:yyyy-MM-dd} y el plazo vencio el " +
                $"{limite:yyyy-MM-dd}; hoy es {hoy:yyyy-MM-dd}. SUNAT ya no " +
                $"admite un resumen que hable de ese dia. Lo que corresponde " +
                $"es una nota de credito sobre la boleta."));
        }

        // --- El motivo --------------------------------------------------------
        //
        // SUNAT no lo pide. Se exige aquí igualmente, y a sabiendas: es el
        // único momento en que alguien sabe por qué se está anulando, y el
        // único sitio donde ese porqué se puede guardar. Un campo vacío ahora
        // es una pregunta sin respuesta dentro de un año.

        var motivo = (peticion.Motivo ?? "").Trim();

        if (motivo.Length == 0)
        {
            return Results.BadRequest(new RespuestaError(
                "Falta el motivo.",
                "SUNAT no lo exige, pero aqui si: es lo unico que va a " +
                "explicar dentro de un año por que esta boleta desaparecio."));
        }

        if (motivo.Length > 500)
        {
            return Results.BadRequest(new RespuestaError(
                "El motivo es demasiado largo.",
                $"Llegaron {motivo.Length} caracteres y el limite son 500."));
        }

        // --- Marcarla ---------------------------------------------------------

        var marcada = await bajas.MarcarBoletaParaAnularAsync(
            tenant.Id, id, motivo, ct);

        if (!marcada)
        {
            return Results.Conflict(new RespuestaError(
                "La boleta ya no esta disponible.",
                "O ya tiene una anulacion pedida, o cambio de estado mientras " +
                "se preparaba esta. Vuelve a consultarla."));
        }

        return Results.Accepted(
            $"/v1/comprobantes/{id}",
            new RespuestaAnulacion(
                id,
                comprobante.NumeroCompleto,
                "PENDIENTE",
                motivo,
                "La boleta quedo marcada. Viajara en el proximo resumen con " +
                "estado 3, y pasara a ANULADO cuando SUNAT lo acepte."));
    }
}

/// <summary>Lo que el emisor ve al pedir una anulación.</summary>
public record RespuestaAnulacion(
    Guid Id,
    string Numero,
    string Anulacion,
    string Motivo,
    string Detalle);
