namespace Facturacion.Cpe;

/// <summary>
/// Tipos de operación sujeta a detracción, del catálogo 51.
///
/// QUÉ ES LA DETRACCIÓN: en ciertas operaciones, el comprador no le paga el
/// total al vendedor. Retiene un porcentaje y lo deposita en una cuenta que
/// el vendedor tiene en el Banco de la Nación, destinada solo a pagar
/// impuestos.
///
/// SUNAT lo llama SPOT, Sistema de Pago de Obligaciones Tributarias, y sirve
/// para asegurarse de que el vendedor tenga con qué pagar sus tributos.
/// </summary>
public static class TipoOperacionDetraccion
{
    /// <summary>El caso general. El código de bien o servicio es libre.</summary>
    public const string General = "1001";

    /// <summary>Recursos hidrobiológicos. Obliga al código 004.</summary>
    public const string Hidrobiologicos = "1002";

    /// <summary>Transporte de pasajeros. Obliga al código 028.</summary>
    public const string TransportePasajeros = "1003";

    /// <summary>Transporte de carga. Obliga al código 027.</summary>
    public const string TransporteCarga = "1004";

    public static bool EsValido(string codigo) =>
        codigo is General or Hidrobiologicos or TransportePasajeros or TransporteCarga;

    /// <summary>
    /// El código de bien o servicio que SUNAT exige para cada tipo.
    ///
    /// Tres de los cuatro tipos tienen un código fijo, y usar otro rechaza la
    /// factura con el error 3129. Solo el tipo general admite cualquiera del
    /// catálogo 54.
    /// </summary>
    public static string? CodigoObligatorio(string tipoOperacion) => tipoOperacion switch
    {
        Hidrobiologicos => "004",
        TransportePasajeros => "028",
        TransporteCarga => "027",
        _ => null
    };
}

/// <summary>
/// Códigos del catálogo 54: qué bien o servicio está sujeto a detracción.
///
/// ESTA TABLA ESTUVO MAL DURANTE MESES, y conviene que quede escrito porque
/// explica cómo está hecha ahora.
///
/// Nueve de sus veintiséis constantes apuntaban al código equivocado. Entre
/// ellas había dos inventadas —"019b" y "021b"— que no existen en ningún
/// catálogo de SUNAT: alguien se encontró con que el 019 y el 021 ya estaban
/// usados por otra constante (mal asignada, precisamente) y les añadió una
/// letra para que compilara.
///
/// No hizo daño por una única razón: NADIE LA USABA. En toda la solución
/// aparecía una sola vez, su propia declaración. Si hubiera estado cableada
/// como validación, habría rechazado detracciones perfectamente válidas.
///
/// De ahí la forma que tiene ahora: cada constante lleva al lado la
/// descripción textual del catálogo. Un nombre en C# puede confundirse —
/// "minerales metálicos" y "minerales no metálicos" se parecen mucho— pero
/// la frase de SUNAT al lado hace que un desajuste se vea al leerlo.
///
///
/// NO ES UNA LISTA BLANCA Y NO DEBE SERLO.
///
/// Al reconstruirla se consultaron los anexos de SUNAT (R.S. 318-2017 y
/// 117-2017) y tablas de otros proveedores, Y NO COINCIDEN: los anexos
/// oficiales van del 001 al 040 y saltan del 026 al 029, sin 027 ni 028 —
/// que son transporte de carga y de pasajeros, y se usan todos los días en
/// Perú. El 041 tampoco está, porque es posterior a esos anexos.
///
/// Es decir: no se puede determinar con certeza la composición exacta del
/// catálogo vigente. Validar contra una lista así rechazaría operaciones
/// legítimas, que es el peor fallo posible en un motor de facturación.
///
/// El código de bien viaja tal cual y lo valida SUNAT. Esto sirve para
/// escribirlo bien, no para impedirlo.
/// </summary>
public static class CodigoDetraccion
{
    // --- Bienes -----------------------------------------------------------

    /// <summary>Azúcar y melaza de caña.</summary>
    public const string Azucar = "001";

    /// <summary>Alcohol etílico.</summary>
    public const string AlcoholEtilico = "003";

    /// <summary>Recursos hidrobiológicos. El que exige el tipo 1002.</summary>
    public const string RecursosHidrobiologicos = "004";

    /// <summary>Maíz amarillo duro.</summary>
    public const string MaizAmarilloDuro = "005";

    /// <summary>Algodón.</summary>
    public const string Algodon = "006";

    /// <summary>Caña de azúcar.</summary>
    public const string CanaDeAzucar = "007";

    /// <summary>Madera.</summary>
    public const string Madera = "008";

    /// <summary>Arena y piedra.</summary>
    public const string ArenaYPiedra = "009";

    /// <summary>Residuos, subproductos, desechos, recortes y desperdicios.</summary>
    public const string Residuos = "010";

    /// <summary>Bienes del inciso A) del Apéndice I de la Ley del IGV.</summary>
    public const string BienesApendiceI = "011";

