namespace Facturacion.Cpe;

/// <summary>
/// Un cargo o un descuento que se aplica al comprobante entero y que NO
/// cambia la base imponible del IGV.
///
/// QUÉ SIGNIFICA "QUE NO AFECTA LA BASE", CON NÚMEROS:
///
///   Valor de venta      2 000.00
///   IGV (18%)             360.00   ← sobre los 2 000, no sobre 2 100
///   Cargo por flete       100.00   ← se suma después, sin generar IGV
///   IMPORTE TOTAL       2 460.00
///
/// Si el mismo flete afectara la base, el IGV sería 378.00 y el total
/// 2 478.00. Dieciocho soles de diferencia, y una declaración distinta.
///
/// CUÁL DE LOS DOS ES EL CORRECTO NO LO DECIDE EL SISTEMA. Depende de si
/// el concepto forma parte de la contraprestación de la venta. Un flete que
/// el vendedor cobra por llevar la mercadería normalmente sí forma parte, y
/// entonces lo limpio es ponerlo como una línea más del detalle: así el
/// cliente puede usar ese IGV como crédito fiscal.
///
/// Estos bloques son para lo que de verdad queda fuera: el recargo al
/// consumo de un restaurante, el FISE de una distribuidora de gas, un
/// descuento comercial pactado aparte del precio.
/// </summary>
public class CargoGlobal
{
    /// <summary>
    /// Código del catálogo 53. Decide todo lo demás: si es cargo o
    /// descuento, y si suma o resta en el importe total.
    ///
    /// EL INDICADOR NO SE PIDE A PROPÓSITO. En el XML hay un
    /// cbc:ChargeIndicator que dice si es cargo o descuento, y SUNAT lo
    /// contrasta con el código (regla 3114). Si se pidieran los dos, se
    /// podrían contradecir; pidiendo solo el código, no.
    /// </summary>
    public string Codigo { get; set; } = CodigoCargoDescuento.CargoGlobalNoAfectaBase;

    /// <summary>El monto, siempre positivo. Que reste o sume lo dice el código.</summary>
    public decimal Monto { get; set; }

    /// <summary>
    /// Sobre qué importe se calculó. Opcional, pero si se declara el
    /// porcentaje, SUNAT necesita esto para recalcular.
    /// </summary>
    public decimal? BaseImponible { get; set; }

    /// <summary>
    /// Porcentaje, si el concepto se calculó como tal. 10 significa 10%.
    /// Viaja al XML como factor: 0.1.
    /// </summary>
    public decimal? Porcentaje { get; set; }

    /// <summary>
    /// Para qué es. No viaja al XML —SUNAT no tiene dónde ponerlo— pero
    /// sirve para el PDF y para que el cliente entienda su factura.
    /// </summary>
    public string Descripcion { get; set; } = "";

    /// <summary>true = cargo (suma), false = descuento (resta).</summary>
    public bool EsCargo => CodigoCargoDescuento.EsCargo(Codigo);

    /// <summary>El porcentaje expresado como factor: 10% → 0.1.</summary>
    public decimal? Factor => Porcentaje is null
        ? null
        : Math.Round(Porcentaje.Value / 100m, 5, MidpointRounding.AwayFromZero);
}

/// <summary>
/// Catálogo 53, con la lógica de qué hace cada código.
///
/// LOS CÓDIGOS VIENEN EN PAREJAS Y ES FÁCIL CONFUNDIRLOS:
///
///   Nivel ítem     00 descuento afecta base    01 descuento no afecta
///                  47 cargo afecta base        48 cargo no afecta
///
///   Nivel global   02 descuento afecta base    03 descuento no afecta
///                  49 cargo afecta base        50 cargo no afecta
///
/// Poner un código de ítem en un bloque global (o al revés) no da un error
/// de formato: da un total que no cuadra, porque SUNAT suma por código y
/// ese código no está en la suma que espera.
/// </summary>
public static class CodigoCargoDescuento
{
    // --- Nivel ítem ---------------------------------------------------------
    public const string DescuentoItem = "00";
    public const string DescuentoItemNoAfectaBase = "01";
    public const string CargoItem = "47";
    public const string CargoItemNoAfectaBase = "48";

    // --- Nivel global -------------------------------------------------------
    public const string DescuentoGlobal = "02";
    public const string DescuentoGlobalNoAfectaBase = "03";
    public const string CargoGlobal = "49";
    public const string CargoGlobalNoAfectaBase = "50";

