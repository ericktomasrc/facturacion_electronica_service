namespace Facturacion.Cpe;

/// <summary>
/// Impuesto Selectivo al Consumo. Tributo 2000.
///
/// QUÉ GRAVA: licores, cervezas, gaseosas, cigarrillos, combustibles,
/// vehículos, juegos de azar. Lo paga el fabricante o el importador en la
/// primera venta, y viaja incorporado al precio hasta el consumidor.
///
/// LA PARTICULARIDAD QUE LO HACE DISTINTO A TODO LO DEMÁS:
///
///   EL ISC ENTRA EN LA BASE DEL IGV.
///
/// No es un impuesto que se sume al final como el ICBPER: se suma ANTES, y
/// el IGV se calcula sobre el resultado. Se paga impuesto sobre impuesto.
///
///   Valor de venta    1 000.00
///   ISC (10%)           100.00
///   Base del IGV      1 100.00   ← aquí está la diferencia
///   IGV (18%)           198.00
///   IMPORTE TOTAL     1 298.00
///
/// Sin esa suma, el IGV saldría 180.00 y SUNAT rechazaría la línea con el
/// error 3272, que compara la base del tributo 1000 contra el valor de venta
/// más el ISC de esa misma línea.
///
/// Y NO ENTRA EN EL VALOR DE VENTA DEL DOCUMENTO. La regla 3278 suma para el
/// LineExtensionAmount los tributos 1000, 1016, 9995, 9997 y 9998 — el 2000
/// no está. Así que el ISC sube la base imponible del IGV pero no el valor de
/// venta declarado. Son dos números que en una factura normal coinciden y
/// aquí dejan de hacerlo.
/// </summary>
public static class Isc
{
    public const string Codigo = "2000";
    public const string Nombre = "ISC";

    /// <summary>
    /// Código internacional del tributo: EXC, de "excise".
    ///
    /// No es "VAT" como el IGV ni "OTH" como el ICBPER. Cada tributo del
    /// catálogo 05 tiene el suyo y no son intercambiables.
    /// </summary>
    public const string TipoCodigo = "EXC";

    /// <summary>El ISC de una línea: la tasa sobre el valor de venta.</summary>
    public static decimal Calcular(decimal baseImponible, decimal tasa) =>
        CalculadoraTotales.Redondear(baseImponible * tasa / 100m);
}

/// <summary>
/// Catálogo 08: los tres sistemas de cálculo del ISC.
///
/// EL SISTEMA NO CAMBIA LA CUENTA, CAMBIA DE DÓNDE SALE LA TASA. SUNAT
/// necesita saber cuál se aplicó porque cada apéndice de la ley tiene su
/// propia lista de productos y de tasas, y el fiscalizador comprueba que el
/// producto esté en el apéndice que dice el comprobante.
/// </summary>
public static class SistemaIsc
{
    /// <summary>
    /// 01 - Sistema al valor. Un porcentaje sobre el valor de venta.
    /// Apéndice IV, literal A. Es el más común: licores, cervezas, gaseosas.
    /// </summary>
    public const string AlValor = "01";

    /// <summary>
    /// 02 - Monto fijo por unidad. Apéndice III y IV literal B.
    /// Combustibles y cigarrillos: tantos soles por galón o por millar.
    ///
    /// AQUÍ HAY QUE DECLARAR LA TASA EQUIVALENTE, no el monto fijo: SUNAT
    /// comprueba que el importe sea la tasa por la base (regla 3108), y no
    /// tiene un campo donde poner soles por unidad. Se calcula el ISC como
    /// corresponda y se declara qué porcentaje del valor de venta resultó.
    /// </summary>
    public const string MontoFijo = "02";

    /// <summary>
    /// 03 - Precio de venta al público. Apéndice IV, literal C.
    /// Cigarrillos y algunos licores: la base es el precio sugerido al
    /// público, no el de esta venta.
    /// </summary>
    public const string PrecioPublico = "03";

    private static readonly string[] Todos = [AlValor, MontoFijo, PrecioPublico];

    public static bool Existe(string codigo) => Array.IndexOf(Todos, codigo) >= 0;

    public static string Descripcion(string codigo) => codigo switch
    {
        AlValor       => "sistema al valor",
        MontoFijo     => "monto fijo por unidad",
        PrecioPublico => "precio de venta al publico",
        _             => "sistema " + codigo
    };
}

