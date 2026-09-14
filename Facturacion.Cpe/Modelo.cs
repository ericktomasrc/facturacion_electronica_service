namespace Facturacion.Cpe;

/// <summary>
/// Lo que comparten todos los comprobantes electrónicos.
/// </summary>
public abstract class ComprobanteBase
{
    public string Serie { get; set; } = "";
    public int Correlativo { get; set; }
    public DateTime FechaEmision { get; set; } = DateTime.Now;

    /// <summary>ISO 4217. "PEN" = soles, "USD" = dólares.</summary>
    public string Moneda { get; set; } = "PEN";

    /// <summary>
    /// Tipo de cambio a soles. Solo se declara cuando la moneda no es PEN.
    /// </summary>
    public TipoCambio? TipoCambio { get; set; }

    /// <summary>
    /// Descuento global sobre el comprobante completo, en porcentaje.
    /// 5 significa 5%.
    ///
    /// DIFERENCIA CON EL DESCUENTO POR LÍNEA: este se aplica sobre la suma de
    /// todas las líneas y reduce la base imponible del documento entero. El
    /// IGV del comprobante se calcula sobre el monto ya descontado.
    ///
    /// Se declara con el código 00 del catálogo 53, que es el descuento global
    /// que sí afecta la base imponible. Existe también el código 01, para
    /// descuentos que no la afectan, pero ese caso no está implementado aquí.
    /// </summary>
    public decimal DescuentoGlobalPorcentaje { get; set; }

    public bool TieneDescuentoGlobal => DescuentoGlobalPorcentaje > 0;

    public Emisor Emisor { get; set; } = new();
    public Receptor Receptor { get; set; } = new();
    public List<LineaComprobante> Lineas { get; set; } = [];

    /// <summary>Catálogo 01. Lo define cada tipo concreto.</summary>
    public abstract string TipoComprobante { get; }

    public string NumeroCompleto => $"{Serie}-{Correlativo:D8}";

    public string NombreArchivo => $"{Emisor.Ruc}-{TipoComprobante}-{NumeroCompleto}";
}

/// <summary>
/// Tipo de cambio aplicado a un comprobante en moneda extranjera.
///
/// SUNAT lleva la contabilidad en soles, así que cuando facturas en dólares
/// necesita saber a qué tasa convertir. La tasa que corresponde es la
/// publicada por la SBS para la fecha de la operación, no la del banco
/// con el que trabajas.
/// </summary>
public class TipoCambio
{
    public string MonedaOrigen { get; set; } = "USD";
    public string MonedaDestino { get; set; } = "PEN";

    /// <summary>Tasa de conversión. Se declara con 3 decimales.</summary>
    public decimal Tasa { get; set; }

    public DateTime Fecha { get; set; } = DateTime.Today;
}

public class Factura : ComprobanteBase
{
    public override string TipoComprobante => Cpe.TipoComprobante.Factura;

    /// <summary>Catálogo 51. "0101" = venta interna, "0200" = exportación.</summary>
    public string TipoOperacion { get; set; } = "0101";

    /// <summary>"Contado" o "Credito". Obligatorio en facturas.</summary>
    public string FormaPago { get; set; } = "Contado";
}

public class Boleta : ComprobanteBase
{
    public override string TipoComprobante => Cpe.TipoComprobante.Boleta;

    public string TipoOperacion { get; set; } = "0101";
    public string FormaPago { get; set; } = "Contado";
}

/// <summary>
/// Nota de crédito. Disminuye o anula un comprobante ya emitido.
/// La serie debe empezar con la misma letra del documento que modifica.
/// </summary>
public class NotaCredito : ComprobanteBase
{
    public override string TipoComprobante => Cpe.TipoComprobante.NotaCredito;

    public string CodigoMotivo { get; set; } = MotivoNotaCredito.AnulacionDeLaOperacion;
    public string DescripcionMotivo { get; set; } = "";
    public DocumentoAfectado Afectado { get; set; } = new();
}

