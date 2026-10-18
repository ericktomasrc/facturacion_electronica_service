namespace Facturacion.Cpe;

/// <summary>
/// Liquidación de compra electrónica — tipo 04 del catálogo 01.
///
/// QUÉ ES, EN UNA FRASE: la factura que emite el COMPRADOR cuando el vendedor
/// no puede emitir ninguna.
///
/// El caso típico es el agricultor, el pescador artesanal, el recolector de
/// chatarra o el minero informal: personas naturales sin RUC que venden
/// producto primario. Sin este documento, la compra no se puede sustentar como
/// gasto ni como crédito fiscal, y el comprador no tiene cómo contabilizarla.
///
/// TODO ESTÁ AL REVÉS RESPECTO A UNA FACTURA, y esa es la única dificultad
/// real de este documento:
///
///   - La raíz no es Invoice, es SelfBilledInvoice.
///   - AccountingCustomerParty es el EMISOR (el comprador, con RUC).
///   - AccountingSupplierParty es el VENDEDOR (con DNI, no con RUC).
///   - El IGV no se le paga al vendedor: lo asume el comprador y lo declara
///     como crédito fiscal. Por eso el importe a pagar NO lleva IGV.
///   - Y encima el comprador RETIENE renta al vendedor, así que el importe a
///     pagar es todavía menor.
///
/// La cuenta, con una compra de 1000 soles gravada:
///
///   Valor de compra        1 000.00
///   IGV (18%)                180.00   ← lo asume el comprador
///   ──────────────────────────────
///   Subtotal               1 180.00   ← TaxInclusiveAmount
///   menos IGV               -180.00
///   menos retención (1.5%)   -15.00
///   ──────────────────────────────
///   IMPORTE A PAGAR          985.00   ← PayableAmount, lo que recibe el vendedor
///
/// Esa resta es la regla 4312 y es lo que hace que este documento no se parezca
/// a ningún otro: en una factura el PayableAmount es el más grande de todos los
/// números, y aquí es el más pequeño.
/// </summary>
public static class TipoOperacionLc
{
    /// <summary>Lo normal: se compra producto primario.</summary>
    public const string CompraInterna = "0501";

    /// <summary>Un adelanto al vendedor, que después se descuenta.</summary>
    public const string Anticipos = "0502";

    /// <summary>
    /// Compra de oro. Trae seis datos extra del catálogo 55 —concesión
    /// minera, ley del mineral, naturaleza, nombre del derecho— y no está
    /// implementada aquí: es un mercado con su propia normativa y ninguno de
    /// tus clientes lo toca.
    /// </summary>
    public const string CompraDeOro = "0503";

    /// <summary>Los únicos tres que el catálogo 51 admite en una liquidación.</summary>
    public static bool Existe(string codigo) =>
        codigo == CompraInterna || codigo == Anticipos || codigo == CompraDeOro;

    public static string Descripcion(string codigo) => codigo switch
    {
        CompraInterna => "Compra interna",
        Anticipos     => "Anticipos",
        CompraDeOro   => "Compra de oro",
        _             => "Tipo de operacion " + codigo
    };
}

/// <summary>
/// Catálogo 60: qué es el sitio cuya dirección se está declarando.
///
/// SUNAT lo pide dos veces en una liquidación —para el domicilio del vendedor
/// y para el lugar donde se hizo la operación— y las dos son obligatorias
/// (errores 2456 y 2458).
///
/// POR QUÉ LE IMPORTA: porque la liquidación de compra existe para el producto
/// primario, y saber si el sitio es una chacra, una mina o un puesto de mercado
/// es lo que le permite cruzar el documento contra la actividad declarada.
/// </summary>
public static class TipoDireccion
{
    public const string PuntoDeVenta = "01";
    public const string Produccion   = "02";
    public const string Extraccion   = "03";
    public const string Explotacion  = "04";
    public const string Otros        = "05";

