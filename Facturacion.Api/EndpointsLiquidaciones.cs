using System.ComponentModel.DataAnnotations;
using System.Text.Json;
using Facturacion.Cpe;
using Facturacion.Persistencia;

namespace Facturacion.Api;

/// <summary>
/// Petición para emitir una liquidación de compra.
///
/// POR QUÉ NO REUTILIZA PeticionComprobante: porque no hay receptor. El que
/// hace de contraparte es el vendedor, y lleva datos que un receptor no tiene
/// —dirección completa, ubigeo, condición del domicilio— y no puede tener el
/// que un receptor sí tiene: RUC.
///
/// Mezclarlos habría obligado a poner la mitad de los campos como opcionales
/// en los dos documentos, y entonces ninguno de los dos valida nada.
/// </summary>
public class PeticionLiquidacion
{
    /// <summary>Serie ya dada de alta para este emisor. Empieza por L: L001.</summary>
    [Required]
    public string Serie { get; set; } = "";

    /// <summary>Si no se indica, se usa la fecha de hoy.</summary>
    public DateTime? FechaEmision { get; set; }

    /// <summary>ISO 4217. Casi siempre PEN.</summary>
    public string Moneda { get; set; } = "PEN";

    /// <summary>
    /// Catálogo 51. "0501" compra interna, "0502" anticipos.
    /// El "0503" (oro) no está implementado.
    /// </summary>
    public string TipoOperacion { get; set; } = TipoOperacionLc.CompraInterna;

    [Required]
    public VendedorDto Vendedor { get; set; } = new();

    [Required]
    public LugarDto Lugar { get; set; } = new();

    [Required]
    public List<LineaDto> Lineas { get; set; } = [];

    /// <summary>
    /// Si se retiene renta. Por defecto sí.
    ///
    /// Solo se apaga cuando el vendedor tiene constancia de no retención.
    /// </summary>
    public bool RetieneRenta { get; set; } = true;

    /// <summary>
    /// Tasa de la retención, en porcentaje. Si no se envía, la vigente.
    /// </summary>
    public decimal? TasaRetencionRenta { get; set; }

    public TipoCambioDto? TipoCambio { get; set; }

    /// <summary>Datos del cliente que viajan con el comprobante sin tocar el XML.</summary>
    public Dictionary<string, object>? Extra { get; set; }
}

/// <summary>
/// El vendedor: la persona natural a la que se le compra.
/// </summary>
public class VendedorDto
{
    /// <summary>
    /// Catálogo 06, y solo tres: "1" DNI, "4" carnet de extranjería,
    /// "7" pasaporte. **El RUC no vale** (error 2800).
    /// </summary>
    public string TipoDocumento { get; set; } = TipoDocIdentidad.Dni;

    [Required]
    public string NumeroDocumento { get; set; } = "";

    /// <summary>Apellidos y nombres.</summary>
    [Required]
    public string Nombres { get; set; } = "";

    /// <summary>Dónde vive. Obligatorio (error 2452).</summary>
    [Required]
    public string Direccion { get; set; } = "";

    /// <summary>Ubigeo de seis dígitos, catálogo 13. Obligatorio (error 2453).</summary>
    [Required]
    public string Ubigeo { get; set; } = "";

    public string Distrito { get; set; } = "";
    public string Provincia { get; set; } = "";
    public string Departamento { get; set; } = "";

    /// <summary>
    /// Catálogo 60: "01" punto de venta, "02" producción, "03" extracción,
    /// "04" explotación, "05" otros. Obligatorio (error 2456).
    /// </summary>
    public string CondicionDomicilio { get; set; } = TipoDireccion.Otros;
}

/// <summary>
/// Dónde se hizo la compra. Es otra dirección, distinta del domicilio del
/// vendedor: el agricultor vive en el pueblo y la chacra está a diez
/// kilómetros.
/// </summary>
public class LugarDto
{
    [Required]
    public string Direccion { get; set; } = "";

    [Required]
    public string Ubigeo { get; set; } = "";

    public string Distrito { get; set; } = "";
    public string Provincia { get; set; } = "";
    public string Departamento { get; set; } = "";

    /// <summary>Catálogo 60. Lo habitual en agricultura es "02" (producción).</summary>
    public string Condicion { get; set; } = TipoDireccion.Produccion;
}

