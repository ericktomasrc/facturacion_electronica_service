using System.ComponentModel.DataAnnotations;
using Facturacion.Cpe;
using Facturacion.Persistencia;

namespace Facturacion.Api;

/// <summary>
/// Petición para emitir un comprobante.
///
/// FÍJATE EN LO QUE **NO** ESTÁ: no hay datos del emisor ni correlativo.
///
///   El emisor lo determina la clave de acceso. Que el cliente declarara su
///   propio RUC sería como dejar que el usuario diga quién es en vez de
///   autenticarse.
///
///   El correlativo lo asigna la base. Aceptarlo desde afuera abriría la
///   puerta a duplicados y saltos de numeración.
/// </summary>
public class PeticionComprobante
{
    /// <summary>Catálogo 01. "01" factura, "03" boleta.</summary>
    [Required]
    public string Tipo { get; set; } = TipoComprobante.Factura;

    /// <summary>Serie ya dada de alta para este emisor. Ej: F001</summary>
    [Required]
    public string Serie { get; set; } = "";

    /// <summary>Si no se indica, se usa la fecha de hoy.</summary>
    public DateTime? FechaEmision { get; set; }

    public string Moneda { get; set; } = "PEN";

    /// <summary>"Contado" o "Credito".</summary>
    public string FormaPago { get; set; } = "Contado";

    /// <summary>Descuento sobre el comprobante completo, en porcentaje.</summary>
    public decimal DescuentoGlobalPorcentaje { get; set; }

    /// <summary>Obligatorio cuando la moneda no es PEN.</summary>
    public TipoCambioDto? TipoCambio { get; set; }

    [Required]
    public ReceptorDto Receptor { get; set; } = new();

    [Required]
    [MinLength(1, ErrorMessage = "El comprobante necesita al menos una línea.")]
    public List<LineaDto> Lineas { get; set; } = [];

    /// <summary>
    /// Campos propios de la empresa. Se guardan tal cual y se pueden consultar
    /// después, pero NUNCA viajan a SUNAT.
    /// </summary>
    public Dictionary<string, object>? Extra { get; set; }
}

public class ReceptorDto
{
    /// <summary>Catálogo 06. "6" RUC, "1" DNI.</summary>
    public string TipoDocumento { get; set; } = TipoDocIdentidad.Ruc;

    [Required]
    public string NumeroDocumento { get; set; } = "";

    [Required]
    public string RazonSocial { get; set; } = "";

    public string Direccion { get; set; } = "";
}

public class LineaDto
{
    public string CodigoProducto { get; set; } = "";

    [Required]
    public string Descripcion { get; set; } = "";

    /// <summary>Catálogo 65. "NIU" unidad, "ZZ" servicio.</summary>
    public string UnidadMedida { get; set; } = "NIU";

    [Range(0.000001, double.MaxValue, ErrorMessage = "La cantidad debe ser mayor que cero.")]
    public decimal Cantidad { get; set; }

    /// <summary>Valor unitario SIN IGV y SIN descuento.</summary>
    [Range(0, double.MaxValue)]
    public decimal ValorUnitario { get; set; }

    public decimal DescuentoPorcentaje { get; set; }

    /// <summary>Catálogo 07. "10" gravado, "20" exonerado, "30" inafecto.</summary>
    public string TipoAfectacionIgv { get; set; } = AfectacionIgv.GravadoOperacionOnerosa;

    public decimal PorcentajeIgv { get; set; } = 18m;
}

public class TipoCambioDto
{
    public string MonedaOrigen { get; set; } = "USD";
    public string MonedaDestino { get; set; } = "PEN";
    public decimal Tasa { get; set; }
    public DateTime? Fecha { get; set; }
}

/// <summary>
/// Respuesta al aceptar un comprobante.
///
/// Se devuelve 202 Accepted, no 201 Created, y la diferencia importa: el
/// comprobante quedó registrado, pero TODAVÍA NO fue a SUNAT. Responder 201
/// daría a entender que ya está emitido, y ese malentendido termina en un
/// cliente que entrega una factura que SUNAT después rechazó.
/// </summary>
public record RespuestaComprobante(
    Guid Id,
    string Numero,
    string Estado,
    decimal ImporteTotal,
    string Moneda,
    bool Duplicado)
{
    public static RespuestaComprobante Desde(ComprobanteGuardado g, string moneda) =>
        new(g.Id, g.NumeroCompleto, g.Estado, g.ImporteTotal, moneda, g.YaExistia);
}

/// <summary>Estado de un comprobante.</summary>
public record RespuestaEstado(
    Guid Id,
    string Numero,
    string Tipo,
    DateTime FechaEmision,
    string Moneda,
    decimal ImporteTotal,
    string Estado,
    string? CodigoSunat,
    string? MensajeSunat,
    string? Ticket,
    DateTime CreadoEn)
{
    public static RespuestaEstado Desde(ResumenComprobante r) =>
        new(r.Id, r.NumeroCompleto, r.TipoComprobante, r.FechaEmision,
            r.Moneda, r.ImporteTotal, r.Estado, r.CodigoSunat,
            r.MensajeSunat, r.Ticket, r.CreadoEn);
}

/// <summary>
/// Error devuelto por la API.
///
/// Un mensaje que describe el hecho observado, no una suposición. Los errores
/// vagos mandan a quien depura en la dirección equivocada, y eso cuesta horas.
/// </summary>
public record RespuestaError(string Error, string? Detalle = null);
