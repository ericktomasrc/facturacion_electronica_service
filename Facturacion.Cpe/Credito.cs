namespace Facturacion.Cpe;

/// <summary>
/// Una cuota de una factura a crédito.
///
/// DESDE EL 1 DE ENERO DE 2022 ESTO NO ES OPCIONAL. Toda factura a crédito
/// cuyo receptor tenga RUC debe declarar el monto pendiente y al menos una
/// cuota con su fecha de vencimiento. Sin eso, SUNAT rechaza con los
/// errores 3249 y 3251.
///
/// La razón es la factura negociable: SUNAT quiere saber cuánto se debe y
/// cuándo vence, porque ese crédito puede transferirse.
/// </summary>
public class CuotaCredito
{
    /// <summary>
    /// Número de cuota, empezando en 1. Viaja al XML como "Cuota001".
    /// </summary>
    public int Numero { get; set; } = 1;

    public decimal Monto { get; set; }

    /// <summary>
    /// Cuándo vence. TIENE QUE SER POSTERIOR a la fecha de emisión: una
    /// cuota que vence el mismo día no es crédito, y SUNAT lo rechaza con
    /// el error 3267.
    /// </summary>
    public DateTime FechaVencimiento { get; set; }

    /// <summary>
    /// El identificador que espera SUNAT: "Cuota" y tres dígitos.
    /// "Cuota1" o "Cuota01" no valen (error 3246).
    /// </summary>
    public string Identificador => $"Cuota{Numero:D3}";
}

/// <summary>
/// Reglas de las facturas a crédito.
///
/// QUÉ COMPRUEBA SUNAT, Y POR QUÉ CADA UNA:
///
///   3245  Hay que decir si es contado o crédito. No hay tercera opción.
///   3246  El identificador de cuota es "Cuota" más tres dígitos, exacto.
///   3247  No puede ser contado y crédito a la vez.
///   3249  Crédito con receptor RUC exige al menos una cuota.
///   3251  ...y exige declarar el monto pendiente.
///   3252  Si hay cuotas, la forma de pago tiene que ser crédito.
///   3265  El monto pendiente no puede superar al importe total.
///   3266  Ninguna cuota puede superar al importe total.
///   3267  Ninguna cuota puede vencer antes o el mismo día de la emisión.
///   3319  La suma de las cuotas tiene que dar el monto pendiente.
///
/// TODAS SON "A PARTIR DEL 01/01/2022". Antes eran observaciones y no
/// impedían nada; hoy rechazan el comprobante.
/// </summary>
public static class ReglasCredito
{
    public const string Contado = "Contado";
    public const string Credito = "Credito";

    public static bool EsCredito(string formaPago) =>
        string.Equals(formaPago, Credito, StringComparison.OrdinalIgnoreCase);

