namespace Facturacion.Cpe;

/// <summary>
/// Lo que comparten todos los comprobantes electrónicos.
/// </summary>
public abstract class ComprobanteBase
{
    public string Serie { get; set; } = "";
    public int Correlativo { get; set; }
    /// <summary>
    /// RelojPeru.Ahora, no DateTime.Now.
    ///
    /// DateTime.Now da la hora del reloj de la máquina, y en un servidor
    /// Linux ese reloj está en UTC. Una factura de las 19:00 de Lima se
    /// fecharía al día siguiente, que para SUNAT es otro periodo tributario.
    /// </summary>
    public DateTime FechaEmision { get; set; } = RelojPeru.Ahora;

    /// <summary>ISO 4217. "PEN" = soles, "USD" = dólares.</summary>
    public string Moneda { get; set; } = "PEN";

    /// <summary>
    /// Tipo de cambio a soles. Solo se declara cuando la moneda no es PEN.
    /// </summary>
    public TipoCambio? TipoCambio { get; set; }

    /// <summary>
    /// Descuento global sobre el comprobante completo, en porcentaje.
    /// 5 significa 5%.
    ///
    /// DIFERENCIA CON EL DESCUENTO POR LÍNEA: este se aplica sobre la suma de
    /// todas las líneas y reduce la base imponible del documento entero. El
    /// IGV del comprobante se calcula sobre el monto ya descontado.
    ///
    /// Se declara con el código 00 del catálogo 53, que es el descuento global
    /// que sí afecta la base imponible. Existe también el código 01, para
    /// descuentos que no la afectan, pero ese caso no está implementado aquí.
    /// </summary>
    public decimal DescuentoGlobalPorcentaje { get; set; }

    public bool TieneDescuentoGlobal => DescuentoGlobalPorcentaje > 0;

    public Emisor Emisor { get; set; } = new();
    public Receptor Receptor { get; set; } = new();
    public List<LineaComprobante> Lineas { get; set; } = [];

    /// <summary>
    /// Anticipos ya facturados que se descuentan de este comprobante.
    ///
    /// Vive en la base y no solo en Factura porque una boleta también admite
    /// anticipos. Las notas de crédito y débito lo dejan vacío.
    /// </summary>
    public List<Anticipo> Anticipos { get; set; } = [];

    /// <summary>
    /// Cargos y descuentos que se aplican al comprobante entero y que NO
    /// cambian la base imponible del IGV: recargo al consumo, FISE, un
    /// descuento comercial pactado fuera del precio.
    ///
    /// NO CONFUNDIR CON DescuentoGlobalPorcentaje, que está unas líneas más
    /// arriba y hace lo contrario: aquel sí reduce la base, y por eso se
    /// reparte dentro de las líneas. Estos van en su propio bloque y solo
    /// mueven el importe a pagar.
    /// </summary>
    public List<CargoGlobal> CargosGlobales { get; set; } = [];

    /// <summary>Catálogo 01. Lo define cada tipo concreto.</summary>
    public abstract string TipoComprobante { get; }

    public string NumeroCompleto => $"{Serie}-{Correlativo:D8}";

    public string NombreArchivo => $"{Emisor.Ruc}-{TipoComprobante}-{NumeroCompleto}";
}

/// <summary>
/// Tipo de cambio aplicado a un comprobante en moneda extranjera.
///
/// SUNAT lleva la contabilidad en soles, así que cuando facturas en dólares
/// necesita saber a qué tasa convertir. La tasa que corresponde es la
/// publicada por la SBS para la fecha de la operación, no la del banco
/// con el que trabajas.
/// </summary>
public class TipoCambio
{
    public string MonedaOrigen { get; set; } = "USD";
    public string MonedaDestino { get; set; } = "PEN";

    /// <summary>Tasa de conversión. Se declara con 3 decimales.</summary>
    public decimal Tasa { get; set; }

    public DateTime Fecha { get; set; } = RelojPeru.Hoy;
}

public class Factura : ComprobanteBase
{
    public override string TipoComprobante => Cpe.TipoComprobante.Factura;

    /// <summary>
    /// Catálogo 51. "0101" venta interna, "0200" exportación de bienes,
    /// "0201" a "0208" exportación de servicios.
    /// </summary>
    public string TipoOperacion { get; set; } = Cpe.TipoOperacion.VentaInterna;

