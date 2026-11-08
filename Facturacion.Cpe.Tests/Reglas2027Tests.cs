using System.Text.RegularExpressions;
using Facturacion.Cpe;

namespace Facturacion.Tests;

/// <summary>
/// LAS REGLAS DE SUNAT DE 2027 (14 de octubre de 2026). Detalle en el
/// documento del proyecto «cambios-sunat-2027.md».
///
/// Las fechas van escritas en cada prueba y no se toca VigenciaSunat: así
/// estas pruebas dan lo mismo hoy que el día que rijan las reglas.
/// </summary>
public class Reglas2027Tests
{
    private static LineaResumen LineaConGratuitas() => new()
    {
        Orden = 1,
        TipoComprobante = TipoComprobante.Boleta,
        Numero = "B001-00000001",
        Receptor = new Receptor { TipoDocumento = "1", NumeroDocumento = "12345678", RazonSocial = "CLIENTE" },
        TotalGravado = 100m,
        TotalIgv = 18m,
        TasaIgv = 18m,
        TotalGratuitoGravado = 20m,
        TotalGratuitoInafecto = 5m,
        TotalIgvGratuitas = 3.6m,
        ImporteTotal = 118m
    };

    private static List<string> CodigosDelResumen(DateTime fechaGeneracion)
    {
        var resumen = new ResumenDiario
        {
            Emisor = new Emisor { Ruc = "20999999990", RazonSocial = "PRUEBA" },
            FechaReferencia = fechaGeneracion.AddDays(-1),
            FechaGeneracion = fechaGeneracion,
            Lineas = [LineaConGratuitas()]
        };

        var xml = GeneradorResumenXml.Generar(resumen).ToString();

        return Regex.Matches(xml, @"InstructionID>(\d\d)<").Select(m => m.Groups[1].Value).ToList();
    }

    [Fact]
    public void Antes_de_2027_las_gratuitas_van_juntas_en_el_05()
    {
        Assert.Equal(["01", "05"], CodigosDelResumen(new DateTime(2026, 12, 31)));
    }

    [Fact]
    public void Desde_2027_las_gratuitas_van_por_clase()
    {
        // 20 gravadas → 06; 5 inafectas → 08. El 05 ya no aparece.
        Assert.Equal(["01", "06", "08"], CodigosDelResumen(new DateTime(2027, 1, 1)));
    }

    [Fact]
    public void Sin_informar_gratuitas_no_van_ni_el_importe_ni_el_9996()
    {
        // SUNAT beta (7 nov 2026) rechaza el 05 y el 06 con el 2256.
        foreach (var fecha in new[] { new DateTime(2026, 11, 7), new DateTime(2027, 1, 2) })
        {
            var resumen = new ResumenDiario
            {
                Emisor = new Emisor { Ruc = "20999999990", RazonSocial = "PRUEBA" },
                FechaReferencia = fecha.AddDays(-1),
                FechaGeneracion = fecha,
                Gratuitas = GratuitasResumen.NoInformar,
                Lineas = [LineaConGratuitas()]
            };

            var xml = GeneradorResumenXml.Generar(resumen).ToString();
            var codigos = Regex.Matches(xml, @"InstructionID>(\d\d)<").Select(m => m.Groups[1].Value).ToList();

            Assert.Equal(["01"], codigos);
            Assert.DoesNotContain(">GRA<", xml);
            Assert.Contains(">IGV<", xml);
        }
    }

    [Fact]
    public void Las_gratuitas_se_omiten_en_beta_y_van_por_fecha_en_produccion()
    {
        Assert.Equal(GratuitasResumen.NoInformar, VigenciaSunat.GratuitasPara("beta"));
        Assert.Equal(GratuitasResumen.SegunFecha, VigenciaSunat.GratuitasPara("produccion"));
        Assert.True(VigenciaSunat.LeerGratuitas(" Fecha ", out var f));
        Assert.Equal(GratuitasResumen.SegunFecha, f);
        Assert.False(VigenciaSunat.LeerGratuitas("otra", out _));
    }

    [Fact]
    public void El_resumen_lleva_la_tasa_y_el_igv_de_las_gratuitas()
    {
        var resumen = new ResumenDiario
        {
            Emisor = new Emisor { Ruc = "20999999990", RazonSocial = "PRUEBA" },
            FechaGeneracion = new DateTime(2027, 1, 1),
            FechaReferencia = new DateTime(2026, 12, 31),
            Lineas = [LineaConGratuitas()]
        };

        var xml = GeneradorResumenXml.Generar(resumen).ToString();

        Assert.Contains("Percent>18.00<", xml);   // 2992
        Assert.Contains(">GRA<", xml);            // tributo 9996
    }

    [Fact]
    public void La_liquidacion_de_compra_se_revierte_con_un_RR()
    {
        var rr = new ComunicacionBaja
        {
            Tipo = TipoComunicacionBaja.Reversion,
            FechaReferencia = RelojPeru.Hoy,
            Lineas = [new LineaBaja { Orden = 1, TipoComprobante = "04", Serie = "L001", Numero = 1, Motivo = "Error de digitacion" }]
        };

        Assert.Empty(ReglasBaja.Errores(rr));
    }

    [Fact]
    public void La_liquidacion_de_compra_no_va_en_una_comunicacion_de_baja()
    {
        var ra = new ComunicacionBaja
        {
            Tipo = TipoComunicacionBaja.Baja,
            FechaReferencia = RelojPeru.Hoy,
            Lineas = [new LineaBaja { Orden = 1, TipoComprobante = "04", Serie = "L001", Numero = 1, Motivo = "Error de digitacion" }]
        };

        Assert.Contains(ReglasBaja.Errores(ra), p => p.Contains("resumen de reversiones"));
    }

    [Fact]
    public void La_serie_de_una_liquidacion_empieza_con_L()
    {
        var rr = new ComunicacionBaja
        {
            Tipo = TipoComunicacionBaja.Reversion,
            FechaReferencia = RelojPeru.Hoy,
            Lineas = [new LineaBaja { Orden = 1, TipoComprobante = "04", Serie = "F001", Numero = 1, Motivo = "Error de digitacion" }]
        };

        Assert.Contains(ReglasBaja.Errores(rr), p => p.Contains("empieza por L"));
    }
}