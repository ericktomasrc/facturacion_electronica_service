namespace Facturacion.Cpe;

/// <summary>
/// El plazo que da SUNAT para hacerle llegar un comprobante ya emitido.
///
/// EL DATO QUE MÁS SORPRENDE: emitir y enviar no son lo mismo. Un
/// comprobante se emite cuando se entrega al cliente, y a partir de ahí
/// corre un reloj para comunicarlo a SUNAT. Pasado el plazo, SUNAT lo
/// rechaza con el error 2108 —"Presentación fuera de fecha"— y ya no hay
/// manera de comunicarlo: ese comprobante queda emitido y no declarado.
///
/// Y OJO CON QUÉ FECHA SE COMPARA: la regla dice "la diferencia entre la
/// fecha de RECEPCIÓN del XML y la fecha de emisión". No es cuándo lo
/// generamos nosotros: es cuándo llega a SUNAT. Si el envío se atasca tres
/// días en la cola porque SUNAT está caído, el plazo sigue corriendo.
///
/// POR ESO ESTO SE COMPRUEBA AL EMITIR Y NO SOLO AL ENVIAR. Un comprobante
/// que nace fuera de plazo no tiene salvación, y es mejor decirlo antes de
/// gastar un correlativo.
/// </summary>
public static class PlazoEnvio
{
    /// <summary>
    /// Días calendario para enviar una factura o sus notas.
    ///
    /// Son TRES desde el día siguiente a la emisión, desde la resolución
    /// 000193-2020. Antes eran siete, y hay mucha documentación por ahí que
    /// todavía dice siete.
    /// </summary>
    public const int DiasFactura = 3;

    /// <summary>
    /// Días para el resumen diario de boletas.
    ///
    /// Es un plazo distinto y más largo, porque las boletas no viajan solas
    /// sino agrupadas. La norma da hasta el séptimo día calendario del mes
    /// siguiente, pero contarlo así complica el cálculo sin ganar nada: con
    /// siete días desde la emisión se cubre el caso real, que es la boleta
    /// de ayer que hay que resumir hoy.
    /// </summary>
    public const int DiasBoleta = 7;

    /// <summary>
    /// Días para una liquidación de compra.
    ///
    /// ES UNO SOLO, el plazo más corto de todo el sistema. El error es el
    /// mismo 2108, pero llega tres veces antes que en una factura: una
    /// liquidación emitida el viernes y enviada el lunes ya está muerta.
    ///
    /// Tiene su lógica desde donde lo mira SUNAT: quien emite una liquidación
    /// está documentando una compra a alguien que no puede documentarla, y
    /// cuanto más tarde se comunique, más fácil es inventarla.
    /// </summary>
    public const int DiasLiquidacion = 1;

    /// <summary>
    /// Días para el comprobante de retención y el de percepción.
    ///
    /// SUNAT no lo fija en las reglas: lo publica en el parámetro 004, que es
    /// una tabla aparte y que puede cambiar sin tocar el esquema. La regla
    /// 2600 solo dice "mayor al plazo máximo vigente".
    ///
    /// Siete días es el valor que SUNAT viene aplicando. Si algún día aparece
    /// un 2600 en un documento que aquí pasó, esta constante es lo primero que
    /// hay que mirar.
    /// </summary>
    public const int DiasCre = 7;

    /// <summary>
    /// Cuántos días de margen quedan antes de que SUNAT deje de aceptarlo.
    /// Negativo significa que el plazo ya venció.
    /// </summary>
    public static int DiasRestantes(string tipoComprobante, DateTime fechaEmision)
    {
        var plazo = PlazoDe(tipoComprobante);
        var vencimiento = fechaEmision.Date.AddDays(plazo);

        return (vencimiento - RelojPeru.Hoy).Days;
    }

    public static int PlazoDe(string tipoComprobante)
    {
        if (tipoComprobante == TipoComprobante.Boleta) return DiasBoleta;
        if (tipoComprobante == LiquidacionCompra.Tipo) return DiasLiquidacion;

        if (tipoComprobante == ComprobanteRetencion.Tipo ||
            tipoComprobante == ComprobantePercepcion.Tipo) return DiasCre;

        // Todo lo demás —facturas y sus notas— va con el plazo de la factura.
        return DiasFactura;
    }