    /// <summary>Animales vivos.</summary>
    public const string AnimalesVivos = "013";

    /// <summary>Carnes y despojos comestibles.</summary>
    public const string CarnesYDespojos = "014";

    /// <summary>Abonos, cueros y pieles de origen animal.</summary>
    public const string AbonosCuerosYPieles = "015";

    /// <summary>Aceite de pescado.</summary>
    public const string AceiteDePescado = "016";

    /// <summary>Harina, polvo y pellets de pescado, crustáceos y moluscos.</summary>
    public const string HarinaDePescado = "017";

    /// <summary>Embarcaciones pesqueras.</summary>
    public const string EmbarcacionesPesqueras = "018";

    /// <summary>Leche.</summary>
    public const string Leche = "023";

    /// <summary>Algodón en rama sin desmontar.</summary>
    public const string AlgodonEnRama = "029";

    /// <summary>Oro gravado con el IGV.</summary>
    public const string OroGravado = "031";

    /// <summary>Páprika y otros frutos de los géneros capsicum o pimienta.</summary>
    public const string Paprika = "032";

    /// <summary>Espárragos.</summary>
    public const string Esparragos = "033";

    /// <summary>Minerales metálicos no auríferos.</summary>
    public const string MineralesMetalicosNoAuriferos = "034";

    /// <summary>Bienes exonerados del IGV.</summary>
    public const string BienesExonerados = "035";

    /// <summary>Oro y demás minerales metálicos exonerados del IGV.</summary>
    public const string OroYMineralesExonerados = "036";

    /// <summary>Minerales no metálicos.</summary>
    public const string MineralesNoMetalicos = "039";

    /// <summary>Bien inmueble gravado con IGV.</summary>
    public const string BienInmuebleGravado = "040";

    // --- Servicios --------------------------------------------------------

    /// <summary>Intermediación laboral y tercerización.</summary>
    public const string Intermediacion = "012";

    /// <summary>Arrendamiento de bienes muebles.</summary>
    public const string ArrendamientoBienes = "019";

    /// <summary>Mantenimiento y reparación de bienes muebles.</summary>
    public const string MantenimientoYReparacion = "020";

    /// <summary>Movimiento de carga.</summary>
    public const string MovimientoDeCarga = "021";

    /// <summary>Otros servicios empresariales.</summary>
    public const string OtrosServiciosEmpresariales = "022";

    /// <summary>Comisión mercantil.</summary>
    public const string ComisionMercantil = "024";

    /// <summary>Fabricación de bienes por encargo.</summary>
    public const string FabricacionPorEncargo = "025";

    /// <summary>Servicio de transporte de personas.</summary>
    public const string TransporteDePersonas = "026";

    /// <summary>Contratos de construcción.</summary>
    public const string ContratosDeConstruccion = "030";

    /// <summary>Demás servicios gravados con el IGV.</summary>
    public const string DemasServiciosGravados = "037";

    // --- Los que no están en los anexos de 2017 ---------------------------
    //
    // Están aparte y con este aviso encima a propósito: si algún día uno de
    // estos deja de funcionar, aquí está la explicación en vez de una
    // búsqueda de media mañana.
    //
    // El 027 y el 028 no aparecen en los anexos oficiales que se consultaron
    // —saltan del 026 al 029— y sin embargo son los que SUNAT EXIGE para los
    // tipos de operación 1004 y 1003, como se ve en
    // TipoOperacionDetraccion.CodigoObligatorio, que sí está en uso y
    // funciona contra SUNAT.
    //
    // El 041 es posterior a esos anexos.

    /// <summary>Servicio de transporte de carga. El que exige el tipo 1004.</summary>
    public const string TransporteDeCarga = "027";

    /// <summary>Transporte de pasajeros. El que exige el tipo 1003.</summary>
    public const string TransporteDePasajeros = "028";

    /// <summary>Plomo. Añadido después de los anexos de 2017.</summary>
    public const string Plomo = "041";

    // --- LAS TASAS SE QUITARON, Y ESO TAMBIÉN ES UNA DECISIÓN -------------
    //
    // Aquí había un diccionario TasasReferencia con quince porcentajes,
    // "solo como referencia para el panel". No lo usaba nadie, y al
    // contrastarlo con las fuentes tampoco coincidía: madera al 10% en un
    // sitio y al 4% en otro, comisión mercantil al 12% y al 10%, fabricación
    // por encargo igual. Las tasas del SPOT se han modificado varias veces y
    // no hay forma de saber desde el código cuál rige hoy.
    //
    // Un número que no se puede respaldar es peor que ningún número: alguien
    // lo va a copiar a una factura creyendo que es la tasa vigente.
    //
    // Quien emite sabe su tasa, y va en el campo `Porcentaje` de la
    // detracción. Si algún día el panel quiere sugerirlas, que las lea de una
    // tabla en la base que se pueda actualizar sin recompilar.
}