    /// <summary>
    /// Revisa la forma de pago y las cuotas. Lista vacía significa que pasa.
    /// Los textos que empiezan por "Aviso:" no impiden emitir.
    /// </summary>
    public static IReadOnlyList<string> Revisar(Factura f)
    {
        var problemas = new List<string>();
        var esCredito = EsCredito(f.FormaPago);

        // --- La forma de pago solo admite dos valores ------------------------

        if (!esCredito &&
            !string.Equals(f.FormaPago, Contado, StringComparison.OrdinalIgnoreCase))
        {
            problemas.Add(
                $"La forma de pago debe ser 'Contado' o 'Credito', no " +
                $"'{f.FormaPago}' (error 3246).");

            return problemas;
        }

        // --- Cuotas donde no corresponde -------------------------------------

        if (!esCredito && f.Cuotas.Count > 0)
        {
            problemas.Add(
                "Hay cuotas declaradas pero la forma de pago es Contado. " +
                "Si se cobra en cuotas, la operacion es a credito (error 3252).");

            return problemas;
        }

        if (!esCredito) return problemas;

        // --- A partir de aquí, la factura es a crédito -----------------------
        //
        // LA EXIGENCIA SOLO APLICA CUANDO EL RECEPTOR TIENE RUC.
        //
        // A una persona natural con DNI se le puede facturar a crédito sin
        // detallar cuotas. Tiene sentido: la factura negociable, que es el
        // motivo de toda esta obligación, se transfiere entre empresas.

        var receptorConRuc = f.Receptor.TipoDocumento == TipoDocIdentidad.Ruc;

        if (!receptorConRuc)
        {
            if (f.Cuotas.Count == 0)
            {
                problemas.Add(
                    "Aviso: factura a credito sin cuotas. SUNAT solo las exige " +
                    "cuando el receptor tiene RUC, asi que esta pasa, pero " +
                    "declararlas deja constancia de cuando vence el cobro.");
            }
        }
        else if (f.Cuotas.Count == 0)
        {
            problemas.Add(
                "Una factura a credito con receptor con RUC necesita al menos " +
                "una cuota, con su monto y su fecha de vencimiento. SUNAT la " +
                "rechaza con los errores 3249 y 3251.");

            return problemas;
        }

        if (f.Cuotas.Count == 0) return problemas;

        // --- Identificadores ---------------------------------------------------

        var repetidos = f.Cuotas
            .GroupBy(c => c.Numero)
            .Where(g => g.Count() > 1)
            .Select(g => g.Key)
            .ToList();

        if (repetidos.Count > 0)
        {
            problemas.Add(
                $"Hay numeros de cuota repetidos: {string.Join(", ", repetidos)}.");
        }

        var totales = CalculadoraTotales.Calcular(f);

        foreach (var c in f.Cuotas)
        {
            if (c.Numero is < 1 or > 999)
            {
                problemas.Add(
                    $"El numero de cuota debe estar entre 1 y 999, y llego " +
                    $"{c.Numero}. El identificador que espera SUNAT es " +
                    $"'Cuota' mas tres digitos (error 3246).");
            }

            if (c.Monto <= 0)
            {
                problemas.Add(
                    $"El monto de la {c.Identificador} debe ser mayor que cero.");
            }

            if (c.Monto > totales.ImporteTotal)
            {
                problemas.Add(
                    $"La {c.Identificador} ({c.Monto:0.00}) no puede superar al " +
                    $"importe total de la factura ({totales.ImporteTotal:0.00}) " +
                    $"(error 3266).");
            }

            // Regla 3267: no puede vencer antes ni el mismo día de la emisión.
            //
            // Se compara solo la fecha, sin hora: una cuota que vence hoy a
            // las 23:59 sigue siendo el mismo día y SUNAT la rechaza igual.
            if (c.FechaVencimiento.Date <= f.FechaEmision.Date)
            {
                problemas.Add(
                    $"La {c.Identificador} vence el " +
                    $"{c.FechaVencimiento:yyyy-MM-dd} y la factura se emite el " +
                    $"{f.FechaEmision:yyyy-MM-dd}. Una cuota tiene que vencer " +
                    $"despues de la emision (error 3267).");
            }
        }

        // --- El monto pendiente ------------------------------------------------
        //
        // Regla 3319: la suma de las cuotas ES el monto pendiente. Por eso
        // no se pide aparte: se calcula, y así no puede descuadrar.

        var pendiente = f.MontoPendiente;

        if (pendiente > totales.ImporteTotal)
        {
            problemas.Add(
                $"Las cuotas suman {pendiente:0.00} y el importe total de la " +
                $"factura es {totales.ImporteTotal:0.00}. El monto pendiente no " +
                $"puede superar al total (error 3265).");
        }

        if (pendiente > 0 && pendiente < totales.ImporteTotal)
        {
            problemas.Add(
                $"Aviso: las cuotas suman {pendiente:0.00} y el total es " +
                $"{totales.ImporteTotal:0.00}. Es valido —el resto se entiende " +
                $"pagado al contado— pero revisa que sea intencional.");
        }

        return problemas;
    }

    /// <summary>Los problemas que impiden emitir. Los avisos quedan fuera.</summary>
    public static IReadOnlyList<string> Errores(Factura f) =>
        Revisar(f).Where(p => !p.StartsWith("Aviso:")).ToList();
}
