namespace Facturacion.Cpe;

/// <summary>
/// Marca los comprobantes que NO tienen líneas de detalle.
///
/// POR QUÉ HACE FALTA: el repositorio rechaza cualquier comprobante sin
/// líneas, y tiene razón para una factura —una factura sin nada que cobrar no
/// existe—. Pero el comprobante de retención y el de percepción no llevan
/// productos: llevan una lista de FACTURAS DE OTRO, con cuánto se retuvo o
/// percibió de cada una. Su detalle son documentos, no artículos.
///
/// En vez de meter un "si el tipo es 20 o 40 entonces no valides" dentro del
/// repositorio, que es donde ese conocimiento no pinta nada, se marcan aquí.
/// </summary>
public interface IComprobanteSinLineas
{
    /// <summary>
    /// El importe que va a la base y al panel. Cada documento decide cuál de
    /// sus números es el que representa la operación.
    /// </summary>
    decimal ImporteDeclarado { get; }
}

/// <summary>
/// Catálogo 23: régimen de retención del IGV.
///
/// LA RETENCIÓN, EN UNA FRASE: SUNAT designa a ciertas empresas grandes como
/// "agentes de retención". Cuando esa empresa le paga a un proveedor, no le
/// paga todo: se queda el 3% y lo deposita a SUNAT a cuenta del IGV que ese
/// proveedor deberá. Y le entrega este comprobante como constancia.
///
/// El proveedor cobra menos, pero ese 3% le sirve después para pagar menos
/// IGV. No es un costo, es un adelanto.
/// </summary>
public static class RegimenRetencion
{
    /// <summary>El régimen general. Es el único vigente.</summary>
    public const string Tasa3 = "01";

    /// <summary>
    /// Tasa del 6%. Existió hasta el 28/02/2014 y SUNAT rechaza con el 2985
    /// cualquier documento relacionado posterior a esa fecha.
    ///
    /// Se deja declarado para no romper comprobantes viejos y para que quien
    /// lo vea sepa por qué no debe usarlo.
    /// </summary>
    public const string Tasa6 = "02";

    public static bool Existe(string codigo) => codigo == Tasa3 || codigo == Tasa6;

    /// <summary>
    /// La tasa que le corresponde al régimen.
    ///
    /// NO SE ACEPTA UNA TASA LIBRE, a propósito: la regla 2619 compara la
    /// declarada contra la del catálogo, así que el único efecto de dejar
    /// escribirla sería permitir equivocarse.
    /// </summary>
    public static decimal Tasa(string codigo) => codigo switch
    {
        Tasa3 => 3m,
        Tasa6 => 6m,
        _ => throw new ArgumentException(
                $"Régimen de retención desconocido: {codigo}", nameof(codigo))
    };

    public static string Descripcion(string codigo) => codigo switch
    {
        Tasa3 => "Tasa 3%",
        Tasa6 => "Tasa 6% (derogada desde el 01/03/2014)",
        _ => "Regimen " + codigo
    };

    /// <summary>El día en que la tasa del 6% dejó de existir.</summary>
    public static readonly DateTime FinDeLaTasa6 = new(2014, 2, 28);
}

// ---------------------------------------------------------------------------
// EL CATÁLOGO 22 NO SE REDECLARA AQUÍ.
//
// RegimenPercepcion ya existe en Percepcion.cs, donde nació para la percepción
// que cuelga de una factura. Es el mismo catálogo y las mismas tres tasas, así
// que este documento lo reutiliza.
//
// LA DIFERENCIA ENTRE LOS DOS DOCUMENTOS, que es lo único que hay que tener
// claro:
//
//   Retención  → el agente PAGA menos.   El importe neto BAJA.
//   Percepción → el agente COBRA más.    El importe neto SUBE.
//
// Está en una sola línea de la calculadora, más abajo.
// ---------------------------------------------------------------------------

/// <summary>
/// La contraparte de un comprobante de retención o percepción.
///
/// SIEMPRE TIENE RUC. En la retención es el proveedor al que se le retuvo; en
/// la percepción, el cliente al que se le percibió. Los dos son empresas: a
/// una persona sin RUC no se le retiene ni se le percibe nada.
/// </summary>
public class ContraparteCre
{
    public string Ruc { get; set; } = "";
    public string RazonSocial { get; set; } = "";
    public string NombreComercial { get; set; } = "";

    // La dirección es opcional en este documento —todo lo que falte sale como
    // observación, no como rechazo— pero conviene mandarla: es lo que se
    // imprime en la constancia que recibe la otra empresa.

