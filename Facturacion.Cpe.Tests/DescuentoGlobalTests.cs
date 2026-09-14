using System.Xml.Linq;
using Facturacion.Cpe;

namespace Facturacion.Tests;

/// <summary>
/// Pruebas del descuento global.
///
/// POR QUÉ SE REPARTE DENTRO DE LAS LÍNEAS Y NO SE DECLARA APARTE:
///
/// La primera implementación declaraba el descuento a nivel documento y bajaba
/// la base imponible allí. SUNAT lo rechazó con el error 3277: "la sumatoria
/// del total valor de venta de línea no corresponde al total". Las líneas
/// sumaban 120 y el documento declaraba 114.
///
/// La conclusión es que SUNAT exige que la base imponible del documento sea
/// exactamente la suma de las líneas. Así que el descuento global se reparte
/// dentro de ellas y no aparece en ningún otro sitio.
/// </summary>
public class DescuentoGlobalTests
{
    private static XNamespace Cac =>
        "urn:oasis:names:specification:ubl:schema:xsd:CommonAggregateComponents-2";

    private static XNamespace Cbc =>
        "urn:oasis:names:specification:ubl:schema:xsd:CommonBasicComponents-2";

    [Fact]
    public void Reduce_la_base_imponible_y_por_lo_tanto_el_igv()
    {
        // 120 de base con 5% global → 114 gravado → 20.52 de IGV.
        // Sin el descuento serían 21.60.
        var factura = Datos.Factura(
            Datos.Linea(cantidad: 1, valorUnitario: 100m, numero: 1),
            Datos.Linea(cantidad: 1, valorUnitario: 20m, numero: 2));

        factura.DescuentoGlobalPorcentaje = 5m;

        var t = CalculadoraTotales.Calcular(factura);

        Assert.Equal(6m, t.TotalDescuentos);
        Assert.Equal(114m, t.TotalGravado);
        Assert.Equal(114m, t.ValorVenta);
        Assert.Equal(20.52m, t.TotalIgv);
        Assert.Equal(134.52m, t.ImporteTotal);
    }

    [Fact]
    public void Los_dos_descuentos_se_combinan_en_cascada_no_se_suman()
    {
        // 10% de línea más 10% global NO es 20%: el global se aplica sobre lo
        // que quedó después del de línea.
        //   1 - (1 - 0.10) x (1 - 0.10) = 0.19
        Assert.Equal(0.19m, CalculadoraTotales.FactorDescuento(10m, 10m));

        // Solo uno de los dos: el factor es ese mismo.
        Assert.Equal(0.10m, CalculadoraTotales.FactorDescuento(10m, 0m));
        Assert.Equal(0.05m, CalculadoraTotales.FactorDescuento(0m, 5m));

        // Ninguno: sin descuento.
        Assert.Equal(0m, CalculadoraTotales.FactorDescuento(0m, 0m));
    }

    [Fact]
    public void Una_linea_con_ambos_descuentos_aplica_el_factor_combinado()
    {
        // 100 con 10% de línea y 10% global → 19 de descuento → 81 de base.
        var linea = Datos.Linea(cantidad: 1, valorUnitario: 100m);
        linea.DescuentoPorcentaje = 10m;

        var c = CalculadoraTotales.CalcularLinea(linea, descuentoGlobalPorcentaje: 10m);

        Assert.Equal(0.19m, c.FactorDescuento);
        Assert.Equal(19m, c.Descuento);
        Assert.Equal(81m, c.ValorVenta);
        Assert.Equal(14.58m, c.Igv);
    }

    [Fact]
    public void El_descuento_global_alcanza_a_las_lineas_exoneradas()
    {
        // Se aplica a todas las líneas por igual, sin importar su afectación.
        var factura = Datos.Factura(
            Datos.Linea(cantidad: 1, valorUnitario: 100m, numero: 1),
            Datos.Linea(cantidad: 1, valorUnitario: 100m, numero: 2,
                afectacion: AfectacionIgv.Exonerado));

        factura.DescuentoGlobalPorcentaje = 10m;

        var t = CalculadoraTotales.Calcular(factura);

        Assert.Equal(90m, t.TotalGravado);
        Assert.Equal(90m, t.TotalExonerado);
        Assert.Equal(16.20m, t.TotalIgv);   // solo sobre el gravado
        Assert.Equal(20m, t.TotalDescuentos);
    }

