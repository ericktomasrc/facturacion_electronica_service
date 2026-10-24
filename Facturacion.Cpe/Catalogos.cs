using System.Xml.Linq;

namespace Facturacion.Cpe;

/// <summary>
/// Espacios de nombres XML del estándar UBL 2.1.
/// No cambiar: SUNAT valida contra estas URIs exactas.
/// </summary>
public static class Ns
{
    public static readonly XNamespace Invoice =
        "urn:oasis:names:specification:ubl:schema:xsd:Invoice-2";

    public static readonly XNamespace CreditNote =
        "urn:oasis:names:specification:ubl:schema:xsd:CreditNote-2";

    public static readonly XNamespace DebitNote =
        "urn:oasis:names:specification:ubl:schema:xsd:DebitNote-2";

    public static readonly XNamespace Cac =
        "urn:oasis:names:specification:ubl:schema:xsd:CommonAggregateComponents-2";

    public static readonly XNamespace Cbc =
        "urn:oasis:names:specification:ubl:schema:xsd:CommonBasicComponents-2";

    public static readonly XNamespace Ext =
        "urn:oasis:names:specification:ubl:schema:xsd:CommonExtensionComponents-2";

    public static readonly XNamespace Ds =
        "http://www.w3.org/2000/09/xmldsig#";
}

/// <summary>URIs de los catálogos de SUNAT, para los atributos listURI/schemeURI.</summary>
public static class CatalogoUri
{
    private const string Base = "urn:pe:gob:sunat:cpe:see:gem:catalogos:catalogo";

    public const string C01_TipoDocumento = Base + "01";
    public const string C06_TipoDocIdentidad = Base + "06";
    public const string C07_AfectacionIgv = Base + "07";
    public const string C09_NotaCredito = Base + "09";
    public const string C10_NotaDebito = Base + "10";
    public const string C16_TipoPrecio = Base + "16";
    public const string C51_TipoOperacion = Base + "51";
    public const string C53_CargoDescuento = Base + "53";
    public const string C55_ConceptoItem = Base + "55";
    public const string C59_MedioPago = Base + "59";
}

/// <summary>
/// Catálogo 53: códigos de descuentos y cargos.
///
/// LA DISTINCIÓN CLAVE ES SI AFECTA O NO LA BASE IMPONIBLE:
///
///   Si afecta    → el IGV se calcula sobre el monto ya descontado.
///   Si no afecta → el IGV se calcula sobre el monto original, y el descuento
///                  solo reduce lo que el cliente paga.
///
/// Elegir el código equivocado cambia el impuesto declarado, así que no es
/// un detalle cosmético.
/// </summary>
public static class CodigoDescuento
{
    // ESTA CLASE SE QUEDÓ CON UN SOLO CÓDIGO, Y ES A PROPÓSITO.
    //
    // Tenía cinco, y TRES ESTABAN MAL: los códigos globales del catálogo 53
    // no son los mismos que los de ítem. El catálogo reserva 00/01 y 47/48
    // para el nivel de ítem, y 02/03 y 49/50 para el global; aquí estaban
    // puestos los de ítem en los tres sitios globales.
    //
    // Nunca llegó a SUNAT porque ninguna de las tres se usaba: el descuento
    // global se reparte dentro de las líneas y sale con el "00" de ítem, que
    // sí era correcto. Habría explotado el día que alguien las usara.
    //
    // El catálogo completo vive ahora en CodigoCargoDescuento, en
    // CargosGlobales.cs, junto a la lógica de qué hace cada código. Dos
    // listas de lo mismo terminan diciendo cosas distintas, así que aquí
    // queda solo el que usa el bloque de descuento por línea.

    /// <summary>Descuento por ítem. Afecta la base imponible de esa línea.</summary>
    public const string PorItem = CodigoCargoDescuento.DescuentoItem;
}

/// <summary>Catálogo 01: tipo de comprobante.</summary>
public static class TipoComprobante
{
    public const string Factura = "01";
    public const string Boleta = "03";
    public const string NotaCredito = "07";
    public const string NotaDebito = "08";
}