/// <summary>Nota de débito. Aumenta el importe de un comprobante ya emitido.</summary>
public class NotaDebito : ComprobanteBase
{
    public override string TipoComprobante => Cpe.TipoComprobante.NotaDebito;

    public string CodigoMotivo { get; set; } = MotivoNotaDebito.InteresPorMora;
    public string DescripcionMotivo { get; set; } = "";
    public DocumentoAfectado Afectado { get; set; } = new();
}

public class DocumentoAfectado
{
    public string Numero { get; set; } = "";
    public string TipoDocumento { get; set; } = TipoComprobante.Factura;
}

public class Emisor
{
    public string Ruc { get; set; } = "";
    public string RazonSocial { get; set; } = "";
    public string NombreComercial { get; set; } = "";
    public string Ubigeo { get; set; } = "150101";
    public string Direccion { get; set; } = "";
    public string Distrito { get; set; } = "";
    public string Provincia { get; set; } = "";
    public string Departamento { get; set; } = "";
    public string CodigoEstablecimiento { get; set; } = "0000";
    public string CodigoPais { get; set; } = "PE";
}

public class Receptor
{
    public string TipoDocumento { get; set; } = TipoDocIdentidad.Ruc;
    public string NumeroDocumento { get; set; } = "";
    public string RazonSocial { get; set; } = "";
    public string Direccion { get; set; } = "";
}

/// <summary>
/// Una línea de detalle. Es idéntica en factura, boleta y notas.
/// </summary>
public class LineaComprobante
{
    public int Numero { get; set; }

    public string CodigoProducto { get; set; } = "";
    public string Descripcion { get; set; } = "";

    /// <summary>Catálogo 65. "NIU" = unidad, "ZZ" = servicio.</summary>
    public string UnidadMedida { get; set; } = "NIU";

    public decimal Cantidad { get; set; }

    /// <summary>Valor unitario SIN IGV y SIN descuento. Es el dato de entrada.</summary>
    public decimal ValorUnitario { get; set; }

    /// <summary>
    /// Descuento sobre esta línea, en porcentaje. 10 significa 10%.
    ///
    /// SE APLICA ANTES DEL IGV: el impuesto se calcula sobre el valor ya
    /// descontado, no sobre el bruto. Calcularlo al revés es un rechazo seguro.
    /// </summary>
    public decimal DescuentoPorcentaje { get; set; }

    /// <summary>Catálogo 07.</summary>
    public string TipoAfectacionIgv { get; set; } = AfectacionIgv.GravadoOperacionOnerosa;

    public decimal PorcentajeIgv { get; set; } = 18m;

    public bool TieneDescuento => DescuentoPorcentaje > 0;
}

/// <summary>
/// Totales calculados del comprobante.
///
/// ValorVenta es la suma de los valores de venta de las líneas, con todos los
/// descuentos ya aplicados. SUNAT exige que la base imponible declarada
/// coincida exactamente con esa suma.
/// </summary>
public record TotalesComprobante(
    decimal TotalGravado,
    decimal TotalExonerado,
    decimal TotalInafecto,
    decimal TotalGratuito,
    decimal TotalDescuentos,
    decimal TotalIgv,
    decimal ValorVenta,
    decimal ImporteTotal);

/// <summary>
/// Resultado del cálculo de una línea.
/// </summary>
/// <param name="FactorDescuento">
/// Descuento efectivo aplicado, ya combinando el de la línea con el global.
/// Es el valor que viaja al XML en MultiplierFactorNumeric.
/// </param>
/// <param name="ValorBruto">Cantidad por valor unitario, antes de descuentos.</param>
/// <param name="Descuento">Monto descontado.</param>
/// <param name="ValorVenta">Valor neto: bruto menos descuento. Es lo que va al XML.</param>
public record LineaCalculada(
    LineaComprobante Linea,
    decimal FactorDescuento,
    decimal ValorBruto,
    decimal Descuento,
    decimal ValorVenta,
    decimal Igv,
    decimal PrecioUnitarioConIgv)
{
    public bool TieneDescuento => Descuento > 0;
}
