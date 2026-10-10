namespace Facturacion.Cpe;

/// <summary>
/// Catálogo 22: regímenes de percepción del IGV.
///
/// QUÉ ES LA PERCEPCIÓN, EN UNA FRASE: el vendedor cobra al comprador un
/// porcentaje ADICIONAL al precio, y se lo entrega a SUNAT como adelanto
/// del IGV que ese comprador declarará después.
///
/// NO CUALQUIERA PUEDE APLICARLA. Solo los contribuyentes que SUNAT designó
/// AGENTES DE PERCEPCIÓN mediante resolución. No es una opción comercial:
/// aplicarla sin estar designado es tan incorrecto como no aplicarla
/// estándolo.
/// </summary>
public static class RegimenPercepcion
{
    /// <summary>Venta interna de bienes del apéndice 1. Tasa 2%.</summary>
    public const string VentaInterna = "01";

    /// <summary>Adquisición de combustible. Tasa 1%.</summary>
    public const string Combustible = "02";

    /// <summary>
    /// Venta a otro agente de percepción. Tasa 0.5%.
    ///
    /// La tasa baja porque el comprador ya es agente: SUNAT sabe que va a
    /// percibir a su vez, y adelantar el 2% sería cobrar de más.
    /// </summary>
    public const string AgenteTasaEspecial = "03";

    public static bool Existe(string regimen) =>
        regimen is VentaInterna or Combustible or AgenteTasaEspecial;

    /// <summary>
    /// La tasa que le corresponde a cada régimen.
    ///
    /// SE USA SOLO PARA AVISAR, nunca para calcular. SUNAT valida el monto
    /// contra su propio parámetro vigente (regla 2798), y esas tasas las
    /// cambia por resolución sin avisar a nadie. Si algún día la de venta
    /// interna deja de ser 2%, este código seguiría aceptando el valor que
    /// mande el cliente y solo dejaría de coincidir el aviso.
    /// </summary>
    public static decimal TasaReferencia(string regimen) => regimen switch
    {
        VentaInterna       => 2m,
        Combustible        => 1m,
        AgenteTasaEspecial => 0.5m,
        _                  => 0m
    };

    /// <summary>
    /// El código de cargo del catálogo 53 que le corresponde.
    ///
    /// Van en paralelo: régimen 01 → cargo 51, 02 → 52, 03 → 53. No es
    /// casualidad, pero tampoco se puede calcular sumando 50: si SUNAT
    /// añade un régimen 04 no hay garantía de que sea el cargo 54.
    /// </summary>
    public static string CodigoCargo(string regimen) => regimen switch
    {
        VentaInterna       => "51",
        Combustible        => "52",
        AgenteTasaEspecial => "53",
        _ => throw new ArgumentException(
                $"Régimen de percepción no válido: {regimen}", nameof(regimen))
    };

    public static string Descripcion(string regimen) => regimen switch
    {
        VentaInterna       => "Percepcion venta interna",
        Combustible        => "Percepcion a la adquisicion de combustible",
        AgenteTasaEspecial => "Percepcion realizada al agente con tasa especial",
        _                  => regimen
    };
}

/// <summary>
/// Datos de la percepción aplicada a una factura.
///
/// TRES COSAS QUE SORPRENDEN Y CONVIENE SABER ANTES DE MIRAR EL CÓDIGO:
///
/// 1. LA PERCEPCIÓN NO ENTRA EN EL IMPORTE TOTAL DEL COMPROBANTE.
///    La regla 3301 dice que ChargeTotalAmount solo suma los cargos 45, 46,
///    48 y 50; los de percepción no están en esa lista. Así que
///    PayableAmount sale sin percepción, y el total que el cliente paga de
///    verdad viaja aparte, en un cac:PaymentTerms con el identificador
///    "Percepcion".
///
///    Suena raro, pero tiene su lógica: la percepción no es parte del
///    precio de la operación. Es un cobro por cuenta de SUNAT que el
///    vendedor solo recauda.
///
/// 2. SIEMPRE EN SOLES, aunque la factura esté en dólares. Es la única
///    excepción que SUNAT admite a "la moneda debe ser la misma en todo el
///    documento" (regla 2071). El dinero percibido se entrega al fisco en
///    moneda nacional.
///
/// 3. SOLO AL CONTADO. Si la forma de pago es crédito, SUNAT rechaza la
///    factura con el error 3330, y la percepción tiene que ir en un
///    Comprobante de Percepción aparte, que es otro formato.
/// </summary>
public record Percepcion(
    string Regimen,
    decimal Porcentaje,
    decimal BaseEnSoles,
    decimal Monto)
{
    /// <summary>
    /// Importe total del comprobante, en soles, más la percepción.
    /// Es lo que va en el cac:PaymentTerms con identificador "Percepcion".
    /// </summary>
    public decimal TotalConPercepcion => CalculadoraTotales.Redondear(
        BaseEnSoles + Monto);

    /// <summary>El código de cargo del catálogo 53.</summary>
    public string CodigoCargo => RegimenPercepcion.CodigoCargo(Regimen);

    /// <summary>
    /// El factor que viaja al XML en MultiplierFactorNumeric.
    /// 2% se declara como 0.02, no como 2.
    /// </summary>
    public decimal Factor => Math.Round(
        Porcentaje / 100m, 5, MidpointRounding.AwayFromZero);

    /// <summary>
    /// Calcula la percepción sobre una base ya expresada en soles.
    ///
    /// LA BASE ES EL IMPORTE TOTAL CON IGV, no el valor de venta. La
    /// percepción se calcula sobre lo que el comprador paga, impuesto
    /// incluido, y confundirlo produce una diferencia del 18%.
    /// </summary>
    public static decimal CalcularMonto(decimal baseEnSoles, decimal porcentaje) =>
        CalculadoraTotales.Redondear(baseEnSoles * porcentaje / 100m);
}