/// <summary>
/// Catálogo 51: tipo de operación.
///
/// Es el atributo listID de InvoiceTypeCode y es lo que le dice a SUNAT qué
/// clase de operación está mirando. De él dependen validaciones que no tienen
/// nada que ver entre sí: qué documento puede tener el receptor, qué tributos
/// se admiten, si hace falta declarar un país.
///
/// Los códigos de detracción (1001-1004) viven en TipoOperacionDetraccion,
/// dentro de Detraccion.cs, porque allí van acompañados de sus propias reglas.
/// </summary>
public static class TipoOperacion
{
    public const string VentaInterna = "0101";
    public const string VentaInternaGastosDeducibles = "0112";

    // --- Exportación (catálogo 51) ---------------------------------------
    public const string ExportacionDeBienes = "0200";
    public const string ExportacionServiciosEnElPais = "0201";
    public const string ExportacionServiciosHospedaje = "0202";
    public const string ExportacionServiciosNavieras = "0203";
    public const string ExportacionServiciosNaves = "0204";
    public const string ExportacionServiciosPaquete = "0205";
    public const string ExportacionServiciosCarga = "0206";
    public const string ExportacionServiciosEnergiaZed = "0207";
    public const string ExportacionServiciosParcial = "0208";

    /// <summary>
    /// Venta a un no domiciliado que NO califica como exportación.
    ///
    /// Es el caso que más se confunde: vender a un cliente extranjero no
    /// convierte la operación en exportación. Si el bien no sale del país o
    /// el servicio no se usa fuera, la venta es gravada con IGV normal y va
    /// con este código, no con 0200.
    /// </summary>
    public const string VentaNoDomiciliadoSinExportacion = "0401";

    public const string SujetaAPercepcion = "2001";

    public static bool EsExportacion(string codigo) => codigo is
        ExportacionDeBienes or ExportacionServiciosEnElPais or
        ExportacionServiciosHospedaje or ExportacionServiciosNavieras or
        ExportacionServiciosNaves or ExportacionServiciosPaquete or
        ExportacionServiciosCarga or ExportacionServiciosEnergiaZed or
        ExportacionServiciosParcial;

    /// <summary>
    /// Los dos únicos tipos donde SUNAT exige declarar el país donde el
    /// servicio se usa, explota o aprovecha (errores 3098 y 3099).
    ///
    /// Tiene lógica: son los casos donde el servicio se presta total o
    /// parcialmente en el Perú, y lo único que lo vuelve exportación es que
    /// el beneficio ocurra afuera. Ese "afuera" hay que nombrarlo.
    /// </summary>
    public static bool ExigePaisDeUso(string codigo) => codigo is
        ExportacionServiciosEnElPais or ExportacionServiciosParcial;

    /// <summary>
    /// Tipos donde el receptor NO puede identificarse con RUC (error 2800).
    ///
    /// El comprador es un no domiciliado: si tuviera RUC peruano, la
    /// operación no sería exportación.
    /// </summary>
    public static bool ProhibeReceptorConRuc(string codigo) => codigo is
        ExportacionDeBienes or ExportacionServiciosEnElPais or
        ExportacionServiciosNaves;

    /// <summary>
    /// Tipos que obligan a declarar los datos del huésped o del turista en
    /// cada línea (errores 3136 a 3145): documento, nombre, país, fechas de
    /// ingreso y salida, días de permanencia.
    ///
    /// Son nueve campos del catálogo 55 que este motor todavía no genera, así
    /// que la emisión se bloquea antes de armar un XML que SUNAT rechazaría.
    /// </summary>
    public static bool NecesitaDatosDeHuesped(string codigo) => codigo is
        ExportacionServiciosHospedaje or ExportacionServiciosPaquete;

