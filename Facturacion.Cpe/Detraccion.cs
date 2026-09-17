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
/// Se listan los más frecuentes. El catálogo completo tiene más de cuarenta
/// entradas y cambia con la normativa, así que el motor NO valida contra esta
/// lista: solo la usa para sugerir y para conocer las tasas habituales.
///
/// Validar contra una lista escrita en el código significaría que el día que
/// SUNAT añada un código, el sistema rechace operaciones legítimas hasta que
/// alguien recompile.
/// </summary>
public static class CodigoDetraccion
{
    public const string AzucarMelaza = "001";
    public const string ArrozPilado = "002";
    public const string AlcoholEtilico = "003";
    public const string RecursosHidrobiologicos = "004";
    public const string MaizAmarilloDuro = "005";
    public const string Madera = "008";
    public const string ArenaYPiedra = "009";
    public const string ResiduosMetalicos = "010";
    public const string CarnesYDespojos = "011";
    public const string HarinaDeTrigo = "014";
    public const string OroGravado = "016";
    public const string MineralesMetalicos = "019";
    public const string OroYMinerales = "021";
    public const string MineralesNoMetalicos = "023";
    public const string TransporteCarga = "027";
    public const string TransportePasajeros = "028";
    public const string Intermediacion = "012";
    public const string ArrendamientoBienes = "019b";
    public const string MantenimientoYReparacion = "020";
    public const string MovimientoDeCarga = "021b";
    public const string OtrosServiciosEmpresariales = "022";
    public const string Comision = "024";
    public const string FabricacionPorEncargo = "025";
    public const string ServicioDeTransportePersonas = "026";
    public const string ContratosDeConstruccion = "030";
    public const string DemasServiciosGravados = "037";

    /// <summary>
    /// Tasas habituales, solo como referencia para el panel.
    ///
    /// NO SE USAN PARA CALCULAR NI PARA VALIDAR: las tasas cambian por norma
    /// y quien emite debe saber la suya. Ponerlas como fuente de verdad haría
    /// que el sistema calculara mal en silencio el día que cambien.
    /// </summary>
    public static readonly IReadOnlyDictionary<string, decimal> TasasReferencia =
        new Dictionary<string, decimal>
        {
            ["004"] = 4m,
            ["008"] = 10m,
            ["009"] = 10m,
            ["010"] = 15m,
            ["011"] = 4m,
            ["019"] = 10m,
            ["020"] = 12m,
            ["021"] = 10m,
            ["022"] = 12m,
            ["024"] = 12m,
            ["025"] = 12m,
            ["027"] = 4m,
            ["028"] = 10m,
            ["030"] = 4m,
            ["037"] = 12m
        };
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