    public static bool Existe(string codigo) =>
        codigo is PuntoDeVenta or Produccion or Extraccion or Explotacion or Otros;

    public static string Descripcion(string codigo) => codigo switch
    {
        PuntoDeVenta => "Punto de venta",
        Produccion   => "Produccion",
        Extraccion   => "Extraccion",
        Explotacion  => "Explotacion",
        Otros        => "Otros",
        _            => "Tipo de direccion " + codigo
    };
}

/// <summary>
/// Tributo 3000 del catálogo 05: la retención del impuesto a la renta.
///
/// NO ES EL MISMO BICHO QUE LA RETENCIÓN DEL IGV que ya tienes en los cargos
/// globales (códigos 62 y 63 del catálogo 53). Aquella es un dato informativo
/// que cuelga del comprobante; esta es un TRIBUTO con su propio TaxSubtotal,
/// tasa y base, declarado línea por línea.
///
/// Y a diferencia del IGV, esta sí le baja el bolsillo al vendedor: el
/// comprador le paga menos y deposita la diferencia a SUNAT a cuenta de la
/// renta que ese vendedor terminará debiendo.
///
/// EL TAXEXEMPTIONREASONCODE NO VA. La regla 3050 rechaza el comprobante si el
/// subtotal del 3000 declara afectación al IGV: no es un tributo de IGV y no
/// tiene afectación que declarar. Mismo caso que el ISC.
/// </summary>
public static class RetencionRenta
{
    public const string Codigo     = "3000";
    public const string Nombre     = "IR";
    public const string TipoCodigo = "TOX";

    /// <summary>
    /// La tasa vigente, en porcentaje.
    ///
    /// SI SUNAT LA CAMBIA, SE CAMBIA AQUÍ Y EN NINGÚN OTRO SITIO. La regla
    /// 4237 observa el comprobante cuando la tasa declarada no es una de las
    /// vigentes a la fecha de emisión, así que el día que se mueva hay que
    /// tocarlo el mismo día.
    /// </summary>
    public const decimal TasaVigente = 1.5m;

    public static decimal Calcular(decimal baseImponible, decimal tasa) =>
        Math.Round(baseImponible * tasa / 100m, 2, MidpointRounding.AwayFromZero);
}

/// <summary>
/// El vendedor de una liquidación de compra.
///
/// NO ES UN Receptor NI UN Emisor, y por eso tiene clase propia: lleva
/// dirección completa y condición del domicilio, que el receptor de una
/// factura no lleva, y NO puede tener RUC, que es justo lo que un emisor
/// necesita.
/// </summary>
public class Vendedor
{
    /// <summary>
    /// Catálogo 06, y solo tres valores: "1" DNI, "4" carnet de extranjería,
    /// "7" pasaporte.
    ///
    /// EL RUC ESTÁ PROHIBIDO (error 2800). Si el vendedor tuviera RUC podría
    /// emitir su propia factura, y entonces este documento no tendría razón
    /// de existir.
    /// </summary>
    public string TipoDocumento { get; set; } = TipoDocIdentidad.Dni;

    public string NumeroDocumento { get; set; } = "";

    /// <summary>Apellidos y nombres. Obligatorio (error 2021).</summary>
    public string Nombres { get; set; } = "";

    /// <summary>Domicilio del vendedor. Obligatorio (error 2452).</summary>
    public string Direccion { get; set; } = "";

    /// <summary>Ubigeo del domicilio. Obligatorio (error 2453).</summary>
    public string Ubigeo { get; set; } = "";

    public string Distrito { get; set; } = "";
    public string Provincia { get; set; } = "";
    public string Departamento { get; set; } = "";

    /// <summary>Catálogo 60. Obligatorio (errores 2456 y 2457).</summary>
    public string CondicionDomicilio { get; set; } = TipoDireccion.Otros;

    public string CodigoPais { get; set; } = "PE";
}

