namespace Facturacion.Cpe;

/// <summary>
/// Impuesto al Consumo de las Bolsas de Plástico. Tributo 7152.
///
/// QUÉ ES: un monto fijo POR BOLSA, no un porcentaje. Lo paga el cliente que
/// se lleva la bolsa, y lo recauda quien se la entrega.
///
/// A QUIÉN LE TOCA: a todo el que entregue bolsas de plástico a un
/// consumidor final. Una ferretería que da bolsas en el mostrador está
/// dentro; una que despacha en cajas y palés, no.
///
/// POR QUÉ SE DECLARA RARO. Es el único tributo del sistema que no se
/// calcula sobre una base imponible, y eso cambia tres cosas:
///
///   1. Su TaxSubtotal NO lleva cbc:Percent. Ponerlo no tiene sentido —no
///      hay porcentaje— y el catálogo lo exime a propósito (regla 2992,
///      que dice "si el código de tributo es DIFERENTE de 7152").
///   2. Lleva dos campos que ningún otro tributo usa: cbc:BaseUnitMeasure
///      (cuántas bolsas) y cbc:PerUnitAmount (cuánto por bolsa).
///   3. Su monto base es cero. Por eso puede convivir en la misma línea con
///      el IGV sin romper la regla 3223 de combinaciones de tributos: esa
///      regla solo mira los tributos con monto base mayor que cero.
///
/// Y SÍ ENTRA EN EL IMPORTE TOTAL, al revés que las gratuitas o la
/// percepción: la regla 3279 lo suma dentro del precio de venta.
/// </summary>
public static class Icbper
{
    public const string Codigo = "7152";
    public const string Nombre = "ICBPER";
    public const string TipoCodigo = "OTH";

    /// <summary>
    /// Desde cuándo existe el impuesto. Antes de esta fecha, declararlo con
    /// monto mayor que cero es el error 2949.
    /// </summary>
    public static readonly DateTime Vigencia = new(2019, 8, 1);

    /// <summary>
    /// La tasa por bolsa según el año, tal como la fijó la Ley 30884.
    ///
    /// SUBÍA DIEZ CÉNTIMOS AL AÑO HASTA 2023 y ahí se quedó fija. La tabla
    /// se declara entera en vez de calcularse porque la ley es una escala,
    /// no una fórmula, y el día que la cambien se toca aquí y en ningún
    /// otro sitio.
    ///
    /// Si algún año futuro la cambian, esta tabla es lo único que hay que
    /// actualizar — y mientras tanto devuelve el último valor conocido.
    /// </summary>
    public static decimal TasaVigente(DateTime fechaEmision) => fechaEmision.Year switch
    {
        <= 2018 => 0m,
        2019    => 0.10m,
        2020    => 0.20m,
        2021    => 0.30m,
        2022    => 0.40m,
        _       => 0.50m
    };

    /// <summary>
    /// El impuesto de una línea: la tasa por la cantidad de bolsas.
    ///
    /// La cantidad de bolsas ES la cantidad de la línea. No son dos números
    /// distintos: la regla 3236 exige que coincidan, y con razón — si la
    /// línea dice "3 bolsas", cobrar el impuesto de cinco sería inventar.
    /// </summary>
    public static decimal Calcular(decimal tasaPorBolsa, decimal cantidad) =>
        CalculadoraTotales.Redondear(tasaPorBolsa * cantidad);
}

