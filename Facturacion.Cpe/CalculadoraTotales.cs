namespace Facturacion.Cpe;

/// <summary>
/// Calcula IGV y totales.
///
/// Aquí es donde nacen la mayoría de los rechazos de SUNAT: sus validaciones
/// comparan lo que declaras contra lo que recalculan ellos, con una tolerancia
/// muy pequeña. Dos reglas que hay que respetar siempre:
///
/// 1. Redondeo a 2 decimales con MidpointRounding.AwayFromZero.
///    El redondeo bancario de .NET (el que trae por defecto) da resultados
///    distintos en los casos .5 y produce diferencias de un céntimo.
///
/// 2. El total del comprobante es la SUMA de los valores ya redondeados de
///    cada línea, no el redondeo de la suma sin redondear. Si se hace al revés
///    aparecen descuadres de céntimos en facturas con muchos ítems.
/// </summary>
public static class CalculadoraTotales
{
    public static decimal Redondear(decimal valor) =>
        Math.Round(valor, 2, MidpointRounding.AwayFromZero);

    public static LineaCalculada CalcularLinea(LineaFactura linea)
    {
        var valorVenta = Redondear(linea.Cantidad * linea.ValorUnitario);

        var igv = AfectacionIgv.GeneraIgv(linea.TipoAfectacionIgv)
            ? Redondear(valorVenta * linea.PorcentajeIgv / 100m)
            : 0m;

        // Precio unitario que ve el cliente, con IGV incluido.
        var precioUnitarioConIgv = linea.Cantidad == 0
            ? 0m
            : Redondear((valorVenta + igv) / linea.Cantidad);

        return new LineaCalculada(linea, valorVenta, igv, precioUnitarioConIgv);
    }

    public static IReadOnlyList<LineaCalculada> CalcularLineas(Factura factura) =>
        factura.Lineas.Select(CalcularLinea).ToList();

    public static TotalesFactura Calcular(Factura factura)
    {
        var calculadas = CalcularLineas(factura);

        decimal gravado = 0, exonerado = 0, inafecto = 0, gratuito = 0, igv = 0;

        foreach (var c in calculadas)
        {
            var afectacion = c.Linea.TipoAfectacionIgv;

            if (AfectacionIgv.EsGratuita(afectacion))
            {
                gratuito += c.ValorVenta;
                // El IGV de operaciones gratuitas se declara pero no se cobra.
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

        // Base imponible total (no incluye las operaciones gratuitas).
        var valorVenta = Redondear(gravado + exonerado + inafecto);
        var importeTotal = Redondear(valorVenta + igv);

        return new TotalesFactura(
            TotalGravado:   Redondear(gravado),
            TotalExonerado: Redondear(exonerado),
            TotalInafecto:  Redondear(inafecto),
            TotalGratuito:  Redondear(gratuito),
            TotalIgv:       Redondear(igv),
            ValorVenta:     valorVenta,
            ImporteTotal:   importeTotal);
    }
}