    /// <summary>"Contado" o "Credito". Obligatorio en facturas.</summary>
    public string FormaPago { get; set; } = ReglasCredito.Contado;

    /// <summary>
    /// Las cuotas, cuando la factura es a crédito.
    ///
    /// NO SON OPCIONALES desde el 1 de enero de 2022 si el receptor tiene
    /// RUC: SUNAT rechaza con los errores 3249 y 3251 una factura a crédito
    /// que no declare al menos una cuota y el monto pendiente.
    ///
    /// A una persona natural con DNI sí se le puede facturar a crédito sin
    /// detallarlas. La obligación nace de la factura negociable, que se
    /// transfiere entre empresas.
    /// </summary>
    public List<CuotaCredito> Cuotas { get; set; } = [];

    /// <summary>
    /// Monto neto pendiente de pago: la suma de las cuotas.
    ///
    /// SE CALCULA Y NO SE PIDE APARTE a propósito. La regla 3319 exige que
    /// coincida con la suma de las cuotas, así que pedirlo por separado solo
    /// abriría la puerta a que no cuadre.
    /// </summary>
    public decimal MontoPendiente =>
        CalculadoraTotales.Redondear(Cuotas.Sum(c => c.Monto));

    /// <summary>
    /// Datos de la detracción, cuando la operación está sujeta al SPOT.
    ///
    /// CUANDO NO ES NULL CAMBIA CUATRO COSAS en el XML: el tipo de operación
    /// pasa a 1001-1004, aparece un bloque PaymentMeans con la cuenta del
    /// Banco de la Nación, otro PaymentTerms con el código y el monto, y se
    /// añade la leyenda obligatoria.
    ///
    /// El TipoOperacion de arriba se ignora: manda el de la detracción.
    /// </summary>
    public Detraccion? Detraccion { get; set; }

    /// <summary>
    /// País donde el servicio exportado se usa, explota o aprovecha.
    /// Código ISO 3166-1 de dos letras.
    ///
    /// SOLO PARA LOS TIPOS 0201 Y 0208, y no puede ser "PE". En cualquier
    /// otro tipo de operación sobra, y declararlo es un error.
    /// </summary>
    public string PaisDeUso { get; set; } = "";

    /// <summary>
    /// Acogimiento a la restitución simplificada de derechos arancelarios
    /// (drawback). Añade la leyenda 2010.
    /// </summary>
    public bool Drawback { get; set; }

    /// <summary>
    /// Percepción del IGV, cuando el emisor es agente de percepción.
    ///
    /// CUANDO NO ES NULL CAMBIA TRES COSAS en el XML: el tipo de operación
    /// pasa a 2001, aparece un cac:AllowanceCharge de cargo con el código
    /// 51, 52 o 53, y otro cac:PaymentTerms con el total ya percibido.
    ///
    /// Lo que NO cambia es el importe total del comprobante: la percepción
    /// no forma parte del precio de la operación y viaja aparte.
    /// </summary>
    public Percepcion? Percepcion { get; set; }

    /// <summary>
    /// Datos del desembarque, cuando la detracción es de recursos
    /// hidrobiológicos (tipo de operación 1002).
    ///
    /// SUNAT los exige para poder cruzar la factura contra el desembarque
    /// real. Son seis y ninguno es opcional.
    /// </summary>
    public RecursosHidrobiologicos? Hidrobiologicos { get; set; }

    /// <summary>
    /// El tipo de operación que de verdad viaja al XML.
    ///
    /// TRES CANDIDATOS SE DISPUTAN UN SOLO ATRIBUTO: la detracción quiere
    /// 1001-1004, la percepción quiere 2001, y la exportación 0200-0208.
    /// Aquí se decide el orden de precedencia, pero las clases de reglas
    /// rechazan de antemano cualquier combinación de dos, así que en la
    /// práctica solo uno puede estar presente.
    /// </summary>
    public string TipoOperacionEfectivo =>
        Detraccion?.TipoOperacion
        ?? (Percepcion is not null
                ? Cpe.TipoOperacion.SujetaAPercepcion
                : TipoOperacion);

    public bool EsExportacion => Cpe.TipoOperacion.EsExportacion(TipoOperacion);
}