    public string Ubigeo { get; set; } = "";
    public string Direccion { get; set; } = "";
    public string Urbanizacion { get; set; } = "";
    public string Provincia { get; set; } = "";
    public string Departamento { get; set; } = "";
    public string Distrito { get; set; } = "";
    public string CodigoPais { get; set; } = "PE";
}

/// <summary>
/// Un documento sobre el que se retuvo o percibió.
///
/// ES EL DETALLE DEL COMPROBANTE: en lugar de artículos, facturas de otro.
/// Cada una con cuánto se pagó o cobró, cuándo, y cuánto se retuvo o percibió.
/// </summary>
public class DocumentoCobrado
{
    /// <summary>
    /// Catálogo 01.
    ///
    /// En retención: "01", "07", "08", "12" o "20".
    /// En percepción: "01", "03", "07", "08", "12" o "40".
    ///
    /// El "12" es el ticket de máquina registradora y tiene formato libre;
    /// los demás van como SERIE-CORRELATIVO.
    /// </summary>
    public string TipoDocumento { get; set; } = TipoComprobante.Factura;

    /// <summary>Serie y correlativo: "F001-00000123".</summary>
    public string Numero { get; set; } = "";

    public DateTime FechaEmision { get; set; }

    /// <summary>Lo que dice ese documento, en su moneda.</summary>
    public decimal ImporteTotal { get; set; }

    /// <summary>Moneda de ese documento. Puede no ser la del comprobante.</summary>
    public string Moneda { get; set; } = "PEN";

    /// <summary>
    /// Número de pago o cobro dentro del comprobante.
    ///
    /// UNA FACTURA PUEDE PAGARSE EN VARIAS VECES, y cada pago genera su propia
    /// retención. Este número las distingue: la regla 2626 rechaza dos líneas
    /// con el mismo documento y el mismo número de pago.
    /// </summary>
    public int NumeroPago { get; set; } = 1;

    public DateTime FechaPago { get; set; }

    /// <summary>
    /// Lo que se pagó o cobró en esta operación, SIN la retención ni la
    /// percepción. Es la base sobre la que se aplica la tasa.
    /// </summary>
    public decimal ImportePago { get; set; }

    /// <summary>
    /// Obligatorio si la moneda del documento no es PEN.
    ///
    /// LA RETENCIÓN Y LA PERCEPCIÓN SE DECLARAN SIEMPRE EN SOLES, aunque la
    /// factura esté en dólares (errores 2742 y 2707). Sin el tipo de cambio
    /// no hay forma de convertir, y SUNAT rechaza con el 2721.
    /// </summary>
    public TipoCambio? TipoCambio { get; set; }

    public bool EsMonedaExtranjera => Moneda != "PEN";
}

/// <summary>
/// Comprobante de retención electrónico. Tipo 20, serie R###.
///
/// Lo emite el AGENTE DE RETENCIÓN designado por SUNAT cuando le paga a un
/// proveedor. No es una factura: no vende nada, constata que se quedó con una
/// parte del pago para depositarla al fisco.
///
/// NO CONFUNDIR CON EL CARGO 62 que ya tienes en las facturas. Ese es lo que
/// declara el PROVEEDOR en su propia factura ("me van a retener 35.40"); este
/// es lo que emite el AGENTE. Son los dos lados de la misma operación, y a
/// tus clientes normalmente les toca el lado del proveedor: reciben este
/// documento, no lo emiten.
/// </summary>
public class ComprobanteRetencion : ComprobanteBase, IComprobanteSinLineas
{
    public const string Tipo = "20";

    public override string TipoComprobante => Tipo;

    /// <summary>Catálogo 23. Prácticamente siempre "01".</summary>
    public string Regimen { get; set; } = RegimenRetencion.Tasa3;

    /// <summary>El proveedor al que se le retuvo.</summary>
    public ContraparteCre Proveedor { get; set; } = new();

    /// <summary>Las facturas que se pagaron, con su retención cada una.</summary>
    public List<DocumentoCobrado> Documentos { get; set; } = [];

    /// <summary>Texto libre. Sale impreso en la constancia.</summary>
    public string Observaciones { get; set; } = "";

    public decimal Tasa => RegimenRetencion.Tasa(Regimen);

    /// <summary>Lo retenido en total. Es lo que este documento declara.</summary>
    public decimal ImporteDeclarado => CalculadoraCre.Calcular(this).Total;
}

