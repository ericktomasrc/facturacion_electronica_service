namespace Facturacion.Cpe;

/// <summary>
/// Estado con el que se informa un comprobante en el resumen diario.
/// Catálogo 19 de SUNAT.
/// </summary>
public enum EstadoResumen
{
    /// <summary>Se informa por primera vez.</summary>
    Adicionar = 1,

    /// <summary>Ya se informó antes y se corrigen sus valores.</summary>
    Modificar = 2,

    /// <summary>Se anula el comprobante.</summary>
    Anular = 3
}

/// <summary>
/// Resumen diario de boletas de venta y notas vinculadas.
///
/// POR QUÉ EXISTE: las boletas se emiten al consumidor final y son muchísimas.
/// Un supermercado emite miles al día. SUNAT no las recibe una por una: se
/// agrupan todas las de un mismo día en un solo documento.
///
/// Eso cambia el tráfico real contra SUNAT de forma drástica. Si de 100.000
/// comprobantes diarios 70.000 son boletas, se convierten en un puñado de
/// envíos en vez de 70.000.
///
/// EL ENVÍO ES ASÍNCRONO, en dos tiempos:
///   1. sendSummary  → SUNAT devuelve un TICKET, no un CDR.
///   2. getStatus    → se consulta el ticket hasta que el proceso termine
///                      y ahí sí entrega el CDR.
///
/// Nomenclatura del documento:  RC-YYYYMMDD-#####
/// Nombre del archivo:          {RUC}-RC-{FECHA}-{CORRELATIVO}
/// </summary>
public class ResumenDiario
{
    public Emisor Emisor { get; set; } = new();

    /// <summary>Fecha en que se emitieron los comprobantes que se informan.</summary>
    public DateTime FechaReferencia { get; set; } = DateTime.Today.AddDays(-1);

    /// <summary>Fecha en que se genera el resumen. Normalmente hoy.</summary>
    public DateTime FechaGeneracion { get; set; } = DateTime.Today;

    /// <summary>Correlativo del resumen dentro del día. Hasta 5 dígitos.</summary>
    public int Correlativo { get; set; } = 1;

    public List<LineaResumen> Lineas { get; set; } = [];

    /// <summary>Identificador del resumen: RC-20260914-1</summary>
    public string Identificador => $"RC-{FechaGeneracion:yyyyMMdd}-{Correlativo}";

    /// <summary>Nombre del archivo, sin extensión.</summary>
    public string NombreArchivo => $"{Emisor.Ruc}-{Identificador}";
}

/// <summary>
/// Un comprobante informado dentro del resumen.
///
/// Fíjate en la diferencia con una línea de factura: aquí NO van los ítems.
/// Una línea del resumen representa un comprobante completo, con sus totales
/// ya consolidados.
/// </summary>
public class LineaResumen
{
    /// <summary>Número secuencial dentro del resumen, empezando en 1.</summary>
    public int Orden { get; set; }

    /// <summary>Catálogo 01. Solo 03, 07 y 08 pueden ir en un resumen.</summary>
    public string TipoComprobante { get; set; } = Cpe.TipoComprobante.Boleta;

    /// <summary>Serie y correlativo del comprobante. Ej: B001-22</summary>
    public string Numero { get; set; } = "";

    public Receptor Receptor { get; set; } = new();

    /// <summary>Solo para notas: el comprobante que modifican.</summary>
    public DocumentoAfectado? Afectado { get; set; }

    public EstadoResumen Estado { get; set; } = EstadoResumen.Adicionar;

    public string Moneda { get; set; } = "PEN";

    public decimal TotalGravado { get; set; }
    public decimal TotalExonerado { get; set; }
    public decimal TotalInafecto { get; set; }
    public decimal TotalIgv { get; set; }
    public decimal ImporteTotal { get; set; }

    /// <summary>
    /// Construye la línea a partir de una boleta ya emitida.
    /// Los totales se recalculan desde sus líneas: así no hay forma de que
    /// el resumen declare un monto distinto al del comprobante original.
    /// </summary>
    public static LineaResumen DesdeBoleta(
        Boleta boleta,
        int orden,
        EstadoResumen estado = EstadoResumen.Adicionar)
    {
        var t = CalculadoraTotales.Calcular(boleta);

        return new LineaResumen
        {
            Orden = orden,
            TipoComprobante = boleta.TipoComprobante,
            Numero = boleta.NumeroCompleto,
            Receptor = boleta.Receptor,
            Estado = estado,
            Moneda = boleta.Moneda,
            TotalGravado = t.TotalGravado,
            TotalExonerado = t.TotalExonerado,
            TotalInafecto = t.TotalInafecto,
            TotalIgv = t.TotalIgv,
            ImporteTotal = t.ImporteTotal
        };
    }
}

/// <summary>Respuesta de un envío asíncrono: SUNAT devuelve un ticket.</summary>
/// <param name="Exitoso">false si hubo un fallo de red o un rechazo inmediato.</param>
/// <param name="Ticket">Número con el que después se consulta el resultado.</param>
public record ResultadoTicket(
    bool Exitoso,
    string Ticket,
    string Mensaje)
{
    public bool EsReintentable { get; init; }

    public static ResultadoTicket Fallo(string mensaje, bool reintentable = false) =>
        new(false, "", mensaje) { EsReintentable = reintentable };
}

/// <summary>Catálogo 11: identificador del tipo de monto en el resumen.</summary>
public static class TipoMontoResumen
{
    public const string Gravado   = "01";
    public const string Exonerado = "02";
    public const string Inafecto  = "03";
    public const string Exportacion = "04";
    public const string Isc       = "05";
    public const string Gratuito  = "06";
}