/// <summary>
/// El lugar donde se hizo la compra.
///
/// ES OTRA DIRECCIÓN, distinta del domicilio del vendedor, y también
/// obligatoria (errores 2454, 2455 y 2458). Tiene sentido: el agricultor vive
/// en el pueblo y la chacra está a diez kilómetros, y a SUNAT le interesa la
/// chacra.
///
/// Cuando coinciden, se repiten los mismos datos y ya está.
/// </summary>
public class LugarOperacion
{
    public string Direccion { get; set; } = "";
    public string Ubigeo { get; set; } = "";
    public string Distrito { get; set; } = "";
    public string Provincia { get; set; } = "";
    public string Departamento { get; set; } = "";

    /// <summary>Catálogo 60. Obligatorio (errores 2458 y 2459).</summary>
    public string Condicion { get; set; } = TipoDireccion.Produccion;

    public string CodigoPais { get; set; } = "PE";
}

/// <summary>
/// Una liquidación de compra.
///
/// HEREDA DE ComprobanteBase por la serie, el correlativo, la fecha, la moneda
/// y las líneas, que son idénticas. La propiedad Receptor que viene de la base
/// NO SE USA: el que hace de contraparte aquí es el Vendedor, y es otra clase
/// porque lleva otros datos.
/// </summary>
public class LiquidacionCompra : ComprobanteBase
{
    /// <summary>Catálogo 01.</summary>
    public const string Tipo = "04";

    public override string TipoComprobante => Tipo;

    /// <summary>Catálogo 51: 0501, 0502 o 0503.</summary>
    public string TipoOperacion { get; set; } = TipoOperacionLc.CompraInterna;

    public Vendedor Vendedor { get; set; } = new();

    public LugarOperacion Lugar { get; set; } = new();

    /// <summary>
    /// Si se retiene renta en esta liquidación.
    ///
    /// Casi siempre sí. Se deja apagable porque hay vendedores con
    /// constancia de no retención, y forzar la retención a quien tiene la
    /// constancia es quitarle plata que no le corresponde a nadie.
    /// </summary>
    public bool RetieneRenta { get; set; } = true;

    /// <summary>Tasa de la retención, en porcentaje.</summary>
    public decimal TasaRetencionRenta { get; set; } = RetencionRenta.TasaVigente;
}

/// <summary>Una línea de la liquidación, ya calculada.</summary>
/// <param name="Numero">Orden del ítem, empezando en 1.</param>
/// <param name="Origen">La línea tal como llegó.</param>
/// <param name="ValorVenta">Valor de compra de la línea, sin impuestos.</param>
/// <param name="Igv">IGV de la línea.</param>
/// <param name="Retencion">Retención de renta de la línea.</param>
/// <param name="PrecioUnitarioConIgv">
/// Lo que SUNAT llama "precio de compra unitario". Va en PricingReference con
/// el código de precio "01", igual que en una factura.
/// </param>
public record LineaLiquidacion(
    int Numero,
    LineaComprobante Origen,
    decimal ValorVenta,
    decimal Igv,
    decimal Retencion,
    decimal PrecioUnitarioConIgv);