/// <summary>Los totales de una liquidación, que no son los de una factura.</summary>
public record RespuestaLiquidacion(
    Guid Id,
    string Numero,
    string Estado,
    decimal ValorCompra,
    decimal Igv,
    decimal Subtotal,
    decimal Retencion,
    decimal ImporteAPagar,
    string Moneda,
    bool Duplicado);

/// <summary>
/// El endpoint de la liquidación de compra.
///
/// VA APARTE DE /v1/comprobantes a propósito. Ese endpoint pide receptor, y
/// una liquidación no tiene; meterlas en el mismo sitio significaría un montón
/// de "si el tipo es 04 entonces no valides esto", que es justo la clase de
/// código que se rompe cuando alguien añade el siguiente documento.
/// </summary>
public static class EndpointsLiquidaciones
{
    public static void MapearLiquidaciones(this WebApplication app)
    {
        app.MapPost("/v1/liquidaciones", async (
            PeticionLiquidacion peticion,
            HttpContext contexto,
            ContextoEmisor emisor,
            RepositorioComprobantes repositorio,
            ILogger<PeticionLiquidacion> registro,
            CancellationToken ct) =>
        {
            var tenant = emisor.Exigir();

            // --- Validación del contrato ---

            var errores = new List<ValidationResult>();

            if (!Validator.TryValidateObject(
                    peticion, new ValidationContext(peticion), errores,
                    validateAllProperties: true))
            {
                return Results.BadRequest(new RespuestaError(
                    "La petición no es válida.",
                    string.Join(" ", errores.Select(e => e.ErrorMessage))));
            }

            if (peticion.Lineas.Count == 0)
            {
                return Results.BadRequest(new RespuestaError(
                    "La liquidación necesita al menos una línea."));
            }

            if (peticion.Moneda != "PEN" && peticion.TipoCambio is null)
            {
                return Results.BadRequest(new RespuestaError(
                    "Falta el tipo de cambio.",
                    "Los comprobantes en moneda distinta de PEN deben declararlo."));
            }

            // --- Construcción ---

            var liquidacion = Construir(peticion, tenant);

            // --- Las reglas propias del documento ---

            var problemas = ReglasLiquidacion.Errores(liquidacion);

            if (problemas.Count > 0)
            {
                return Results.BadRequest(new RespuestaError(
                    "Datos inválidos.", string.Join(" ", problemas)));
            }

            // El plazo es de UN día, la mitad de corto que el de una boleta.
            foreach (var aviso in ReglasFechaEmision.Avisos(liquidacion)
                         .Concat(ReglasLiquidacion.Avisos(liquidacion)))
                registro.LogWarning("{Serie}: {Aviso}", peticion.Serie, aviso);

            // --- Persistencia ---

            var idempotencyKey = contexto.Request.Headers["Idempotency-Key"].ToString();

            try
            {
                var guardado = await repositorio.CrearAsync(
                    tenant.Id,
                    liquidacion,
                    extraJson: peticion.Extra is null
                        ? null
                        : JsonSerializer.Serialize(peticion.Extra),
                    idempotencyKey: string.IsNullOrWhiteSpace(idempotencyKey)
                        ? null
                        : idempotencyKey,
                    ct: ct);

                var totales = CalculadoraLiquidacion.Calcular(liquidacion);

                var respuesta = new RespuestaLiquidacion(
                    guardado.Id,
                    guardado.NumeroCompleto,
                    guardado.Estado,
                    totales.ValorVenta,
                    totales.Igv,
                    totales.Subtotal,
                    totales.Retencion,
                    totales.ImporteAPagar,
                    peticion.Moneda,
                    guardado.YaExistia);

                return guardado.YaExistia
                    ? Results.Ok(respuesta)
                    : Results.Accepted($"/v1/comprobantes/{guardado.Id}", respuesta);
            }
            catch (InvalidOperationException ex)
            {
                // Serie inexistente o inactiva. Aquí el aviso más probable es
                // que nadie haya dado de alta la serie L001 para el tipo 04.
                return Results.BadRequest(new RespuestaError(
                    "No se pudo emitir.", ex.Message));
            }
        })
        .WithName("EmitirLiquidacionCompra")
        .WithTags("Comprobantes")
        .WithSummary("Emite una liquidación de compra")
        .WithDescription(
            "La factura que emite **el comprador** cuando el vendedor no puede " +
            "emitir ninguna: agricultores, pescadores artesanales, " +
            "recolectores — personas naturales sin RUC que venden producto " +
            "primario.\n\n" +
            "Responde 202: queda registrada, pero todavía NO fue a SUNAT.\n\n" +
            "**El vendedor no puede tener RUC.** Solo DNI (`1`), carnet de " +
            "extranjería (`4`) o pasaporte (`7`). Si tuviera RUC emitiría su " +
            "propia factura.\n\n" +
            "**Hacen falta dos direcciones:** el domicilio del vendedor y el " +
            "lugar donde se hizo la compra, cada una con ubigeo de seis " +
            "dígitos y con su código del catálogo 60.\n\n" +
            "**El importe a pagar es el número más pequeño del documento.** " +
            "Al valor de compra se le suma el IGV —que asume el comprador como " +
            "crédito fiscal— y después se le restan el IGV y la retención de " +
            "renta del 1.5%. De 6 000 de café, el vendedor cobra 5 910.\n\n" +
            "**Plazo: un día.** Es la mitad que el de una boleta. Pasado, " +
            "SUNAT rechaza con el error 2108.\n\n" +
            "Tres cosas que solo comprueba SUNAT y que salen en el CDR: que el " +
            "emisor no sea NRUS (2463), que el DNI exista en RENIEC y no sea " +
            "de un menor o un fallecido (2450, 2460, 2461), y que el vendedor " +
            "no haya pasado de **75 UIT** de ventas en el año (2451).")
        .Produces<RespuestaLiquidacion>(StatusCodes.Status202Accepted)
        .Produces<RespuestaLiquidacion>(StatusCodes.Status200OK)
        .Produces<RespuestaError>(StatusCodes.Status400BadRequest)
        .Produces<RespuestaError>(StatusCodes.Status401Unauthorized);
    }