public class Boleta : ComprobanteBase
{
    public override string TipoComprobante => Cpe.TipoComprobante.Boleta;

    public string TipoOperacion { get; set; } = Cpe.TipoOperacion.VentaInterna;
    public string FormaPago { get; set; } = "Contado";
}

/// <summary>
/// Nota de crédito. Disminuye o anula un comprobante ya emitido.
/// La serie debe empezar con la misma letra del documento que modifica.
/// </summary>
public class NotaCredito : ComprobanteBase
{
    public override string TipoComprobante => Cpe.TipoComprobante.NotaCredito;

    public string CodigoMotivo { get; set; } = MotivoNotaCredito.AnulacionDeLaOperacion;
    public string DescripcionMotivo { get; set; } = "";
    public DocumentoAfectado Afectado { get; set; } = new();

    /// <summary>
    /// 24 oct: SOLO EL MOTIVO 13 (corrección del monto neto pendiente y/o de
    /// las fechas y montos de las cuotas). Las cuotas NUEVAS; el monto neto
    /// pendiente es su suma. Va en cac:PaymentTerms, como en la factura.
    /// </summary>
    public List<CuotaCredito> Cuotas { get; set; } = [];

    public decimal MontoPendiente => CalculadoraTotales.Redondear(Cuotas.Sum(c => c.Monto));
}

/// <summary>Nota de débito. Aumenta el importe de un comprobante ya emitido.</summary>
public class NotaDebito : ComprobanteBase
{
    public override string TipoComprobante => Cpe.TipoComprobante.NotaDebito;

    public string CodigoMotivo { get; set; } = MotivoNotaDebito.InteresPorMora;
    public string DescripcionMotivo { get; set; } = "";
    public DocumentoAfectado Afectado { get; set; } = new();
}

public class DocumentoAfectado
{
    public string Numero { get; set; } = "";
    public string TipoDocumento { get; set; } = TipoComprobante.Factura;
}

public class Emisor
{
    public string Ruc { get; set; } = "";
    public string RazonSocial { get; set; } = "";
    public string NombreComercial { get; set; } = "";
    public string Ubigeo { get; set; } = "150101";
    public string Direccion { get; set; } = "";
    public string Distrito { get; set; } = "";
    public string Provincia { get; set; } = "";
    public string Departamento { get; set; } = "";
    public string CodigoEstablecimiento { get; set; } = "0000";
    public string CodigoPais { get; set; } = "PE";

    /// <summary>
    /// 23 oct: la dirección del local anexo desde el que se emite (sucursal).
    /// Solo para el PDF («Local: …»); no va al XML, que lleva el domicilio
    /// fiscal y el código de establecimiento. Vacío = la 0000.
    /// </summary>
    public string DireccionLocal { get; set; } = "";
}

public class Receptor
{
    public string TipoDocumento { get; set; } = TipoDocIdentidad.Ruc;
    public string NumeroDocumento { get; set; } = "";
    public string RazonSocial { get; set; } = "";
    public string Direccion { get; set; } = "";
}

/// <summary>
/// Una línea de detalle. Es idéntica en factura, boleta y notas.
/// </summary>
public class LineaComprobante
{
    public int Numero { get; set; }

    public string CodigoProducto { get; set; } = "";

    /// <summary>
    /// El código de producto SUNAT (catálogo 25, UNSPSC): 8 dígitos de una
    /// lista oficial. Opcional; obligatorio en la liquidación de compra desde
    /// 2027. Ver <see cref="Facturacion.Cpe.CodigoProductoSunat"/>.
    /// </summary>
    public string? CodigoProductoSunat { get; set; }

    public string Descripcion { get; set; } = "";

    /// <summary>Catálogo 65. "NIU" = unidad, "ZZ" = servicio.</summary>
    public string UnidadMedida { get; set; } = "NIU";

    public decimal Cantidad { get; set; }

    /// <summary>Valor unitario SIN IGV y SIN descuento. Es el dato de entrada.</summary>
    public decimal ValorUnitario { get; set; }

