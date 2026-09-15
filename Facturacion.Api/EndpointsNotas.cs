using System.ComponentModel.DataAnnotations;
using System.Text.Json;
using Facturacion.Cpe;
using Facturacion.Persistencia;

namespace Facturacion.Api;

/// <summary>
/// Petición para emitir una nota de crédito o de débito.
///
/// Igual que en la factura, el emisor NO viene aquí: lo determina la clave
/// de acceso. Lo que sí viene, y es obligatorio, es a qué comprobante afecta.
/// </summary>
public class PeticionNota
{
    /// <summary>
    /// Serie de la nota.
    ///
    /// DEBE EMPEZAR CON LA MISMA LETRA del documento que modifica: F para
    /// notas sobre facturas, B para notas sobre boletas. SUNAT lo valida.
    /// </summary>
    [Required]
    public string Serie { get; set; } = "";

    public DateTime? FechaEmision { get; set; }

    public string Moneda { get; set; } = "PEN";

    public TipoCambioDto? TipoCambio { get; set; }

    /// <summary>
    /// Catálogo 09 para notas de crédito, catálogo 10 para las de débito.
    ///
    /// Crédito: 01 anulación, 02 error en el RUC, 03 corrección de descripción,
    /// 04 descuento global, 06 devolución total, 09 disminución en el valor.
    ///
    /// Débito: 01 interés por mora, 02 aumento en el valor, 03 penalidades.
    /// </summary>
    [Required]
    public string CodigoMotivo { get; set; } = "";

    /// <summary>Texto libre. Si se omite, se usa la descripción del catálogo.</summary>
    public string DescripcionMotivo { get; set; } = "";

    [Required]
    public DocumentoAfectadoDto Afectado { get; set; } = new();

    [Required]
    public ReceptorDto Receptor { get; set; } = new();

    [Required]
    [MinLength(1, ErrorMessage = "La nota necesita al menos una línea.")]
    public List<LineaDto> Lineas { get; set; } = [];

    public Dictionary<string, object>? Extra { get; set; }
}

/// <summary>El comprobante al que la nota afecta.</summary>
public class DocumentoAfectadoDto
{
    /// <summary>Catálogo 01. "01" factura, "03" boleta.</summary>
    public string TipoDocumento { get; set; } = TipoComprobante.Factura;

    /// <summary>Serie del documento original. Ej: F001</summary>
    [Required]
    public string Serie { get; set; } = "";

    /// <summary>Correlativo del documento original, sin ceros a la izquierda.</summary>
    [Range(1, int.MaxValue)]
    public int Correlativo { get; set; }

    public string NumeroCompleto => $"{Serie}-{Correlativo:D8}";
}

/// <summary>
/// Emisión de notas de crédito y de débito.
///
/// POR QUÉ SON IMPRESCINDIBLES: una vez que SUNAT acepta un comprobante, no
/// se puede modificar ni borrar. La nota es la única forma de corregir un
/// error, aplicar una devolución o cobrar intereses. Un servicio que solo
/// emite facturas no sirve para operar de verdad: basta un error de digitación
/// el primer día para bloquear al cliente.
/// </summary>
public static class EndpointsNotas
{
    public static void MapearNotas(this WebApplication app)
    {
        var grupo = app.MapGroup("/v1").WithTags("Notas");

        grupo.MapPost("/notas-credito", (
            PeticionNota peticion, HttpContext contexto, ContextoEmisor emisor,
            RepositorioComprobantes repositorio, CancellationToken ct) =>
            Emitir(peticion, contexto, emisor, repositorio, esCredito: true, ct))
            .WithSummary("Emite una nota de crédito")
            .WithDescription(
                "Disminuye o anula un comprobante ya emitido: devoluciones, " +
                "descuentos posteriores, errores en el monto.\\n\\n" +
                "La serie debe empezar con la misma letra del documento que " +
                "modifica: F para notas sobre facturas, B para boletas.")
            .Produces<RespuestaComprobante>(StatusCodes.Status202Accepted)
            .Produces<RespuestaError>(StatusCodes.Status400BadRequest);

        grupo.MapPost("/notas-debito", (
            PeticionNota peticion, HttpContext contexto, ContextoEmisor emisor,
            RepositorioComprobantes repositorio, CancellationToken ct) =>
            Emitir(peticion, contexto, emisor, repositorio, esCredito: false, ct))
            .WithSummary("Emite una nota de débito")
            .WithDescription(
                "Aumenta el importe de un comprobante ya emitido: intereses " +
                "por mora, penalidades, aumento de valor.")
            .Produces<RespuestaComprobante>(StatusCodes.Status202Accepted)
            .Produces<RespuestaError>(StatusCodes.Status400BadRequest);
    }

