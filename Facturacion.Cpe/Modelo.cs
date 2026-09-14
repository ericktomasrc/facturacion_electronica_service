namespace Facturacion.Cpe;

/// <summary>
/// Modelo de dominio de una factura. No sabe nada de XML.
/// Esta separación es deliberada: el mismo modelo alimentará el generador de XML,
/// el de PDF y las validaciones, sin que ninguno dependa del otro.
/// </summary>
public class Factura
{
    public string Serie { get; set; } = "F001";
    public int Correlativo { get; set; }
    public DateTime FechaEmision { get; set; } = DateTime.Now;

    /// <summary>Catálogo 01. Para factura siempre "01".</summary>
    public string TipoComprobante { get; set; } = Cpe.TipoComprobante.Factura;

    /// <summary>Catálogo 51. "0101" = venta interna.</summary>
    public string TipoOperacion { get; set; } = "0101";

    /// <summary>ISO 4217. "PEN" = soles.</summary>
    public string Moneda { get; set; } = "PEN";

    /// <summary>"Contado" o "Credito".</summary>
    public string FormaPago { get; set; } = "Contado";

    public Emisor Emisor { get; set; } = new();
    public Receptor Receptor { get; set; } = new();
    public List<LineaFactura> Lineas { get; set; } = [];

    /// <summary>Identificador del comprobante: F001-00000001.</summary>
    public string NumeroCompleto => $"{Serie}-{Correlativo:D8}";

    /// <summary>
    /// Nombre del archivo XML según la convención obligatoria de SUNAT.
    /// Si este nombre está mal, el comprobante se rechaza aunque el XML sea correcto.
    /// </summary>
    public string NombreArchivo => $"{Emisor.Ruc}-{TipoComprobante}-{NumeroCompleto}";
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

public class LineaFactura
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

    /// <summary>Porcentaje del IGV vigente.</summary>
    public decimal PorcentajeIgv { get; set; } = 18m;
}

/// <summary>
/// Totales calculados de la factura. Se generan, no se capturan:
/// permitir que entren desde afuera es la forma más rápida de que no cuadren.
/// </summary>
public record TotalesFactura(
    decimal TotalGravado,
    decimal TotalExonerado,
    decimal TotalInafecto,
    decimal TotalGratuito,
    decimal TotalIgv,
    decimal ValorVenta,
    decimal ImporteTotal);

/// <summary>Resultado del cálculo por línea.</summary>
public record LineaCalculada(
    LineaFactura Linea,
    decimal ValorVenta,
    decimal Igv,
    decimal PrecioUnitarioConIgv);
