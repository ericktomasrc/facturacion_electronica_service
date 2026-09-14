namespace Facturacion.Cpe;

/// <summary>
/// Calcula descuentos, IGV y totales. Sirve para factura, boleta y notas.
///
/// CÓMO SE TRATA EL DESCUENTO GLOBAL, Y POR QUÉ:
///
/// SUNAT exige que la base imponible declarada en el documento sea exactamente
/// la suma de los valores de venta de las líneas (validación 3277). Por eso el
/// descuento global NO se declara aparte: se reparte dentro de las líneas.
///
/// Cada línea combina su propio descuento con su parte del global en un único
/// factor efectivo, aplicado en cascada:
///
///     factor = 1 - (1 - descuentoLinea) x (1 - descuentoGlobal)
///
/// Con 10% de línea y 10% global, el factor no es 20% sino 19%: el global se
/// aplica sobre lo que quedó después del de línea, no sobre el bruto.
///
/// TRES REGLAS MÁS QUE HAY QUE RESPETAR SIEMPRE:
///
/// 1. Redondeo a 2 decimales con MidpointRounding.AwayFromZero. El redondeo
///    bancario que .NET trae por defecto produce diferencias de un céntimo.
///
/// 2. El total es la SUMA de los valores ya redondeados de cada línea,
///    no el redondeo de la suma sin redondear.
///
/// 3. El descuento va ANTES del IGV.
/// </summary>
public static class CalculadoraTotales
{
    public static decimal Redondear(decimal valor) =>
        Math.Round(valor, 2, MidpointRounding.AwayFromZero);

    /// <summary>
    /// Factor de descuento efectivo de una línea, combinando el suyo propio
    /// con el descuento global del comprobante.
    ///
    /// Se redondea a 5 decimales porque es el valor que viaja al XML en
    /// MultiplierFactorNumeric, y SUNAT recalcula Amount = Base x Factor.
    /// Si aquí se usara más precisión que la declarada, no cuadraría.
    /// </summary>
    public static decimal FactorDescuento(decimal porcentajeLinea, decimal porcentajeGlobal)
    {
        if (porcentajeLinea <= 0 && porcentajeGlobal <= 0) return 0m;

        var restanteLinea = 1m - porcentajeLinea / 100m;
        var restanteGlobal = 1m - porcentajeGlobal / 100m;

        return Math.Round(
            1m - restanteLinea * restanteGlobal, 5, MidpointRounding.AwayFromZero);
    }

    public static LineaCalculada CalcularLinea(
        LineaComprobante linea, decimal descuentoGlobalPorcentaje = 0m)
    {
        var valorBruto = Redondear(linea.Cantidad * linea.ValorUnitario);

        var factor = FactorDescuento(
            linea.DescuentoPorcentaje, descuentoGlobalPorcentaje);

        var descuento = factor > 0 ? Redondear(valorBruto * factor) : 0m;

        // Orden importante: primero el descuento, después el impuesto.
        var valorVenta = valorBruto - descuento;

        var igv = AfectacionIgv.GeneraIgv(linea.TipoAfectacionIgv)
            ? Redondear(valorVenta * linea.PorcentajeIgv / 100m)
            : 0m;

        var precioUnitarioConIgv = linea.Cantidad == 0
            ? 0m
            : Redondear((valorVenta + igv) / linea.Cantidad);

        return new LineaCalculada(
            linea, factor, valorBruto, descuento, valorVenta, igv, precioUnitarioConIgv);
    }

    public static IReadOnlyList<LineaCalculada> CalcularLineas(ComprobanteBase comprobante) =>
        comprobante.Lineas
            .Select(l => CalcularLinea(l, comprobante.DescuentoGlobalPorcentaje))
            .ToList();

    public static TotalesComprobante Calcular(ComprobanteBase comprobante)
    {
        var calculadas = CalcularLineas(comprobante);

        decimal gravado = 0, exonerado = 0, inafecto = 0, gratuito = 0;
        decimal descuentos = 0, igv = 0;

        foreach (var c in calculadas)
        {
            var afectacion = c.Linea.TipoAfectacionIgv;

            descuentos += c.Descuento;

            if (AfectacionIgv.EsGratuita(afectacion))
            {
                // El IGV de operaciones gratuitas se declara pero no se cobra.
                gratuito += c.ValorVenta;
                continue;
            }

            switch (afectacion)
            {
                case AfectacionIgv.GravadoOperacionOnerosa:
                case AfectacionIgv.Exportacion:
                    gravado += c.ValorVenta;
                    igv += c.Igv;
                    break;
                case AfectacionIgv.Exonerado:
                    exonerado += c.ValorVenta;
                    break;
                case AfectacionIgv.Inafecto:
                    inafecto += c.ValorVenta;
                    break;
                default:
                    throw new InvalidOperationException(
                        $"Afectación no contemplada en el cálculo: {afectacion}");
            }
        }

        var valorVenta = Redondear(gravado + exonerado + inafecto);
        var importeTotal = Redondear(valorVenta + igv);

        return new TotalesComprobante(
            TotalGravado:     Redondear(gravado),
            TotalExonerado:   Redondear(exonerado),
            TotalInafecto:    Redondear(inafecto),
            TotalGratuito:    Redondear(gratuito),
            TotalDescuentos:  Redondear(descuentos),
            TotalIgv:         Redondear(igv),
            ValorVenta:       valorVenta,
            ImporteTotal:     importeTotal);
    }
}