    /// <summary>
    /// e182 — EL PRECIO CON IGV, si así se vendió (28.50). Opcional.
    ///
    /// Con él, una línea gravada se calcula DESDE EL TOTAL, como lo hacen las
    /// demás facturadoras: total = cantidad × precio (57.00), valor de venta =
    /// total / 1.18 (48.31) e IGV = la diferencia (8.69). Sin él, desde el
    /// valor unitario (48.31 + 8.70 = 57.01): el céntimo de más que el cliente
    /// no entiende. SUNAT acepta los dos (la diferencia del IGV con el 18 %
    /// exacto queda muy dentro de su tolerancia de un sol).
    ///
    /// No se usa con ISC, ICBPER ni en las gratuitas: ahí manda el valor.
    /// </summary>
    public decimal? PrecioUnitario { get; set; }

    /// <summary>
    /// Descuento sobre esta línea, en porcentaje. 10 significa 10%.
    ///
    /// SE APLICA ANTES DEL IGV: el impuesto se calcula sobre el valor ya
    /// descontado, no sobre el bruto. Calcularlo al revés es un rechazo seguro.
    /// </summary>
    public decimal DescuentoPorcentaje { get; set; }

    /// <summary>Catálogo 07. "40" es exportación.</summary>
    public string TipoAfectacionIgv { get; set; } = AfectacionIgv.GravadoOperacionOnerosa;

    public decimal PorcentajeIgv { get; set; } = 18m;

    public bool TieneDescuento => DescuentoPorcentaje > 0;

    /// <summary>
    /// La tasa que se declara en el XML.
    ///
    /// En exportación es 0: el tributo es el 9995 - EXP y su importe es cero,
    /// así que declarar 18% sería contradecirse dentro del mismo bloque.
    /// </summary>
    public decimal TasaDeclarada =>
        AfectacionIgv.EsExportacion(TipoAfectacionIgv) ? 0m : PorcentajeIgv;

    /// <summary>
    /// ¿Esta línea son bolsas de plástico sujetas al ICBPER?
    ///
    /// VA EN LA LÍNEA Y NO EN EL COMPROBANTE porque el impuesto grava las
    /// bolsas, no la venta. Una boleta de ferretería puede llevar cemento,
    /// clavos y, en su propia línea, las tres bolsas en las que se lo lleva
    /// el cliente.
    ///
    /// LA CANTIDAD DE BOLSAS ES LA CANTIDAD DE ESTA LÍNEA. No es un campo
    /// aparte: la regla 3236 exige que coincidan.
    /// </summary>
    public bool AfectoIcbper { get; set; }

    /// <summary>
    /// Soles por bolsa. En null se usa la tasa vigente a la fecha de
    /// emisión, que es lo habitual y lo que evita equivocarse.
    /// </summary>
    public decimal? IcbperUnitario { get; set; }

    /// <summary>
    /// Sistema de cálculo del ISC, catálogo 08. Vacío si no lleva ISC.
    ///
    /// DECLARARLO ES LO QUE ACTIVA EL IMPUESTO en esta línea. Si está
    /// vacío, la línea no tiene ISC aunque traiga tasa.
    /// </summary>
    public string SistemaIsc { get; set; } = "";

    /// <summary>Tasa del ISC, en porcentaje. 10 significa 10%.</summary>
    public decimal TasaIsc { get; set; }

    /// <summary>
    /// ¿Esta línea lleva ISC?
    ///
    /// Lo decide el sistema y NO la tasa, a propósito: así una tasa en cero
    /// con sistema declarado sale como el error que es (3104), en vez de
    /// desaparecer sin que nadie se entere.
    /// </summary>
    public bool TieneIsc => !string.IsNullOrWhiteSpace(SistemaIsc);

    /// <summary>
    /// Datos extra del catálogo 55 que viajan dentro del ítem.
    ///
    /// SON EL CAJÓN DE SASTRE DE SUNAT: datos que no caben en ningún campo
    /// del estándar UBL y que se declaran como propiedades del producto.
    /// Hoy los usan la detracción de pesca y el transporte de pasajeros.
    ///
    /// Normalmente se rellenan solos, a partir del bloque que corresponda.
    /// </summary>
    public List<PropiedadItem> Propiedades { get; set; } = [];
}

