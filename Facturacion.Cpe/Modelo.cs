namespace Facturacion.Cpe;

/// <summary>
/// Lo que comparten todos los comprobantes electrónicos.
///
/// Se extrae una base común porque factura, nota de crédito y nota de débito
/// coinciden en casi todo: emisor, receptor, líneas, moneda y numeración.
/// Lo que cambia es el documento XML que se genera y unos pocos bloques propios.
/// </summary>
public abstract class ComprobanteBase
{
    public string Serie { get; set; } = "";
    public int Correlativo { get; set; }
    public DateTime FechaEmision { get; set; } = DateTime.Now;

    /// <summary>ISO 4217. "PEN" = soles.</summary>
    public string Moneda { get; set; } = "PEN";

    public Emisor Emisor { get; set; } = new();
    public Receptor Receptor { get; set; } = new();
    public List<LineaComprobante> Lineas { get; set; } = [];

    /// <summary>Catálogo 01. Lo define cada tipo concreto.</summary>
    public abstract string TipoComprobante { get; }

    /// <summary>Identificador del comprobante: F001-00000001.</summary>
    public string NumeroCompleto => $"{Serie}-{Correlativo:D8}";

    /// <summary>
    /// Nombre del archivo según la convención obligatoria de SUNAT.
    /// Si está mal, el comprobante se rechaza aunque el XML sea correcto.
    /// </summary>
    public string NombreArchivo => $"{Emisor.Ruc}-{TipoComprobante}-{NumeroCompleto}";
}

/// <summary>Factura electrónica. Catálogo 01, código 01.</summary>
public class Factura : ComprobanteBase
{
    public override string TipoComprobante => Cpe.TipoComprobante.Factura;

    /// <summary>Catálogo 51. "0101" = venta interna.</summary>
    public string TipoOperacion { get; set; } = "0101";

    /// <summary>"Contado" o "Credito". Obligatorio en facturas.</summary>
    public string FormaPago { get; set; } = "Contado";
}

/// <summary>Boleta de venta electrónica. Catálogo 01, código 03.</summary>
public class Boleta : ComprobanteBase
{
    public override string TipoComprobante => Cpe.TipoComprobante.Boleta;

    public string TipoOperacion { get; set; } = "0101";
    public string FormaPago { get; set; } = "Contado";
}

/// <summary>
/// Nota de crédito. Catálogo 01, código 07.
///
/// Disminuye o anula un comprobante ya emitido: devoluciones, descuentos
/// posteriores, errores en el monto. Una vez que SUNAT acepta un comprobante
/// no se puede modificar, así que esta es la única forma de corregirlo.
///
/// La serie debe empezar con la misma letra del documento que modifica:
/// F para notas sobre facturas, B para notas sobre boletas.
/// </summary>
public class NotaCredito : ComprobanteBase
{
    public override string TipoComprobante => Cpe.TipoComprobante.NotaCredito;

    /// <summary>Catálogo 09. Ver <see cref="MotivoNotaCredito"/>.</summary>
    public string CodigoMotivo { get; set; } = MotivoNotaCredito.AnulacionDeLaOperacion;

    /// <summary>Texto libre que explica el motivo. Lo lee una persona.</summary>
    public string DescripcionMotivo { get; set; } = "";

    /// <summary>El comprobante que esta nota modifica.</summary>
    public DocumentoAfectado Afectado { get; set; } = new();
}

/// <summary>
/// Nota de débito. Catálogo 01, código 08.
///
/// Aumenta el importe de un comprobante ya emitido: intereses por mora,
/// penalidades, aumento de valor.
/// </summary>
public class NotaDebito : ComprobanteBase
{
    public override string TipoComprobante => Cpe.TipoComprobante.NotaDebito;

    /// <summary>Catálogo 10. Ver <see cref="MotivoNotaDebito"/>.</summary>
    public string CodigoMotivo { get; set; } = MotivoNotaDebito.InteresPorMora;

    public string DescripcionMotivo { get; set; } = "";

    public DocumentoAfectado Afectado { get; set; } = new();
}

/// <summary>Referencia al comprobante que una nota modifica.</summary>
public class DocumentoAfectado
{
    /// <summary>Serie y correlativo del documento original. Ej: F001-00000001</summary>
    public string Numero { get; set; } = "";

    /// <summary>Catálogo 01. "01" si modifica una factura, "03" una boleta.</summary>
    public string TipoDocumento { get; set; } = TipoComprobante.Factura;
}

public class Emisor
{
    public string Ruc { get; set; } = "";
    public string RazonSocial { get; set; } = "";
    public string NombreComercial { get; set; } = "";

    /// <summary>Código de ubigeo del INEI, 6 dígitos.</summary>
    public string Ubigeo { get; set; } = "150101";

    public string Direccion { get; set; } = "";
    public string Distrito { get; set; } = "";
    public string Provincia { get; set; } = "";
    public string Departamento { get; set; } = "";

    /// <summary>Código del establecimiento anexo. "0000" es el domicilio fiscal.</summary>
    public string CodigoEstablecimiento { get; set; } = "0000";

    public string CodigoPais { get; set; } = "PE";
}

public class Receptor
{
    /// <summary>Catálogo 06. "6" = RUC, "1" = DNI.</summary>
    public string TipoDocumento { get; set; } = TipoDocIdentidad.Ruc;

    public string NumeroDocumento { get; set; } = "";
    public string RazonSocial { get; set; } = "";
    public string Direccion { get; set; } = "";
}

/// <summary>
/// Una línea de detalle. Es idéntica en factura, boleta y notas,
/// por eso no lleva el nombre del documento.
/// </summary>
public class LineaComprobante
{
    /// <summary>Número de orden dentro del comprobante, empezando en 1.</summary>
    public int Numero { get; set; }

    public string CodigoProducto { get; set; } = "";
    public string Descripcion { get; set; } = "";

    /// <summary>Catálogo 65 (UN/ECE rec 20). "NIU" = unidad, "ZZ" = servicio.</summary>
    public string UnidadMedida { get; set; } = "NIU";

    public decimal Cantidad { get; set; }

    /// <summary>Valor unitario SIN IGV. Es el dato de entrada.</summary>
    public decimal ValorUnitario { get; set; }

    /// <summary>Catálogo 07.</summary>
    public string TipoAfectacionIgv { get; set; } = AfectacionIgv.GravadoOperacionOnerosa;

    public decimal PorcentajeIgv { get; set; } = 18m;
}

/// <summary>
/// Totales calculados. Se generan, no se capturan: permitir que entren
/// desde afuera es la forma más rápida de que no cuadren con las líneas.
/// </summary>
public record TotalesComprobante(
    decimal TotalGravado,
    decimal TotalExonerado,
    decimal TotalInafecto,
    decimal TotalGratuito,
    decimal TotalIgv,
    decimal ValorVenta,
    decimal ImporteTotal);

/// <summary>Resultado del cálculo de una línea.</summary>
public record LineaCalculada(
    LineaComprobante Linea,
    decimal ValorVenta,
    decimal Igv,
    decimal PrecioUnitarioConIgv);
