namespace Facturacion.Cpe;

/// <summary>
/// Estado con el que se informa un comprobante en el resumen diario.
/// Catálogo 19 de SUNAT.
/// </summary>
public enum EstadoResumen
{
    /// <summary>Se informa por primera vez.</summary>
    Adicionar = 1,

    /// <summary>Ya se informó antes y se corrigen sus valores.</summary>
    Modificar = 2,

    /// <summary>Se anula el comprobante.</summary>
    Anular = 3
}

/// <summary>
/// Resumen diario de boletas de venta y notas vinculadas.
///
/// POR QUÉ EXISTE: las boletas se emiten al consumidor final y son muchísimas.
/// Un supermercado emite miles al día. SUNAT no las recibe una por una: se
/// agrupan todas las de un mismo día en un solo documento.
///
/// Eso cambia el tráfico real contra SUNAT de forma drástica. Si de 100.000
/// comprobantes diarios 70.000 son boletas, se convierten en un puñado de
/// envíos en vez de 70.000.
///
/// EL ENVÍO ES ASÍNCRONO, en dos tiempos:
///   1. sendSummary  → SUNAT devuelve un TICKET, no un CDR.
///   2. getStatus    → se consulta el ticket hasta que el proceso termine
///                      y ahí sí entrega el CDR.
///
/// Nomenclatura del documento:  RC-YYYYMMDD-#####
/// Nombre del archivo:          {RUC}-RC-{FECHA}-{CORRELATIVO}
/// </summary>
public class ResumenDiario
{
    public Emisor Emisor { get; set; } = new();

    /// <summary>Fecha en que se emitieron los comprobantes que se informan.</summary>
    public DateTime FechaReferencia { get; set; } = RelojPeru.Hoy.AddDays(-1);

    /// <summary>Fecha en que se genera el resumen. Normalmente hoy.</summary>
    public DateTime FechaGeneracion { get; set; } = RelojPeru.Hoy;

    /// <summary>Correlativo del resumen dentro del día. Hasta 5 dígitos.</summary>
    public int Correlativo { get; set; } = 1;

    public List<LineaResumen> Lineas { get; set; } = [];

    /// <summary>Identificador del resumen: RC-20260914-1</summary>
    public string Identificador => $"RC-{FechaGeneracion:yyyyMMdd}-{Correlativo}";

    /// <summary>Nombre del archivo, sin extensión.</summary>
    public string NombreArchivo => $"{Emisor.Ruc}-{Identificador}";
}

/// <summary>
/// La percepción de una boleta, tal como la declara el resumen diario.
///
/// NO SE PARECE AL BLOQUE DE LA FACTURA. Allí la percepción viaja como un
/// cac:AllowanceCharge más un cac:PaymentTerms; aquí va en un nodo propio de
/// SUNAT, con otros nombres y otros campos.
///
/// LOS TRES IMPORTES VAN EN SOLES, siempre, aunque la boleta esté en otra
/// moneda: errores 2685 y 2690. Es la misma excepción de la factura.
/// </summary>
/// <param name="Regimen">Catálogo 22: "01", "02" o "03".</param>
/// <param name="Porcentaje">La tasa. 2 significa 2%.</param>
/// <param name="BaseEnSoles">Sobre qué importe se calculó.</param>
/// <param name="Monto">Cuánto se percibió.</param>
public record PercepcionResumen(
    string Regimen,
    decimal Porcentaje,
    decimal BaseEnSoles,
    decimal Monto)
{
    /// <summary>Lo que el cliente paga de verdad: la base más la percepción.</summary>
    public decimal TotalCobrado =>
        CalculadoraTotales.Redondear(BaseEnSoles + Monto);
}

/// <summary>
/// Un comprobante informado dentro del resumen.
///
/// Fíjate en la diferencia con una línea de factura: aquí NO van los ítems.
/// Una línea del resumen representa un comprobante completo, con sus totales
/// ya consolidados.
/// </summary>
public class LineaResumen
{
    /// <summary>Número secuencial dentro del resumen, empezando en 1.</summary>
    public int Orden { get; set; }

    /// <summary>Catálogo 01. Solo 03, 07 y 08 pueden ir en un resumen.</summary>
    public string TipoComprobante { get; set; } = Cpe.TipoComprobante.Boleta;

    /// <summary>Serie y correlativo del comprobante. Ej: B001-22</summary>
    public string Numero { get; set; } = "";

    public Receptor Receptor { get; set; } = new();

    /// <summary>Solo para notas: el comprobante que modifican.</summary>
    public DocumentoAfectado? Afectado { get; set; }

    public EstadoResumen Estado { get; set; } = EstadoResumen.Adicionar;