/// <summary>
/// Comprobante de percepción electrónico. Tipo 40, serie P###.
///
/// El espejo del anterior. Lo emite el AGENTE DE PERCEPCIÓN cuando le cobra a
/// un cliente: le suma un 2% al total y lo deposita a SUNAT a cuenta del IGV
/// que ese cliente deberá cuando revenda.
///
/// El cliente paga MÁS, no menos. Esa es toda la diferencia.
/// </summary>
public class ComprobantePercepcion : ComprobanteBase, IComprobanteSinLineas
{
    public const string Tipo = "40";

    public override string TipoComprobante => Tipo;

    /// <summary>Catálogo 22. "01" venta interna es el habitual.</summary>
    public string Regimen { get; set; } = RegimenPercepcion.VentaInterna;

    /// <summary>El cliente al que se le percibió.</summary>
    public ContraparteCre Cliente { get; set; } = new();

    public List<DocumentoCobrado> Documentos { get; set; } = [];

    public string Observaciones { get; set; } = "";

    public decimal Tasa => RegimenPercepcion.TasaReferencia(Regimen);

    /// <summary>Lo percibido en total.</summary>
    public decimal ImporteDeclarado => CalculadoraCre.Calcular(this).Total;
}

/// <summary>Un documento ya calculado.</summary>
/// <param name="Documento">El documento tal como llegó.</param>
/// <param name="ImporteEnSoles">
/// El importe del pago convertido a soles. Si la factura ya está en soles es
/// el mismo número.
/// </param>
/// <param name="Monto">Lo retenido o percibido, siempre en soles.</param>
/// <param name="Neto">
/// El importe que realmente cambia de manos: el pago menos la retención, o el
/// cobro más la percepción.
/// </param>
public record LineaCre(
    DocumentoCobrado Documento,
    decimal ImporteEnSoles,
    decimal Monto,
    decimal Neto);

/// <summary>Los totales del comprobante.</summary>
/// <param name="Total">
/// La suma de lo retenido o percibido. Va en cbc:TotalInvoiceAmount.
/// </param>
/// <param name="Neto">
/// La suma de los netos. Va en sac:SUNATTotalPaid o sac:SUNATTotalCashed.
/// </param>
public record TotalesCre(decimal Total, decimal Neto, IReadOnlyList<LineaCre> Lineas);

/// <summary>
/// Calcula un comprobante de retención o de percepción.
///
/// LOS DOS EN LA MISMA CLASE, y no por ahorrar código: porque la diferencia
/// entre ellos es literalmente un signo, y tenerla a la vista en una sola
/// línea es lo que impide que dentro de seis meses alguien "corrija" uno de
/// los dos sin darse cuenta de que el otro hace lo contrario a propósito.
/// </summary>
public static class CalculadoraCre
{
    private static decimal Redondear(decimal v) =>
        Math.Round(v, 2, MidpointRounding.AwayFromZero);

    public static TotalesCre Calcular(ComprobanteRetencion r) =>
        Calcular(r.Documentos, r.Tasa, resta: true);

    public static TotalesCre Calcular(ComprobantePercepcion p) =>
        Calcular(p.Documentos, p.Tasa, resta: false);

    private static TotalesCre Calcular(
        IEnumerable<DocumentoCobrado> documentos, decimal tasa, bool resta)
    {
        var lineas = new List<LineaCre>();

        decimal total = 0, neto = 0;

        foreach (var d in documentos)
        {
            // El pago, convertido a soles. Todo lo que este documento declara
            // va en soles aunque la factura no lo esté.
            var enSoles = d.EsMonedaExtranjera && d.TipoCambio is not null
                ? Redondear(d.ImportePago * d.TipoCambio.Tasa)
                : Redondear(d.ImportePago);

            var monto = Redondear(enSoles * tasa / 100m);

            // AQUÍ ESTÁ LA ÚNICA DIFERENCIA ENTRE LOS DOS DOCUMENTOS.
            //
            // Retención: el proveedor cobra el pago menos lo retenido.
            // Percepción: el cliente paga el cobro más lo percibido.
            var netoLinea = resta ? enSoles - monto : enSoles + monto;

            lineas.Add(new LineaCre(d, enSoles, monto, Redondear(netoLinea)));

            total += monto;
            neto += netoLinea;
        }

        return new TotalesCre(Redondear(total), Redondear(neto), lineas);
    }
}

/// <summary>
/// Reglas de los dos comprobantes.
///
/// Las que no se pueden comprobar desde aquí, y que salen en el CDR:
///
///   2617  el emisor tiene que estar en el padrón de agentes de retención
///         (o de percepción). No basta con querer: SUNAT te designa.
///
///   2621  el RUC de la contraparte tiene que existir en el padrón.
///
///   4091  observación si la contraparte también es agente. No impide emitir,
///         pero suele significar que no había que retenerle.
/// </summary>
public static class ReglasCre
{
    /// <summary>
    /// Tipos de documento que admite el detalle de una retención.
    /// Regla 2692.
    /// </summary>
    public static readonly string[] DocumentosEnRetencion =
        ["01", "07", "08", "12", "20"];

