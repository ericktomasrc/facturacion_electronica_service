using Facturacion.Cpe;

namespace Facturacion.Tests;

/// <summary>
/// La boleta de más de S/ 700 identifica al comprador (Reglamento de
/// Comprobantes de Pago, art. 8, num. 3.10).
/// </summary>
public class BoletaIdentificadaTests
{
    private static Boleta Boleta(decimal valorUnitario, Receptor receptor,
                                 string moneda = "PEN", decimal? tasa = null) => new()
    {
        Serie = "B001",
        Moneda = moneda,
        TipoCambio = tasa is { } t ? new TipoCambio { Tasa = t } : null,
        Emisor = new Emisor { Ruc = "20999999990", RazonSocial = "PRUEBA" },
        Receptor = receptor,
        Lineas =
        [
            new LineaComprobante
            {
                Numero = 1, Descripcion = "PRODUCTO", UnidadMedida = "NIU", Cantidad = 1,
                ValorUnitario = valorUnitario, TipoAfectacionIgv = "10", PorcentajeIgv = 18m
            }
        ]
    };

    private static Receptor Mostrador() =>
        new() { TipoDocumento = "0", NumeroDocumento = "-", RazonSocial = "CLIENTES VARIOS" };

    private static Receptor ConDni() =>
        new() { TipoDocumento = "1", NumeroDocumento = "45678912", RazonSocial = "ANA TORRES" };

    [Fact]
    public void Hasta_700_la_boleta_de_mostrador_pasa()
    {
        // 593.22 + 18 % = 700.00 exactos: no supera el tope.
        Assert.Empty(BoletaIdentificada.Errores(Boleta(593.22m, Mostrador())));
    }

    [Fact]
    public void Mas_de_700_sin_identificar_no_pasa()
    {
        var errores = BoletaIdentificada.Errores(Boleta(600m, Mostrador()));   // 708.00
        Assert.Contains("708.00", Assert.Single(errores));
    }

    [Fact]
    public void Mas_de_700_con_dni_pasa()
    {
        Assert.Empty(BoletaIdentificada.Errores(Boleta(5000m, ConDni())));
    }

    [Theory]
    [InlineData("1", "00000000", "JUAN PEREZ")]
    [InlineData("1", "99999999", "JUAN PEREZ")]
    [InlineData("1", "11111111", "JUAN PEREZ")]
    [InlineData("1", "45678912", "Público en general")]
    [InlineData("1", "45678912", "  clientes   varios ")]
    [InlineData("0", "12345", "JUAN PEREZ")]
    public void El_receptor_de_mostrador_se_reconoce(string tipo, string numero, string nombre)
    {
        Assert.True(BoletaIdentificada.SinIdentificar(
            new Receptor { TipoDocumento = tipo, NumeroDocumento = numero, RazonSocial = nombre }));
    }

    [Fact]
    public void En_dolares_se_compara_en_soles()
    {
        // 200 + IGV = 236 USD; a 3.750 son S/ 885.00: supera el tope.
        var errores = BoletaIdentificada.Errores(Boleta(200m, Mostrador(), "USD", 3.75m));
        Assert.Contains("885.00", Assert.Single(errores));

        // 150 + IGV = 177 USD; a 3.750 son S/ 663.75: no lo supera.
        Assert.Empty(BoletaIdentificada.Errores(Boleta(150m, Mostrador(), "USD", 3.75m)));
    }

    [Fact]
    public void En_dolares_sin_tipo_de_cambio_y_sin_identificar_no_pasa()
    {
        Assert.Single(BoletaIdentificada.Errores(Boleta(10m, Mostrador(), "USD", 0m)));
        Assert.Empty(BoletaIdentificada.Errores(Boleta(10m, ConDni(), "USD", 0m)));
    }

    [Fact]
    public void La_factura_no_se_mira()
    {
        var factura = new Factura
        {
            Serie = "F001",
            Emisor = new Emisor { Ruc = "20999999990", RazonSocial = "PRUEBA" },
            Receptor = Mostrador(),
            Lineas = Boleta(5000m, Mostrador()).Lineas
        };

        Assert.Empty(BoletaIdentificada.Errores(factura));
    }
}