using Facturacion.Cpe;

namespace Facturacion.Tests;

/// <summary>
/// Pruebas de la leyenda con el importe en letras.
///
/// SUNAT exige esta leyenda en todo comprobante. Es fácil de pasar por alto
/// porque no afecta al cálculo, pero su ausencia o un formato incorrecto
/// genera observaciones.
/// </summary>
public class NumeroALetrasTests
{
    [Theory]
    [InlineData(118.00, "SON CIENTO DIECIOCHO CON 00/100 SOLES")]
    [InlineData(0.00, "SON CERO CON 00/100 SOLES")]
    [InlineData(1.50, "SON UNO CON 50/100 SOLES")]
    [InlineData(15.00, "SON QUINCE CON 00/100 SOLES")]
    [InlineData(21.00, "SON VEINTIUNO CON 00/100 SOLES")]
    [InlineData(100.00, "SON CIEN CON 00/100 SOLES")]
    [InlineData(115.00, "SON CIENTO QUINCE CON 00/100 SOLES")]
    [InlineData(1000.00, "SON MIL CON 00/100 SOLES")]
    [InlineData(2500.00, "SON DOS MIL QUINIENTOS CON 00/100 SOLES")]
    [InlineData(1000000.00, "SON UN MILLON CON 00/100 SOLES")]
    [InlineData(2000000.00, "SON DOS MILLONES CON 00/100 SOLES")]
    public void Convierte_importes_a_letras(decimal importe, string esperado)
    {
        Assert.Equal(esperado, NumeroALetras.Leyenda(importe));
    }

    [Fact]
    public void Usa_el_nombre_correcto_de_cada_moneda()
    {
        Assert.Contains("SOLES", NumeroALetras.Leyenda(10m, "PEN"));
        Assert.Contains("DOLARES AMERICANOS", NumeroALetras.Leyenda(10m, "USD"));
        Assert.Contains("EUROS", NumeroALetras.Leyenda(10m, "EUR"));
    }

    [Fact]
    public void Los_centimos_que_redondean_a_cien_suben_al_entero()
    {
        // 9.999 debería leerse como diez con 00/100, no como nueve con 100/100.
        Assert.Equal("SON DIEZ CON 00/100 SOLES", NumeroALetras.Leyenda(9.999m));
    }

    [Fact]
    public void Formatea_los_importes_con_dos_decimales_y_punto()
    {
        // Si la máquina tuviera configuración regional con coma decimal,
        // el XML saldría con "118,00" y SUNAT lo rechazaría.
        Assert.Equal("118.00", NumeroALetras.F2(118m));
        Assert.Equal("0.50", NumeroALetras.F2(0.5m));
    }
}

/// <summary>
/// Pruebas de la numeración y el nombre de archivo.
///
/// El nombre del archivo es parte de la validación de SUNAT, no una formalidad:
/// si no calza con lo que declara el XML por dentro, hay rechazo, y el mensaje
/// de error no suele decir que el problema es el nombre.
/// </summary>
public class NombresYNumeracionTests
{
    [Fact]
    public void El_correlativo_se_rellena_a_ocho_digitos()
    {
        var factura = Datos.Factura();
        factura.Correlativo = 7;

        Assert.Equal("F001-00000007", factura.NumeroCompleto);
    }

    [Fact]
    public void El_nombre_de_archivo_sigue_la_convencion_de_sunat()
    {
        var factura = Datos.Factura();

        // RUC - tipo de comprobante - serie - correlativo
        Assert.Equal("20601234567-01-F001-00000001", factura.NombreArchivo);
    }

    [Fact]
    public void Cada_tipo_de_documento_lleva_su_propio_codigo()
    {
        Assert.Equal("01", Datos.Factura().TipoComprobante);
        Assert.Equal("07", Datos.NotaCredito().TipoComprobante);
        Assert.Equal("08", new NotaDebito().TipoComprobante);
        Assert.Equal("03", new Boleta().TipoComprobante);
    }

    [Fact]
    public void El_resumen_diario_usa_la_nomenclatura_RC()
    {
        var resumen = new ResumenDiario
        {
            Emisor = Datos.Emisor(),
            FechaGeneracion = new DateTime(2026, 9, 14),
            Correlativo = 3
        };

        Assert.Equal("RC-20260914-3", resumen.Identificador);
        Assert.Equal("20601234567-RC-20260914-3", resumen.NombreArchivo);
    }

    [Fact]
    public void La_comunicacion_de_baja_usa_la_nomenclatura_RA()
    {
        var baja = new ComunicacionBaja
        {
            Emisor = Datos.Emisor(),
            FechaGeneracion = new DateTime(2026, 9, 14),
            Correlativo = 1
        };

        Assert.Equal("RA-20260914-1", baja.Identificador);
        Assert.Equal("20601234567-RA-20260914-1", baja.NombreArchivo);
    }

    [Fact]
    public void El_cdr_lleva_el_prefijo_R()
    {
        Assert.Equal(
            "R-20601234567-01-F001-00000001",
            LectorCdr.NombreArchivoCdr("20601234567-01-F001-00000001"));
    }
}