/// <summary>
/// Totales calculados del comprobante.
///
/// LEER ESTO ANTES DE TOCAR NADA, porque con anticipos el documento declara
/// dos verdades a la vez y los nombres se prestan a confusión:
///
///   ValorVenta   → la operación COMPLETA sin IGV, sin restar anticipos.
///   PrecioVenta  → la operación COMPLETA con IGV, sin restar anticipos.
///   TotalGravado → la base imponible NETA, ya con el anticipo descontado.
///   TotalIgv     → el IGV sobre esa base neta: solo lo que falta cobrar.
///   ImporteTotal → lo que el cliente paga hoy: PrecioVenta menos anticipos.
///
/// No es una incoherencia de SUNAT: el IGV del anticipo se pagó cuando se
/// emitió aquella factura, y volver a declararlo sería pagarlo dos veces.
/// Sin anticipos, PrecioVenta e ImporteTotal son el mismo número y todo
/// esto desaparece.
///
/// Los campos nuevos van AL FINAL y con valor por defecto a propósito: así
/// cualquier código que ya construyera este record por posición sigue
/// compilando. Moverlos de sitio rompería las llamadas existentes sin que
/// el compilador diga dónde.
/// </summary>
public record TotalesComprobante(
    decimal TotalGravado,
    decimal TotalExonerado,
    decimal TotalInafecto,
    decimal TotalGratuito,
    decimal TotalDescuentos,
    decimal TotalIgv,
    decimal ValorVenta,
    decimal ImporteTotal,
    decimal TotalExportacion = 0m,
    decimal TotalAnticipos = 0m,
    decimal AnticipoGravado = 0m,
    decimal AnticipoExonerado = 0m,
    decimal AnticipoInafecto = 0m,
    decimal PrecioVenta = 0m,

    // IgvGratuito: el IGV de las líneas gratuitas. Se declara y no se cobra.
    //
    // NO ESTÁ SUMADO EN TotalIgv, a propósito: la regla 3294 dice que el
    // total de impuestos del documento solo suma los tributos 1000, 1016,
    // 2000, 7152 y 9999. El 9996 de las gratuitas viaja en su propio
    // subtotal y en ningún otro sitio.
    decimal IgvGratuito = 0m,

    // TotalOtrosCargos: cbc:ChargeTotalAmount. Los cargos que no afectan la
    // base imponible: códigos 45, 46, 48 y 50 (regla 3301).
    decimal TotalOtrosCargos = 0m,

    // TotalOtrosDescuentos: cbc:AllowanceTotalAmount. Los descuentos que no
    // afectan la base imponible: códigos 01, 03 y 63 (regla 3300).
    //
    // OJO CON EL NOMBRE PARECIDO: TotalDescuentos, más arriba, es otra cosa
    // —los descuentos de línea que SÍ reducen la base— y no se declara en
    // ningún tag; ya está restado dentro del valor de venta.
    decimal TotalOtrosDescuentos = 0m,

    // TotalIcbper: el impuesto a las bolsas de plástico, tributo 7152.
    //
    // ESTE SÍ ENTRA EN EL PRECIO DE VENTA Y EN EL IMPORTE TOTAL, al revés
    // que las gratuitas y la percepción: la regla 3279 lo suma dentro del
    // TaxInclusiveAmount, y la 3294 lo suma dentro del total de impuestos.
    decimal TotalIcbper = 0m,

    // TotalGravadoIvap: la base imponible del arroz pilado, tributo 1016.
    //
    // VA APARTE DE TotalGravado porque son tributos distintos y cada uno
    // necesita su propio subtotal global. Por la regla 2644 nunca hay
    // valores en los dos a la vez: un comprobante es de IVAP o no lo es.
    decimal TotalGravadoIvap = 0m,

    // TotalIvap: el impuesto del 4% sobre esa base.
    decimal TotalIvap = 0m,

    // TotalIsc: el Impuesto Selectivo al Consumo, tributo 2000.
    decimal TotalIsc = 0m,

    // TotalBaseIsc: la suma de las bases sobre las que se calculó (regla
    // 3296). No es lo mismo que TotalIsc ni que el valor de venta.
    decimal TotalBaseIsc = 0m,

    // ValorVentaGravado: la suma de los valores de venta de las líneas
    // gravadas, SIN el ISC.
    //
    // EXISTE PORQUE CON ISC TotalGravado YA NO SIRVE PARA ESTO. TotalGravado
    // es la base del IGV, que incluye el ISC (regla 3272); el valor de venta
    // del documento no lo incluye (regla 3278, que no lista el tributo
    // 2000). Son dos números que en una factura normal coinciden y aquí
    // dejan de hacerlo.
    decimal ValorVentaGravado = 0m)
{
    /// <summary>
    /// El precio de venta que de verdad viaja al XML.
    ///
    /// Si alguien construyó el record sin PrecioVenta, cae de pie en el
    /// importe total, que es el valor correcto cuando no hay anticipos.
    /// Un cero ahí sería un rechazo silencioso muy difícil de rastrear.
    /// </summary>
    public decimal PrecioVentaEfectivo => PrecioVenta > 0 ? PrecioVenta : ImporteTotal;

    public bool HayAnticipos => TotalAnticipos > 0;

    /// <summary>Base gravada de las líneas, antes de descontar anticipos.</summary>
    public decimal GravadoDeLineas => TotalGravado + AnticipoGravado;

    public decimal ExoneradoDeLineas => TotalExonerado + AnticipoExonerado;

    public decimal InafectoDeLineas => TotalInafecto + AnticipoInafecto;

    /// <summary>¿El comprobante entregó algo gratis?</summary>
    public bool HayGratuitas => TotalGratuito > 0;

    public bool HayOtrosCargos => TotalOtrosCargos > 0;

    public bool HayOtrosDescuentos => TotalOtrosDescuentos > 0;

    public bool HayIcbper => TotalIcbper > 0;

    /// <summary>
    /// El total de impuestos que va en cbc:TaxAmount de cabecera.
    ///
    /// SUMA EL IGV Y EL ICBPER, porque la regla 3294 dice que ese tag es la
    /// suma de los tributos 1000, 1016, 2000, 7152 y 9999. El 9996 de las
    /// gratuitas no está en la lista y por eso no entra.
    /// </summary>
    public decimal ImpuestosDeclarados =>
        CalculadoraTotales.Redondear(
            TotalIgv + TotalIcbper + TotalIvap + TotalIsc);

    public bool HayIsc => TotalIsc > 0;

    /// <summary>¿El comprobante es de arroz pilado?</summary>
    public bool HayIvap => TotalGravadoIvap > 0;
}

