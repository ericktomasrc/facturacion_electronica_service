namespace Facturacion.Cpe;

/// <summary>
/// Calcula descuentos, IGV y totales. Sirve para factura, boleta y notas.
///
/// Aquí nace la mayoría de los rechazos de SUNAT: sus validaciones comparan
/// lo declarado contra lo que ellos recalculan, con una tolerancia mínima.
///
/// TRES REGLAS QUE HAY QUE RESPETAR SIEMPRE:
///
/// 1. Redondeo a 2 decimales con MidpointRounding.AwayFromZero.
///    El redondeo bancario que .NET trae por defecto trata los casos .5
///    de otra forma y produce diferencias de un céntimo.
///
/// 2. El total es la SUMA de los valores ya redondeados de cada línea,
///    no el redondeo de la suma sin redondear.
///
/// 3. EL DESCUENTO VA ANTES DEL IGV. El impuesto se calcula sobre el valor
///    ya descontado. Al revés, el cliente pagaría impuesto sobre un monto
///    que nunca se le cobró, y SUNAT lo rechaza.
/// </summary>
public static class CalculadoraTotales
{
    public static decimal Redondear(decimal valor) =>
        Math.Round(valor, 2, MidpointRounding.AwayFromZero);

    public static LineaCalculada CalcularLinea(LineaComprobante linea)
    {
        var valorBruto = Redondear(linea.Cantidad * linea.ValorUnitario);

        var descuento = linea.TieneDescuento
            ? Redondear(valorBruto * linea.DescuentoPorcentaje / 100m)
            : 0m;

        // Orden importante: primero el descuento, después el impuesto.
        var valorVenta = valorBruto - descuento;

        var igv = AfectacionIgv.GeneraIgv(linea.TipoAfectacionIgv)
            ? Redondear(valorVenta * linea.PorcentajeIgv / 100m)
            : 0m;

        var precioUnitarioConIgv = linea.Cantidad == 0
            ? 0m
            : Redondear((valorVenta + igv) / linea.Cantidad);

        return new LineaCalculada(
            linea, valorBruto, descuento, valorVenta, igv, precioUnitarioConIgv);
    }

    public static IReadOnlyList<LineaCalculada> CalcularLineas(ComprobanteBase comprobante) =>
        comprobante.Lineas.Select(CalcularLinea).ToList();

    public static TotalesComprobante Calcular(ComprobanteBase comprobante)
    {
        var calculadas = CalcularLineas(comprobante);

        decimal gravado = 0, exonerado = 0, inafecto = 0, gratuito = 0;
        decimal igv = 0, descuentos = 0;

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
