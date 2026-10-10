using System.ComponentModel.DataAnnotations;
using System.Text.Json;
using Facturacion.Cpe;
using Facturacion.Persistencia;

namespace Facturacion.Api;

/// <summary>
/// Un documento del detalle: la factura sobre la que se retuvo o percibió.
/// </summary>
public class DocumentoCobradoDto
{
    /// <summary>
    /// Catálogo 01. En retención: 01, 07, 08, 12, 20.
    /// En percepción: 01, 03, 07, 08, 12, 40.
    /// </summary>
    public string TipoDocumento { get; set; } = TipoComprobante.Factura;

    /// <summary>Serie y correlativo: "F001-00000123".</summary>
    [Required]
    public string Numero { get; set; } = "";

    [Required]
    public DateTime FechaEmision { get; set; }

    /// <summary>Lo que dice esa factura, en su moneda.</summary>
    [Range(0.01, double.MaxValue)]
    public decimal ImporteTotal { get; set; }

    public string Moneda { get; set; } = "PEN";

    /// <summary>
    /// Número del pago dentro de este comprobante. Si una factura se paga en
    /// tres veces y las tres van aquí, son 1, 2 y 3.
    /// </summary>
    public int NumeroPago { get; set; } = 1;

    [Required]
    public DateTime FechaPago { get; set; }

    /// <summary>
    /// Lo que se pagó o cobró, SIN la retención ni la percepción.
    /// Es la base sobre la que se aplica la tasa.
    /// </summary>
    [Range(0.01, double.MaxValue)]
    public decimal ImportePago { get; set; }

    /// <summary>Obligatorio si la moneda no es PEN.</summary>
    public TipoCambioDto? TipoCambio { get; set; }
}

/// <summary>El proveedor o el cliente. Siempre con RUC.</summary>
public class ContraparteDto
{
    [Required]
    public string Ruc { get; set; } = "";

    [Required]
    public string RazonSocial { get; set; } = "";

    public string NombreComercial { get; set; } = "";
    public string Ubigeo { get; set; } = "";
    public string Direccion { get; set; } = "";
    public string Urbanizacion { get; set; } = "";
    public string Provincia { get; set; } = "";
    public string Departamento { get; set; } = "";
    public string Distrito { get; set; } = "";
}

/// <summary>Petición para emitir un comprobante de retención.</summary>
public class PeticionRetencion
{
    /// <summary>Serie dada de alta para el tipo 20. Empieza por R: R001.</summary>
    [Required]
    public string Serie { get; set; } = "";

    public DateTime? FechaEmision { get; set; }

    /// <summary>Catálogo 23. "01" es el 3% y es el único vigente.</summary>
    public string Regimen { get; set; } = RegimenRetencion.Tasa3;

    /// <summary>El proveedor al que se le retuvo.</summary>
    [Required]
    public ContraparteDto Proveedor { get; set; } = new();

    /// <summary>Las facturas que se pagaron.</summary>
    [Required]
    public List<DocumentoCobradoDto> Documentos { get; set; } = [];

    public string Observaciones { get; set; } = "";

    public Dictionary<string, object>? Extra { get; set; }
}

/// <summary>Petición para emitir un comprobante de percepción.</summary>
public class PeticionPercepcion
{
    /// <summary>Serie dada de alta para el tipo 40. Empieza por P: P001.</summary>
    [Required]
    public string Serie { get; set; } = "";

    public DateTime? FechaEmision { get; set; }

    /// <summary>
    /// Catálogo 22. "01" venta interna (2%), "02" combustible (1%),
    /// "03" agente con tasa especial (0.5%).
    /// </summary>
    public string Regimen { get; set; } = RegimenPercepcion.VentaInterna;

    /// <summary>El cliente al que se le percibió.</summary>
    [Required]
    public ContraparteDto Cliente { get; set; } = new();

    [Required]
    public List<DocumentoCobradoDto> Documentos { get; set; } = [];

    public string Observaciones { get; set; } = "";

    public Dictionary<string, object>? Extra { get; set; }
}

/// <summary>
/// Respuesta de los dos. Los tres números son los que importan: cuánto se
/// movió, cuánto se retuvo o percibió, y cuánto quedó.
/// </summary>
public record RespuestaCre(
    Guid Id,
    string Numero,
    string Estado,
    decimal Total,
    decimal Neto,
    int Documentos,
    bool Duplicado);