/// <summary>Los totales de la liquidación.</summary>
/// <param name="ValorVentaGravado">Base del IGV. Tributo 1000.</param>
/// <param name="ValorVentaExonerado">Tributo 9997.</param>
/// <param name="ValorVentaInafecto">Tributo 9998.</param>
/// <param name="ValorVentaGratuito">Tributo 9996.</param>
/// <param name="Igv">Total del IGV.</param>
/// <param name="BaseRetencion">Sobre cuánto se retuvo.</param>
/// <param name="Retencion">Cuánto se retuvo. Tributo 3000.</param>
public record TotalesLiquidacion(
    decimal ValorVentaGravado,
    decimal ValorVentaExonerado,
    decimal ValorVentaInafecto,
    decimal ValorVentaGratuito,
    decimal Igv,
    decimal BaseRetencion,
    decimal Retencion)
{
    /// <summary>
    /// LineExtensionAmount: la suma de las líneas gravadas, exoneradas e
    /// inafectas. Las gratuitas quedan fuera (regla 4309).
    /// </summary>
    public decimal ValorVenta =>
        Redondear(ValorVentaGravado + ValorVentaExonerado + ValorVentaInafecto);

    /// <summary>TaxInclusiveAmount: el valor de venta con el IGV encima.</summary>
    public decimal Subtotal => Redondear(ValorVenta + Igv);

    /// <summary>
    /// PayableAmount: lo que el vendedor cobra de verdad.
    ///
    /// Es el subtotal menos el IGV —que se queda el comprador como crédito
    /// fiscal— menos la retención de renta. Regla 4312.
    /// </summary>
    public decimal ImporteAPagar => Redondear(Subtotal - Igv - Retencion);

    /// <summary>
    /// El TaxAmount global. Solo suma el IGV: la retención de renta tiene su
    /// propio subtotal pero no entra en este total (regla 4301).
    /// </summary>
    public decimal TotalTributos => Igv;

    public bool HayGravadas   => ValorVentaGravado > 0;
    public bool HayExoneradas => ValorVentaExonerado > 0;
    public bool HayInafectas  => ValorVentaInafecto > 0;
    public bool HayGratuitas  => ValorVentaGratuito > 0;

    internal static decimal Redondear(decimal v) =>
        Math.Round(v, 2, MidpointRounding.AwayFromZero);
}

/// <summary>Calcula las líneas y los totales de una liquidación de compra.</summary>
public static class CalculadoraLiquidacion
{
    private static decimal Redondear(decimal v) =>
        Math.Round(v, 2, MidpointRounding.AwayFromZero);

    public static IReadOnlyList<LineaLiquidacion> CalcularLineas(LiquidacionCompra lc)
    {
        var resultado = new List<LineaLiquidacion>();
        var numero = 1;

        foreach (var l in lc.Lineas)
        {
            var bruto = l.ValorUnitario * l.Cantidad;

            var descuento = l.TieneDescuento
                ? Redondear(bruto * l.DescuentoPorcentaje / 100m)
                : 0m;

            var valorVenta = Redondear(bruto - descuento);

            var igv = AfectacionIgv.GeneraIgv(l.TipoAfectacionIgv)
                ? Redondear(valorVenta * l.PorcentajeIgv / 100m)
                : 0m;

            // La retención se calcula sobre el valor de venta de la línea, no
            // sobre el precio con IGV: la regla 4345 compara la base del 3000
            // contra el LineExtensionAmount.
            //
            // Y no se retiene sobre lo gratuito, porque no hay pago del que
            // retener.
            var retencion = lc.RetieneRenta && !AfectacionIgv.EsGratuita(l.TipoAfectacionIgv)
                ? RetencionRenta.Calcular(valorVenta, lc.TasaRetencionRenta)
                : 0m;

            var precioUnitario = l.Cantidad == 0
                ? 0m
                : (valorVenta + igv) / l.Cantidad;

            resultado.Add(new LineaLiquidacion(
                numero++, l, valorVenta, igv, retencion, precioUnitario));
        }

        return resultado;
    }

    public static TotalesLiquidacion Calcular(LiquidacionCompra lc)
    {
        var lineas = CalcularLineas(lc);

        decimal gravado = 0, exonerado = 0, inafecto = 0, gratuito = 0;
        decimal igv = 0, baseRetencion = 0, retencion = 0;

        foreach (var c in lineas)
        {
            var afectacion = c.Origen.TipoAfectacionIgv;

            if (AfectacionIgv.EsGratuita(afectacion)) gratuito += c.ValorVenta;
            else if (afectacion == AfectacionIgv.Exonerado) exonerado += c.ValorVenta;
            else if (afectacion == AfectacionIgv.Inafecto) inafecto += c.ValorVenta;
            else gravado += c.ValorVenta;

            igv += c.Igv;

            if (c.Retencion > 0)
            {
                baseRetencion += c.ValorVenta;
                retencion += c.Retencion;
            }
        }

        return new TotalesLiquidacion(
            Redondear(gravado),
            Redondear(exonerado),
            Redondear(inafecto),
            Redondear(gratuito),
            Redondear(igv),
            Redondear(baseRetencion),
            Redondear(retencion));
    }
}