/// <summary>
/// Reglas del ICBPER.
///
/// LO QUE COMPRUEBA SUNAT:
///
///   2949  No se puede declarar antes del 1 de agosto de 2019.
///   3236  La cantidad de bolsas tiene que ser la cantidad de la línea.
///   3237  Si la línea lleva el tributo, tiene que declarar la cantidad.
///   3238  El monto por bolsa no puede ser cero.
///   4318  El importe tiene que ser la tasa por la cantidad. (aviso)
///   4237  La tasa debería ser la vigente a la fecha. (aviso)
///   3306  El total del documento es la suma de los importes de línea.
/// </summary>
public static class ReglasIcbper
{
    /// <summary>
    /// Revisa las líneas afectas al ICBPER. Lista vacía significa que pasa.
    /// Los textos que empiezan por "Aviso:" no impiden emitir.
    /// </summary>
    public static IReadOnlyList<string> Revisar(ComprobanteBase c)
    {
        var problemas = new List<string>();

        var conBolsas = c.Lineas.Where(l => l.AfectoIcbper).ToList();

        if (conBolsas.Count == 0) return problemas;

        // --- Vigencia -------------------------------------------------------

        if (c.FechaEmision.Date < Icbper.Vigencia)
        {
            problemas.Add(
                $"El ICBPER no estaba vigente el " +
                $"{c.FechaEmision:yyyy-MM-dd}: rige desde el 1 de agosto de " +
                $"2019 (error 2949).");

            return problemas;
        }

        var tasaEsperada = Icbper.TasaVigente(c.FechaEmision);

        foreach (var l in conBolsas)
        {
            // --- La cantidad de bolsas tiene que ser entera -------------------
            //
            // El campo es n5: un entero de hasta cinco dígitos. Media bolsa
            // no existe, y SUNAT rechaza el decimal con el 2892.

            if (l.Cantidad != Math.Truncate(l.Cantidad))
            {
                problemas.Add(
                    $"La linea {l.Numero} lleva ICBPER y su cantidad es " +
                    $"{l.Cantidad}. Las bolsas se cuentan enteras: el campo " +
                    $"que SUNAT espera no admite decimales (error 2892).");
            }

            if (l.Cantidad <= 0)
            {
                problemas.Add(
                    $"La linea {l.Numero} lleva ICBPER y necesita una cantidad " +
                    $"mayor que cero: es el numero de bolsas (error 3237).");
            }

            if (l.Cantidad > 99999)
            {
                problemas.Add(
                    $"La linea {l.Numero} declara {l.Cantidad} bolsas y el " +
                    $"campo admite hasta 99999 (error 2892).");
            }

            // --- LA BOLSA TIENE QUE VALER ALGO, AUNQUE NO SE COBRE ------------
            //
            // Es el error que se comete en la primera boleta: "la bolsa la
            // regalo, pongo cero". Pero entonces la línea se queda sin
            // ningún tributo con base imponible: el IGV sale sobre cero, y
            // el ICBPER no cuenta porque su monto base es cero por diseño.
            //
            // La regla 3105 exige que toda línea tenga al menos un tributo
            // con monto base mayor que cero, entre 1000, 1016, 9995, 9996,
            // 9997 y 9998. Una bolsa a cero no tiene ninguno, y el
            // comprobante entero se rechaza.
            //
            // Hay dos salidas, y las dos son legítimas: cobrar la bolsa, o
            // declararla como entrega gratuita —afectación 13 o 15— con su
            // valor referencial. Lo que no vale es un cero a secas.

            var esGratuita = AfectacionIgv.EsGratuita(l.TipoAfectacionIgv);

            if (l.ValorUnitario <= 0 && !esGratuita)
            {
                problemas.Add(
                    $"La linea {l.Numero} son bolsas con valor cero, y asi " +
                    $"SUNAT rechaza el comprobante entero (error 3105): una " +
                    $"linea necesita al menos un tributo con base mayor que " +
                    $"cero, y el ICBPER no cuenta porque no tiene base. " +
                    $"Ponle el precio de la bolsa, o declarala como entrega " +
                    $"gratuita con afectacion '13' o '15' y su valor " +
                    $"referencial. El ICBPER se cobra igual en los dos casos.");
            }

            // --- La tasa ------------------------------------------------------

            var tasa = l.IcbperUnitario ?? tasaEsperada;

            if (tasa <= 0)
            {
                problemas.Add(
                    $"El monto por bolsa de la linea {l.Numero} no puede ser " +
                    $"cero (error 3238). La tasa vigente a la fecha de esta " +
                    $"emision es {tasaEsperada:0.00} soles por bolsa.");
            }
            else if (l.IcbperUnitario is not null && tasa != tasaEsperada)
            {
                // AVISO Y NO ERROR, a propósito. SUNAT lo marca como
                // observación (4237) porque la tasa la fija una ley que puede
                // cambiar antes que este código. Bloquearlo dejaría el
                // sistema inservible el día que suba.
                problemas.Add(
                    $"Aviso: la linea {l.Numero} declara {tasa:0.00} soles por " +
                    $"bolsa y la tasa vigente en {c.FechaEmision.Year} es " +
                    $"{tasaEsperada:0.00}. Se emite igual, pero SUNAT lo marca " +
                    $"como observacion (4237).");
            }
        }

        // --- La moneda --------------------------------------------------------
        //
        // El impuesto está fijado en soles por ley. En una factura en dólares
        // el monto viajaría en dólares y diría otra cosa.

        if (c.Moneda != "PEN")
        {
            problemas.Add(
                $"Aviso: el comprobante esta en {c.Moneda} y el ICBPER esta " +
                $"fijado en soles por ley. Revisa que el monto por bolsa este " +
                $"convertido a {c.Moneda}, porque viaja en la moneda del " +
                $"documento.");
        }

        return problemas;
    }

    /// <summary>Los problemas que impiden emitir. Los avisos quedan fuera.</summary>
    public static IReadOnlyList<string> Errores(ComprobanteBase c) =>
        Revisar(c).Where(p => !p.StartsWith("Aviso:")).ToList();
}