/// <summary>
/// Los endpoints de retención y percepción.
///
/// Van juntos porque son el mismo documento con el signo cambiado, y
/// separarlos habría duplicado la misma validación en dos sitios que después
/// se desincronizan.
/// </summary>
public static class EndpointsRetencionPercepcion
{
    public static void MapearRetencionPercepcion(this WebApplication app)
    {
        // ------------------------------------------------------------ retención

        app.MapPost("/v1/retenciones", async (
            PeticionRetencion peticion,
            HttpContext contexto,
            ContextoEmisor emisor,
            RepositorioComprobantes repositorio,
            CancellationToken ct) =>
        {
            var tenant = emisor.Exigir();

            if (ValidarContrato(peticion, peticion.Documentos) is { } problema)
                return Results.BadRequest(problema);

            if (!RegimenRetencion.Existe(peticion.Regimen))
            {
                return Results.BadRequest(new RespuestaError(
                    "Régimen de retención inválido.",
                    $"'{peticion.Regimen}' no está en el catálogo 23. Los únicos " +
                    "son '01' (3%) y '02' (6%, derogado desde 2014)."));
            }

            var retencion = new ComprobanteRetencion
            {
                Serie = peticion.Serie,
                FechaEmision = peticion.FechaEmision ?? RelojPeru.Ahora,
                Regimen = peticion.Regimen,
                Observaciones = peticion.Observaciones,
                Emisor = ConstruirEmisor(tenant),
                Proveedor = ConstruirContraparte(peticion.Proveedor),
                Documentos = peticion.Documentos.Select(Convertir).ToList()
            };

            var errores = ReglasCre.Errores(retencion);

            if (errores.Count > 0)
            {
                return Results.BadRequest(new RespuestaError(
                    "Datos inválidos.", string.Join(" ", errores)));
            }

            var totales = CalculadoraCre.Calcular(retencion);

            return await Guardar(
                repositorio, tenant.Id, retencion, totales,
                peticion.Extra, contexto, ct);
        })
        .WithName("EmitirComprobanteRetencion")
        .WithTags("Comprobantes")
        .WithSummary("Emite un comprobante de retención (tipo 20)")
        .WithDescription(
            "Lo emite el **agente de retención** designado por SUNAT cuando le " +
            "paga a un proveedor: se queda el 3% y lo deposita al fisco a " +
            "cuenta del IGV de ese proveedor.\n\n" +
            "**No confundir con el cargo `62`** que ya existe en las facturas. " +
            "Aquel es lo que declara el proveedor en su propia factura; este es " +
            "lo que emite el agente. Son los dos lados de la misma operación.\n\n" +
            "El detalle no son productos: son **las facturas que se pagaron**, " +
            "cada una con su importe, su fecha de pago y su número de pago. Una " +
            "factura pagada en tres veces son tres líneas con números 1, 2 y 3.\n\n" +
            "**Todos los pagos tienen que ser del mismo mes** (error 2661), y la " +
            "retención se declara siempre en soles aunque la factura esté en " +
            "dólares — por eso el tipo de cambio es obligatorio ahí.\n\n" +
            "La tasa **no se envía**: sale del régimen, porque SUNAT la " +
            "recalcula contra el catálogo 23.")
        .Produces<RespuestaCre>(StatusCodes.Status202Accepted)
        .Produces<RespuestaError>(StatusCodes.Status400BadRequest);

        // ----------------------------------------------------------- percepción

        app.MapPost("/v1/percepciones", async (
            PeticionPercepcion peticion,
            HttpContext contexto,
            ContextoEmisor emisor,
            RepositorioComprobantes repositorio,
            CancellationToken ct) =>
        {
            var tenant = emisor.Exigir();

            if (ValidarContrato(peticion, peticion.Documentos) is { } problema)
                return Results.BadRequest(problema);

            if (!RegimenPercepcion.Existe(peticion.Regimen))
            {
                return Results.BadRequest(new RespuestaError(
                    "Régimen de percepción inválido.",
                    $"'{peticion.Regimen}' no está en el catálogo 22. Los únicos " +
                    "son '01' (venta interna, 2%), '02' (combustible, 1%) y " +
                    "'03' (agente con tasa especial, 0.5%)."));
            }

            var percepcion = new ComprobantePercepcion
            {
                Serie = peticion.Serie,
                FechaEmision = peticion.FechaEmision ?? RelojPeru.Ahora,
                Regimen = peticion.Regimen,
                Observaciones = peticion.Observaciones,
                Emisor = ConstruirEmisor(tenant),
                Cliente = ConstruirContraparte(peticion.Cliente),
                Documentos = peticion.Documentos.Select(Convertir).ToList()
            };

            var errores = ReglasCre.Errores(percepcion);

            if (errores.Count > 0)
            {
                return Results.BadRequest(new RespuestaError(
                    "Datos inválidos.", string.Join(" ", errores)));
            }

            var totales = CalculadoraCre.Calcular(percepcion);

            return await Guardar(
                repositorio, tenant.Id, percepcion, totales,
                peticion.Extra, contexto, ct);
        })
        .WithName("EmitirComprobantePercepcion")
        .WithTags("Comprobantes")
        .WithSummary("Emite un comprobante de percepción (tipo 40)")
        .WithDescription(
            "La retención al revés. Lo emite el **agente de percepción** cuando " +
            "le cobra a un cliente: le suma un 2% al total y lo deposita al " +
            "fisco a cuenta del IGV que ese cliente deberá al revender.\n\n" +
            "El cliente paga **más**, no menos. Es la única diferencia real con " +
            "el comprobante de retención.\n\n" +
            "El detalle son las facturas cobradas, con su importe y su fecha de " +
            "cobro. Todos los cobros tienen que ser del mismo mes.\n\n" +
            "La tasa sale del régimen: SUNAT la recalcula contra el catálogo 22.")
        .Produces<RespuestaCre>(StatusCodes.Status202Accepted)
        .Produces<RespuestaError>(StatusCodes.Status400BadRequest);
    }