    // --- Conceptos con nombre propio ---------------------------------------
    public const string Fise = "45";
    public const string RecargoAlConsumo = "46";
    public const string RetencionIgv = "62";
    public const string RetencionSegundaCategoria = "63";

    /// <summary>
    /// Los códigos que este sistema sabe emitir como bloque global.
    ///
    /// SON LOS QUE NO TOCAN LA BASE IMPONIBLE, a propósito. Los que sí la
    /// tocan (02 y 49) cambian el IGV declarado y necesitan que el cálculo
    /// del impuesto los tenga en cuenta; el 02 ya se resuelve repartiendo
    /// el descuento dentro de las líneas, que es la vía que este sistema
    /// usa y tiene probada.
    /// </summary>
    private static readonly string[] Soportados =
    [
        DescuentoGlobalNoAfectaBase,   // 03
        CargoGlobalNoAfectaBase,       // 50
        CargoGlobal,                   // 49
        Fise,                          // 45
        RecargoAlConsumo,              // 46
        RetencionIgv,                  // 62
        RetencionSegundaCategoria      // 63
    ];

    /// <summary>
    /// Las retenciones, que se comportan distinto entre sí.
    ///
    /// LA DEL IGV (62) NO MUEVE NINGÚN TOTAL. Es informativa: dice que el
    /// cliente, por ser agente de retención designado, va a retener ese
    /// importe al pagar. El comprobante sigue declarando lo que vale la
    /// operación, y por eso el 62 no aparece en la regla 3300 ni en la 3301.
    ///
    /// LA DE SEGUNDA CATEGORÍA (63) SÍ RESTA del importe a pagar: la regla
    /// 3300 la suma en cbc:AllowanceTotalAmount junto a los descuentos.
    ///
    /// Las dos llevan ChargeIndicator en "false" aunque el nombre suene a
    /// cargo (regla 3114).
    /// </summary>
    public static bool EsRetencion(string codigo) =>
        codigo == RetencionIgv || codigo == RetencionSegundaCategoria;

    /// <summary>
    /// Los que SÍ mueven la base imponible, y por tanto el impuesto.
    ///
    /// Solo el 49 por ahora. El 02 —el descuento global que afecta la
    /// base— no está aquí porque se resuelve de otra manera: se reparte
    /// dentro de las líneas, con el campo descuentoGlobalPorcentaje.
    /// </summary>
    public static bool AfectaLaBase(string codigo) =>
        codigo == CargoGlobal;

    /// <summary>Los que suman en cbc:ChargeTotalAmount (regla 3301).</summary>
    private static readonly string[] OtrosCargos =
    [
        Fise, RecargoAlConsumo, CargoItemNoAfectaBase, CargoGlobalNoAfectaBase
    ];

    /// <summary>Los que suman en cbc:AllowanceTotalAmount (regla 3300).</summary>
    private static readonly string[] OtrosDescuentos =
    [
        DescuentoItemNoAfectaBase, DescuentoGlobalNoAfectaBase,
        RetencionSegundaCategoria
    ];

    /// <summary>
    /// Los que llevan ChargeIndicator "true". Es una lista literal de la
    /// regla 3114, no una deducción: el 62 y el 63 son retenciones y van
    /// en "false" aunque su nombre no lo sugiera.
    /// </summary>
    private static readonly string[] Cargos =
    [
        Fise, RecargoAlConsumo, CargoItem, CargoItemNoAfectaBase,
        CargoGlobal, CargoGlobalNoAfectaBase,
        "51", "52", "53"   // percepción, que tiene su propio módulo
    ];

    public static bool EsCargo(string codigo) =>
        Array.IndexOf(Cargos, codigo) >= 0;

    public static bool EstaSoportado(string codigo) =>
        Array.IndexOf(Soportados, codigo) >= 0;

    public static bool SumaEnOtrosCargos(string codigo) =>
        Array.IndexOf(OtrosCargos, codigo) >= 0;

    public static bool SumaEnOtrosDescuentos(string codigo) =>
        Array.IndexOf(OtrosDescuentos, codigo) >= 0;

