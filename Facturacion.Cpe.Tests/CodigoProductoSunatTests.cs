using System.Xml.Linq;
using Facturacion.Cpe;

namespace Facturacion.Tests;

/// <summary>
/// EL CÓDIGO DE PRODUCTO SUNAT (catálogo 25) — 14 de octubre de 2026.
///
/// Que viaje en el XML en su sitio, que su forma se compruebe, y que en la
/// liquidación de compra sea obligatorio desde las reglas de 2027. Las fechas
/// van escritas en cada prueba: dan lo mismo hoy que en 2027.
/// </summary>
public class CodigoProductoSunatTests
{
    private static readonly XNamespace Cac =
        "urn:oasis:names:specification:ubl:schema:xsd:CommonAggregateComponents-2";

    private static Factura FacturaCon(string? codigoSunat) => new()
    {
        Serie = "F001",
        Correlativo = 1,
        FechaEmision = new DateTime(2026, 10, 14),
        Emisor = new Emisor { Ruc = "20999999990", RazonSocial = "PRUEBA" },
        Receptor = new Receptor { NumeroDocumento = "20100066603", RazonSocial = "CLIENTE" },
        Lineas =
        [
            new LineaComprobante
            {
                Numero = 1, CodigoProducto = "AZU-1K", CodigoProductoSunat = codigoSunat,
                Descripcion = "AZUCAR RUBIA", Cantidad = 2, ValorUnitario = 4m,
                TipoAfectacionIgv = "10", PorcentajeIgv = 18m
            }
        ]
    };

    private static LiquidacionCompra LiquidacionCon(string? codigoSunat, DateTime fecha) => new()
    {
        Serie = "L001",
        Correlativo = 1,
        FechaEmision = fecha,
        Emisor = new Emisor { Ruc = "20999999990", RazonSocial = "PRUEBA" },
        Vendedor = new Vendedor { NumeroDocumento = "12345678", Nombres = "JUAN PEREZ", Direccion = "CHACRA 1", Ubigeo = "150101" },
        Lugar = new LugarOperacion { Direccion = "CHACRA 1", Ubigeo = "150101" },
        Lineas =
        [
            new LineaComprobante
            {
                Numero = 1, CodigoProducto = "CAFE", CodigoProductoSunat = codigoSunat,
                Descripcion = "CAFE EN GRANO", Cantidad = 100, ValorUnitario = 10m,
                TipoAfectacionIgv = "10", PorcentajeIgv = 18m
            }
        ]
    };

    private static XElement Item(XDocument xml) =>
        xml.Descendants(Cac + "Item").Single();

    [Fact]
    public void La_factura_lleva_el_codigo_en_su_sitio()
    {
        var item = Item(GeneradorFacturaXml.Generar(FacturaCon("50161509")));

        var hijos = item.Elements().Select(e => e.Name.LocalName).ToList();
        Assert.Equal(["Description", "SellersItemIdentification", "CommodityClassification"], hijos);

        var codigo = item.Element(Cac + "CommodityClassification")!.Elements().Single();
        Assert.Equal("ItemClassificationCode", codigo.Name.LocalName);
        Assert.Equal("50161509", codigo.Value);
        Assert.Equal("UNSPSC", (string?)codigo.Attribute("listID"));
        Assert.Equal("GS1 US", (string?)codigo.Attribute("listAgencyName"));
        Assert.Equal("Item Classification", (string?)codigo.Attribute("listName"));
    }

    [Fact]
    public void Sin_codigo_no_se_escribe_nada()
    {
        var item = Item(GeneradorFacturaXml.Generar(FacturaCon(null)));
        Assert.Null(item.Element(Cac + "CommodityClassification"));
    }

    [Fact]
    public void La_liquidacion_lleva_el_codigo()
    {
        var xml = GeneradorLiquidacionXml.Generar(LiquidacionCon("10101501", new DateTime(2027, 1, 2)));
        Assert.Contains(">10101501<", xml.ToString());
    }

    [Fact]
    public void Sin_codigo_vale() =>
        Assert.Null(CodigoProductoSunat.Problema(null));

    [Theory]
    [InlineData("")]
    [InlineData("50161509")]   // producto
    [InlineData("50161500")]   // clase: el mínimo
    [InlineData("00000000")]
    [InlineData("99999999")]
    public void Formas_validas(string codigo) =>
        Assert.Null(CodigoProductoSunat.Problema(codigo));

    [Theory]
    [InlineData("AZU-1K")]     // el código propio en la casilla equivocada
    [InlineData("5016150")]    // siete dígitos
    [InlineData("501615090")]  // nueve
    [InlineData("50160000")]   // familia
    [InlineData("50000000")]   // segmento
    public void Formas_invalidas(string codigo) =>
        Assert.NotNull(CodigoProductoSunat.Problema(codigo));

    [Fact]
    public void Los_problemas_dicen_la_linea()
    {
        var p = CodigoProductoSunat.Problemas([null, "50161509", "ABC"]);
        Assert.Single(p);
        Assert.StartsWith("Linea 3:", p[0]);
    }

    [Fact]
    public void Liquidacion_sin_codigo_antes_de_2027_es_aviso()
    {
        var lc = LiquidacionCon(null, new DateTime(2026, 12, 31));
        Assert.DoesNotContain(ReglasLiquidacion.Errores(lc), e => e.Contains("3506"));
        Assert.Contains(ReglasLiquidacion.Avisos(lc), a => a.Contains("3506"));
    }

    [Fact]
    public void Liquidacion_sin_codigo_desde_2027_es_error()
    {
        var lc = LiquidacionCon(null, new DateTime(2027, 1, 1));
        Assert.Contains(ReglasLiquidacion.Errores(lc), e => e.Contains("3506"));
    }

    [Fact]
    public void Liquidacion_con_codigo_invalido_es_error_siempre()
    {
        var lc = LiquidacionCon("12340000", new DateTime(2026, 10, 14));
        Assert.Contains(ReglasLiquidacion.Errores(lc), e => e.StartsWith("Linea 1:"));
    }
}