/// <summary>
/// Reglas de la liquidación de compra.
///
/// Las que se pueden comprobar desde aquí. Hay tres que NO:
///
///   2463  el emisor tiene que estar afecto a renta de tercera categoría.
///         Un NRUS no puede emitir liquidaciones de compra, y eso solo lo
///         sabe SUNAT mirando el padrón.
///
///   2450  el DNI del vendedor tiene que existir en RENIEC, no estar
///         fallecido (2460) y no ser menor de edad (2461).
///
///   2451  el vendedor no puede haber superado las 75 UIT de ventas en el
///         año. Eso es un acumulado anual por persona que solo SUNAT lleva.
///
/// Las tres se descubren en el CDR, no antes.
/// </summary>
public static class ReglasLiquidacion
{
    /// <summary>
    /// Los tres documentos de identidad que el vendedor puede tener.
    /// El RUC no está, y esa ausencia es el documento entero.
    /// </summary>
    public static readonly string[] DocumentosDelVendedor =
    [
        TipoDocIdentidad.Dni,
        TipoDocIdentidad.Extranjeria,
        TipoDocIdentidad.Pasaporte
    ];

    /// <summary>
    /// Las afectaciones que admite una línea de liquidación.
    ///
    /// Regla 3223: el tributo de la línea solo puede ser 1000, 9996, 9997 o
    /// 9998, cada uno con 3000 y 9999 opcionales. Lo que queda fuera es
    /// exportación (9995) —no se exporta comprando— e IVAP (1016).
    /// </summary>
    public static bool AfectacionAdmitida(string afectacion) =>
        !AfectacionIgv.EsExportacion(afectacion) && !AfectacionIgv.EsIvap(afectacion);

    /// <summary>
    /// El plazo para enviar la liquidación: un día calendario desde la
    /// emisión (error 2108). Es más corto que el de la factura.
    /// </summary>
    public const int DiasParaEnviar = 1;