    private static async Task<IResult> Emitir(
        PeticionNota peticion,
        HttpContext contexto,
        ContextoEmisor emisor,
        RepositorioComprobantes repositorio,
        bool esCredito,
        CancellationToken ct)
    {
        var tenant = emisor.Exigir();

        // --- Validación del contrato ---

        var errores = new List<ValidationResult>();

        if (!Validator.TryValidateObject(
                peticion, new ValidationContext(peticion), errores, true))
        {
            return Results.BadRequest(new RespuestaError(
                "La petición no es válida.",
                string.Join(" ", errores.Select(e => e.ErrorMessage))));
        }

        if (peticion.Lineas.Count == 0)
            return Results.BadRequest(new RespuestaError(
                "La nota necesita al menos una línea."));

        if (peticion.Moneda != "PEN" && peticion.TipoCambio is null)
            return Results.BadRequest(new RespuestaError(
                "Falta el tipo de cambio.",
                "Las notas en moneda distinta de PEN deben declararlo."));

        // --- La serie debe corresponder al documento afectado ---
        //
        // SUNAT valida esto, y el error que devuelve no menciona la serie.
        // Comprobarlo aquí convierte un rechazo desconcertante en un mensaje
        // que dice exactamente qué corregir.

        var letraEsperada = peticion.Afectado.TipoDocumento == TipoComprobante.Boleta
            ? 'B' : 'F';

        if (peticion.Serie.Length != 4 ||
            char.ToUpperInvariant(peticion.Serie[0]) != letraEsperada)
        {
            return Results.BadRequest(new RespuestaError(
                "La serie de la nota no corresponde al documento que modifica.",
                $"Como afecta a {(letraEsperada == 'B' ? "una boleta" : "una factura")}, " +
                $"su serie debe empezar con '{letraEsperada}' y tener 4 caracteres. " +
                $"Recibido: '{peticion.Serie}'."));
        }

        // --- El documento afectado tiene que existir ---
        //
        // Emitir una nota sobre algo inexistente termina en rechazo de SUNAT,
        // y para entonces ya se quemó un correlativo de la serie de notas.

        var afectado = await repositorio.BuscarPorNumeroAsync(
            tenant.Id,
            peticion.Afectado.TipoDocumento,
            peticion.Afectado.Serie,
            peticion.Afectado.Correlativo,
            ct);

        if (afectado is null)
        {
            return Results.BadRequest(new RespuestaError(
                "El comprobante que la nota modifica no existe.",
                $"No se encontró {peticion.Afectado.NumeroCompleto} entre los " +
                "comprobantes de este emisor."));
        }

        if (afectado.Estado is not ("ACEPTADO" or "ACEPTADO_CON_OBSERVACIONES"))
        {
            // Una nota sobre un comprobante que SUNAT no aceptó no tiene
            // sentido: no hay nada que corregir todavía.
            return Results.BadRequest(new RespuestaError(
                "El comprobante que la nota modifica todavía no fue aceptado.",
                $"{afectado.NumeroCompleto} está en estado {afectado.Estado}. " +
                "Espera a que SUNAT lo acepte, o corrígelo si fue rechazado: " +
                "un comprobante rechazado no existe para SUNAT y no hay nada " +
                "que anular."));
        }

        // --- Construcción ---

        ComprobanteBase nota = esCredito
            ? ConstruirCredito(peticion, tenant)
            : ConstruirDebito(peticion, tenant);

        // --- Persistencia ---

        var idempotencyKey = contexto.Request.Headers["Idempotency-Key"].ToString();

        try
        {
            var guardado = await repositorio.CrearAsync(
                tenant.Id,
                nota,
                extraJson: peticion.Extra is null
                    ? null
                    : JsonSerializer.Serialize(peticion.Extra),
                idempotencyKey: string.IsNullOrWhiteSpace(idempotencyKey)
                    ? null : idempotencyKey,
                ct: ct);

            var respuesta = RespuestaComprobante.Desde(guardado, peticion.Moneda);

            return guardado.YaExistia
                ? Results.Ok(respuesta)
                : Results.Accepted($"/v1/comprobantes/{guardado.Id}", respuesta);
        }
        catch (InvalidOperationException ex)
        {
            return Results.BadRequest(new RespuestaError("No se pudo emitir.", ex.Message));
        }
    }

