using System.Xml.Linq;
using static Facturacion.Cpe.BloquesComunes;

namespace Facturacion.Cpe;

/// <summary>
/// Anula comprobantes que SUNAT ya aceptó.
///
/// UNA CLASE PARA DOS DOCUMENTOS, porque en el fondo son el mismo:
///
///   RA  comunicación de baja      facturas y sus notas
///   RR  resumen de reversiones    retenciones y percepciones
///
/// Comparten esquema (VoidedDocuments), servicio (sendSummary), ciclo de
/// ticket, firma y hasta el orden de los elementos. Lo que cambia es el
/// prefijo del identificador y qué documentos admite cada uno. Separarlos en
/// dos clases habría duplicado todo lo demás para distinguir dos letras.
///
///
/// DIFERENCIA CON UNA NOTA DE CRÉDITO, que se confunde siempre:
///
///   Nota de crédito → corrige o revierte la operación, y deja rastro contable.
///                     Se usa cuando hubo una venta real que después cambió.
///
///   Baja / reversión → el comprobante queda como si nunca hubiera existido.
///                     Se usa cuando se emitió por error.
///
///
/// LAS BOLETAS NO ENTRAN EN NINGUNO DE LOS DOS. Se anulan dentro del resumen
/// diario, informándolas con el estado 3. Y las guías tampoco: van por el
/// canal REST de GRE.
///
///
/// EL PLAZO SON SIETE DÍAS desde la emisión, y solo para la RA. Es un ERROR,
/// no un aviso: el 2957. Pasados, solo queda la nota de crédito.
///
/// Y OJO CON CÓMO FALLA: si una sola línea excede el plazo, SUNAT rechaza la
/// COMUNICACIÓN ENTERA, con todas las demás dentro. Por eso vale la pena
/// comprobarlo antes de enviar y no después.
///
/// Nomenclatura:  RA-YYYYMMDD-#####  ·  RR-YYYYMMDD-#####
/// Envío:         sendSummary → ticket → getStatus. El mismo flujo del resumen.
/// </summary>
public class ComunicacionBaja
{
    public Emisor Emisor { get; set; } = new();

    /// <summary>
    /// Qué clase de comunicación es: RA para facturas y notas, RR para
    /// retenciones y percepciones.
    ///
    /// ES UN CAMPO Y NO OTRA CLASE PORQUE EL DOCUMENTO ES EL MISMO. Mismo
    /// esquema VoidedDocuments, mismo servicio sendSummary, mismo ticket,
    /// misma firma, hasta la misma plantilla. Lo único que cambia es el
    /// prefijo del identificador y qué documentos se pueden meter dentro.
    /// </summary>
    public string Tipo { get; set; } = TipoComunicacionBaja.Baja;

    /// <summary>Fecha en que se emitieron los comprobantes que se anulan.</summary>
    public DateTime FechaReferencia { get; set; } = RelojPeru.Hoy.AddDays(-1);

    /// <summary>Fecha en que se genera esta comunicación. Normalmente hoy.</summary>
    public DateTime FechaGeneracion { get; set; } = RelojPeru.Hoy;

    /// <summary>Correlativo de la comunicación dentro del día. Hasta 5 dígitos.</summary>
    public int Correlativo { get; set; } = 1;

    public List<LineaBaja> Lineas { get; set; } = [];

    /// <summary>Identificador: RA-20260914-1 o RR-20260914-1</summary>
    public string Identificador => $"{Tipo}-{FechaGeneracion:yyyyMMdd}-{Correlativo}";

    /// <summary>Nombre del archivo, sin extensión.</summary>
    public string NombreArchivo => $"{Emisor.Ruc}-{Identificador}";
}

/// <summary>
/// Las dos formas de matar un comprobante ya aceptado.
///
/// SON DOS PORQUE SUNAT LO QUISO ASÍ, no por nada de fondo. El documento es
/// idéntico hasta el último elemento. Pero una comunicación de baja que
/// lleve dentro un comprobante de retención se rechaza con el error 2308, y
/// una reversión que lleve una factura, también.
///
/// Cada una admite los suyos y no se mezclan.
/// </summary>
public static class TipoComunicacionBaja
{
    /// <summary>RA — facturas y sus notas. Plazo: 7 días desde la emisión.</summary>
    public const string Baja = "RA";

