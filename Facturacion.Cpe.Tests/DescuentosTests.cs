using System.Xml.Linq;
using Facturacion.Cpe;

namespace Facturacion.Tests;

/// <summary>
/// Pruebas de los descuentos por línea.
///
/// El error más común aquí es aplicar el IGV antes del descuento. El resultado
/// se ve razonable, la factura cuadra consigo misma, y SUNAT la rechaza porque
/// su recálculo da otro número.
/// </summary>
public class DescuentosTests
{
    [Fact]
    public void El_descuento_se_aplica_antes_del_igv()
    {
        // 100 de base, 10% de descuento → 90 gravado → 16.20 de IGV.
        // Si el IGV se calculara sobre los 100, daría 18.00 y el cliente
        // pagaría impuesto sobre un monto que nunca se le cobró.
        var linea = Datos.Linea(cantidad: 1, valorUnitario: 100m);
        linea.DescuentoPorcentaje = 10m;

        var c = CalculadoraTotales.CalcularLinea(linea);

        Assert.Equal(100m, c.ValorBruto);
        Assert.Equal(10m, c.Descuento);
        Assert.Equal(90m, c.ValorVenta);
        Assert.Equal(16.20m, c.Igv);
    }

    [Fact]
    public void El_precio_unitario_final_refleja_el_descuento()
    {
        var linea = Datos.Linea(cantidad: 2, valorUnitario: 50m);
        linea.DescuentoPorcentaje = 10m;

        var c = CalculadoraTotales.CalcularLinea(linea);

        // Valor neto 90 + IGV 16.20 = 106.20, entre 2 unidades = 53.10
        Assert.Equal(53.10m, c.PrecioUnitarioConIgv);
    }

    [Fact]
    public void Sin_descuento_los_valores_bruto_y_neto_coinciden()
    {
        var c = CalculadoraTotales.CalcularLinea(
            Datos.Linea(cantidad: 2, valorUnitario: 50m));

        Assert.Equal(0m, c.Descuento);
        Assert.Equal(c.ValorBruto, c.ValorVenta);
    }

    [Fact]
    public void El_total_de_descuentos_suma_todas_las_lineas()
    {
        var l1 = Datos.Linea(cantidad: 1, valorUnitario: 100m, numero: 1);
        l1.DescuentoPorcentaje = 10m;

        var l2 = Datos.Linea(cantidad: 1, valorUnitario: 200m, numero: 2);
        l2.DescuentoPorcentaje = 5m;

        var totales = CalculadoraTotales.Calcular(Datos.Factura(l1, l2));

        Assert.Equal(20m, totales.TotalDescuentos);     // 10 + 10
        Assert.Equal(280m, totales.TotalGravado);       // 90 + 190
        Assert.Equal(50.40m, totales.TotalIgv);
    }

    [Fact]
    public void El_xml_declara_el_descuento_con_su_base_original()
    {
        // SUNAT recalcula Amount = BaseAmount x MultiplierFactorNumeric.
        // Si BaseAmount llevara el valor ya descontado, no cuadraría.
        var linea = Datos.Linea(cantidad: 1, valorUnitario: 100m);
        linea.DescuentoPorcentaje = 10m;

        var xml = GeneradorFacturaXml.Generar(Datos.Factura(linea));

        XNamespace cac = "urn:oasis:names:specification:ubl:schema:xsd:CommonAggregateComponents-2";
        XNamespace cbc = "urn:oasis:names:specification:ubl:schema:xsd:CommonBasicComponents-2";

        var descuento = xml.Descendants(cac + "AllowanceCharge").Single();

        Assert.Equal("false", descuento.Element(cbc + "ChargeIndicator")!.Value);
        Assert.Equal("10.00", descuento.Element(cbc + "Amount")!.Value);
        Assert.Equal("100.00", descuento.Element(cbc + "BaseAmount")!.Value);
        Assert.Equal("0.1", descuento.Element(cbc + "MultiplierFactorNumeric")!.Value);
    }

    [Fact]
    public void Los_descuentos_de_linea_no_se_declaran_como_total_global()
    {
        // AllowanceTotalAmount es SOLO para descuentos globales. El descuento
        // de una línea ya está dentro de su LineExtensionAmount, así que
        // declararlo también a nivel documento lo cuenta dos veces.
        //
        // Esta prueba existe porque SUNAT rechazó exactamente ese caso con el
        // error 3300, y el XSD no lo había detectado: el esquema valida la
        // forma del documento, no su aritmética.
        var linea = Datos.Linea(cantidad: 1, valorUnitario: 100m);
        linea.DescuentoPorcentaje = 10m;

        var xml = GeneradorFacturaXml.Generar(Datos.Factura(linea));

        XNamespace cbc = "urn:oasis:names:specification:ubl:schema:xsd:CommonBasicComponents-2";

        Assert.Empty(xml.Descendants(cbc + "AllowanceTotalAmount"));
    }