    /// <summary>
    /// Tipos que admite una percepción. Lleva además la boleta ("03"),
    /// porque a un cliente se le puede percibir sin que tenga factura.
    /// </summary>
    public static readonly string[] DocumentosEnPercepcion =
        ["01", "03", "07", "08", "12", "40"];

    /// <summary>Ticket de máquina registradora: formato libre.</summary>
    public const string Ticket = "12";

    public static IReadOnlyList<string> Revisar(ComprobanteRetencion r)
    {
        var problemas = Comunes(
            r, 'R', r.Proveedor, r.Documentos, DocumentosEnRetencion,
            "retencion");

        if (!RegimenRetencion.Existe(r.Regimen))
        {
            problemas.Add(
                $"El regimen de retencion '{r.Regimen}' no esta en el catalogo " +
                $"23. Los unicos son '01' (3%) y '02' (6%, derogado) " +
                $"(error 2618).");

            return problemas;
        }

        // --- La tasa del 6% murió en 2014 -------------------------------------

        if (r.Regimen == RegimenRetencion.Tasa6)
        {
            var posteriores = r.Documentos
                .Where(d => d.FechaEmision.Date > RegimenRetencion.FinDeLaTasa6)
                .Select(d => d.Numero)
                .ToList();

            if (posteriores.Count > 0)
            {
                problemas.Add(
                    $"El regimen '02' es la tasa del 6%, que dejo de existir el " +
                    $"28/02/2014. Estos documentos son posteriores y SUNAT los " +
                    $"rechaza con el 2985: {string.Join(", ", posteriores)}. " +
                    $"El regimen vigente es el '01'.");
            }
        }

        return problemas;
    }

    public static IReadOnlyList<string> Revisar(ComprobantePercepcion p)
    {
        var problemas = Comunes(
            p, 'P', p.Cliente, p.Documentos, DocumentosEnPercepcion,
            "percepcion");

        if (!RegimenPercepcion.Existe(p.Regimen))
        {
            problemas.Add(
                $"El regimen de percepcion '{p.Regimen}' no esta en el catalogo " +
                $"22. Los unicos son '01' (venta interna, 2%), '02' " +
                $"(combustible, 1%) y '03' (agente con tasa especial, 0.5%) " +
                $"(error 2602).");
        }

        return problemas;
    }

    // ------------------------------------------------------------------ interno