    /// <summary>
    /// RR — comprobantes de retención y de percepción.
    ///
    /// EL PLAZO NO SE COMPRUEBA AQUÍ, y es a propósito. La norma cuenta siete
    /// días desde que se le comunicó al proveedor o al cliente, no desde que
    /// se emitió el comprobante — y esa fecha el sistema no la conoce: ocurre
    /// fuera, en un correo o una llamada.
    ///
    /// Las fuentes consultadas tampoco coinciden: unas dan ese plazo de siete
    /// días y otras dicen que la reversión no tiene límite. Inventar una
    /// fecha de corte a partir de la emisión bloquearía reversiones válidas,
    /// que es el peor error posible.
    ///
    /// Se deja pasar y decide SUNAT.
    /// </summary>
    public const string Reversion = "RR";

    public static bool Existe(string tipo) => tipo is Baja or Reversion;

    /// <summary>Cómo se llama en castellano, para los mensajes de error.</summary>
    public static string Nombre(string tipo) => tipo switch
    {
        Baja => "comunicacion de baja",
        Reversion => "resumen de reversiones",
        _ => $"comunicacion '{tipo}'"
    };

    /// <summary>
    /// El nombre con su artículo: "la comunicacion de baja", "el resumen de
    /// reversiones".
    ///
    /// EXISTE POR UNA RAZÓN TONTA Y REAL: uno es femenino y el otro
    /// masculino. Construir la frase con un artículo fijo produce "esta
    /// resumen de reversiones", que es lo que salió en la primera prueba.
    ///
    /// Un mensaje mal escrito lo lee el cliente y le resta crédito a todo lo
    /// demás que diga el sistema.
    /// </summary>
    public static string ConArticulo(string tipo) => tipo switch
    {
        Baja => "la comunicacion de baja",
        Reversion => "el resumen de reversiones",
        _ => $"la comunicacion '{tipo}'"
    };
}

/// <summary>Un comprobante que se da de baja.</summary>
public class LineaBaja
{
    /// <summary>Número secuencial dentro de la comunicación, empezando en 1.</summary>
    public int Orden { get; set; }

    /// <summary>Catálogo 01. "01" factura, "07" nota de crédito, "08" nota de débito.</summary>
    public string TipoComprobante { get; set; } = Cpe.TipoComprobante.Factura;

    /// <summary>Serie del comprobante. Ej: F001</summary>
    public string Serie { get; set; } = "";

    /// <summary>Correlativo del comprobante, sin ceros a la izquierda.</summary>
    public int Numero { get; set; }

    /// <summary>Por qué se anula. Texto libre, lo lee una persona en SUNAT.</summary>
    public string Motivo { get; set; } = "";

    /// <summary>
    /// El número como lo escribe todo el mundo: F001-00000012.
    ///
    /// EN EL XML VA SIN CEROS —SUNAT lo quiere así, y por eso `Numero` es un
    /// entero— pero en un mensaje de error eso queda como "B001-1", que nadie
    /// reconoce como un comprobante. Quien lee el error busca ese número en
    /// su sistema, y ahí está escrito con los ocho dígitos.
    ///
    /// Dos formas para dos públicos: la de arriba es para SUNAT, esta es para
    /// personas.
    /// </summary>
    public string NumeroCompleto => $"{Serie}-{Numero:D8}";

    /// <summary>Construye la línea a partir de un comprobante ya emitido.</summary>
    public static LineaBaja Desde(ComprobanteBase comprobante, int orden, string motivo) =>
        new()
        {
            Orden = orden,
            TipoComprobante = comprobante.TipoComprobante,
            Serie = comprobante.Serie,
            Numero = comprobante.Correlativo,
            Motivo = motivo
        };
}