    [Fact]
    public void El_valor_de_venta_del_documento_ya_incluye_el_descuento()
    {
        // 100 con 10% de descuento, más 30 sin descuento = 120 de base.
        var l1 = Datos.Linea(cantidad: 1, valorUnitario: 100m, numero: 1);
        l1.DescuentoPorcentaje = 10m;

        var l2 = Datos.Linea(cantidad: 1, valorUnitario: 30m, numero: 2);

        var xml = GeneradorFacturaXml.Generar(Datos.Factura(l1, l2));

        XNamespace cac = "urn:oasis:names:specification:ubl:schema:xsd:CommonAggregateComponents-2";
        XNamespace cbc = "urn:oasis:names:specification:ubl:schema:xsd:CommonBasicComponents-2";

        var totales = xml.Descendants(cac + "LegalMonetaryTotal").Single();

        Assert.Equal("120.00", totales.Element(cbc + "LineExtensionAmount")!.Value);
    }
}

/// <summary>
/// Pruebas de comprobantes en moneda extranjera.
/// </summary>
public class MonedaExtranjeraTests
{
    private static Factura FacturaEnDolares()
    {
        var f = Datos.Factura(Datos.Linea(cantidad: 1, valorUnitario: 100m));
        f.Moneda = "USD";
        f.TipoCambio = new TipoCambio
        {
            MonedaOrigen = "USD",
            MonedaDestino = "PEN",
            Tasa = 3.752m,
            Fecha = new DateTime(2026, 1, 15)
        };
        return f;
    }

    [Fact]
    public void El_xml_declara_la_moneda_del_comprobante()
    {
        var xml = GeneradorFacturaXml.Generar(FacturaEnDolares());

        XNamespace cbc = "urn:oasis:names:specification:ubl:schema:xsd:CommonBasicComponents-2";

        Assert.Equal("USD", xml.Root!.Element(cbc + "DocumentCurrencyCode")!.Value);
    }

    [Fact]
    public void Todos_los_importes_llevan_el_codigo_de_moneda()
    {
        var xml = GeneradorFacturaXml.Generar(FacturaEnDolares());

        var importes = xml.Descendants()
            .Where(e => e.Attribute("currencyID") is not null)
            .ToList();

        Assert.NotEmpty(importes);
        Assert.All(importes,
            e => Assert.Equal("USD", e.Attribute("currencyID")!.Value));
    }

    [Fact]
    public void El_tipo_de_cambio_se_declara_con_tres_decimales()
    {
        var xml = GeneradorFacturaXml.Generar(FacturaEnDolares());

        XNamespace cac = "urn:oasis:names:specification:ubl:schema:xsd:CommonAggregateComponents-2";
        XNamespace cbc = "urn:oasis:names:specification:ubl:schema:xsd:CommonBasicComponents-2";

        var tc = xml.Descendants(cac + "PaymentExchangeRate").Single();

        Assert.Equal("USD", tc.Element(cbc + "SourceCurrencyCode")!.Value);
        Assert.Equal("PEN", tc.Element(cbc + "TargetCurrencyCode")!.Value);
        Assert.Equal("3.752", tc.Element(cbc + "CalculationRate")!.Value);
    }

    [Fact]
    public void Una_factura_en_soles_no_declara_tipo_de_cambio()
    {
        // Declararlo cuando la moneda ya es PEN genera observaciones.
        var xml = GeneradorFacturaXml.Generar(Datos.Factura());

        XNamespace cac = "urn:oasis:names:specification:ubl:schema:xsd:CommonAggregateComponents-2";

        Assert.Empty(xml.Descendants(cac + "PaymentExchangeRate"));
    }

    [Fact]
    public void La_leyenda_usa_el_nombre_de_la_moneda_extranjera()
    {
        var factura = FacturaEnDolares();
        var totales = CalculadoraTotales.Calcular(factura);

        var leyenda = NumeroALetras.Leyenda(totales.ImporteTotal, factura.Moneda);

        Assert.Contains("DOLARES AMERICANOS", leyenda);
    }

    [Fact]
    public void La_factura_en_dolares_firmada_valida_contra_el_esquema()
    {
        var rutaXsd = Datos.RutaXsd("UBL-Invoice-2.1.xsd");
        if (rutaXsd is null) return;

        using var certificado = Datos.Certificado();

        var firmado = FirmadorXml.Firmar(
            GeneradorFacturaXml.Generar(FacturaEnDolares()), certificado);

        var resultado = new ValidadorXsd(rutaXsd)
            .Validar(XDocument.Parse(firmado.OuterXml));

        Assert.True(resultado.Valido,
            string.Join(Environment.NewLine,
                resultado.Errores.Select(e => e.ToString())));
    }

    [Fact]
    public void La_factura_con_descuento_firmada_valida_contra_el_esquema()
    {
        var rutaXsd = Datos.RutaXsd("UBL-Invoice-2.1.xsd");
        if (rutaXsd is null) return;

        var linea = Datos.Linea(cantidad: 2, valorUnitario: 50m);
        linea.DescuentoPorcentaje = 15m;

        using var certificado = Datos.Certificado();

        var firmado = FirmadorXml.Firmar(
            GeneradorFacturaXml.Generar(Datos.Factura(linea)), certificado);

        var resultado = new ValidadorXsd(rutaXsd)
            .Validar(XDocument.Parse(firmado.OuterXml));

        Assert.True(resultado.Valido,
            string.Join(Environment.NewLine,
                resultado.Errores.Select(e => e.ToString())));
    }
}
