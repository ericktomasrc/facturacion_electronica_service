namespace Facturacion.Cpe;

/// <summary>
/// Calcula IGV y totales. Sirve para factura, boleta y notas por igual:
/// las reglas de cálculo son las mismas, solo cambia el documento XML.
///
/// Aquí nace la mayoría de los rechazos de SUNAT: sus validaciones comparan
/// lo declarado contra lo que ellos recalculan, con una tolerancia mínima.
///
/// DOS REGLAS QUE HAY QUE RESPETAR SIEMPRE:
///
/// 1. Redondeo a 2 decimales con MidpointRounding.AwayFromZero.
///    El redondeo bancario que .NET trae por defecto trata los casos .5
///    de otra forma y produce diferencias de un céntimo.
///
/// 2. El total es la SUMA de los valores ya redondeados de cada línea,
///    no el redondeo de la suma sin redondear. Al revés aparecen descuadres
///    en comprobantes con muchos ítems.
/// </summary>
public static class CalculadoraTotales
{
    public static decimal Redondear(decimal valor) =>
        Math.Round(valor, 2, MidpointRounding.AwayFromZero);

    public static LineaCalculada CalcularLinea(LineaComprobante linea)
    {
        var valorVenta = Redondear(linea.Cantidad * linea.ValorUnitario);

        var igv = AfectacionIgv.GeneraIgv(linea.TipoAfectacionIgv)
            ? Redondear(valorVenta * linea.PorcentajeIgv / 100m)
            : 0m;

        var precioUnitarioConIgv = linea.Cantidad == 0
            ? 0m
            : Redondear((valorVenta + igv) / linea.Cantidad);

        return new LineaCalculada(linea, valorVenta, igv, precioUnitarioConIgv);
    }

    public static IReadOnlyList<LineaCalculada> CalcularLineas(ComprobanteBase comprobante) =>
        comprobante.Lineas.Select(CalcularLinea).ToList();

    public static TotalesComprobante Calcular(ComprobanteBase comprobante)
    {
        var calculadas = CalcularLineas(comprobante);

        decimal gravado = 0, exonerado = 0, inafecto = 0, gratuito = 0, igv = 0;

        foreach (var c in calculadas)
        {
            var afectacion = c.Linea.TipoAfectacionIgv;

            if (AfectacionIgv.EsGratuita(afectacion))
            {
                // El IGV de operaciones gratuitas se declara pero no se cobra.
                gratuito += c.ValorVenta;
                continue;
            }

            switch (afectacion)
            {
                case AfectacionIgv.GravadoOperacionOnerosa:
                    gravado += c.ValorVenta;
                    igv += c.Igv;
                    break;
                case AfectacionIgv.Exonerado:
                    exonerado += c.ValorVenta;
                    break;
                case AfectacionIgv.Inafecto:
                    inafecto += c.ValorVenta;
                    break;
                case AfectacionIgv.Exportacion:
                    gravado += c.ValorVenta;
                    break;
                default:
                    throw new InvalidOperationException(
                        $"Afectación no contemplada en el cálculo: {afectacion}");
            }
        }

        var valorVenta = Redondear(gravado + exonerado + inafecto);
        var importeTotal = Redondear(valorVenta + igv);

        return new TotalesComprobante(
            TotalGravado:   Redondear(gravado),
            TotalExonerado: Redondear(exonerado),
            TotalInafecto:  Redondear(inafecto),
            TotalGratuito:  Redondear(gratuito),
            TotalIgv:       Redondear(igv),
            ValorVenta:     valorVenta,
            ImporteTotal:   importeTotal);
    }
}