/// <summary>
/// Reglas de la comunicación de baja y del resumen de reversiones.
///
/// LAS DOS COMPARTEN CLASE porque comparten documento. Donde difieren —qué
/// tipos admiten, qué serie les toca, si hay plazo— se pregunta por
/// <see cref="ComunicacionBaja.Tipo"/>.
///
///   2308  Solo admite ciertos tipos de documento, y cada comunicación los
///         suyos: meter una retención en una RA se rechaza igual que meter
///         una factura en un RR.
///   2957  Siete días desde la emisión, SOLO para la RA.
///   2310  La serie tiene que corresponder al tipo.
///   2315  El motivo no puede ir vacío: lo lee una persona en SUNAT.
/// </summary>
public static class ReglasBaja
{
    /// <summary>
    /// Los tipos que admite una comunicación de BAJA (RA).
    ///
    /// Ni "03" ni "09" están, y son justo los dos que la gente intenta: las
    /// boletas se anulan en el resumen diario con el estado 3, y las guías
    /// por el servicio REST de GRE.
    ///
    /// El 20 y el 40 tampoco: esos van por el resumen de reversiones.
    /// </summary>
    private static readonly string[] TiposDeBaja =
    [
        "01", "07", "08", "25", "28", "30", "34", "42", "56"
    ];

    /// <summary>
    /// Los tipos que admite un resumen de REVERSIONES (RR): solo estos dos.
    ///
    /// La liquidación de compra (04) NO está, y no por olvido: no se pudo
    /// determinar por cuál de las dos vías se anula. Ni el anexo de SUNAT ni
    /// las fuentes consultadas lo dicen. Antes de añadirla aquí hay que
    /// confirmarlo, porque meterla en la comunicación equivocada rechaza el
    /// envío entero.
    /// </summary>
    private static readonly string[] TiposDeReversion = ["20", "40"];

    private static string[] TiposAdmitidosDe(string tipoComunicacion) =>
        tipoComunicacion == TipoComunicacionBaja.Reversion
            ? TiposDeReversion
            : TiposDeBaja;

    /// <summary>Días desde la emisión para poder dar de baja (error 2957).</summary>
    public const int DiasParaDarDeBaja = 7;

