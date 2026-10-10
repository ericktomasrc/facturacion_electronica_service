namespace Facturacion.Cpe;

/// <summary>
/// Reglas de las operaciones gratuitas: bonificaciones, muestras,
/// promociones, premios, donaciones, entregas a trabajadores.
///
/// LA IDEA, EN UNA FRASE: el cliente no paga nada, pero SUNAT quiere saber
/// cuánto valía lo que se entregó.
///
/// POR ESO UNA LÍNEA GRATUITA SE DECLARA AL REVÉS QUE UNA NORMAL:
///
///   cac:Price/cbc:PriceAmount           →  0.00   (no se cobró nada)
///   AlternativeConditionPrice, tipo 02  →  cuánto valía (mayor que cero)
///   cbc:LineExtensionAmount             →  ese valor por la cantidad
///   TaxSubtotal de la línea             →  tributo 9996 - GRA
///
/// En una línea normal el precio va en el primero y el segundo lleva el
/// precio con IGV. En una gratuita se invierten: el primero es cero y el
/// valor vive en el segundo. Ponerlo al revés produce el error 2640.
///
/// Y LO QUE NO ENTRA EN NINGÚN TOTAL: las gratuitas no suman al valor de
/// venta (regla 3277) ni al total de impuestos (regla 3294) ni al importe a
/// pagar. Aparecen solo en su propio subtotal 9996. El cliente no paga
/// nada por ellas, así que el documento no puede pedirle nada.
///
/// QUIÉN PAGA EL IGV ENTONCES: el que entrega. En las afectaciones 11 a 16
/// la ley grava el retiro de bienes aunque no haya venta, y ese impuesto
/// sale del bolsillo del emisor. En las 21 y 31 a 37 no hay IGV que pagar.
/// </summary>
public static class Gratuitas
{
    /// <summary>
    /// El texto de la leyenda 1002, que SUNAT fija palabra por palabra.
    /// </summary>
    public const string TextoLeyenda =
        "TRANSFERENCIA GRATUITA DE UN BIEN Y/O SERVICIO PRESTADO GRATUITAMENTE";

    /// <summary>¿Hay alguna línea gratuita en este comprobante?</summary>
    public static bool Hay(ComprobanteBase c) =>
        c.Lineas.Any(l => AfectacionIgv.EsGratuita(l.TipoAfectacionIgv));

    /// <summary>
    /// Revisa las líneas gratuitas. Lista vacía significa que pasa.
    /// Los textos que empiezan por "Aviso:" no impiden emitir.
    /// </summary>
    public static IReadOnlyList<string> Revisar(ComprobanteBase c)
    {
        var problemas = new List<string>();

        var gratuitas = c.Lineas
            .Where(l => AfectacionIgv.EsGratuita(l.TipoAfectacionIgv))
            .ToList();

        if (gratuitas.Count == 0) return problemas;

        foreach (var l in gratuitas)
        {
            // EL VALOR REFERENCIAL TIENE QUE SER MAYOR QUE CERO.
            //
            // Es lo que más se falla: como el cliente no paga, la intuición
            // dice poner cero. Pero entonces el comprobante no declara qué
            // se entregó, y SUNAT lo rechaza con el 2367.
            if (l.ValorUnitario <= 0)
            {
                problemas.Add(
                    $"La linea {l.Numero} es gratuita y necesita un valor " +
                    $"referencial mayor que cero: cuanto habria costado el bien " +
                    $"o servicio si se hubiera vendido. Cero no vale (error 2367).");
            }

            if (l.Cantidad <= 0)
            {
                problemas.Add(
                    $"La cantidad de la linea {l.Numero} debe ser mayor que cero.");
            }

            // Las gratuitas GRAVADAS declaran IGV, así que necesitan tasa.
            // Con tasa cero el impuesto saldría cero y SUNAT lo rechaza con
            // el 2993 y el 3111: si es gravada, tiene que tributar.
            if (AfectacionIgv.EsGratuitaGravada(l.TipoAfectacionIgv) &&
                l.PorcentajeIgv <= 0)
            {
                problemas.Add(
                    $"La linea {l.Numero} tiene la afectacion " +
                    $"{l.TipoAfectacionIgv}, que es gratuita GRAVADA, y por eso " +
                    $"necesita una tasa de IGV mayor que cero. El impuesto se " +
                    $"declara aunque no se cobre, y lo asume el emisor " +
                    $"(errores 2993 y 3111).");
            }
        }

        // --- Todas las líneas afectas al IGV, con la misma tasa --------------
        //
        // Regla 3462. Mezclar una línea al 18% con una gratuita al 10% en el
        // mismo comprobante lo invalida entero, y el mensaje de SUNAT no dice
        // qué línea es la rara.

        var tasas = c.Lineas
            .Where(l => AfectacionIgv.GeneraIgv(l.TipoAfectacionIgv))
            .Select(l => l.PorcentajeIgv)
            .Distinct()
            .ToList();

        if (tasas.Count > 1)
        {
            problemas.Add(
                $"Hay lineas afectas al IGV con tasas distintas " +
                $"({string.Join(", ", tasas.Select(t => $"{t:0.##}%"))}). Todas " +
                $"las lineas afectas, gratuitas incluidas, tienen que llevar la " +
                $"misma tasa vigente (error 3462).");
        }

        // --- Un comprobante enteramente gratuito no se puede emitir ----------
        //
        // El importe total (cbc:PayableAmount) es obligatorio y su formato
        // exige un decimal positivo DISTINTO DE CERO: error 2062. Si todas
        // las líneas son gratuitas, ese importe sale cero.
        //
        // No es un capricho: una factura sin importe no documenta una venta.
        // Lo que corresponde entonces es una nota de crédito por bonificación
        // sobre la factura original, no una factura en cero.

        if (gratuitas.Count == c.Lineas.Count)
        {
            problemas.Add(
                "Todas las lineas son gratuitas, asi que el importe total seria " +
                "cero y SUNAT rechaza el comprobante (error 2062). Una entrega " +
                "totalmente gratuita se documenta con una nota de credito por " +
                "bonificacion sobre la factura original, o anadiendo la gratuita " +
                "a la factura de la venta que la origina.");
        }

        return problemas;
    }

    /// <summary>Los problemas que impiden emitir. Los avisos quedan fuera.</summary>
    public static IReadOnlyList<string> Errores(ComprobanteBase c) =>
        Revisar(c).Where(p => !p.StartsWith("Aviso:")).ToList();
}