    public static string Descripcion(string codigo) => codigo switch
    {
        DescuentoGlobalNoAfectaBase => "descuento global que no afecta la base imponible",
        CargoGlobalNoAfectaBase => "cargo global que no afecta la base imponible",
        Fise => "FISE (Fondo de Inclusion Social Energetico)",
        RecargoAlConsumo => "recargo al consumo y/o propinas",
        RetencionIgv => "retencion del IGV",
        RetencionSegundaCategoria => "retencion de renta de segunda categoria",
        DescuentoGlobal => "descuento global que afecta la base imponible",
        CargoGlobal => "cargo global que afecta la base imponible",
        _ => "codigo " + codigo
    };
}

/// <summary>
/// Reglas de los cargos y descuentos globales.
///
/// DÓNDE ACABA CADA MONTO, QUE ES LO QUE MÁS CUESTA VER:
///
///   cbc:LineExtensionAmount  → NO los incluye. El valor de venta es el de
///                              las líneas, y estos conceptos van aparte.
///   cbc:TaxInclusiveAmount   → tampoco. Es valor de venta más impuestos.
///   cbc:ChargeTotalAmount    → la suma de los cargos (45, 46, 48, 50).
///   cbc:AllowanceTotalAmount → la suma de los descuentos (01, 03, 63).
///   cbc:PayableAmount        → precio de venta + cargos - descuentos
///                              - anticipos. Aquí es donde por fin aparecen.
///
/// Regla 3280 para el total, 3300 y 3301 para las dos sumatorias.
/// </summary>
public static class ReglasCargosGlobales
{
    /// <summary>
    /// Revisa los cargos y descuentos globales. Lista vacía significa que
    /// pasa. Los textos que empiezan por "Aviso:" no impiden emitir.
    /// </summary>
    public static IReadOnlyList<string> Revisar(ComprobanteBase c)
    {
        var problemas = new List<string>();

        if (c.CargosGlobales.Count == 0) return problemas;

        foreach (var cg in c.CargosGlobales)
        {
            // --- El código ---------------------------------------------------

            if (!CodigoCargoDescuento.EstaSoportado(cg.Codigo))
            {
                // Los dos que sí afectan la base merecen un mensaje propio:
                // no es que no existan, es que se declaran de otra manera.
                if (cg.Codigo == CodigoCargoDescuento.DescuentoGlobal)
                {
                    problemas.Add(
                        "El descuento global que afecta la base imponible (codigo " +
                        "02) no se manda aqui: se declara con el campo " +
                        "'descuentoGlobalPorcentaje', que lo reparte dentro de " +
                        "las lineas para que el IGV salga sobre el monto ya " +
                        "descontado.");
                }
                else
                {
                    problemas.Add(
                        $"El codigo de cargo/descuento '{cg.Codigo}' no esta " +
                        $"soportado. Los disponibles son: 49 (cargo global que " +
                        $"afecta la base), 50 (cargo global que no la afecta), " +
                        $"03 (descuento global que no afecta la base), 45 (FISE), " +
                        $"46 (recargo al consumo), 62 (retencion del IGV) y " +
                        $"63 (retencion de segunda categoria).");
                }

                continue;
            }

            // --- El monto ----------------------------------------------------

            if (cg.Monto <= 0)
            {
                problemas.Add(
                    $"El monto del {CodigoCargoDescuento.Descripcion(cg.Codigo)} " +
                    $"debe ser mayor que cero. SUNAT rechaza el cero con el " +
                    $"error 2968: si no hay monto, el bloque sobra.");

                continue;
            }

            // --- La base y el porcentaje -------------------------------------

            if (cg.BaseImponible is not null && cg.BaseImponible <= 0)
            {
                problemas.Add(
                    $"La base del {CodigoCargoDescuento.Descripcion(cg.Codigo)} " +
                    $"debe ser mayor que cero si se declara (error 3016).");
            }

            // --- LA RETENCIÓN DEL IGV NECESITA BASE Y PORCENTAJE ------------
            //
            // La regla 3263 recalcula el importe como el de la operación por
            // el porcentaje, y compara. Sin los dos datos no hay nada que
            // recalcular, y SUNAT rechaza.
            //
            // La de segunda categoría no lo exige: ahí el importe sale de la
            // renta del perceptor, no de esta operación.

            if (cg.Codigo == CodigoCargoDescuento.RetencionIgv)
            {
                if (cg.BaseImponible is null || cg.Porcentaje is null)
                {
                    problemas.Add(
                        "La retencion del IGV (codigo 62) necesita la base y el " +
                        "porcentaje. SUNAT recalcula el importe multiplicando " +
                        "los dos y compara (error 3263).");
                }

                // El importe de la retención NO se resta del total del
                // comprobante. Se dice para que nadie lo descuadre a mano.
                if (cg.Monto > 0 && cg.BaseImponible is > 0 &&
                    cg.Monto >= cg.BaseImponible)
                {
                    problemas.Add(
                        $"La retencion del IGV ({cg.Monto:0.00}) no puede ser " +
                        $"mayor o igual que la base sobre la que se calcula " +
                        $"({cg.BaseImponible:0.00}).");
                }
            }

            if (cg.Porcentaje is not null)
            {
                if (cg.Porcentaje <= 0 || cg.Porcentaje >= 100000)
                {
                    problemas.Add(
                        $"El porcentaje del " +
                        $"{CodigoCargoDescuento.Descripcion(cg.Codigo)} " +
                        $"({cg.Porcentaje}) no es valido. Va como factor de " +
                        $"hasta 3 enteros y 5 decimales, y no puede ser cero " +
                        $"(error 3025).");
                }
                else if (cg.BaseImponible is null)
                {
                    // SUNAT recalcula monto = base x factor. Sin base no hay
                    // nada que recalcular, y el porcentaje queda de adorno.
                    problemas.Add(
                        $"El {CodigoCargoDescuento.Descripcion(cg.Codigo)} trae " +
                        $"porcentaje pero no base. Si declaras el porcentaje, " +
                        $"declara tambien sobre que importe se calculo: SUNAT " +
                        $"multiplica los dos y compara con el monto.");
                }
                else
                {
                    var esperado = CalculadoraTotales.Redondear(
                        cg.BaseImponible.Value * cg.Porcentaje.Value / 100m);

                    if (Math.Abs(esperado - cg.Monto) > 1m)
                    {
                        problemas.Add(
                            $"El {CodigoCargoDescuento.Descripcion(cg.Codigo)} " +
                            $"no cuadra: {cg.BaseImponible:0.00} por " +
                            $"{cg.Porcentaje:0.##}% da {esperado:0.00}, y el " +
                            $"monto declarado es {cg.Monto:0.00}.");
                    }
                }
            }
        }

        // --- El cargo 49 necesita una base a la que sumarse ------------------
        //
        // "Afecta la base imponible" significa que ese monto se suma a la
        // base y genera su propio impuesto. Si el comprobante no tiene
        // ninguna línea gravada —todo exonerado, todo inafecto, todo
        // exportación— no hay base que afectar, y el cargo subiría el valor
        // de venta sin generar el impuesto que le corresponde. El documento
        // diría dos cosas contrarias.

        var hayCargoQueAfectaBase = c.CargosGlobales
            .Any(cg => CodigoCargoDescuento.AfectaLaBase(cg.Codigo));

        if (hayCargoQueAfectaBase)
        {
            var hayBase = c.Lineas.Any(l =>
                l.TipoAfectacionIgv == AfectacionIgv.GravadoOperacionOnerosa ||
                AfectacionIgv.EsIvap(l.TipoAfectacionIgv));

            if (!hayBase)
            {
                problemas.Add(
                    "Hay un cargo global con el codigo 49, que afecta la base " +
                    "imponible, pero el comprobante no tiene ninguna linea " +
                    "gravada a la que sumarselo. Si el concepto no genera " +
                    "impuesto, el codigo que corresponde es el 50.");
            }
        }

        // --- El importe total tiene que seguir siendo positivo ---------------
        //
        // Los descuentos globales se restan del importe a pagar. Si se pasan,
        // el PayableAmount sale cero o negativo, y la regla 2062 exige un
        // decimal positivo distinto de cero.

        var totales = CalculadoraTotales.Calcular(c);

        if (totales.ImporteTotal <= 0)
        {
            problemas.Add(
                $"Con estos cargos y descuentos el importe total sale " +
                $"{totales.ImporteTotal:0.00}, y SUNAT exige que sea mayor que " +
                $"cero (error 2062). Revisa los descuentos globales: suman " +
                $"{totales.TotalOtrosDescuentos:0.00} sobre un precio de venta " +
                $"de {totales.PrecioVentaEfectivo:0.00}.");
        }

        return problemas;
    }

    /// <summary>Los problemas que impiden emitir. Los avisos quedan fuera.</summary>
    public static IReadOnlyList<string> Errores(ComprobanteBase c) =>
        Revisar(c).Where(p => !p.StartsWith("Aviso:")).ToList();
}