    // ------------------------------------------------------------------ interno

    /// <summary>
    /// Lo que se valida igual en los dos. Devuelve null si todo está bien.
    /// </summary>
    private static RespuestaError? ValidarContrato(
        object peticion, List<DocumentoCobradoDto> documentos)
    {
        var errores = new List<ValidationResult>();

        if (!Validator.TryValidateObject(
                peticion, new ValidationContext(peticion), errores,
                validateAllProperties: true))
        {
            return new RespuestaError(
                "La petición no es válida.",
                string.Join(" ", errores.Select(e => e.ErrorMessage)));
        }

        if (documentos.Count == 0)
        {
            return new RespuestaError(
                "Hace falta al menos un documento.",
                "El detalle de este comprobante son las facturas sobre las que " +
                "se aplicó la retención o la percepción.");
        }

        var sinTipoCambio = documentos
            .Where(d => d.Moneda != "PEN" && d.TipoCambio is null)
            .Select(d => d.Numero)
            .ToList();

        if (sinTipoCambio.Count > 0)
        {
            return new RespuestaError(
                "Falta el tipo de cambio.",
                $"Estos documentos no están en soles y no lo traen: " +
                $"{string.Join(", ", sinTipoCambio)}. El importe retenido o " +
                "percibido se declara siempre en soles.");
        }

        return null;
    }

    private static Emisor ConstruirEmisor(TenantResuelto tenant) => new()
    {
        Ruc = tenant.Ruc,
        RazonSocial = tenant.RazonSocial,
        NombreComercial = tenant.NombreComercial,
        Ubigeo = tenant.Ubigeo,
        Direccion = tenant.Direccion,
        Distrito = tenant.Distrito,
        Provincia = tenant.Provincia,
        Departamento = tenant.Departamento
    };

    private static ContraparteCre ConstruirContraparte(ContraparteDto c) => new()
    {
        Ruc = c.Ruc,
        RazonSocial = c.RazonSocial,
        NombreComercial = c.NombreComercial,
        Ubigeo = c.Ubigeo,
        Direccion = c.Direccion,
        Urbanizacion = c.Urbanizacion,
        Provincia = c.Provincia,
        Departamento = c.Departamento,
        Distrito = c.Distrito
    };

    private static DocumentoCobrado Convertir(DocumentoCobradoDto d) => new()
    {
        TipoDocumento = d.TipoDocumento,
        Numero = d.Numero,
        FechaEmision = d.FechaEmision,
        ImporteTotal = d.ImporteTotal,
        Moneda = d.Moneda,
        NumeroPago = d.NumeroPago,
        FechaPago = d.FechaPago,
        ImportePago = d.ImportePago,
        TipoCambio = d.TipoCambio is null ? null : new TipoCambio
        {
            MonedaOrigen = d.TipoCambio.MonedaOrigen,
            MonedaDestino = d.TipoCambio.MonedaDestino,
            Tasa = d.TipoCambio.Tasa,
            Fecha = d.TipoCambio.Fecha ?? d.FechaPago
        }
    };

    private static async Task<IResult> Guardar(
        RepositorioComprobantes repositorio,
        Guid tenantId,
        ComprobanteBase comprobante,
        TotalesCre totales,
        Dictionary<string, object>? extra,
        HttpContext contexto,
        CancellationToken ct)
    {
        var idempotencyKey = contexto.Request.Headers["Idempotency-Key"].ToString();

        try
        {
            var guardado = await repositorio.CrearAsync(
                tenantId,
                comprobante,
                extraJson: extra is null ? null : JsonSerializer.Serialize(extra),
                idempotencyKey: string.IsNullOrWhiteSpace(idempotencyKey)
                    ? null
                    : idempotencyKey,
                ct: ct);

            var respuesta = new RespuestaCre(
                guardado.Id,
                guardado.NumeroCompleto,
                guardado.Estado,
                totales.Total,
                totales.Neto,
                totales.Lineas.Count,
                guardado.YaExistia);

            return guardado.YaExistia
                ? Results.Ok(respuesta)
                : Results.Accepted($"/v1/comprobantes/{guardado.Id}", respuesta);
        }
        catch (InvalidOperationException ex)
        {
            return Results.BadRequest(new RespuestaError("No se pudo emitir.", ex.Message));
        }
    }
}