    /// <summary>La fecha límite para que llegue a SUNAT.</summary>
    public static DateTime Vencimiento(string tipoComprobante, DateTime fechaEmision) =>
        fechaEmision.Date.AddDays(PlazoDe(tipoComprobante));
}

/// <summary>
/// Reglas de la fecha de emisión.
///
/// Son dos, y las dos terminan en un comprobante que SUNAT no acepta:
///
///   Fecha futura   → un comprobante no puede nacer mañana.
///   Fuera de plazo → error 2108, y no hay segunda oportunidad.
///
/// SOBRE LA CONTINGENCIA, QUE ES LO QUE MUCHA GENTE BUSCA AQUÍ: SUNAT llama
/// "comprobante de contingencia" al comprobante FÍSICO, impreso en papel,
/// que se entrega cuando no hay sistema y que después se informa. Se
/// reconoce porque su serie empieza con número en vez de con letra.
///
/// Este sistema no emite comprobantes físicos, así que ese camino no le
/// toca. Lo que sí le toca es no dejar que un comprobante se quede sin
/// comunicar mientras el plazo corre — y eso es lo que hay aquí.
/// </summary>
public static class ReglasFechaEmision
{
    /// <summary>
    /// Revisa la fecha de emisión. Lista vacía significa que pasa.
    /// Los textos que empiezan por "Aviso:" no impiden emitir.
    /// </summary>
    public static IReadOnlyList<string> Revisar(ComprobanteBase c)
    {
        var problemas = new List<string>();

        var emision = c.FechaEmision.Date;
        var hoy = RelojPeru.Hoy;

        // --- Una factura no puede nacer mañana -------------------------------
        //
        // Se comparan FECHAS DE LIMA, no instantes UTC. Con la hora del
        // servidor, una factura emitida a las 20:00 del lunes parecería del
        // martes y este aviso saltaría sin motivo.

        if (emision > hoy)
        {
            problemas.Add(
                $"La fecha de emision es {emision:yyyy-MM-dd} y hoy es " +
                $"{hoy:yyyy-MM-dd}. Un comprobante no se puede emitir con " +
                $"fecha futura.");

            return problemas;
        }

        // --- El plazo de envío ------------------------------------------------

        var restantes = PlazoEnvio.DiasRestantes(c.TipoComprobante, emision);
        var plazo = PlazoEnvio.PlazoDe(c.TipoComprobante);

        if (restantes < 0)
        {
            var vencimiento = PlazoEnvio.Vencimiento(c.TipoComprobante, emision);

            problemas.Add(
                $"El plazo para comunicar este comprobante vencio el " +
                $"{vencimiento:yyyy-MM-dd}. Se emitio el {emision:yyyy-MM-dd} y " +
                $"SUNAT da {plazo} dias calendario; hoy es {hoy:yyyy-MM-dd}. " +
                $"Lo rechazaria con el error 2108 y el correlativo se perderia. " +
                $"Emitelo con la fecha de hoy.");

            return problemas;
        }

        // --- Aviso cuando queda poco -------------------------------------------
        //
        // NO BLOQUEA, PORQUE ES LEGÍTIMO: una venta del sábado se factura el
        // lunes y eso está dentro de plazo. Pero conviene que quede en el log,
        // porque si el envío se atasca ya no hay margen.

        if (restantes == 0)
        {
            problemas.Add(
                $"Aviso: este comprobante vence HOY. Se emitio el " +
                $"{emision:yyyy-MM-dd} y hoy es el ultimo dia para que llegue a " +
                $"SUNAT. Si el envio falla, no habra otra oportunidad.");
        }
        else if (restantes == 1)
        {
            problemas.Add(
                $"Aviso: a este comprobante le queda 1 dia de plazo. Se emitio " +
                $"el {emision:yyyy-MM-dd}.");
        }

        return problemas;
    }

    /// <summary>Los problemas que impiden emitir. Los avisos quedan fuera.</summary>
    public static IReadOnlyList<string> Errores(ComprobanteBase c) =>
        Revisar(c).Where(p => !p.StartsWith("Aviso:")).ToList();

    /// <summary>Solo los avisos, para dejarlos en el log.</summary>
    public static IReadOnlyList<string> Avisos(ComprobanteBase c) =>
        Revisar(c).Where(p => p.StartsWith("Aviso:")).ToList();
}