/// <summary>
/// Reglas de la percepción declarada en una factura.
///
/// Se llama ReglasPercepcion y no Percepcion porque el comprobante ya tiene
/// una propiedad con ese nombre, y un tipo que se llama igual que un
/// miembro es la trampa que nos costó una hora con Exportacion.
/// </summary>
public static class ReglasPercepcion
{
    /// <summary>
    /// Revisa la percepción de una factura. Lista vacía significa que pasa.
    /// Los textos que empiezan por "Aviso:" no impiden emitir.
    /// </summary>
    public static IReadOnlyList<string> Revisar(Factura f)
    {
        var problemas = new List<string>();
        var p = f.Percepcion;

        if (p is null) return problemas;

        // --- Incompatibilidades ---------------------------------------------
        //
        // El tipo de operación es un solo atributo del XML, y detracción,
        // exportación y percepción se lo disputan. No se pueden declarar dos.

        if (f.Detraccion is not null)
        {
            problemas.Add(
                "Una factura no puede estar sujeta a percepcion y a detraccion " +
                "a la vez: el tipo de operacion es uno solo y ambas lo ocupan.");
        }

        if (f.EsExportacion)
        {
            problemas.Add(
                "Una exportacion no puede llevar percepcion: el comprador es un " +
                "no domiciliado y no declara IGV en el Peru.");
        }

        // --- Solo al contado -------------------------------------------------
        //
        // Regla 3330. A crédito, la percepción se documenta en un Comprobante
        // de Percepción aparte, que es otro formato y otro envío.

        if (!string.Equals(f.FormaPago, "Contado", StringComparison.OrdinalIgnoreCase))
        {
            problemas.Add(
                $"La percepcion dentro de la factura solo se admite al contado, " +
                $"y la forma de pago es '{f.FormaPago}'. A credito hay que emitir " +
                $"un Comprobante de Percepcion aparte, que este motor todavia no " +
                $"genera.");
        }

        // --- Régimen y tasa --------------------------------------------------

        if (!RegimenPercepcion.Existe(p.Regimen))
        {
            problemas.Add(
                $"El regimen de percepcion '{p.Regimen}' no existe en el " +
                $"catalogo 22. Solo 01 (venta interna), 02 (combustible) y " +
                $"03 (agente con tasa especial).");

            // Sin un régimen válido, el resto de comprobaciones no tienen
            // sentido: todas dependen de él.
            return problemas;
        }

        if (p.Porcentaje <= 0)
        {
            problemas.Add("El porcentaje de percepcion debe ser mayor que cero.");
        }

        var tasaEsperada = RegimenPercepcion.TasaReferencia(p.Regimen);

        if (p.Porcentaje > 0 && p.Porcentaje != tasaEsperada)
        {
            problemas.Add(
                $"Aviso: el regimen {p.Regimen} " +
                $"({RegimenPercepcion.Descripcion(p.Regimen)}) suele aplicar " +
                $"{tasaEsperada}% y se esta declarando {p.Porcentaje}%. SUNAT " +
                $"valida el monto contra su tasa vigente, asi que si la cambiaron " +
                $"esto es correcto y el aviso sobra.");
        }

        // --- Montos ----------------------------------------------------------

        if (p.BaseEnSoles <= 0)
        {
            problemas.Add(
                "La base de la percepcion debe ser mayor que cero (regla 3233).");
        }

        if (p.Monto <= 0)
        {
            problemas.Add("El monto de la percepcion debe ser mayor que cero.");
        }

        // Regla 2797: la percepción no puede superar al importe total.
        //
        // Con tasas del 0.5% al 2% eso no debería pasar nunca, y justo por
        // eso vale la pena comprobarlo: si pasa, es que alguien confundió el
        // porcentaje con el monto.
        if (p.Monto > 0 && p.BaseEnSoles > 0 && p.Monto > p.BaseEnSoles)
        {
            problemas.Add(
                $"El monto de percepcion ({p.Monto:0.00}) no puede superar al " +
                $"importe total ({p.BaseEnSoles:0.00}). Revisa si se envio el " +
                $"monto donde iba el porcentaje.");
        }

        // --- Moneda ----------------------------------------------------------
        //
        // La percepción siempre va en soles. Cuando la factura está en otra
        // moneda hace falta el tipo de cambio para convertir la base, y sin
        // él no hay forma de calcularla.

        if (f.Moneda != "PEN" && f.TipoCambio is null)
        {
            problemas.Add(
                $"La factura esta en {f.Moneda} y la percepcion se declara " +
                $"siempre en soles, asi que hace falta el tipo de cambio para " +
                $"convertir la base.");
        }

        return problemas;
    }

    /// <summary>Los problemas que impiden emitir. Los avisos quedan fuera.</summary>
    public static IReadOnlyList<string> Errores(Factura f) =>
        Revisar(f).Where(x => !x.StartsWith("Aviso:")).ToList();
}