    public static string Descripcion(string codigo) => codigo switch
    {
        VentaInterna => "Venta interna",
        VentaInternaGastosDeducibles => "Venta interna - gastos deducibles persona natural",
        ExportacionDeBienes => "Exportación de bienes",
        ExportacionServiciosEnElPais => "Exportación de servicios prestados íntegramente en el país",
        ExportacionServiciosHospedaje => "Exportación de servicios - hospedaje a no domiciliado",
        ExportacionServiciosNavieras => "Exportación de servicios - transporte de navieras",
        ExportacionServiciosNaves => "Exportación de servicios - naves y aeronaves de bandera extranjera",
        ExportacionServiciosPaquete => "Exportación de servicios - paquete turístico",
        ExportacionServiciosCarga => "Exportación de servicios - complementarios al transporte de carga",
        ExportacionServiciosEnergiaZed => "Exportación de servicios - energía eléctrica a sujetos en ZED",
        ExportacionServiciosParcial => "Exportación de servicios prestados parcialmente en el extranjero",
        VentaNoDomiciliadoSinExportacion => "Venta a no domiciliado que no califica como exportación",
        SujetaAPercepcion => "Operación sujeta a percepción",
        _ => codigo
    };
}

/// <summary>
/// Catálogo 06: tipo de documento de identidad.
///
/// La lista completa importa desde que existe exportación: el comprador
/// extranjero casi nunca tiene RUC, y SUNAT valida que el documento declarado
/// esté en el catálogo.
/// </summary>
public static class TipoDocIdentidad
{
    /// <summary>Documento tributario de no domiciliado sin RUC. El habitual en exportación.</summary>
    public const string SinDocumento = "0";

    public const string Dni = "1";
    public const string Extranjeria = "4";
    public const string Ruc = "6";
    public const string Pasaporte = "7";
    public const string CedulaDiplomatica = "A";

    /// <summary>Documento de identidad del país de residencia, de un no domiciliado.</summary>
    public const string DocPaisResidencia = "B";

    /// <summary>TIN - documento tributario de persona natural del exterior.</summary>
    public const string Tin = "C";

    /// <summary>IN - documento tributario de persona jurídica del exterior.</summary>
    public const string In = "D";

    public const string TarjetaAndina = "E";
    public const string PermisoTemporal = "F";
    public const string Salvoconducto = "G";
    public const string CarnePermisoTemp = "H";

    private static readonly HashSet<string> Todos =
    [
        SinDocumento, Dni, Extranjeria, Ruc, Pasaporte, CedulaDiplomatica,
        DocPaisResidencia, Tin, In, TarjetaAndina, PermisoTemporal,
        Salvoconducto, CarnePermisoTemp
    ];

    public static bool Existe(string codigo) => Todos.Contains(codigo);
}

/// <summary>
/// Catálogo 52: códigos de leyenda.
///
/// Una leyenda es un cbc:Note con el código en el atributo languageLocaleID.
/// El texto lo elige el emisor salvo donde SUNAT lo fija.
/// </summary>
public static class CodigoLeyenda
{
    public const string MontoEnLetras = "1000";
    public const string TransferenciaGratuita = "1002";
    public const string Percepcion = "2000";
    public const string Detraccion = "2006";

    /// <summary>Operación sujeta al IVAP (arroz pilado).</summary>
    public const string Ivap = "2007";

    /// <summary>Drawback: restitución simplificada de derechos arancelarios.</summary>
    public const string Drawback = "2010";

    /// <summary>Exportación de servicios - Decreto Legislativo N° 919.</summary>
    public const string ExportacionServicios = "2011";
}

/// <summary>
/// Catálogo 09: motivos de nota de crédito.
/// Solo los más usados. La lista completa está en el Anexo 8 de SUNAT.
/// </summary>
public static class MotivoNotaCredito
{
    public const string AnulacionDeLaOperacion = "01";
    public const string AnulacionPorErrorEnElRuc = "02";
    public const string CorreccionPorErrorEnDescripcion = "03";
    public const string DescuentoGlobal = "04";
    public const string DescuentoPorItem = "05";
    public const string DevolucionTotal = "06";
    public const string DevolucionPorItem = "07";
    public const string BonificacionOtros = "08";
    public const string DisminucionEnElValor = "09";
    public const string OtrosConceptos = "10";
    public const string AjustesExportacion = "11";
    public const string AjustesIvap = "12";
    public const string AjusteMontosYFechasDePago = "13";

    /// <summary>24 oct: los 13 códigos del catálogo 09.</summary>
    public static readonly string[] Todos =
        ["01", "02", "03", "04", "05", "06", "07", "08", "09", "10", "11", "12", "13"];