    public static IReadOnlyList<string> Revisar(ComunicacionBaja b)
    {
        var problemas = new List<string>();

        if (b.Lineas.Count == 0)
        {
            problemas.Add(
                $"No tiene sentido enviar " +
                $"{TipoComunicacionBaja.ConArticulo(b.Tipo)} sin lineas.");

            return problemas;
        }

        if (!TipoComunicacionBaja.Existe(b.Tipo))
        {
            problemas.Add(
                $"El tipo de comunicacion '{b.Tipo}' no existe. Solo hay dos: " +
                $"'RA' para facturas y notas, y 'RR' para retenciones y " +
                $"percepciones.");

            return problemas;
        }

        var esReversion = b.Tipo == TipoComunicacionBaja.Reversion;
        var admitidos = TiposAdmitidosDe(b.Tipo);

        // --- Documentos repetidos ---------------------------------------------
        //
        // Dos veces el mismo comprobante rechaza la comunicacion entera.

        var repetidos = b.Lineas
            .GroupBy(l => $"{l.TipoComprobante}-{l.Serie}-{l.Numero}")
            .Where(g => g.Count() > 1)
            .Select(g => g.Key)
            .ToList();

        if (repetidos.Count > 0)
        {
            problemas.Add(
                $"Hay comprobantes repetidos en la comunicacion: " +
                $"{string.Join(", ", repetidos)}.");
        }

        foreach (var l in b.Lineas)
        {
            // --- El tipo ------------------------------------------------------

            if (Array.IndexOf(admitidos, l.TipoComprobante) < 0)
            {
                // CADA MENSAJE DICE ADONDE IR, no solo que aqui no vale.
                //
                // Los cuatro casos de abajo son los cuatro errores que de
                // verdad comete la gente, y los cuatro tienen salida. Un
                // "tipo no admitido" a secas obliga a buscar cual es la
                // buena; decirlo aqui ahorra esa busqueda.

                if (l.TipoComprobante == TipoComprobante.Boleta)
                {
                    problemas.Add(
                        $"La linea {l.Orden} es una boleta ({l.NumeroCompleto}). " +
                        $"Las boletas no se dan de baja: se anulan informandolas " +
                        $"en el resumen diario con el estado 3.");
                }
                else if (l.TipoComprobante is "09" or "31")
                {
                    problemas.Add(
                        $"La linea {l.Orden} es una guia de remision " +
                        $"({l.NumeroCompleto}). Las guias van por el servicio " +
                        $"REST de GRE, que es otro canal.");
                }
                else if (esReversion)
                {
                    problemas.Add(
                        $"La linea {l.Orden} es un documento de tipo " +
                        $"'{l.TipoComprobante}' ({l.NumeroCompleto}) y un resumen " +
                        $"de reversiones solo admite comprobantes de retencion " +
                        $"(20) y de percepcion (40). Una factura o una nota se " +
                        $"anulan con una comunicacion de baja (error 2308).");
                }
                else if (l.TipoComprobante is "20" or "40")
                {
                    problemas.Add(
                        $"La linea {l.Orden} es un comprobante de " +
                        $"{(l.TipoComprobante == "20" ? "retencion" : "percepcion")} " +
                        $"({l.NumeroCompleto}). Estos no se dan de baja: se " +
                        $"anulan con un resumen de reversiones (error 2308).");
                }
                else
                {
                    problemas.Add(
                        $"El tipo de documento '{l.TipoComprobante}' de la linea " +
                        $"{l.Orden} no se puede anular con " +
                        $"{TipoComunicacionBaja.ConArticulo(b.Tipo)} " +
                        $"(error 2308).");
                }

                continue;
            }

            // --- La serie -----------------------------------------------------

            // LA SERIE TIENE QUE CUADRAR CON EL TIPO, y la letra la fija
            // SUNAT: F para facturas y sus notas, R para retenciones, P para
            // percepciones. No es una convencion nuestra.
            var letra = LetraDeSerie(l.TipoComprobante);

            if (letra is not null &&
                (l.Serie.Length != 4 ||
                 char.ToUpperInvariant(l.Serie[0]) != letra))
            {
                problemas.Add(
                    $"La serie '{l.Serie}' de la linea {l.Orden} no corresponde: " +
                    $"un documento de tipo '{l.TipoComprobante}' lleva serie que " +
                    $"empieza por {letra} y de cuatro caracteres (error 2310).");
            }

            if (l.Numero <= 0 || l.Numero > 99999999)
            {
                problemas.Add(
                    $"El correlativo {l.Numero} de la linea {l.Orden} no es " +
                    $"valido: hasta ocho digitos y mayor que cero.");
            }

            // --- El motivo ----------------------------------------------------
            //
            // Lo lee una persona en SUNAT. Un texto vacio rechaza (2315), y uno
            // de tres letras no explica nada.

            if (string.IsNullOrWhiteSpace(l.Motivo))
            {
                problemas.Add(
                    $"La linea {l.Orden} necesita un motivo de baja. Lo lee una " +
                    $"persona en SUNAT, asi que tiene que explicar que paso " +
                    $"(error 2315).");
            }
            else if (l.Motivo.Trim().Length > 100)
            {
                problemas.Add(
                    $"El motivo de la linea {l.Orden} pasa de 100 caracteres.");
            }
        }

        // --- EL PLAZO DE SIETE DIAS, Y SOLO PARA LA BAJA ----------------------
        //
        // Se comprueba sobre la fecha de referencia, que es la de emision de
        // los comprobantes que se anulan.
        //
        // SI UNA SOLA LINEA SE PASA, SUNAT RECHAZA LA COMUNICACION ENTERA.
        // Por eso vale la pena verlo aqui: sin esto, una factura vieja
        // arrastraria consigo todas las bajas que iban en el mismo envio.
        //
        // EN LA REVERSION NO SE COMPRUEBA NADA, y no es un olvido. La norma
        // cuenta siete dias desde que se le aviso al proveedor o al cliente,
        // no desde que se emitio el comprobante, y esa fecha ocurre fuera del
        // sistema: en un correo o una llamada. Ademas las fuentes no
        // coinciden —unas dan ese plazo y otras dicen que no hay limite—, asi
        // que inventar una fecha de corte a partir de la emision bloquearia
        // reversiones validas. Se deja pasar y decide SUNAT.

        if (!esReversion)
        {
            var limite = b.FechaReferencia.Date.AddDays(DiasParaDarDeBaja);
            var hoy = RelojPeru.Hoy;

            if (hoy > limite)
            {
                problemas.Add(
                    $"Los comprobantes de esta comunicacion se emitieron el " +
                    $"{b.FechaReferencia:yyyy-MM-dd} y el plazo para darlos de " +
                    $"baja vencio el {limite:yyyy-MM-dd}; hoy es " +
                    $"{hoy:yyyy-MM-dd}. SUNAT rechazaria la comunicacion entera " +
                    $"con el error 2957. Pasado el plazo, lo que corresponde es " +
                    $"una nota de credito.");
            }
            else if (hoy == limite)
            {
                problemas.Add(
                    $"Aviso: hoy es el ultimo dia para dar de baja estos " +
                    $"comprobantes. Si el envio falla, no habra otra oportunidad.");
            }
        }

        return problemas;
    }