/// <summary>
/// Reglas del ISC.
///
///   2041  El sistema tiene que estar en el catálogo 08.
///   2373  Si hay ISC en la línea, hay que decir con qué sistema se calculó.
///   3104  La tasa no puede ser cero.
///   3108  El importe es la tasa por la base.
///   3272  La base del IGV de esa línea es el valor de venta MÁS el ISC.
///   2650  Una factura de arroz pilado no lleva ISC.
///   3223  El ISC no convive con exportación (9995) ni con IVAP (1016).
/// </summary>
public static class ReglasIsc
{
    /// <summary>
    /// Revisa las líneas con ISC. Lista vacía significa que pasa.
    /// Los textos que empiezan por "Aviso:" no impiden emitir.
    /// </summary>
    public static IReadOnlyList<string> Revisar(ComprobanteBase c)
    {
        var problemas = new List<string>();

        var conIsc = c.Lineas.Where(l => l.TieneIsc).ToList();

        if (conIsc.Count == 0) return problemas;

        // --- Con qué no convive -----------------------------------------------

        if (Ivap.Aplica(c))
        {
            problemas.Add(
                "Una factura de arroz pilado no puede llevar ISC (error 2650). " +
                "Son dos regimenes distintos y ninguno admite al otro.");

            return problemas;
        }

        foreach (var l in conIsc)
        {
            var afectacion = l.TipoAfectacionIgv;

            // Regla 3223: el 2000 solo convive con 1000, 9996, 9997 y 9998.
            // Ni con el 9995 de exportacion ni con el 1016 del IVAP.
            if (AfectacionIgv.EsExportacion(afectacion))
            {
                problemas.Add(
                    $"La linea {l.Numero} es de exportacion y lleva ISC. Una " +
                    $"exportacion no puede llevarlo: el ISC grava el consumo " +
                    $"en el pais (error 3223).");

                continue;
            }

            // --- El sistema de cálculo ----------------------------------------

            if (!SistemaIsc.Existe(l.SistemaIsc))
            {
                problemas.Add(
                    $"El sistema de calculo del ISC '{l.SistemaIsc}' de la linea " +
                    $"{l.Numero} no existe en el catalogo 08. Solo 01 (al " +
                    $"valor), 02 (monto fijo) y 03 (precio de venta al " +
                    $"publico) (errores 2041 y 2373).");
            }

            // --- La tasa ------------------------------------------------------

            if (l.TasaIsc <= 0)
            {
                problemas.Add(
                    $"La tasa de ISC de la linea {l.Numero} debe ser mayor que " +
                    $"cero (error 3104). Si el producto no esta afecto al ISC, " +
                    $"quita el sistema de calculo en vez de poner tasa cero.");
            }

            if (l.TasaIsc >= 1000)
            {
                problemas.Add(
                    $"La tasa de ISC de la linea {l.Numero} ({l.TasaIsc}) no es " +
                    $"valida: el campo admite 3 enteros y 5 decimales.");
            }

            // --- Avisos sobre el sistema 02 -----------------------------------
            //
            // Es el que más se malentiende: el usuario tiene un monto por
            // galón y busca dónde ponerlo. No hay dónde.

            if (l.SistemaIsc == SistemaIsc.MontoFijo)
            {
                problemas.Add(
                    $"Aviso: la linea {l.Numero} usa el sistema de monto fijo. " +
                    $"SUNAT no tiene campo para los soles por unidad: comprueba " +
                    $"que el importe sea la tasa por la base (regla 3108), asi " +
                    $"que la tasa declarada ({l.TasaIsc:0.#####}%) tiene que ser " +
                    $"la equivalente al monto fijo sobre este valor de venta.");
            }
        }

        return problemas;
    }

    /// <summary>Los problemas que impiden emitir. Los avisos quedan fuera.</summary>
    public static IReadOnlyList<string> Errores(ComprobanteBase c) =>
        Revisar(c).Where(p => !p.StartsWith("Aviso:")).ToList();

    /// <summary>Solo los avisos, para el log.</summary>
    public static IReadOnlyList<string> Avisos(ComprobanteBase c) =>
        Revisar(c).Where(p => p.StartsWith("Aviso:")).ToList();
}