    /// <summary>24 oct: los que SUNAT no acepta sobre boletas.</summary>
    public static readonly string[] SoloFacturas = ["04", "05", "08"];

    public static string Descripcion(string codigo) => codigo switch
    {
        AnulacionDeLaOperacion => "ANULACION DE LA OPERACION",
        AnulacionPorErrorEnElRuc => "ANULACION POR ERROR EN EL RUC",
        CorreccionPorErrorEnDescripcion => "CORRECCION POR ERROR EN LA DESCRIPCION",
        DescuentoGlobal => "DESCUENTO GLOBAL",
        DescuentoPorItem => "DESCUENTO POR ITEM",
        DevolucionTotal => "DEVOLUCION TOTAL",
        DevolucionPorItem => "DEVOLUCION POR ITEM",
        BonificacionOtros => "BONIFICACION",
        DisminucionEnElValor => "DISMINUCION EN EL VALOR",
        OtrosConceptos => "OTROS CONCEPTOS",
        AjustesExportacion => "AJUSTES DE OPERACIONES DE EXPORTACION",
        AjustesIvap => "AJUSTES AFECTOS AL IVAP",
        AjusteMontosYFechasDePago => "CORRECCION DEL MONTO NETO PENDIENTE DE PAGO Y/O FECHAS DE VENCIMIENTO",
        _ => "OTROS CONCEPTOS"
    };
}

/// <summary>Catálogo 10: motivos de nota de débito.</summary>
public static class MotivoNotaDebito
{
    public const string InteresPorMora = "01";
    public const string AumentoEnElValor = "02";
    public const string PenalidadesOtros = "03";
    public const string AjustesExportacion = "10";
    public const string AjustesIvap = "11";

    /// <summary>24 oct: los 5 códigos del catálogo 10.</summary>
    public static readonly string[] Todos = ["01", "02", "03", "10", "11"];

    public static string Descripcion(string codigo) => codigo switch
    {
        InteresPorMora => "INTERES POR MORA",
        AumentoEnElValor => "AUMENTO EN EL VALOR",
        PenalidadesOtros => "PENALIDADES U OTROS CONCEPTOS",
        AjustesExportacion => "AJUSTES DE OPERACIONES DE EXPORTACION",
        AjustesIvap => "AJUSTES AFECTOS AL IVAP",
        _ => "OTROS CONCEPTOS"
    };
}

/// <summary>Catálogo 07: tipo de afectación del IGV.</summary>
public static class AfectacionIgv
{
    public const string GravadoOperacionOnerosa = "10";
    public const string Exonerado = "20";
    public const string Inafecto = "30";
    public const string Exportacion = "40";

    /// <summary>
    /// 17 - Gravado, IVAP: Impuesto a la Venta de Arroz Pilado.
    ///
    /// NO ES UN IGV CON OTRA TASA. Es un tributo distinto, el 1016, que
    /// SUSTITUYE al IGV: el arroz pilado no paga IGV, paga esto.
    ///
    /// Y es excluyente: la regla 2644 exige que un comprobante con una sola
    /// linea de IVAP tenga TODAS sus lineas en 17.
    /// </summary>
    public const string GravadoIvap = "17";

    // --- Gratuitas gravadas -------------------------------------------------
    //
    // Las seis son entregas sin cobro que SÍ generan IGV: el impuesto se
    // declara y lo asume quien entrega, porque la ley grava el retiro de
    // bienes aunque no haya venta.
    //
    // NO SON SINÓNIMOS Y NO DA IGUAL CUÁL SE PONE: SUNAT cruza el código con
    // el gasto que el contribuyente deduce. Una ferretería que regala fierro
    // por volumen de compra usa BONIFICACIONES (15), no "retiro" (13).

    /// <summary>11 - Gravado, retiro por premio (sorteos, concursos).</summary>
    public const string GratuitoGravado = "11";

    /// <summary>12 - Gravado, retiro por donación.</summary>
    public const string GratuitoDonacion = "12";

    /// <summary>13 - Gravado, retiro. El caso genérico.</summary>
    public const string GratuitoRetiro = "13";

    /// <summary>14 - Gravado, retiro por publicidad (muestras, degustación).</summary>
    public const string GratuitoPublicidad = "14";