    [Fact]
    public void La_base_del_documento_siempre_es_la_suma_de_las_lineas()
    {
        // Esta es LA invariante que SUNAT valida con el error 3277.
        // Si alguna vez deja de cumplirse, el comprobante se rechaza.
        var factura = Datos.Factura(
            Datos.Linea(cantidad: 3, valorUnitario: 11.37m, numero: 1),
            Datos.Linea(cantidad: 7, valorUnitario: 4.59m, numero: 2),
            Datos.Linea(cantidad: 2, valorUnitario: 0.99m, numero: 3));

        factura.DescuentoGlobalPorcentaje = 3.5m;

        var lineas = CalculadoraTotales.CalcularLineas(factura);
        var t = CalculadoraTotales.Calcular(factura);

        Assert.Equal(lineas.Sum(l => l.ValorVenta), t.ValorVenta);
        Assert.Equal(t.TotalGravado, t.ValorVenta);
    }

    [Fact]
    public void El_importe_total_siempre_cuadra_con_sus_partes()
    {
        var factura = Datos.Factura(
            Datos.Linea(cantidad: 3, valorUnitario: 11.37m, numero: 1),
            Datos.Linea(cantidad: 7, valorUnitario: 4.59m, numero: 2));

        factura.DescuentoGlobalPorcentaje = 3.5m;

        var t = CalculadoraTotales.Calcular(factura);

        Assert.Equal(t.ValorVenta + t.TotalIgv, t.ImporteTotal);
    }

    [Fact]
    public void El_descuento_global_nunca_se_declara_a_nivel_documento()
    {
        // Ni AllowanceCharge en la raíz ni AllowanceTotalAmount en los totales.
        // Declararlo ahí fue exactamente lo que SUNAT rechazó.
        var factura = Datos.Factura(Datos.Linea(cantidad: 1, valorUnitario: 100m));
        factura.DescuentoGlobalPorcentaje = 10m;

        var xml = GeneradorFacturaXml.Generar(factura);

        Assert.Empty(xml.Root!.Elements(Cac + "AllowanceCharge"));
        Assert.Empty(xml.Descendants(Cbc + "AllowanceTotalAmount"));
    }

    [Fact]
    public void La_linea_declara_el_factor_combinado_en_el_xml()
    {
        var linea = Datos.Linea(cantidad: 1, valorUnitario: 100m);
        linea.DescuentoPorcentaje = 10m;

        var factura = Datos.Factura(linea);
        factura.DescuentoGlobalPorcentaje = 10m;

        var xml = GeneradorFacturaXml.Generar(factura);

        var descuento = xml.Descendants(Cac + "AllowanceCharge").Single();

        Assert.Equal("0.19", descuento.Element(Cbc + "MultiplierFactorNumeric")!.Value);
        Assert.Equal("19.00", descuento.Element(Cbc + "Amount")!.Value);
        Assert.Equal("100.00", descuento.Element(Cbc + "BaseAmount")!.Value);
    }

    [Fact]
    public void El_monto_declarado_coincide_con_base_por_factor()
    {
        // SUNAT recalcula Amount = BaseAmount x MultiplierFactorNumeric.
        // Por eso el factor se redondea a 5 decimales antes de usarlo: si el
        // cálculo usara más precisión que la declarada, no cuadraría.
        var factura = Datos.Factura(
            Datos.Linea(cantidad: 3, valorUnitario: 33.33m));

        factura.DescuentoGlobalPorcentaje = 7.5m;

        var c = CalculadoraTotales.CalcularLineas(factura).Single();

        var recalculado = CalculadoraTotales.Redondear(
            c.ValorBruto * c.FactorDescuento);

        Assert.Equal(recalculado, c.Descuento);
    }

    [Fact]
    public void La_factura_con_descuento_global_valida_contra_el_esquema()
    {
        var rutaXsd = Datos.RutaXsd("UBL-Invoice-2.1.xsd");
        if (rutaXsd is null) return;

        var factura = Datos.Factura(Datos.Linea(cantidad: 2, valorUnitario: 50m));
        factura.DescuentoGlobalPorcentaje = 5m;

        using var certificado = Datos.Certificado();

        var firmado = FirmadorXml.Firmar(
            GeneradorFacturaXml.Generar(factura), certificado);

        var resultado = new ValidadorXsd(rutaXsd)
            .Validar(XDocument.Parse(firmado.OuterXml));

        Assert.True(resultado.Valido,
            string.Join(Environment.NewLine,
                resultado.Errores.Select(e => e.ToString())));
    }
}