    public string Moneda { get; set; } = "PEN";

    // --- Valores de venta, uno por tipo de operación -----------------------
    //
    // Cada uno sale en su propio sac:BillingPayment con su código del
    // catálogo 11. Los que valen cero no se declaran: la regla 2357 prohíbe
    // repetir un InstructionID, y un cero solo añade ruido.

    public decimal TotalGravado { get; set; }
    public decimal TotalExonerado { get; set; }
    public decimal TotalInafecto { get; set; }
    public decimal TotalExportacion { get; set; }

    // --- Gratuitas, desglosadas ---------------------------------------------
    //
    // EN LA FACTURA VAN TODAS JUNTAS en un subtotal 9996. Aquí no: el
    // catálogo 11 da un código distinto a cada una —06 gravadas, 07
    // exoneradas, 08 inafectas, 09 exportación— y hay que separarlas.
    //
    // Es la diferencia más incómoda entre los dos documentos, y la razón de
    // que este desglose no salga directo de TotalesComprobante.

    public decimal TotalGratuitoGravado { get; set; }
    public decimal TotalGratuitoExonerado { get; set; }
    public decimal TotalGratuitoInafecto { get; set; }
    public decimal TotalGratuitoExportacion { get; set; }

    // --- Tributos ------------------------------------------------------------
    //
    // Cada uno va en SU PROPIO cac:TaxTotal, no como subtotales de uno
    // compartido: la regla 2355 prohíbe dos TaxTotal con el mismo código de
    // tributo, y el XSD del resumen espera bloques hermanos. Es al revés que
    // en la factura, donde un TaxTotal agrupa todos los subtotales.

    public decimal TotalIgv { get; set; }

    /// <summary>IVAP, si la boleta es de arroz pilado. Tributo 1016.</summary>
    public decimal TotalIvap { get; set; }

    /// <summary>Base imponible del IVAP. Se declara junto a la gravada.</summary>
    public decimal TotalGravadoIvap { get; set; }

    /// <summary>El IGV de las líneas gratuitas. Tributo 9996.</summary>
    public decimal TotalIgvGratuitas { get; set; }

    /// <summary>Impuesto a las bolsas de plástico. Tributo 7152.</summary>
    public decimal TotalIcbper { get; set; }

    /// <summary>
    /// La tasa del IGV que declaró el comprobante.
    ///
    /// HAY QUE GUARDARLA porque el resumen la pide en cbc:Percent y no se
    /// puede deducir del importe: si el IGV es cero, dividir no dice nada.
    /// Sin este campo el resumen salía sin Percent, y la regla 2992 lo
    /// rechaza con un ERROR.
    /// </summary>
    public decimal TasaIgv { get; set; } = 18m;

    /// <summary>Cargos que no afectan la base: FISE, recargo al consumo, 50.</summary>
    public decimal OtrosCargos { get; set; }

    /// <summary>Percepción, si la hubo. Solo en boletas nuevas (error 2986).</summary>
    public PercepcionResumen? Percepcion { get; set; }

    public decimal ImporteTotal { get; set; }

    /// <summary>
    /// El importe que se declara en sac:TotalAmount.
    ///
    /// NO ES EL IMPORTE TOTAL DEL COMPROBANTE SIN MÁS: SUNAT lo recalcula con
    /// una fórmula propia y compara. Es la suma de los cuatro valores de
    /// venta —gravado, inafecto, exonerado y exportación— más el IGV, el
    /// IVAP, el ISC, otros tributos, el ICBPER y otros cargos.
    ///
    /// LAS GRATUITAS NO ENTRAN, igual que en la factura: no se cobran.
    ///
    /// Se calcula en vez de copiarse para que los dos números no puedan
    /// discrepar. Cuando discrepan, ReglasResumen lo dice.
    /// </summary>
    public decimal TotalDeclarado => CalculadoraTotales.Redondear(
        TotalGravado + TotalGravadoIvap + TotalExonerado + TotalInafecto +
        TotalExportacion + TotalIgv + TotalIvap + TotalIcbper + OtrosCargos);