    /// <summary>
    /// La letra con la que empieza la serie de cada tipo de documento.
    ///
    /// LA FIJA SUNAT Y NO ES NEGOCIABLE. Se comprueba aqui porque el error
    /// que devuelve SUNAT —el 2310— habla de "el dato no cumple el formato"
    /// sin decir cual era el formato esperado.
    ///
    /// null significa que ese tipo no tiene letra fija y no hay nada que
    /// comprobar.
    /// </summary>
    private static char? LetraDeSerie(string tipoComprobante) => tipoComprobante switch
    {
        "01" or "07" or "08" => 'F',
        "20" => 'R',
        "40" => 'P',
        _ => null
    };

    /// <summary>Los problemas que impiden emitir. Los avisos quedan fuera.</summary>
    public static IReadOnlyList<string> Errores(ComunicacionBaja b) =>
        Revisar(b).Where(p => !p.StartsWith("Aviso:")).ToList();

    /// <summary>Solo los avisos, para el log.</summary>
    public static IReadOnlyList<string> Avisos(ComunicacionBaja b) =>
        Revisar(b).Where(p => p.StartsWith("Aviso:")).ToList();
}

/// <summary>
/// Genera el XML de la comunicación de baja.
///
/// Usa los esquemas propios de SUNAT, igual que el resumen diario:
/// VoidedDocuments-1 y SunatAggregateComponents-1, con UBL 2.0.
///
/// Fíjate en un detalle: aquí la serie y el número van en elementos SEPARADOS
/// (DocumentSerialID y DocumentNumberID), no juntos como "F001-00000002".
/// Y el número va sin ceros a la izquierda.
/// </summary>
public static class GeneradorBajaXml
{
    private static readonly XNamespace Baja =
        "urn:sunat:names:specification:ubl:peru:schema:xsd:VoidedDocuments-1";

    public static XDocument Generar(ComunicacionBaja b)
    {
        // Las reglas primero: generar un XML que sabemos que SUNAT va a
        // rechazar solo sirve para perder el viaje, y en una baja se lleva
        // por delante las demas lineas del envio.
        var problemas = ReglasBaja.Errores(b);

        if (problemas.Count > 0)
            throw new InvalidOperationException(string.Join(" ", problemas));

        var raiz = new XElement(Baja + "VoidedDocuments",
            BloquesSunat.Namespaces(),

            ExtensionesVacias(),

            new XElement(Ns.Cbc + "UBLVersionID", "2.0"),
            new XElement(Ns.Cbc + "CustomizationID", "1.0"),

            new XElement(Ns.Cbc + "ID", b.Identificador),

            // ReferenceDate = cuándo se emitieron los comprobantes que se anulan
            // IssueDate     = cuándo se genera esta comunicación
            new XElement(Ns.Cbc + "ReferenceDate",
                b.FechaReferencia.ToString("yyyy-MM-dd", Inv)),
            new XElement(Ns.Cbc + "IssueDate",
                b.FechaGeneracion.ToString("yyyy-MM-dd", Inv)),

            BloquesSunat.Firmante(b.Emisor),
            BloquesSunat.Emisor(b.Emisor)
        );

        foreach (var linea in b.Lineas.OrderBy(l => l.Orden))
            raiz.Add(BloqueLinea(linea));

        return new XDocument(new XDeclaration("1.0", "UTF-8", null), raiz);
    }

    private static XElement BloqueLinea(LineaBaja l) =>
        new(BloquesSunat.Sac + "VoidedDocumentsLine",
            new XElement(Ns.Cbc + "LineID", l.Orden),
            new XElement(Ns.Cbc + "DocumentTypeCode", l.TipoComprobante),

            // Serie y número por separado, y el número sin ceros a la izquierda.
            new XElement(BloquesSunat.Sac + "DocumentSerialID", l.Serie),
            new XElement(BloquesSunat.Sac + "DocumentNumberID", l.Numero),

            new XElement(BloquesSunat.Sac + "VoidReasonDescription",
                new XCData(l.Motivo)));
}