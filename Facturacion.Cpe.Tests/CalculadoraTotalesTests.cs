using Facturacion.Cpe;

namespace Facturacion.Tests;

/// <summary>
/// Pruebas del cálculo de IGV y totales.
///
/// Este es el código más delicado del motor: SUNAT recalcula todo por su cuenta
/// y compara con una tolerancia mínima, así que un céntimo de diferencia es un
/// rechazo. Estas pruebas existen para que se pueda tocar la calculadora sin
/// miedo cuando haya que agregar descuentos, ISC o moneda extranjera.
/// </summary>
public class CalculadoraTotalesTests
{
    // ------------------------------------------------------------- redondeo

    [Theory]
    [InlineData(0.125, 0.13)]   // el redondeo bancario daría 0.12
    [InlineData(0.135, 0.14)]   // el redondeo bancario daría 0.14 también
    [InlineData(0.145, 0.15)]   // el redondeo bancario daría 0.14
    [InlineData(2.675, 2.68)]
    public void Redondea_alejandose_del_cero_no_al_par_mas_cercano(
        decimal valor, decimal esperado)
    {
        // .NET redondea "al par más cercano" por defecto, que trata los casos
        // terminados en 5 de otra forma. SUNAT espera el redondeo común.
        Assert.Equal(esperado, CalculadoraTotales.Redondear(valor));
    }

    [Fact]
    public void El_total_es_la_suma_de_lineas_ya_redondeadas()
    {
        // Tres líneas de 0.335 cada una.
        //   Suma de redondeados: 0.34 x 3 = 1.02   ← lo correcto
        //   Redondeo de la suma: 1.005     = 1.01   ← lo incorrecto
        //
        // La diferencia parece trivial, pero en un comprobante con cincuenta
        // ítems se convierte en varios céntimos y SUNAT lo rechaza.
        var factura = Datos.Factura(
            Datos.Linea(cantidad: 1, valorUnitario: 0.335m, numero: 1),
            Datos.Linea(cantidad: 1, valorUnitario: 0.335m, numero: 2),
            Datos.Linea(cantidad: 1, valorUnitario: 0.335m, numero: 3));

        var totales = CalculadoraTotales.Calcular(factura);

        Assert.Equal(1.02m, totales.TotalGravado);
    }

    // ----------------------------------------------------------------- IGV

    [Fact]
    public void Calcula_el_igv_de_una_linea_gravada()
    {
        var factura = Datos.Factura(
            Datos.Linea(cantidad: 2, valorUnitario: 50.00m));

        var totales = CalculadoraTotales.Calcular(factura);

        Assert.Equal(100.00m, totales.TotalGravado);
        Assert.Equal(18.00m, totales.TotalIgv);
        Assert.Equal(118.00m, totales.ImporteTotal);
    }

    [Fact]
    public void El_importe_total_siempre_cuadra_con_sus_partes()
    {
        var factura = Datos.Factura(
            Datos.Linea(cantidad: 3, valorUnitario: 11.30m, numero: 1),
            Datos.Linea(cantidad: 7, valorUnitario: 4.57m, numero: 2));

        var t = CalculadoraTotales.Calcular(factura);

        Assert.Equal(t.ValorVenta + t.TotalIgv, t.ImporteTotal);
    }

    // --------------------------------------------------- tipos de afectación

    [Fact]
    public void Una_linea_exonerada_no_genera_igv()
    {
        var factura = Datos.Factura(
            Datos.Linea(valorUnitario: 100m, cantidad: 1,
                afectacion: AfectacionIgv.Exonerado));

        var t = CalculadoraTotales.Calcular(factura);

        Assert.Equal(100m, t.TotalExonerado);
        Assert.Equal(0m, t.TotalGravado);
        Assert.Equal(0m, t.TotalIgv);
        Assert.Equal(100m, t.ImporteTotal);
    }

    [Fact]
    public void Una_linea_inafecta_no_genera_igv()
    {
        var factura = Datos.Factura(
            Datos.Linea(valorUnitario: 80m, cantidad: 1,
                afectacion: AfectacionIgv.Inafecto));

        var t = CalculadoraTotales.Calcular(factura);

        Assert.Equal(80m, t.TotalInafecto);
        Assert.Equal(0m, t.TotalIgv);
    }

    [Fact]
    public void Una_linea_gratuita_no_suma_al_importe_a_pagar()
    {
        // Las operaciones gratuitas se declaran aparte y no se cobran.
        // Si se sumaran al total, el cliente pagaría por una muestra regalada.
        var factura = Datos.Factura(
            Datos.Linea(valorUnitario: 100m, cantidad: 1, numero: 1),
            Datos.Linea(valorUnitario: 50m, cantidad: 1, numero: 2,
                afectacion: AfectacionIgv.GratuitoGravado));

        var t = CalculadoraTotales.Calcular(factura);

        Assert.Equal(100m, t.TotalGravado);
        Assert.Equal(50m, t.TotalGratuito);
        Assert.Equal(118m, t.ImporteTotal);
    }

    [Fact]
    public void Mezcla_gravado_exonerado_e_inafecto_en_el_mismo_comprobante()
    {
        var factura = Datos.Factura(
            Datos.Linea(valorUnitario: 100m, cantidad: 1, numero: 1),
            Datos.Linea(valorUnitario: 50m, cantidad: 1, numero: 2,
                afectacion: AfectacionIgv.Exonerado),
            Datos.Linea(valorUnitario: 30m, cantidad: 1, numero: 3,
                afectacion: AfectacionIgv.Inafecto));

        var t = CalculadoraTotales.Calcular(factura);

        Assert.Equal(100m, t.TotalGravado);
        Assert.Equal(50m, t.TotalExonerado);
        Assert.Equal(30m, t.TotalInafecto);
        Assert.Equal(18m, t.TotalIgv);       // solo sobre lo gravado
        Assert.Equal(180m, t.ValorVenta);
        Assert.Equal(198m, t.ImporteTotal);
    }

    // ---------------------------------------------------------- por línea

    [Fact]
    public void El_precio_unitario_incluye_el_igv()
    {
        var linea = Datos.Linea(cantidad: 3, valorUnitario: 10m);

        var c = CalculadoraTotales.CalcularLinea(linea);

        Assert.Equal(30m, c.ValorVenta);
        Assert.Equal(5.40m, c.Igv);
        Assert.Equal(11.80m, c.PrecioUnitarioConIgv);
    }

    [Fact]
    public void Una_cantidad_cero_no_rompe_el_calculo()
    {
        // Dividir entre la cantidad para obtener el precio unitario sería
        // una división por cero si nadie lo controla.
        var linea = Datos.Linea(cantidad: 0, valorUnitario: 10m);

        var c = CalculadoraTotales.CalcularLinea(linea);

        Assert.Equal(0m, c.PrecioUnitarioConIgv);
    }

    [Fact]
    public void Una_afectacion_desconocida_falla_en_vez_de_calcular_mal()
    {
        // Preferible una excepción ruidosa que un comprobante silenciosamente
        // incorrecto enviado a SUNAT.
        var factura = Datos.Factura(Datos.Linea(afectacion: "99"));

        Assert.ThrowsAny<Exception>(() => CalculadoraTotales.Calcular(factura));
    }
}