    /// <summary>
    /// Construye la línea a partir de una boleta ya emitida.
    /// Los totales se recalculan desde sus líneas: así no hay forma de que
    /// el resumen declare un monto distinto al del comprobante original.
    /// </summary>
    public static LineaResumen DesdeBoleta(
        Boleta boleta,
        int orden,
        EstadoResumen estado = EstadoResumen.Adicionar)
    {
        var t = CalculadoraTotales.Calcular(boleta);
        var calculadas = CalculadoraTotales.CalcularLineas(boleta);

        // EL DESGLOSE DE LAS GRATUITAS SE HACE AQUÍ Y NO EN LA CALCULADORA.
        //
        // La factura no lo necesita: allí todas comparten un solo subtotal
        // 9996. Solo el resumen las separa, así que la lógica vive donde se
        // usa, en vez de engordar un tipo que comparten los cuatro
        // documentos.

        decimal gratGravado = 0, gratExonerado = 0;
        decimal gratInafecto = 0, gratExportacion = 0;

        foreach (var c in calculadas)
        {
            var a = c.Linea.TipoAfectacionIgv;

            if (!AfectacionIgv.EsGratuita(a)) continue;

            if (AfectacionIgv.EsGratuitaGravada(a))
                gratGravado += c.ValorVenta;

            else if (a == AfectacionIgv.GratuitoExonerado)
                gratExonerado += c.ValorVenta;

            else
                gratInafecto += c.ValorVenta;
        }

        // La tasa declarada, leída de las propias líneas afectas. Si no hay
        // ninguna —una boleta toda exonerada— se deja el 18, que es lo que
        // SUNAT espera ver aunque el importe sea cero.
        var tasa = boleta.Lineas
            .Where(l => AfectacionIgv.GeneraIgv(l.TipoAfectacionIgv))
            .Select(l => l.PorcentajeIgv)
            .DefaultIfEmpty(18m)
            .First();

        return new LineaResumen
        {
            Orden = orden,
            TipoComprobante = boleta.TipoComprobante,
            Numero = boleta.NumeroCompleto,
            Receptor = boleta.Receptor,
            Estado = estado,
            Moneda = boleta.Moneda,

            TotalGravado = t.TotalGravado,
            TotalExonerado = t.TotalExonerado,
            TotalInafecto = t.TotalInafecto,
            TotalExportacion = t.TotalExportacion,

            TotalGratuitoGravado = CalculadoraTotales.Redondear(gratGravado),
            TotalGratuitoExonerado = CalculadoraTotales.Redondear(gratExonerado),
            TotalGratuitoInafecto = CalculadoraTotales.Redondear(gratInafecto),
            TotalGratuitoExportacion = CalculadoraTotales.Redondear(gratExportacion),

            TotalIgv = t.TotalIgv,
            TotalIvap = t.TotalIvap,
            TotalGravadoIvap = t.TotalGravadoIvap,
            TotalIgvGratuitas = t.IgvGratuito,
            TotalIcbper = t.TotalIcbper,
            TasaIgv = tasa,

            OtrosCargos = t.TotalOtrosCargos,

            ImporteTotal = t.ImporteTotal
        };
    }
}

/// <summary>
/// Lo que el resumen diario NO puede declarar.
///
/// POR QUÉ EXISTE ESTA CLASE: el resumen es un formato más pobre que la
/// factura. Tiene sitio para los tributos y para los cargos, pero no para
/// los descuentos globales ni para los anticipos. Una boleta con esos datos
/// se envía, SUNAT la acepta, y el importe declarado no coincide con el que
/// cobró el comercio.
///
/// Esa es la peor clase de error: silencioso, contable, y descubierto en una
/// fiscalización dos años después. Mejor decirlo al construir el resumen.
/// </summary>
public static class ReglasResumen
{
    public static IReadOnlyList<string> Revisar(ResumenDiario r)
    {
        var problemas = new List<string>();

        if (r.Lineas.Count == 0)
        {
            problemas.Add(
                "El resumen no tiene lineas. No tiene sentido enviarlo vacio.");

            return problemas;
        }

        if (r.Lineas.Count > 500)
        {
            problemas.Add(
                $"El resumen trae {r.Lineas.Count} lineas y SUNAT admite hasta " +
                $"500 por envio. Hay que partirlo en varios resumenes, cada uno " +
                $"con su correlativo.");
        }

        var ordenRepetido = r.Lineas
            .GroupBy(l => l.Orden)
            .Where(g => g.Count() > 1)
            .Select(g => g.Key)
            .ToList();

        if (ordenRepetido.Count > 0)
        {
            problemas.Add(
                $"Hay numeros de orden repetidos en el resumen: " +
                $"{string.Join(", ", ordenRepetido)}.");
        }

        foreach (var l in r.Lineas)
        {
            // --- Solo boletas y sus notas ------------------------------------

            if (l.TipoComprobante is not (TipoComprobante.Boleta
                    or TipoComprobante.NotaCredito or TipoComprobante.NotaDebito))
            {
                problemas.Add(
                    $"La linea {l.Orden} es del tipo '{l.TipoComprobante}'. Un " +
                    $"resumen diario solo admite boletas (03) y sus notas (07 " +
                    $"y 08). Las facturas se envian una por una.");
            }

            // --- EL IMPORTE DECLARADO TIENE QUE CUADRAR ----------------------
            //
            // Si no cuadra es que el comprobante lleva algo que el resumen no
            // sabe declarar. La diferencia se ve aquí, no dos años después.

            var diferencia = Math.Abs(l.TotalDeclarado - l.ImporteTotal);

            if (diferencia > 1m)
            {
                problemas.Add(
                    $"La linea {l.Orden} ({l.Numero}) declara un total de " +
                    $"{l.TotalDeclarado:0.00} y el comprobante cobro " +
                    $"{l.ImporteTotal:0.00}. Casi siempre significa que la " +
                    $"boleta lleva un descuento global o un anticipo, y el " +
                    $"resumen diario no tiene donde declararlos: esa venta hay " +
                    $"que documentarla con factura.");
            }

            // --- La percepcion, solo en boletas nuevas -----------------------

            if (l.Percepcion is null) continue;

            if (l.TipoComprobante != TipoComprobante.Boleta)
            {
                problemas.Add(
                    $"La linea {l.Orden} declara percepcion y no es una boleta. " +
                    $"Solo se acepta percepcion en boletas (error 2986).");
            }

            if (l.Estado != EstadoResumen.Adicionar)
            {
                problemas.Add(
                    $"La linea {l.Orden} declara percepcion con estado " +
                    $"'{l.Estado}'. Solo se acepta en comprobantes que se " +
                    $"informan por primera vez (error 2986).");
            }

            if (l.Percepcion.Monto <= 0 || l.Percepcion.BaseEnSoles <= 0)
            {
                problemas.Add(
                    $"La percepcion de la linea {l.Orden} necesita base y monto " +
                    $"mayores que cero (errores 2893 y 2897).");
            }

            if (!RegimenPercepcion.Existe(l.Percepcion.Regimen))
            {
                problemas.Add(
                    $"El regimen de percepcion '{l.Percepcion.Regimen}' de la " +
                    $"linea {l.Orden} no existe en el catalogo 22 (error 2517).");
            }
        }

        return problemas;
    }

