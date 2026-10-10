namespace Facturacion.Cpe;

/// <summary>
/// Un anticipo ya facturado que se descuenta de la factura final.
///
/// CÓMO FUNCIONA EL CIRCUITO COMPLETO:
///
/// 1. El cliente adelanta dinero. Se le emite una factura NORMAL por ese
///    monto, sin nada especial. Esa factura paga su IGV como cualquier otra.
///
/// 2. Cuando se entrega la mercadería, se emite la factura final por el
///    TOTAL de la operación, y dentro se declara el anticipo: qué factura
///    fue, cuánto se pagó y con qué identificador.
///
/// 3. SUNAT cruza las dos. Si la factura de anticipo no existe o no está
///    aceptada, rechaza la final (errores 3218 y 3219).
///
/// LO QUE MÁS CONFUNDE, Y CONVIENE TENER CLARO:
///
/// La factura final declara la operación COMPLETA en el valor y el precio
/// de venta, pero declara el IGV solo sobre lo que falta cobrar. No es una
/// incoherencia: el IGV del anticipo ya se pagó en la factura del paso 1.
/// Declararlo otra vez sería pagarlo dos veces.
///
/// Y el importe final es el saldo, porque el cliente ya adelantó el resto.
/// </summary>
public class Anticipo
{
    /// <summary>
    /// Identificador del pago. Un número del 1 al 99 que enlaza el monto con
    /// el comprobante dentro de esta misma factura.
    ///
    /// No es el número de la factura de anticipo: es un correlativo interno
    /// del documento. Si hay tres anticipos, son 1, 2 y 3. Repetirlo es el
    /// error 3212.
    /// </summary>
    public int IdentificadorPago { get; set; } = 1;

    /// <summary>
    /// Catálogo 12. "02" si el anticipo se facturó con factura,
    /// "03" si con boleta. SUNAT no admite ningún otro valor (error 2505).
    /// </summary>
    public string TipoComprobante { get; set; } = TipoComprobanteAnticipo.Factura;

    /// <summary>Serie y número de la factura del anticipo. Ej: F001-00000010</summary>
    public string Numero { get; set; } = "";

    /// <summary>
    /// RUC de quien emitió la factura del anticipo. Casi siempre el mismo
    /// emisor, pero SUNAT lo pide explícito porque admite que sea otro.
    /// </summary>
    public string RucEmisor { get; set; } = "";

    /// <summary>
    /// Importe del anticipo CON IGV incluido: lo que el cliente pagó de
    /// verdad, el total de aquella factura.
    ///
    /// ESTE ES EL PUNTO DONDE MÁS SE FALLA. El descuento que va al XML es
    /// el valor SIN IGV, y se calcula a partir de este monto. Si aquí se
    /// pone el valor sin IGV, la factura cuadra mal por el 18% y SUNAT
    /// devuelve el 3280.
    /// </summary>
    public decimal MontoTotal { get; set; }

    /// <summary>Fecha en que se recibió el pago. Opcional.</summary>
    public DateTime? FechaPago { get; set; }

    /// <summary>
    /// Catálogo 07. Determina de qué base se descuenta el anticipo y con qué
    /// código de descuento viaja: 04 gravado, 05 exonerado, 06 inafecto.
    /// </summary>
    public string TipoAfectacion { get; set; } = AfectacionIgv.GravadoOperacionOnerosa;

    public decimal PorcentajeIgv { get; set; } = 18m;

    /// <summary>
    /// Valor del anticipo sin IGV. Es lo que se resta de la base imponible.
    ///
    /// Solo las operaciones gravadas llevan IGV dentro; en exoneradas e
    /// inafectas el monto total ya es el valor de venta.
    /// </summary>
    public decimal ValorVenta =>
        AfectacionIgv.GeneraIgv(TipoAfectacion)
            ? CalculadoraTotales.Redondear(MontoTotal / (1m + PorcentajeIgv / 100m))
            : MontoTotal;

    /// <summary>
    /// Código de descuento global del catálogo 53 que le corresponde.
    /// </summary>
    public string CodigoDescuento => TipoAfectacion switch
    {
        AfectacionIgv.GravadoOperacionOnerosa => CodigoAnticipo.Gravado,
        AfectacionIgv.Exonerado               => CodigoAnticipo.Exonerado,
        AfectacionIgv.Inafecto                => CodigoAnticipo.Inafecto,
        _ => throw new InvalidOperationException(
                $"Un anticipo no puede tener la afectación {TipoAfectacion}. " +
                $"Solo 10 (gravado), 20 (exonerado) o 30 (inafecto).")
    };
}

/// <summary>Catálogo 12, en lo que a anticipos respecta.</summary>
public static class TipoComprobanteAnticipo
{
    public const string Factura = "02";
    public const string Boleta  = "03";

    public static bool Existe(string codigo) => codigo is Factura or Boleta;
}

/// <summary>
/// Catálogo 53: los tres códigos de descuento global por anticipo.
///
/// Van aparte de CodigoDescuento porque se comportan distinto: no son un
/// descuento comercial, son el reconocimiento de algo ya cobrado, y cada
/// uno resta de una base imponible diferente.
/// </summary>
public static class CodigoAnticipo
{
    public const string Gravado   = "04";
    public const string Exonerado = "05";
    public const string Inafecto  = "06";
}

