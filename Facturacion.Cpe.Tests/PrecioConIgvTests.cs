using Facturacion.Cpe;

namespace Facturacion.Tests;

/// <summary>
/// e182 — EL CÉNTIMO DE MÁS. Con el precio con IGV, la línea se calcula desde
/// el total (como Nubefact, Bsale o el facturador de SUNAT): 2 × 28.50 son
/// 57.00 y no 57.01.
/// </summary>
public class PrecioConIgvTests
{
    [Fact]
    public void Dos_por_28_50_son_57_justos()
    {
        var linea = Datos.Linea(cantidad: 2, valorUnitario: 24.1525423729m);
        linea.PrecioUnitario = 28.50m;

        var c = CalculadoraTotales.CalcularLinea(linea);

        Assert.Equal(48.31m, c.ValorVenta);
        Assert.Equal(8.69m, c.Igv);
        Assert.Equal(57.00m, c.ValorVenta + c.Igv);
        Assert.Equal(28.50m, c.PrecioUnitarioConIgv);
    }

    [Fact]
    public void Sin_precio_con_igv_se_calcula_como_siempre()
    {
        var linea = Datos.Linea(cantidad: 2, valorUnitario: 24.1525423729m);

        var c = CalculadoraTotales.CalcularLinea(linea);

        Assert.Equal(48.31m, c.ValorVenta);
        Assert.Equal(8.70m, c.Igv);
    }

    [Fact]
    public void Con_descuento_se_descuenta_del_total_con_igv()
    {
        // 7 × 4.50 = 31.50; −10 % = 28.35; 28.35 / 1.18 = 24.03; IGV 4.32.
        var linea = Datos.Linea(cantidad: 7, valorUnitario: 3.8135593220m);
        linea.PrecioUnitario = 4.50m;
        linea.DescuentoPorcentaje = 10m;

        var c = CalculadoraTotales.CalcularLinea(linea);

        Assert.Equal(24.03m, c.ValorVenta);
        Assert.Equal(4.32m, c.Igv);
        Assert.Equal(28.35m, c.ValorVenta + c.Igv);
    }

    [Fact]
    public void El_igv_queda_dentro_de_la_tolerancia_de_sunat()
    {
        var linea = Datos.Linea(cantidad: 2, valorUnitario: 24.1525423729m);
        linea.PrecioUnitario = 28.50m;

        var c = CalculadoraTotales.CalcularLinea(linea);

        Assert.True(Math.Abs(c.Igv - c.ValorVenta * 0.18m) < 1m);
    }
}