    /// <summary>
    /// 15 - Gravado, bonificaciones.
    ///
    /// EL MÁS FRECUENTE EN COMERCIO: "llévate 12 y paga 10". Las dos de
    /// regalo van en su propia línea con este código.
    /// </summary>
    public const string GratuitoBonificacion = "15";

    /// <summary>16 - Gravado, retiro por entrega a trabajadores.</summary>
    public const string GratuitoTrabajadores = "16";

    // --- Gratuitas exoneradas e inafectas -----------------------------------
    //
    // Aquí el IGV es cero: lo que se entrega ya estaba exonerado o inafecto,
    // así que regalarlo tampoco genera impuesto.

    /// <summary>21 - Exonerado, transferencia gratuita.</summary>
    public const string GratuitoExonerado = "21";

    /// <summary>31 - Inafecto, retiro por bonificación.</summary>
    public const string GratuitoInafecto = "31";

    /// <summary>32 - Inafecto, retiro.</summary>
    public const string InafectoRetiro = "32";

    /// <summary>33 - Inafecto, retiro por muestras médicas.</summary>
    public const string InafectoMuestrasMedicas = "33";

    /// <summary>34 - Inafecto, retiro por convenio colectivo.</summary>
    public const string InafectoConvenioColectivo = "34";

    /// <summary>35 - Inafecto, retiro por premio.</summary>
    public const string InafectoPremio = "35";

    /// <summary>36 - Inafecto, retiro por publicidad.</summary>
    public const string InafectoPublicidad = "36";

    /// <summary>37 - Inafecto, transferencia gratuita.</summary>
    public const string InafectoTransferencia = "37";

    /// <summary>Las seis gratuitas que generan IGV: afectaciones 11 a 16.</summary>
    private static readonly string[] GratuitasGravadas =
    [
        GratuitoGravado, GratuitoDonacion, GratuitoRetiro,
        GratuitoPublicidad, GratuitoBonificacion, GratuitoTrabajadores
    ];

    /// <summary>Las gratuitas sin IGV: 21 y 31 a 37.</summary>
    private static readonly string[] GratuitasSinIgv =
    [
        GratuitoExonerado, GratuitoInafecto, InafectoRetiro,
        InafectoMuestrasMedicas, InafectoConvenioColectivo,
        InafectoPremio, InafectoPublicidad, InafectoTransferencia
    ];

    /// <summary>
    /// Categoría tributaria que corresponde a cada afectación.
    ///
    /// CORRECCIÓN IMPORTANTE RESPECTO A LA VERSIÓN ANTERIOR:
    ///
    /// La exportación estaba compartiendo el tributo 1000 (IGV) con las
    /// operaciones gravadas. Es un error que no se notó porque nunca se
    /// emitió una factura de exportación: la regla 3107 de SUNAT rechaza
    /// cualquier comprobante de exportación que declare el tributo 1000 a
    /// nivel global, y la 3110 exige que el impuesto sea 0.
    ///
    /// El tributo correcto es el 9995 - EXP, del catálogo 05.
    /// </summary>
    public static CategoriaTributaria Categoria(string afectacion)
    {
        // Las gratuitas van primero y todas al mismo tributo: el 9996 - GRA.
        //
        // Da igual que sea una bonificación gravada o una muestra inafecta;
        // lo que cambia entre ellas es si el IGV de la línea es cero o no,
        // no el código de tributo.
        if (EsGratuita(afectacion)) return new("9996", "GRA", "FRE");

        return afectacion switch
        {
            GravadoOperacionOnerosa => new("1000", "IGV", "VAT"),
            GravadoIvap => new(Ivap.Codigo, Ivap.Nombre, Ivap.TipoCodigo),
            Exportacion => new("9995", "EXP", "FRE"),
            Exonerado => new("9997", "EXO", "VAT"),
            Inafecto => new("9998", "INA", "FRE"),
            _ => throw new ArgumentException(
                    $"Tipo de afectación no soportado: {afectacion}", nameof(afectacion))
        };
    }