    private static List<string> Comunes(
        ComprobanteBase c,
        char inicialDeSerie,
        ContraparteCre contraparte,
        List<DocumentoCobrado> documentos,
        string[] tiposAdmitidos,
        string nombre)
    {
        var problemas = new List<string>();

        // --- Serie ------------------------------------------------------------

        if (string.IsNullOrWhiteSpace(c.Serie) ||
            c.Serie.Length != 4 ||
            char.ToUpperInvariant(c.Serie[0]) != inicialDeSerie)
        {
            problemas.Add(
                $"La serie de un comprobante de {nombre} empieza por " +
                $"'{inicialDeSerie}' y tiene cuatro caracteres, como " +
                $"'{inicialDeSerie}001'. Llego '{c.Serie}' (error 1001).");
        }

        // --- La contraparte ---------------------------------------------------

        if (string.IsNullOrWhiteSpace(contraparte.Ruc) ||
            contraparte.Ruc.Length != 11 ||
            !contraparte.Ruc.All(char.IsDigit))
        {
            problemas.Add(
                $"El RUC de la contraparte ('{contraparte.Ruc}') tiene que ser " +
                $"de once digitos (error 2724).");
        }
        else if (!DocumentoIdentidad.RucValido(contraparte.Ruc))
        {
            var probable = DocumentoIdentidad.RucSugerido(contraparte.Ruc);

            problemas.Add(
                $"El RUC {contraparte.Ruc} no existe: el digito verificador no " +
                $"cuadra." +
                (probable is null ? "" : $" Probablemente quisiste poner {probable}."));
        }

        if (contraparte.Ruc == c.Emisor.Ruc)
        {
            problemas.Add(
                $"El emisor y la contraparte son el mismo RUC ({contraparte.Ruc}). " +
                $"Nadie se retiene ni se percibe a si mismo (error 2620).");
        }

        if (string.IsNullOrWhiteSpace(contraparte.RazonSocial))
            problemas.Add("Falta la razon social de la contraparte (error 2134).");

        // --- Los documentos ---------------------------------------------------

        if (documentos.Count == 0)
        {
            problemas.Add(
                $"El comprobante de {nombre} no referencia ningun documento. " +
                $"Su detalle son las facturas sobre las que se aplico la " +
                $"{nombre}, y sin ninguna no hay nada que constatar.");

            return problemas;
        }

        var vistos = new HashSet<string>();

        foreach (var (d, i) in documentos.Select((d, i) => (d, i + 1)))
        {
            if (!tiposAdmitidos.Contains(d.TipoDocumento))
            {
                problemas.Add(
                    $"El documento {i} es de tipo '{d.TipoDocumento}', que no " +
                    $"admite un comprobante de {nombre}. Los admitidos son " +
                    $"{string.Join(", ", tiposAdmitidos)} (error 2692).");
            }

            if (string.IsNullOrWhiteSpace(d.Numero))
                problemas.Add($"Falta el numero del documento {i} (error 2693).");

            // Un mismo documento pagado dos veces es legítimo; con el mismo
            // número de pago, no.
            if (!vistos.Add($"{d.TipoDocumento}|{d.Numero}|{d.NumeroPago}"))
            {
                problemas.Add(
                    $"El documento {d.Numero} aparece dos veces con el mismo " +
                    $"numero de pago ({d.NumeroPago}). Si se pago en varias " +
                    $"veces, cada pago lleva su propio numero (error 2626).");
            }

            if (d.ImportePago <= 0)
            {
                problemas.Add(
                    $"El importe del pago del documento {i} tiene que ser mayor " +
                    $"que cero (error 2736).");
            }

            if (d.ImporteTotal <= 0)
            {
                problemas.Add(
                    $"El importe total del documento {i} tiene que ser mayor " +
                    $"que cero (error 2696).");
            }

            if (d.ImportePago > d.ImporteTotal)
            {
                problemas.Add(
                    $"El pago del documento {d.Numero} ({d.ImportePago:0.00}) es " +
                    $"mayor que el importe del propio documento " +
                    $"({d.ImporteTotal:0.00}). Se puede pagar en partes, nunca " +
                    $"de mas.");
            }

            // --- Las fechas -------------------------------------------------
            //
            // Regla 2625: el pago no puede ser anterior a la factura ni
            // posterior a este comprobante.

            if (d.FechaPago.Date < d.FechaEmision.Date)
            {
                problemas.Add(
                    $"El documento {d.Numero} se pago el " +
                    $"{d.FechaPago:yyyy-MM-dd}, antes de emitirse " +
                    $"({d.FechaEmision:yyyy-MM-dd}) (error 2625).");
            }

            if (d.FechaPago.Date > c.FechaEmision.Date)
            {
                problemas.Add(
                    $"El documento {d.Numero} figura pagado el " +
                    $"{d.FechaPago:yyyy-MM-dd}, despues de la fecha de este " +
                    $"comprobante ({c.FechaEmision:yyyy-MM-dd}) (error 2625).");
            }

            // --- Moneda extranjera --------------------------------------------

            if (d.EsMonedaExtranjera && d.TipoCambio is null)
            {
                problemas.Add(
                    $"El documento {d.Numero} esta en {d.Moneda} y no trae tipo " +
                    $"de cambio. La {nombre} se declara siempre en soles, asi " +
                    $"que sin el no hay forma de convertirla (error 2721).");
            }

            if (d.TipoCambio is not null && d.TipoCambio.Tasa <= 0)
            {
                problemas.Add(
                    $"El tipo de cambio del documento {d.Numero} tiene que ser " +
                    $"mayor que cero (error 2716).");
            }
        }

        // --- Todos los pagos tienen que ser del mismo periodo -------------------
        //
        // Regla 2661: un comprobante agrupa los pagos de un mes. Mezclar dos
        // meses rechaza el documento entero.

        var periodos = documentos
            .Select(d => $"{d.FechaPago:yyyy-MM}")
            .Distinct()
            .ToList();

        if (periodos.Count > 1)
        {
            problemas.Add(
                $"Los pagos son de periodos distintos ({string.Join(", ", periodos)}). " +
                $"Un comprobante agrupa los de un solo mes (error 2661).");
        }

        return problemas;
    }

    public static IReadOnlyList<string> Errores(ComprobanteRetencion r) =>
        Revisar(r).Where(p => !p.StartsWith("Aviso:")).ToList();

    public static IReadOnlyList<string> Errores(ComprobantePercepcion p) =>
        Revisar(p).Where(p2 => !p2.StartsWith("Aviso:")).ToList();
}