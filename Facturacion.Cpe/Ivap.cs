namespace Facturacion.Cpe;

/// <summary>
/// Impuesto a la Venta de Arroz Pilado. Tributo 1016, afectación 17.
///
/// QUÉ ES: el arroz pilado no paga IGV. Paga un impuesto propio del 4% que
/// lo sustituye. No son dos impuestos: es uno en lugar del otro.
///
/// A QUIÉN LE TOCA: a los molinos y a quien vende arroz pilado. La primera
/// venta después del pilado es la que tributa.
///
/// LA REGLA QUE LO GOBIERNA TODO ES LA 2644: un comprobante sujeto al IVAP
/// solo puede tener líneas con afectación 17. Ni una gravada, ni una
/// exonerada, ni una gratuita. O el comprobante entero es de arroz pilado,
/// o no lo es.
///
/// Eso lo hace, por suerte, el régimen más fácil de los que faltaban: no
/// interactúa con nada. Un comprobante IVAP tampoco lleva ISC (regla 2650)
/// ni puede ser de exportación (regla 3107).
/// </summary>
public static class Ivap
{
    public const string Codigo = "1016";
    public const string Nombre = "IVAP";
    public const string TipoCodigo = "VAT";

    /// <summary>
    /// La tasa vigente: 4%.
    ///
    /// SE DECLARA AQUÍ Y NO LA MANDA EL CLIENTE porque equivocarla no da un
    /// error de formato: da un comprobante que declara mal el impuesto y que
    /// SUNAT recalcula con la tasa que toca (regla 3295). Si algún día la
    /// cambian, se toca este número y nada más.
    /// </summary>
    public const decimal Tasa = 4m;

    /// <summary>
    /// El texto de la leyenda 2007, que acompaña a todo comprobante de
    /// arroz pilado.
    ///
    /// SIN ELLA EL COMPROBANTE SE ACEPTA IGUAL, pero con la observación
    /// 4264 colgando del CDR. Una aceptación con observaciones no es un
    /// rechazo, pero es una mancha que el contador del cliente ve y
    /// pregunta.
    /// </summary>
    public const string TextoLeyenda = "OPERACION SUJETA AL IVAP";

    /// <summary>¿Este comprobante está sujeto al IVAP?</summary>
    public static bool Aplica(ComprobanteBase c) =>
        c.Lineas.Any(l => l.TipoAfectacionIgv == AfectacionIgv.GravadoIvap);
}

/// <summary>
/// Reglas del IVAP.
///
///   2644  Todas las líneas tienen que ser IVAP. Sin excepciones.
///   2650  Una factura IVAP no lleva ISC.
///   3107  Una exportación no lleva IVAP.
///   3103  El impuesto es la tasa por la base.
///   3295  SUNAT lo recalcula con la tasa vigente y compara.
/// </summary>
public static class ReglasIvap
{
    /// <summary>
    /// Revisa un comprobante sujeto al IVAP. Lista vacía significa que pasa.
    /// Los textos que empiezan por "Aviso:" no impiden emitir.
    /// </summary>
    public static IReadOnlyList<string> Revisar(ComprobanteBase c)
    {
        var problemas = new List<string>();

        if (!Ivap.Aplica(c)) return problemas;

        // --- Todo o nada -----------------------------------------------------
        //
        // Es la regla 2644, y es la que sorprende: no se puede vender arroz
        // pilado y un saco de azúcar en la misma factura. Son dos
        // comprobantes distintos.

        var ajenas = c.Lineas
            .Where(l => l.TipoAfectacionIgv != AfectacionIgv.GravadoIvap)
            .Select(l => $"la linea {l.Numero} lleva '{l.TipoAfectacionIgv}'")
            .ToList();

        if (ajenas.Count > 0)
        {
            problemas.Add(
                $"Un comprobante sujeto al IVAP solo puede tener lineas con " +
                $"afectacion 17, y {string.Join(", ", ajenas)}. El arroz " +
                $"pilado va en su propio comprobante: no se mezcla con ventas " +
                $"gravadas, exoneradas ni gratuitas (error 2644).");

            return problemas;
        }

        // --- No se combina con otros regímenes --------------------------------

        if (c is Factura f)
        {
            if (f.EsExportacion)
            {
                problemas.Add(
                    "Una factura de exportacion no puede estar sujeta al IVAP " +
                    "(error 3107). El arroz que se exporta va con afectacion " +
                    "'40', no con '17'.");
            }

            if (f.Percepcion is not null)
            {
                problemas.Add(
                    "El IVAP y la percepcion no van juntos: la percepcion se " +
                    "aplica sobre operaciones gravadas con IGV, y el arroz " +
                    "pilado no lo esta.");
            }
        }

        // --- La tasa ----------------------------------------------------------

        foreach (var l in c.Lineas)
        {
            if (l.PorcentajeIgv != Ivap.Tasa)
            {
                problemas.Add(
                    $"La linea {l.Numero} declara {l.PorcentajeIgv:0.##}% y la " +
                    $"tasa del IVAP es {Ivap.Tasa:0.##}%. SUNAT recalcula el " +
                    $"impuesto con la tasa vigente y compara (error 3295).");
            }

            if (l.ValorUnitario <= 0)
            {
                problemas.Add(
                    $"La linea {l.Numero} necesita un valor unitario mayor que " +
                    $"cero.");
            }
        }

        return problemas;
    }

    /// <summary>Los problemas que impiden emitir. Los avisos quedan fuera.</summary>
    public static IReadOnlyList<string> Errores(ComprobanteBase c) =>
        Revisar(c).Where(p => !p.StartsWith("Aviso:")).ToList();
}