/// <summary>
/// Resultado del cálculo de una línea.
/// </summary>
/// <param name="FactorDescuento">
/// Descuento efectivo aplicado, ya combinando el de la línea con el global.
/// Es el valor que viaja al XML en MultiplierFactorNumeric.
/// </param>
/// <param name="ValorBruto">Cantidad por valor unitario, antes de descuentos.</param>
/// <param name="Descuento">Monto descontado.</param>
/// <param name="ValorVenta">Valor neto: bruto menos descuento. Es lo que va al XML.</param>
public record LineaCalculada(
    LineaComprobante Linea,
    decimal FactorDescuento,
    decimal ValorBruto,
    decimal Descuento,
    decimal ValorVenta,
    decimal Igv,
    decimal PrecioUnitarioConIgv,

    // Icbper: el impuesto a las bolsas de esta línea, si las hay.
    // Va al final y con valor por defecto para no romper las llamadas
    // posicionales que ya existían.
    decimal Icbper = 0m,

    // TasaIcbper: los soles por bolsa que se declararon. Se guarda porque
    // el XML lo pide aparte del importe (cbc:PerUnitAmount), y recalcularlo
    // en el generador abriría la puerta a que los dos dejaran de cuadrar.
    decimal TasaIcbper = 0m,

    // Isc: el Impuesto Selectivo al Consumo de esta línea.
    decimal Isc = 0m)
{
    public bool TieneDescuento => Descuento > 0;

    public bool TieneIcbper => Icbper > 0;

    public bool TieneIsc => Isc > 0;

    /// <summary>
    /// La base sobre la que se calcula el IGV de esta línea.
    ///
    /// ES EL VALOR DE VENTA MÁS EL ISC, y ahí está toda la particularidad
    /// del ISC: se paga IGV sobre el ISC. La regla 3272 compara justamente
    /// esto, y una línea que declare solo el valor de venta se rechaza.
    ///
    /// Sin ISC vale lo mismo que ValorVenta y no cambia nada.
    /// </summary>
    public decimal BaseIgv => ValorVenta + Isc;
}