    // ------------------------------------------------------------------ interno

    /// <summary>
    /// Arma la liquidación. El emisor sale del tenant, nunca de la petición.
    /// </summary>
    private static LiquidacionCompra Construir(
        PeticionLiquidacion peticion, TenantResuelto tenant) =>
        new()
        {
            Serie = peticion.Serie,
            FechaEmision = peticion.FechaEmision ?? RelojPeru.Ahora,
            Moneda = peticion.Moneda,
            TipoOperacion = peticion.TipoOperacion,

            RetieneRenta = peticion.RetieneRenta,
            TasaRetencionRenta =
                peticion.TasaRetencionRenta ?? RetencionRenta.TasaVigente,

            TipoCambio = peticion.TipoCambio is null ? null : new TipoCambio
            {
                MonedaOrigen = peticion.TipoCambio.MonedaOrigen,
                MonedaDestino = peticion.TipoCambio.MonedaDestino,
                Tasa = peticion.TipoCambio.Tasa,
                Fecha = peticion.TipoCambio.Fecha ?? RelojPeru.Hoy
            },

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

            Vendedor = new Vendedor
            {
                TipoDocumento = peticion.Vendedor.TipoDocumento,
                NumeroDocumento = peticion.Vendedor.NumeroDocumento,
                Nombres = peticion.Vendedor.Nombres,
                Direccion = peticion.Vendedor.Direccion,
                Ubigeo = peticion.Vendedor.Ubigeo,
                Distrito = peticion.Vendedor.Distrito,
                Provincia = peticion.Vendedor.Provincia,
                Departamento = peticion.Vendedor.Departamento,
                CondicionDomicilio = peticion.Vendedor.CondicionDomicilio
            },

            Lugar = new LugarOperacion
            {
                Direccion = peticion.Lugar.Direccion,
                Ubigeo = peticion.Lugar.Ubigeo,
                Distrito = peticion.Lugar.Distrito,
                Provincia = peticion.Lugar.Provincia,
                Departamento = peticion.Lugar.Departamento,
                Condicion = peticion.Lugar.Condicion
            },

            Lineas = peticion.Lineas.Select((l, indice) => new LineaComprobante
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
                    ?? AfectacionIgv.TasaPorDefecto(l.TipoAfectacionIgv),
                AfectoIcbper = l.AfectoIcbper,
                IcbperUnitario = l.IcbperUnitario,
                SistemaIsc = l.SistemaIsc,
                TasaIsc = l.TasaIsc
            }).ToList()
        };
}