/// <summary>
/// Los datos de la detracción que van en la factura.
/// </summary>
/// <param name="TipoOperacion">
/// Del catálogo 51: 1001 general, 1002 hidrobiológicos, 1003 transporte de
/// pasajeros, 1004 transporte de carga.
/// </param>
/// <param name="CodigoBienServicio">
/// Del catálogo 54. Para los tipos 1002, 1003 y 1004 SUNAT obliga a un valor
/// concreto.
/// </param>
/// <param name="Porcentaje">
/// La tasa que se retiene, en porcentaje. Por ejemplo 12 para el 12%.
/// </param>
/// <param name="Monto">
/// El importe retenido, SIEMPRE EN SOLES aunque la factura esté en otra
/// moneda. Lo exige la regla 3208: la cuenta del Banco de la Nación es en
/// soles.
/// </param>
/// <param name="CuentaBancoNacion">
/// La cuenta de detracciones del vendedor. La abre él, no el comprador.
/// </param>
/// <param name="MedioDePago">
/// Del catálogo 59. Por defecto, depósito en cuenta.
/// </param>
public record Detraccion(
    string TipoOperacion,
    string CodigoBienServicio,
    decimal Porcentaje,
    decimal Monto,
    string CuentaBancoNacion,
    string MedioDePago = "001")
{
    /// <summary>
    /// El umbral por debajo del cual NO se aplica el sistema.
    ///
    /// Está en la norma y no en el catálogo: operaciones de 700 soles o menos
    /// quedan exceptuadas. Por eso el motor avisa si se declara detracción en
    /// una factura menor: casi siempre es un error de configuración del
    /// cliente.
    /// </summary>
    public const decimal UmbralMinimo = 700m;

    /// <summary>
    /// La leyenda obligatoria, del catálogo 15.
    ///
    /// Sin ella SUNAT rechaza, y el texto debe ser exactamente este.
    /// </summary>
    public const string CodigoLeyenda = "2006";

    public const string TextoLeyenda =
        "Operacion sujeta al Sistema de Pago de Obligaciones Tributarias con " +
        "el Gobierno Central";

    /// <summary>
    /// Comprueba lo que se puede comprobar antes de enviar.
    /// </summary>
    /// <param name="importeTotal">
    /// El total de la factura, para avisar del umbral.
    /// </param>
    public IReadOnlyList<string> Revisar(decimal importeTotal, string moneda)
    {
        var problemas = new List<string>();

        if (!TipoOperacionDetraccion.EsValido(TipoOperacion))
        {
            problemas.Add(
                $"El tipo de operación '{TipoOperacion}' no es de detracción. " +
                "Los válidos son 1001, 1002, 1003 y 1004.");
        }

        // Tres de los cuatro tipos tienen código obligatorio.
        //
        // Usar otro rechaza la factura con el error 3129, cuyo mensaje —"el
        // dato no corresponde al valor esperado"— no dice cuál se esperaba.
        var obligatorio = TipoOperacionDetraccion.CodigoObligatorio(TipoOperacion);

        if (obligatorio is not null && CodigoBienServicio != obligatorio)
        {
            problemas.Add(
                $"Con el tipo de operación {TipoOperacion}, el código de bien " +
                $"o servicio debe ser exactamente '{obligatorio}', no " +
                $"'{CodigoBienServicio}'.");
        }

        if (string.IsNullOrWhiteSpace(CodigoBienServicio))
            problemas.Add("Falta el código de bien o servicio del catálogo 54.");

        if (Porcentaje <= 0 || Porcentaje > 100)
            problemas.Add("El porcentaje de detracción debe estar entre 0 y 100.");

        if (Monto <= 0)
            problemas.Add("El monto de la detracción debe ser mayor que cero.");

        if (string.IsNullOrWhiteSpace(CuentaBancoNacion))
        {
            problemas.Add(
                "Falta el número de cuenta del Banco de la Nación. La abre el " +
                "vendedor, no el comprador.");
        }

        // El umbral es una advertencia, no un error.
        //
        // Hay casos donde se detrae igualmente por acuerdo o por régimen
        // especial, así que el motor no lo impide: solo avisa, porque casi
        // siempre es un error de configuración del cliente.
        if (moneda == "PEN" && importeTotal <= UmbralMinimo)
        {
            problemas.Add(
                $"Aviso: la factura es de {importeTotal:N2} soles y el sistema " +
                $"de detracciones no se aplica a operaciones de " +
                $"{UmbralMinimo:N0} soles o menos. Comprueba que corresponda.");
        }

        return problemas;
    }

    /// <summary>
    /// Calcula el monto a partir del total y el porcentaje.
    ///
    /// SE REDONDEA AL ENTERO MÁS PRÓXIMO, que es lo que hace el sistema del
    /// Banco de la Nación. Declarar céntimos produce diferencias con el
    /// depósito real.
    /// </summary>
    public static decimal CalcularMonto(decimal importeTotal, decimal porcentaje) =>
        Math.Round(importeTotal * porcentaje / 100m, 0, MidpointRounding.AwayFromZero);
}