    public static IReadOnlyList<string> Revisar(LiquidacionCompra lc)
    {
        var problemas = new List<string>();

        // --- Serie ------------------------------------------------------------

        if (string.IsNullOrWhiteSpace(lc.Serie) ||
            lc.Serie.Length != 4 ||
            char.ToUpperInvariant(lc.Serie[0]) != 'L')
        {
            problemas.Add(
                $"La serie de una liquidacion de compra empieza por 'L' y tiene " +
                $"cuatro caracteres, como 'L001'. Llego '{lc.Serie}' (error 1001).");
        }

        // --- Tipo de operación ------------------------------------------------

        if (!TipoOperacionLc.Existe(lc.TipoOperacion))
        {
            problemas.Add(
                $"El tipo de operacion '{lc.TipoOperacion}' no existe para una " +
                $"liquidacion de compra. Los unicos son '0501' (compra interna), " +
                $"'0502' (anticipos) y '0503' (compra de oro) (error 3206).");
        }

        if (lc.TipoOperacion == TipoOperacionLc.CompraDeOro)
        {
            problemas.Add(
                "La compra de oro (0503) exige cuatro datos mineros por item " +
                "—concesion, ley del mineral, naturaleza y nombre del derecho— " +
                "que no estan implementados (errores 2466 a 2469).");
        }

        // --- El vendedor ------------------------------------------------------

        var v = lc.Vendedor;

        if (!DocumentosDelVendedor.Contains(v.TipoDocumento))
        {
            var esRuc = v.TipoDocumento == TipoDocIdentidad.Ruc;

            problemas.Add(esRuc
                ? "El vendedor de una liquidacion de compra no puede tener RUC " +
                  "(error 2800). Si lo tiene, que emita su propia factura: " +
                  "este documento existe precisamente para quien no puede."
                : $"El documento del vendedor es de tipo '{v.TipoDocumento}'. " +
                  $"Solo se admite '1' (DNI), '4' (carnet de extranjeria) y " +
                  $"'7' (pasaporte) (error 2800).");
        }

        if (v.TipoDocumento == TipoDocIdentidad.Dni &&
            (v.NumeroDocumento?.Length != 8 || !v.NumeroDocumento.All(char.IsDigit)))
        {
            problemas.Add(
                $"El DNI del vendedor ('{v.NumeroDocumento}') tiene que ser de " +
                $"ocho digitos.");
        }

        if (string.IsNullOrWhiteSpace(v.NumeroDocumento))
            problemas.Add("Falta el documento de identidad del vendedor (error 2014).");

        if (string.IsNullOrWhiteSpace(v.Nombres))
            problemas.Add("Faltan los apellidos y nombres del vendedor (error 2021).");

        if (string.IsNullOrWhiteSpace(v.Direccion))
        {
            problemas.Add(
                "Falta el domicilio del vendedor (error 2452). En una " +
                "liquidacion de compra no es opcional como en una factura.");
        }

        if (string.IsNullOrWhiteSpace(v.Ubigeo) || v.Ubigeo.Length != 6)
        {
            problemas.Add(
                $"Falta el ubigeo del domicilio del vendedor, o no son seis " +
                $"digitos (error 2453). Llego '{v.Ubigeo}'.");
        }

        if (!TipoDireccion.Existe(v.CondicionDomicilio))
        {
            problemas.Add(
                $"La condicion del domicilio del vendedor ('{v.CondicionDomicilio}') " +
                $"no esta en el catalogo 60: '01' punto de venta, '02' produccion, " +
                $"'03' extraccion, '04' explotacion, '05' otros (error 2457).");
        }

        // --- El lugar de la operación -----------------------------------------

        var lugar = lc.Lugar;

        if (string.IsNullOrWhiteSpace(lugar.Direccion))
        {
            problemas.Add(
                "Falta la direccion del lugar donde se hizo la compra " +
                "(error 2454). Es otro dato distinto del domicilio del " +
                "vendedor: el agricultor vive en el pueblo y la chacra esta " +
                "a diez kilometros.");
        }

        if (string.IsNullOrWhiteSpace(lugar.Ubigeo) || lugar.Ubigeo.Length != 6)
        {
            problemas.Add(
                $"Falta el ubigeo del lugar de la operacion, o no son seis " +
                $"digitos (error 2455). Llego '{lugar.Ubigeo}'.");
        }

        if (!TipoDireccion.Existe(lugar.Condicion))
        {
            problemas.Add(
                $"La condicion del lugar de la operacion ('{lugar.Condicion}') " +
                $"no esta en el catalogo 60 (error 2459).");
        }

        // --- Las líneas -------------------------------------------------------

        if (lc.Lineas.Count == 0)
        {
            problemas.Add("La liquidacion no tiene ninguna linea.");
        }

        foreach (var (l, i) in lc.Lineas.Select((l, i) => (l, i + 1)))
        {
            if (!AfectacionIgv.Existe(l.TipoAfectacionIgv))
            {
                problemas.Add(
                    $"La linea {i} tiene la afectacion '{l.TipoAfectacionIgv}', " +
                    $"que no esta en el catalogo 07.");

                continue;
            }

            if (!AfectacionAdmitida(l.TipoAfectacionIgv))
            {
                problemas.Add(
                    $"La linea {i} declara la afectacion '{l.TipoAfectacionIgv}'. " +
                    $"Una liquidacion de compra solo admite gravado, exonerado, " +
                    $"inafecto y gratuito: ni exportacion ni IVAP tienen sentido " +
                    $"comprando (regla 3223).");
            }

            if (l.AfectoIcbper)
            {
                problemas.Add(
                    $"La linea {i} declara ICBPER. Una liquidacion de compra no " +
                    $"admite el tributo 7152 (regla 3223).");
            }

            if (l.TieneIsc)
            {
                problemas.Add(
                    $"La linea {i} declara ISC. Una liquidacion de compra no " +
                    $"admite el tributo 2000 (regla 3223).");
            }

            if (l.Cantidad <= 0)
                problemas.Add($"La cantidad de la linea {i} tiene que ser mayor que cero (error 2024).");

            if (l.ValorUnitario <= 0 && !AfectacionIgv.EsGratuita(l.TipoAfectacionIgv))
                problemas.Add($"El valor unitario de la linea {i} tiene que ser mayor que cero (error 2369).");

            if (string.IsNullOrWhiteSpace(l.Descripcion))
                problemas.Add($"Falta la descripcion del producto de la linea {i} (error 2026).");

            // EL CÓDIGO DE PRODUCTO SUNAT: con forma válida si viene, y
            // OBLIGATORIO desde las reglas de 2027 (ERR-3506). Antes de esa
            // fecha, que falte es solo un aviso, para ir preparándolo.
            if (CodigoProductoSunat.Problema(l.CodigoProductoSunat) is { } malCodigo)
            {
                problemas.Add($"Linea {i}: {malCodigo}");
            }
            else if (string.IsNullOrWhiteSpace(l.CodigoProductoSunat))
            {
                problemas.Add(VigenciaSunat.Rigen2027(lc.FechaEmision)
                    ? $"La linea {i} no tiene codigo de producto SUNAT (codigoProductoSunat, " +
                      $"catalogo 25). En la liquidacion de compra es obligatorio (error 3506)."
                    : $"Aviso: la linea {i} no tiene codigo de producto SUNAT. Desde el " +
                      $"{VigenciaSunat.Reglas2027Desde:dd/MM/yyyy} sera obligatorio en la " +
                      $"liquidacion de compra (error 3506).");
            }
        }

        // --- La retención -----------------------------------------------------

        if (lc.RetieneRenta && lc.TasaRetencionRenta <= 0)
        {
            problemas.Add(
                "Se declara retencion de renta con tasa cero. O se retiene con " +
                "una tasa, o no se retiene (error 3102).");
        }

        if (lc.RetieneRenta && lc.TasaRetencionRenta != RetencionRenta.TasaVigente)
        {
            problemas.Add(
                $"Aviso: la tasa de retencion declarada es {lc.TasaRetencionRenta}% " +
                $"y la vigente es {RetencionRenta.TasaVigente}%. SUNAT observa el " +
                $"comprobante con el 4237 si no reconoce la tasa.");
        }

        if (!lc.RetieneRenta)
        {
            problemas.Add(
                "Aviso: esta liquidacion no retiene renta. Solo es correcto si " +
                "el vendedor tiene constancia de no retencion.");
        }

        // --- Los cargos globales ----------------------------------------------
        //
        // El XSD del SelfBilledInvoice solo admite AllowanceCharge para los
        // anticipos (códigos 04, 05, 06 y 61). Un recargo al consumo o un
        // descuento comercial no caben aquí.

        if (lc.CargosGlobales.Count > 0)
        {
            problemas.Add(
                "Una liquidacion de compra no admite cargos ni descuentos " +
                "globales: el unico AllowanceCharge que acepta es el de los " +
                "anticipos.");
        }

        return problemas;
    }

    /// <summary>Los problemas que impiden emitir. Los avisos quedan fuera.</summary>
    public static IReadOnlyList<string> Errores(LiquidacionCompra lc) =>
        Revisar(lc).Where(p => !p.StartsWith("Aviso:")).ToList();

    /// <summary>Solo los avisos, para el log.</summary>
    public static IReadOnlyList<string> Avisos(LiquidacionCompra lc) =>
        Revisar(lc).Where(p => p.StartsWith("Aviso:")).ToList();
}