/// <summary>
/// Reglas de los anticipos declarados en una factura.
///
/// SE LLAMA "ReglasAnticipos" Y NO "Anticipos" A PROPÓSITO: el comprobante
/// ya tiene una propiedad llamada Anticipos, y un tipo que se llama igual
/// que un miembro es una trampa. En algunos contextos C# resuelve el nombre
/// hacia el tipo y en otros hacia el miembro, y cuando se equivoca no falla
/// la compilación: produce código que no hace nada, con una advertencia
/// fácil de pasar por alto.
///
/// Ya nos pasó con la clase Exportacion y la constante AfectacionIgv.Exportacion.
/// </summary>
public static class ReglasAnticipos
{
    /// <summary>
    /// Revisa los anticipos de una factura. Lista vacía significa que pasa.
    /// Los textos que empiezan por "Aviso:" no impiden emitir.
    /// </summary>
    public static IReadOnlyList<string> Revisar(Factura f)
    {
        var problemas = new List<string>();

        if (f.Anticipos.Count == 0) return problemas;

        // --- Identificadores de pago ----------------------------------------

        var repetidos = f.Anticipos
            .GroupBy(a => a.IdentificadorPago)
            .Where(g => g.Count() > 1)
            .Select(g => g.Key)
            .ToList();

        if (repetidos.Count > 0)
        {
            problemas.Add(
                $"Hay identificadores de pago repetidos: " +
                $"{string.Join(", ", repetidos)}. Cada anticipo necesita el suyo " +
                $"(1, 2, 3...).");
        }

        foreach (var a in f.Anticipos)
        {
            var quien = string.IsNullOrWhiteSpace(a.Numero)
                ? $"el anticipo {a.IdentificadorPago}"
                : $"el anticipo {a.Numero}";

            if (a.IdentificadorPago is < 1 or > 99)
            {
                problemas.Add(
                    $"El identificador de pago de {quien} debe estar entre 1 y 99.");
            }

            if (!TipoComprobanteAnticipo.Existe(a.TipoComprobante))
            {
                problemas.Add(
                    $"El tipo de comprobante de {quien} debe ser '02' (factura) o " +
                    $"'03' (boleta), no '{a.TipoComprobante}'.");
            }

            if (string.IsNullOrWhiteSpace(a.Numero) || !a.Numero.Contains('-'))
            {
                problemas.Add(
                    $"Falta la serie y numero del comprobante de {quien}, " +
                    $"con formato SERIE-CORRELATIVO.");
            }

            if (a.RucEmisor?.Length != 11 || !a.RucEmisor.All(char.IsAsciiDigit))
            {
                problemas.Add(
                    $"El RUC del emisor de {quien} debe tener 11 digitos.");
            }

            if (a.MontoTotal <= 0)
            {
                problemas.Add($"El monto de {quien} debe ser mayor que cero.");
            }

            if (a.TipoAfectacion is not (AfectacionIgv.GravadoOperacionOnerosa
                or AfectacionIgv.Exonerado or AfectacionIgv.Inafecto))
            {
                problemas.Add(
                    $"La afectacion de {quien} solo puede ser 10 (gravado), " +
                    $"20 (exonerado) o 30 (inafecto).");
            }
        }

        // --- El anticipo no puede superar a la operación ---------------------
        //
        // Si lo supera, el importe a pagar sale negativo o cero, y SUNAT
        // rechaza con el 2062 porque PayableAmount debe ser positivo.
        //
        // Cuando lo cobrado de más hay que devolverlo, el camino es una nota
        // de crédito sobre la factura del anticipo, no una factura final en
        // negativo.

        var totales = CalculadoraTotales.Calcular(f);
        var anticipado = f.Anticipos.Sum(a => a.MontoTotal);

        if (anticipado >= totales.PrecioVenta && totales.PrecioVenta > 0)
        {
            problemas.Add(
                $"Los anticipos suman {anticipado:0.00} y la operacion completa " +
                $"vale {totales.PrecioVenta:0.00}. La factura final tiene que " +
                $"dejar un saldo por cobrar mayor que cero.");
        }

        // --- Coherencia por tipo de afectación -------------------------------
        //
        // Un anticipo gravado se resta de la base gravada. Si esa base no
        // existe o no alcanza, la resta deja un negativo y el comprobante
        // no cuadra.

        RevisarBase(problemas, f, AfectacionIgv.GravadoOperacionOnerosa,
            totales.GravadoDeLineas, "gravada");

        RevisarBase(problemas, f, AfectacionIgv.Exonerado,
            totales.ExoneradoDeLineas, "exonerada");

        RevisarBase(problemas, f, AfectacionIgv.Inafecto,
            totales.InafectoDeLineas, "inafecta");

        return problemas;
    }

    private static void RevisarBase(
        List<string> problemas, Factura f, string afectacion,
        decimal baseDeLineas, string nombre)
    {
        var delTipo = f.Anticipos
            .Where(a => a.TipoAfectacion == afectacion)
            .Sum(a => a.ValorVenta);

        if (delTipo > 0 && delTipo > baseDeLineas)
        {
            problemas.Add(
                $"Los anticipos de operacion {nombre} suman {delTipo:0.00} sin " +
                $"IGV, pero las lineas {nombre}s de esta factura solo suman " +
                $"{baseDeLineas:0.00}. El anticipo no puede descontar mas de lo " +
                $"que la factura declara en esa base.");
        }
    }

    /// <summary>Los problemas que impiden emitir. Los avisos quedan fuera.</summary>
    public static IReadOnlyList<string> Errores(Factura f) =>
        Revisar(f).Where(p => !p.StartsWith("Aviso:")).ToList();
}
