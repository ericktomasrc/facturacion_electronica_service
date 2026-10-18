using Facturacion.Cpe;

namespace Facturacion.Tests;

/// <summary>
/// La lista de códigos de producto que usa la plataforma, y la comparación con
/// la de SUNAT (Vigilancia SUNAT, migración 031) — 14 de octubre de 2026.
/// </summary>
public class CatalogoProductosSunatTests
{
    [Fact]
    public void La_lista_en_uso_esta_completa_y_coincide_con_su_huella()
    {
        Assert.Equal(CatalogoProductosSunat.CantidadEnUso, CatalogoProductosSunat.EnUso.Count);
        Assert.Equal(CatalogoProductosSunat.HuellaEnUso,
            CatalogoProductosSunat.Huella(CatalogoProductosSunat.EnUso));
        Assert.Contains("50161509", CatalogoProductosSunat.EnUso);   // azúcares naturales
        Assert.Contains("50161500", CatalogoProductosSunat.EnUso);   // su clase
    }

    [Fact]
    public void Misma_lista_es_igual()
    {
        var d = CatalogoProductosSunat.Comparar(new HashSet<string>(CatalogoProductosSunat.EnUso));
        Assert.True(d.Igual);
    }

    [Fact]
    public void Dice_que_se_agrego_y_que_se_quito()
    {
        var deSunat = new HashSet<string>(CatalogoProductosSunat.EnUso);
        deSunat.Remove("50161509");
        deSunat.Add("50161599");

        var d = CatalogoProductosSunat.Comparar(deSunat);

        Assert.False(d.Igual);
        Assert.Equal(["50161599"], d.Agregados);
        Assert.Equal(["50161509"], d.Quitados);
    }

    [Fact]
    public void La_huella_no_depende_del_orden()
    {
        Assert.Equal(
            CatalogoProductosSunat.Huella(["10101501", "50161509"]),
            CatalogoProductosSunat.Huella(["50161509", "10101501", "50161509"]));
    }

    [Fact]
    public void Un_archivo_que_no_es_Excel_se_dice_claro()
    {
        var ex = Assert.Throws<FormatException>(() => LectorCatalogoXlsx.Leer([1, 2, 3]));
        Assert.Contains("no es un Excel", ex.Message);
    }
}