    /// <summary>
    /// ¿Esta línea produce IGV?
    ///
    /// Sí en la venta normal y en las seis gratuitas gravadas (11 a 16). En
    /// las gratuitas el impuesto se declara pero no se cobra: lo asume el
    /// que entrega.
    /// </summary>
    public static bool GeneraIgv(string afectacion) =>
        afectacion == GravadoOperacionOnerosa ||
        afectacion == GravadoIvap ||
        EsGratuitaGravada(afectacion);

    /// <summary>¿Esta linea tributa IVAP en vez de IGV?</summary>
    public static bool EsIvap(string afectacion) =>
        afectacion == GravadoIvap;

    /// <summary>
    /// La tasa que corresponde a una afectación cuando nadie la declara.
    ///
    /// EXISTE PARA QUE UN CAMPO VACÍO NO SEA UN ERROR SILENCIOSO. El campo
    /// porcentajeIgv de la API es opcional, y antes valía 18 por defecto:
    /// una línea de arroz pilado sin ese campo salía al 18% en vez de al
    /// 4%, declarando mal el impuesto sin que nadie hubiera pedido nada.
    ///
    /// VIVE AQUÍ, EN EL CATÁLOGO, Y NO EN LA API. La primera versión la
    /// puso como función local de Program.cs, y entonces las notas de
    /// crédito —que arman sus líneas desde el mismo contrato, en otro
    /// archivo— no la veían y dejaban de compilar. La tasa depende de la
    /// afectación, así que su sitio es donde viven las afectaciones.
    /// </summary>
    public static decimal TasaPorDefecto(string afectacion) =>
        EsIvap(afectacion) ? Ivap.Tasa : 18m;

    public static bool EsGratuitaGravada(string afectacion) =>
        Array.IndexOf(GratuitasGravadas, afectacion) >= 0;

    public static bool EsGratuita(string afectacion) =>
        EsGratuitaGravada(afectacion) ||
        Array.IndexOf(GratuitasSinIgv, afectacion) >= 0;

    /// <summary>
    /// ¿Existe esta afectación en el catálogo 07?
    ///
    /// SIRVE PARA CONVERTIR UN 500 EN UN 400. Sin esta comprobación, un
    /// "1O" con la letra O en vez del cero llega hasta el cálculo de
    /// totales y revienta allí con una excepción interna: el cliente de la
    /// API recibe "error del servidor" y no tiene forma de saber qué puso
    /// mal. Con quince códigos válidos en vez de siete, la probabilidad de
    /// un dedazo ya no es despreciable.
    /// </summary>
    public static bool Existe(string afectacion) =>
        afectacion == GravadoOperacionOnerosa ||
        afectacion == GravadoIvap ||
        afectacion == Exonerado ||
        afectacion == Inafecto ||
        afectacion == Exportacion ||
        EsGratuita(afectacion);

    /// <summary>
    /// AQUÍ VA "==" Y NO "is", Y NO ES UN CAPRICHO DE ESTILO.
    ///
    /// Existe una clase llamada Exportacion en este mismo espacio de nombres,
    /// con las reglas de las facturas de exportación. Cuando el operando
    /// derecho de un "is" puede leerse como un tipo, C# elige el tipo: la
    /// constante de aquí abajo queda ignorada y la comparación pasa a
    /// preguntar "¿este string es de la clase Exportacion?", que nunca.
    ///
    /// El método devolvía siempre false y el compilador lo avisaba con
    /// CS7023 y CS0184 — dos advertencias fáciles de pasar por alto entre
    /// el ruido de un build. Con "==" el nombre se resuelve como expresión,
    /// donde la constante de la clase gana, y compara lo que debe.
    ///
    /// Si alguna vez alguien lo "ordena" volviendo a poner "is", el bug
    /// regresa sin romper la compilación.
    /// </summary>
    public static bool EsExportacion(string afectacion) =>
        afectacion == Exportacion;
}

/// <summary>Código, nombre y tipo del tributo, según el catálogo 05 de SUNAT.</summary>
public readonly record struct CategoriaTributaria(string Codigo, string Nombre, string TipoCodigo);

/// <summary>Catálogo 16: tipo de precio unitario.</summary>
public static class TipoPrecio
{
    public const string PrecioUnitarioIncluyeIgv = "01";
    public const string ValorReferencialGratuito = "02";
}