    // ------------------------------------------------------------------ armado

    private static NotaCredito ConstruirCredito(PeticionNota p, TenantResuelto t) => new()
    {
        Serie = p.Serie.ToUpperInvariant(),
        FechaEmision = p.FechaEmision ?? DateTime.Now,
        Moneda = p.Moneda,
        TipoCambio = MapearTipoCambio(p.TipoCambio),
        CodigoMotivo = p.CodigoMotivo,
        DescripcionMotivo = p.DescripcionMotivo,
        Afectado = new DocumentoAfectado
        {
            Numero = p.Afectado.NumeroCompleto,
            TipoDocumento = p.Afectado.TipoDocumento
        },
        Emisor = MapearEmisor(t),
        Receptor = MapearReceptor(p.Receptor),
        Lineas = MapearLineas(p.Lineas)
    };

    private static NotaDebito ConstruirDebito(PeticionNota p, TenantResuelto t) => new()
    {
        Serie = p.Serie.ToUpperInvariant(),
        FechaEmision = p.FechaEmision ?? DateTime.Now,
        Moneda = p.Moneda,
        TipoCambio = MapearTipoCambio(p.TipoCambio),
        CodigoMotivo = p.CodigoMotivo,
        DescripcionMotivo = p.DescripcionMotivo,
        Afectado = new DocumentoAfectado
        {
            Numero = p.Afectado.NumeroCompleto,
            TipoDocumento = p.Afectado.TipoDocumento
        },
        Emisor = MapearEmisor(t),
        Receptor = MapearReceptor(p.Receptor),
        Lineas = MapearLineas(p.Lineas)
    };

    private static Emisor MapearEmisor(TenantResuelto t) => new()
    {
        Ruc = t.Ruc,
        RazonSocial = t.RazonSocial,
        NombreComercial = t.NombreComercial,
        Ubigeo = t.Ubigeo,
        Direccion = t.Direccion,
        Distrito = t.Distrito,
        Provincia = t.Provincia,
        Departamento = t.Departamento
    };

    private static Receptor MapearReceptor(ReceptorDto r) => new()
    {
        TipoDocumento = r.TipoDocumento,
        NumeroDocumento = r.NumeroDocumento,
        RazonSocial = r.RazonSocial,
        Direccion = r.Direccion
    };

    private static List<LineaComprobante> MapearLineas(List<LineaDto> lineas) =>
        lineas.Select((l, indice) => new LineaComprobante
        {
            Numero = indice + 1,
            CodigoProducto = l.CodigoProducto,
            Descripcion = l.Descripcion,
            UnidadMedida = l.UnidadMedida,
            Cantidad = l.Cantidad,
            ValorUnitario = l.ValorUnitario,
            DescuentoPorcentaje = l.DescuentoPorcentaje,
            TipoAfectacionIgv = l.TipoAfectacionIgv,
            PorcentajeIgv = l.PorcentajeIgv
        }).ToList();

    private static TipoCambio? MapearTipoCambio(TipoCambioDto? dto) =>
        dto is null ? null : new TipoCambio
        {
            MonedaOrigen = dto.MonedaOrigen,
            MonedaDestino = dto.MonedaDestino,
            Tasa = dto.Tasa,
            Fecha = dto.Fecha ?? DateTime.Today
        };
}