    public static IReadOnlyList<string> Errores(ResumenDiario r) =>
        Revisar(r).Where(p => !p.StartsWith("Aviso:")).ToList();
}

/// <summary>Respuesta de un envío asíncrono: SUNAT devuelve un ticket.</summary>
/// <param name="Exitoso">false si hubo un fallo de red o un rechazo inmediato.</param>
/// <param name="Ticket">Número con el que después se consulta el resultado.</param>
public record ResultadoTicket(
    bool Exitoso,
    string Ticket,
    string Mensaje)
{
    public bool EsReintentable { get; init; }

    public static ResultadoTicket Fallo(string mensaje, bool reintentable = false) =>
        new(false, "", mensaje) { EsReintentable = reintentable };
}

/// <summary>
/// Catálogo 11: identificador del tipo de monto en el resumen.
///
/// HISTORIA, PORQUE ESTA CLASE YA SE EQUIVOCÓ DOS VECES:
///
/// 1. Tenía un "05 = ISC" que no existe. El ISC no se declara en el catálogo
///    11 en absoluto: va en su propio cac:TaxTotal con el tributo 2000.
///
/// 2. Se le añadieron 06, 07, 08 y 09 para desglosar las gratuitas cuando
///    TODAVÍA NO EXISTÍAN, y SUNAT rechazó con el error 2256 («Valor no se
///    encuentra en el catalogo: 11», valor "06"). Se volvió al 05.
///
/// 3. AHORA SUNAT LOS CREA DE VERDAD (Reglas de validación, 24/04/2026, con
///    vigencia postergada al 01/01/2027): 06 gratuitas gravadas, 07
///    exoneradas, 08 inafectas y 09 de exportación. Y DESACTIVA el 05.
///
/// Por eso conviven los dos juegos de códigos, y cuál se usa lo decide la
/// fecha de generación del resumen: <see cref="VigenciaSunat.Rigen2027"/>.
/// Antes de esa fecha, el 05; desde esa fecha, el desglose. Mandar el
/// desglose antes, o el 05 después, es el mismo error 2256.
/// </summary>
public static class TipoMontoResumen
{
    public const string Gravado = "01";
    public const string Exonerado = "02";
    public const string Inafecto = "03";
    public const string Exportacion = "04";

    /// <summary>05 - Gratuitas, todas juntas. Solo hasta que rijan las reglas de 2027.</summary>
    public const string Gratuitas = "05";

    // --- Desde que rigen las reglas de 2027 -----------------------------------
    public const string GratuitasGravadas = "06";
    public const string GratuitasExoneradas = "07";
    public const string GratuitasInafectas = "08";
    public const string GratuitasExportacion = "09";
}