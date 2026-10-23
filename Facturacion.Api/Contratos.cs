using System.ComponentModel.DataAnnotations;
using Facturacion.Cpe;
using Facturacion.Persistencia;

namespace Facturacion.Api;

/// <summary>
/// Petición para emitir un comprobante.
///
/// FÍJATE EN LO QUE **NO** ESTÁ: no hay datos del emisor ni correlativo.
///
///   El emisor lo determina la clave de acceso. Que el cliente declarara su
///   propio RUC sería como dejar que el usuario diga quién es en vez de
///   autenticarse.
///
///   El correlativo lo asigna la base. Aceptarlo desde afuera abriría la
///   puerta a duplicados y saltos de numeración.
/// </summary>
public class PeticionComprobante
{
    /// <summary>Catálogo 01. "01" factura, "03" boleta.</summary>
    [Required]
    public string Tipo { get; set; } = TipoComprobante.Factura;

    /// <summary>Serie ya dada de alta para este emisor. Ej: F001</summary>
    [Required]
    public string Serie { get; set; } = "";

    /// <summary>Si no se indica, se usa la fecha de hoy.</summary>
    public DateTime? FechaEmision { get; set; }

    public string Moneda { get; set; } = "PEN";

    /// <summary>
    /// Catálogo 51. Qué clase de operación es.
    ///
    ///   "0101" venta interna (por defecto)
    ///   "0200" exportación de bienes
    ///   "0201" a "0208" exportación de servicios
    ///   "0401" venta a no domiciliado que NO califica como exportación
    ///
    /// NO SE USA PARA DETRACCIÓN: cuando la petición trae el bloque
    /// "detraccion", el tipo lo manda ese bloque (1001-1004) y este campo
    /// se ignora.
    /// </summary>
    public string TipoOperacion { get; set; } = Cpe.TipoOperacion.VentaInterna;

    /// <summary>"Contado" o "Credito".</summary>
    public string FormaPago { get; set; } = ReglasCredito.Contado;

    /// <summary>
    /// Las cuotas, cuando la factura es a credito.
    ///
    /// OBLIGATORIAS desde 2022 si el receptor tiene RUC: sin al menos una,
    /// SUNAT rechaza la factura con los errores 3249 y 3251.
    /// </summary>
    public List<CuotaDto> Cuotas { get; set; } = [];

    /// <summary>
    /// Descuento sobre el comprobante completo, en porcentaje.
    ///
    /// ESTE SÍ REDUCE LA BASE IMPONIBLE: el IGV se calcula sobre el monto ya
    /// descontado. Se reparte dentro de las líneas, que es como SUNAT lo
    /// cuadra (regla 3277).
    ///
    /// Para lo contrario —un descuento que no toca el IGV— está
    /// `cargosGlobales` con el código 03.
    /// </summary>
    public decimal DescuentoGlobalPorcentaje { get; set; }

    /// <summary>
    /// Cargos y descuentos del comprobante entero que NO cambian la base
    /// imponible del IGV.
    ///
    /// Ejemplo: recargo al consumo de un restaurante, FISE de una
    /// distribuidora de gas, un descuento comercial pactado aparte.
    ///
    /// NO SE SUMAN AL VALOR DE VENTA NI GENERAN IGV. Solo mueven el importe
    /// a pagar: los cargos lo suben, los descuentos lo bajan.
    /// </summary>
    public List<CargoGlobalDto> CargosGlobales { get; set; } = [];

    /// <summary>
    /// Datos del desembarque, obligatorios cuando la detracción es de
    /// recursos hidrobiológicos (tipo de operación `1002`).
    ///
    /// SUNAT los usa para cruzar la factura contra el desembarque real, y
    /// rechaza el comprobante por cada uno que falte.
    /// </summary>
    public HidrobiologicosDto? Hidrobiologicos { get; set; }

    /// <summary>Obligatorio cuando la moneda no es PEN.</summary>
    public TipoCambioDto? TipoCambio { get; set; }

    /// <summary>
    /// Código ISO del país donde se usa o aprovecha el servicio exportado.
    /// Dos letras, y no puede ser "PE".
    ///
    /// SOLO PARA LOS TIPOS 0201 Y 0208. En cualquier otro la petición se
    /// rechaza, porque declararlo donde no corresponde significa casi
    /// siempre que el tipo de operación elegido es el equivocado.
    /// </summary>
    public string PaisDeUso { get; set; } = "";

    /// <summary>
    /// Acogimiento al drawback: restitución simplificada de derechos
    /// arancelarios. Añade la leyenda 2010 al comprobante.
    ///
    /// Opcional, y solo tiene efecto en facturas de exportación.
    /// </summary>
    public bool Drawback { get; set; }

    [Required]
    public ReceptorDto Receptor { get; set; } = new();

    /// <summary>
    /// 23 oct: desde qué local del MISMO RUC se emite (sucursal): código de
    /// establecimiento (va al XML) y su dirección (va al PDF). Sin él, 0000.
    /// </summary>
    public EstablecimientoDto? Establecimiento { get; set; }

    [Required]
    [MinLength(1, ErrorMessage = "El comprobante necesita al menos una línea.")]
    public List<LineaDto> Lineas { get; set; } = [];

    /// <summary>
    /// Detracción, cuando la operación está sujeta al SPOT.
    ///
    /// Solo aplica a facturas. Si se envía en una boleta, se ignora: SUNAT no
    /// admite detracción en comprobantes que no dan crédito fiscal.
    /// </summary>
    public DetraccionDto? Detraccion { get; set; }

    /// <summary>
    /// Anticipos ya facturados que se descuentan de este comprobante.
    ///
    /// LAS LINEAS VAN POR EL TOTAL DE LA OPERACION, no por el saldo. El
    /// anticipo se declara aparte y el sistema calcula lo que queda por
    /// cobrar. Facturar solo el saldo en las lineas es el error mas comun,
    /// y produce un comprobante que SUNAT acepta pero declara mal el IGV.
    /// </summary>
    public List<AnticipoDto> Anticipos { get; set; } = [];

    /// <summary>
    /// Percepcion del IGV, cuando el emisor es agente de percepcion
    /// designado por SUNAT.
    ///
    /// SOLO AL CONTADO. A credito SUNAT la rechaza (error 3330) y hay que
    /// emitir un Comprobante de Percepcion aparte.
    /// </summary>
    public PercepcionDto? Percepcion { get; set; }

    /// <summary>
    /// Campos propios de la empresa. Se guardan tal cual y se pueden consultar
    /// después, pero NUNCA viajan a SUNAT.
    /// </summary>
    public Dictionary<string, object>? Extra { get; set; }
}

/// <summary>
/// Datos de la detracción.
///
/// QUÉ ES: en ciertas operaciones el comprador no paga el total al vendedor.
/// Retiene un porcentaje y lo deposita en la cuenta que el vendedor tiene en
/// el Banco de la Nación, destinada solo a pagar impuestos.
/// </summary>
public class DetraccionDto
{
    /// <summary>
    /// Catálogo 51. "1001" general, "1002" hidrobiológicos,
    /// "1003" transporte de pasajeros, "1004" transporte de carga.
    /// </summary>
    public string TipoOperacion { get; set; } = TipoOperacionDetraccion.General;

    /// <summary>
    /// Catálogo 54: qué bien o servicio está sujeto.
    ///
    /// Para los tipos 1002, 1003 y 1004, SUNAT obliga a un valor concreto:
    /// 004, 028 y 027 respectivamente. Enviar otro rechaza la factura.
    /// </summary>
    [Required]
    public string CodigoBienServicio { get; set; } = "";

    /// <summary>La tasa que se retiene. 12 significa 12%.</summary>
    [Range(0.01, 100)]
    public decimal Porcentaje { get; set; }

    /// <summary>
    /// Opcional. Si no se envía, se calcula sobre el importe total y se
    /// redondea al entero más próximo, que es lo que hace el Banco de la
    /// Nación. Declarar céntimos produce diferencias con el depósito real.
    /// </summary>
    public decimal? Monto { get; set; }

    /// <summary>
    /// La cuenta de detracciones del vendedor. La abre él, no el comprador.
    /// </summary>
    [Required]
    public string CuentaBancoNacion { get; set; } = "";

    /// <summary>Catálogo 59. Por defecto, depósito en cuenta.</summary>
    public string MedioDePago { get; set; } = "001";
}

/// <summary>
/// Un anticipo ya facturado.
///
/// EL CIRCUITO, EN CORTO: el cliente adelanta dinero y se le emite una
/// factura normal por ese monto. Cuando se entrega la mercaderia se emite
/// la factura final por el TOTAL, declarando aqui aquel anticipo. SUNAT
/// cruza las dos y rechaza si la primera no existe o no fue aceptada.
/// </summary>
public class AnticipoDto
{
    /// <summary>
    /// Numero del 1 al 99 que enlaza este anticipo dentro de la factura.
    /// Si hay tres anticipos, son 1, 2 y 3. No es el numero de la factura.
    /// </summary>
    [Range(1, 99)]
    public int IdentificadorPago { get; set; } = 1;

    /// <summary>Catalogo 12. "02" factura, "03" boleta.</summary>
    public string TipoComprobante { get; set; } = TipoComprobanteAnticipo.Factura;

    /// <summary>Serie y numero de la factura del anticipo. Ej: F001-00000010</summary>
    [Required]
    public string Numero { get; set; } = "";

    /// <summary>RUC de quien emitio la factura del anticipo.</summary>
    [Required]
    public string RucEmisor { get; set; } = "";

    /// <summary>
    /// Importe del anticipo CON IGV: lo que el cliente pago de verdad, el
    /// total de aquella factura.
    ///
    /// AQUI ES DONDE MAS SE FALLA. Si se manda el valor sin IGV, la factura
    /// cuadra mal por el 18% y SUNAT devuelve el 3280.
    /// </summary>
    [Range(0.01, double.MaxValue)]
    public decimal MontoTotal { get; set; }

    /// <summary>Fecha del pago. Opcional.</summary>
    public DateTime? FechaPago { get; set; }

    /// <summary>
    /// Catalogo 07: "10" gravado, "20" exonerado, "30" inafecto.
    /// Determina de que base imponible se descuenta.
    /// </summary>
    public string TipoAfectacion { get; set; } = AfectacionIgv.GravadoOperacionOnerosa;

    public decimal PorcentajeIgv { get; set; } = 18m;
}

/// <summary>
/// Datos de la percepcion.
///
/// QUE ES: el vendedor cobra al comprador un porcentaje ADICIONAL al precio
/// y se lo entrega a SUNAT como adelanto del IGV que ese comprador
/// declarara despues.
///
/// NO CUALQUIERA PUEDE APLICARLA: solo los contribuyentes que SUNAT designo
/// agentes de percepcion por resolucion.
/// </summary>
public class PercepcionDto
{
    /// <summary>
    /// Catalogo 22. "01" venta interna (2%), "02" combustible (1%),
    /// "03" venta a otro agente de percepcion (0.5%).
    /// </summary>
    public string Regimen { get; set; } = RegimenPercepcion.VentaInterna;

    /// <summary>
    /// La tasa que se percibe. 2 significa 2%.
    ///
    /// Si no se envia, se usa la tasa de referencia del regimen. Se admite
    /// enviarla porque SUNAT las cambia por resolucion, y el dia que la
    /// cambien esto seguira funcionando sin tocar el codigo.
    /// </summary>
    public decimal? Porcentaje { get; set; }

    /// <summary>
    /// Opcional. Si no se envia, se calcula sobre el importe total del
    /// comprobante convertido a soles.
    ///
    /// LA BASE ES EL IMPORTE TOTAL CON IGV, no el valor de venta: la
    /// percepcion se calcula sobre lo que el comprador paga.
    /// </summary>
    public decimal? Monto { get; set; }
}

/// <summary>
/// Una cuota de una factura a credito.
/// </summary>
public class CuotaDto
{
    /// <summary>Numero de cuota, empezando en 1. Viaja como "Cuota001".</summary>
    [Range(1, 999)]
    public int Numero { get; set; } = 1;

    [Range(0.01, double.MaxValue)]
    public decimal Monto { get; set; }

    /// <summary>
    /// Cuando vence. Tiene que ser POSTERIOR a la fecha de emision: una
    /// cuota que vence el mismo dia no es credito (error 3267).
    /// </summary>
    [Required]
    public DateTime FechaVencimiento { get; set; }
}

/// <summary>
/// Un cargo o descuento sobre el comprobante entero que NO afecta la base
/// imponible del IGV.
/// </summary>
public class CargoGlobalDto
{
    /// <summary>
    /// Código del catálogo 53. Estos siete:
    ///
    ///   "49" cargo global que SÍ afecta la base imponible
    ///   "50" cargo global que no afecta la base imponible
    ///   "03" descuento global que no afecta la base imponible
    ///   "45" FISE (Fondo de Inclusión Social Energético)
    ///   "46" recargo al consumo y/o propinas
    ///   "62" retención del IGV — informativa, no mueve el total
    ///   "63" retención de renta de segunda categoría — resta del total
    ///
    /// NO SE ENVÍA SI ES CARGO O DESCUENTO: lo dice el código. El "03" resta
    /// del importe a pagar, los otros cuatro suman.
    ///
    /// EL "49" ES DISTINTO DE TODOS LOS DEMÁS: se suma a la base imponible y
    /// genera su propio IGV. Con 100 soles de cargo 49, el impuesto sube 18
    /// soles y el total 118. Con el "50", el total sube 100 y el impuesto no
    /// se mueve. Elegir mal cambia lo que se declara.
    /// </summary>
    [Required]
    public string Codigo { get; set; } = CodigoCargoDescuento.CargoGlobalNoAfectaBase;

    /// <summary>El monto, siempre positivo. Mayor que cero (error 2968).</summary>
    [Range(0.01, double.MaxValue)]
    public decimal Monto { get; set; }

    /// <summary>
    /// Sobre qué importe se calculó. Opcional, pero obligatorio si envías
    /// `porcentaje`: SUNAT multiplica los dos y compara con el monto.
    /// </summary>
    public decimal? BaseImponible { get; set; }

    /// <summary>Porcentaje, si se calculó como tal. 10 significa 10%.</summary>
    public decimal? Porcentaje { get; set; }

    /// <summary>
    /// Para qué es. NO VIAJA AL XML —SUNAT no tiene dónde ponerlo— pero sale
    /// en el PDF, que es lo que lee el cliente.
    /// </summary>
    public string Descripcion { get; set; } = "";
}

/// <summary>
/// Los seis datos del desembarque en una detracción de pesca.
/// Todos obligatorios: errores 3063, 3130, 3131, 3132, 3133 y 3134.
/// </summary>
public class HidrobiologicosDto
{
    /// <summary>Matrícula de la embarcación. Ej: "CE-12345-PM".</summary>
    [Required]
    public string Matricula { get; set; } = "";

    /// <summary>Cómo se llama el barco.</summary>
    [Required]
    public string NombreEmbarcacion { get; set; } = "";

    /// <summary>Qué se pescó. Ej: "ANCHOVETA".</summary>
    [Required]
    public string TipoEspecie { get; set; } = "";

    /// <summary>Dónde se descargó. Ej: "PAITA".</summary>
    [Required]
    public string LugarDescarga { get; set; } = "";

    /// <summary>
    /// Cuándo se descargó. No puede ser posterior a la emisión: primero se
    /// descarga y después se factura.
    /// </summary>
    [Required]
    public DateTime FechaDescarga { get; set; }

    /// <summary>
    /// Cuánto se vendió, EN TONELADAS MÉTRICAS.
    ///
    /// LA UNIDAD NO SE ELIGE: SUNAT exige `TNE` y rechaza cualquier otra con
    /// el error 3115. Doce mil kilos son **12**, no 12000.
    /// </summary>
    [Range(0.000001, double.MaxValue)]
    public decimal CantidadEspecie { get; set; }
}

public class ReceptorDto
{
    /// <summary>
    /// Catálogo 06. "6" RUC, "1" DNI.
    ///
    /// EN EXPORTACIÓN EL COMPRADOR NO TIENE RUC, y en los tipos 0200, 0201 y
    /// 0204 declararlo con RUC es un rechazo. Los valores habituales ahí son
    /// "0" (documento tributario de no domiciliado sin RUC), "7" (pasaporte),
    /// "C" (TIN, persona natural del exterior) y "D" (IN, persona jurídica).
    /// </summary>
    public string TipoDocumento { get; set; } = TipoDocIdentidad.Ruc;

    /// <summary>
    /// El número, sin guiones ni espacios.
    ///
    /// UN RUC SE COMPRUEBA ANTES DE EMITIR. Lleva un dígito verificador de
    /// módulo 11, así que un número mal tecleado se detecta aquí mismo y la
    /// petición devuelve 400 con el RUC que probablemente quisiste poner.
    ///
    /// No se comprueba contra el padrón de SUNAT —eso necesita el archivo
    /// del padrón o una consulta externa— pero sí ataja el error que de
    /// verdad pasa: el dedazo.
    /// </summary>
    [Required]
    public string NumeroDocumento { get; set; } = "";

    [Required]
    public string RazonSocial { get; set; } = "";

    public string Direccion { get; set; } = "";

    /// <summary>
    /// Opcional. A dónde se le manda el comprobante cuando SUNAT lo acepte, con
    /// el PDF y el enlace al portal del receptor.
    ///
    /// NO ES UN DATO TRIBUTARIO Y NUNCA VA AL XML. Se guarda en su propia
    /// columna (`comprobantes.correo_receptor`), no en el `cpe`, que es lo que
    /// se firma.
    ///
    /// Se usa en facturas, boletas y notas. En las guías (`Destinatario`) hoy
    /// no se usa: el portal es para comprobantes de pago.
    ///
    /// La comprobación es floja a propósito —una arroba, un punto en el
    /// dominio, sin espacios—: lo único que demuestra que un correo existe es
    /// mandarle algo.
    /// </summary>
    public string? Correo { get; set; }

    /// <summary>El correo sin espacios alrededor, o null si no vino.</summary>
    public string? CorreoLimpio() =>
        string.IsNullOrWhiteSpace(Correo) ? null : Correo.Trim();

    /// <summary>
    /// Null si el correo está bien o no vino; si no, el motivo, para devolver
    /// un 400 que diga qué pasa.
    /// </summary>
    public string? ProblemaCorreo()
    {
        if (CorreoLimpio() is not { } correo) return null;

        if (correo.Length > 254)
            return "El correo del receptor es demasiado largo (máximo 254 caracteres).";

        var arroba = correo.IndexOf('@');
        var dominio = arroba > 0 ? correo[(arroba + 1)..] : "";

        var tieneForma =
            arroba > 0 &&
            arroba == correo.LastIndexOf('@') &&
            dominio.Contains('.') &&
            !dominio.StartsWith('.') &&
            !dominio.EndsWith('.') &&
            !correo.Any(char.IsWhiteSpace);

        return tieneForma ? null : $"El correo del receptor no tiene forma de correo: «{correo}».";
    }
}

public class LineaDto
{
    public string CodigoProducto { get; set; } = "";

    /// <summary>
    /// Código de producto SUNAT: 8 dígitos del catálogo 25 (UNSPSC v14), por
    /// ejemplo 50161509 «Azúcares naturales». NO es tu código propio, que va en
    /// codigoProducto.
    ///
    /// Opcional en factura, boleta y notas, pero si lo mandas tiene que ser
    /// válido: desde el 1 de enero de 2027 uno inválido hace rechazar el
    /// comprobante (regla 3496). Mínimo nivel clase: 50161500 vale, 50160000
    /// no.
    ///
    /// En la LIQUIDACIÓN DE COMPRA es obligatorio desde el 1 de enero de 2027
    /// (regla 3506).
    /// </summary>
    public string? CodigoProductoSunat { get; set; }

    [Required]
    public string Descripcion { get; set; } = "";

    /// <summary>Catálogo 65. "NIU" unidad, "ZZ" servicio.</summary>
    public string UnidadMedida { get; set; } = "NIU";

    [Range(0.000001, double.MaxValue, ErrorMessage = "La cantidad debe ser mayor que cero.")]
    public decimal Cantidad { get; set; }

    /// <summary>Valor unitario SIN IGV y SIN descuento.</summary>
    [Range(0, double.MaxValue)]
    public decimal ValorUnitario { get; set; }

    public decimal DescuentoPorcentaje { get; set; }

    /// <summary>
    /// Catálogo 07. "10" gravado, "20" exonerado, "30" inafecto,
    /// "40" exportación, "17" arroz pilado (IVAP).
    ///
    /// EL "17" ES EXCLUYENTE: si una línea lo lleva, TODAS tienen que
    /// llevarlo. El arroz pilado no paga IGV sino un impuesto propio del
    /// 4% que lo sustituye, y va en su propio comprobante (regla 2644).
    ///
    /// En una factura de exportación TODAS las líneas llevan "40". No se
    /// puede mezclar con líneas gravadas en el mismo comprobante.
    ///
    /// OPERACIONES GRATUITAS — lo que se entrega sin cobrar va en su propia
    /// línea, con su valor referencial en valorUnitario y uno de estos
    /// códigos. No da igual cuál: SUNAT los cruza con el gasto que el
    /// contribuyente deduce.
    ///
    ///   Con IGV (lo declara y lo asume el emisor):
    ///     "11" retiro por premio       "12" retiro por donación
    ///     "13" retiro                  "14" retiro por publicidad
    ///     "15" BONIFICACIONES          "16" entrega a trabajadores
    ///
    ///   Sin IGV:
    ///     "21" transferencia gratuita exonerada
    ///     "31" retiro por bonificación inafecto   "32" retiro
    ///     "33" muestras médicas        "34" convenio colectivo
    ///     "35" retiro por premio       "36" retiro por publicidad
    ///     "37" transferencia gratuita inafecta
    ///
    /// El "15" es el del comercio: "llévate 12 y paga 10". Las dos de regalo
    /// van en una línea aparte con ese código.
    /// </summary>
    public string TipoAfectacionIgv { get; set; } = AfectacionIgv.GravadoOperacionOnerosa;

    /// <summary>
    /// Tasa del impuesto. Déjalo vacío salvo que sepas lo que haces.
    ///
    /// ES NULLABLE A PROPÓSITO, Y NO ES UN DETALLE: la tasa correcta
    /// depende de la afectación. El IGV es 18%, pero el arroz pilado
    /// (afectación "17") tributa IVAP al 4%. Con un 18 por defecto, una
    /// línea de arroz saldría con la tasa equivocada sin que nadie lo
    /// pidiera.
    ///
    /// En vacío se resuelve sola: 4 para el IVAP, 18 para todo lo demás.
    ///
    /// Si la mandas, tiene que ser la MISMA en todas las líneas afectas del
    /// comprobante, gratuitas gravadas incluidas (regla 3462).
    /// </summary>
    public decimal? PorcentajeIgv { get; set; }

    /// <summary>
    /// ¿Esta línea son bolsas de plástico sujetas al ICBPER?
    ///
    /// LAS BOLSAS VAN EN SU PROPIA LÍNEA, con su cantidad: esa cantidad es
    /// la que SUNAT cuenta para el impuesto (regla 3236). No se marca la
    /// línea del producto que va dentro de la bolsa.
    ///
    /// Ejemplo de una boleta de mostrador:
    ///
    ///   1. CEMENTO PORTLAND, 2 BG,  25.00
    ///   2. BOLSA PLASTICA,   3 NIU,  0.00   ← afectoIcbper: true
    ///
    /// El impuesto SÍ sube el importe total: tres bolsas son 1.50 más.
    /// </summary>
    public bool AfectoIcbper { get; set; }

    /// <summary>
    /// Soles por bolsa. Déjalo vacío y se usa la tasa vigente a la fecha de
    /// emisión, que es lo habitual y lo que evita equivocarse.
    ///
    /// La escala de la Ley 30884: 0.10 en 2019, 0.20 en 2020, 0.30 en 2021,
    /// 0.40 en 2022 y 0.50 desde 2023.
    /// </summary>
    public decimal? IcbperUnitario { get; set; }

    /// <summary>
    /// Sistema de cálculo del ISC, catálogo 08. Vacío si la línea no lleva.
    ///
    ///   "01" al valor — un porcentaje sobre el valor de venta
    ///   "02" monto fijo por unidad — combustibles, cigarrillos
    ///   "03" precio de venta al público
    ///
    /// DECLARARLO ES LO QUE ACTIVA EL IMPUESTO. Si va vacío, la línea no
    /// tiene ISC aunque mandes tasa.
    ///
    /// OJO CON EL "02": SUNAT no tiene campo para los soles por unidad.
    /// Comprueba que el importe sea la tasa por la base, así que hay que
    /// calcular el ISC aparte y declarar qué porcentaje resultó.
    /// </summary>
    public string SistemaIsc { get; set; } = "";

    /// <summary>
    /// Tasa del ISC, en porcentaje. 10 significa 10%.
    ///
    /// EL ISC ENTRA EN LA BASE DEL IGV: con 1000 de valor de venta y 10% de
    /// ISC, el IGV se calcula sobre 1100 y no sobre 1000. Son 18 soles de
    /// diferencia y lo comprueba la regla 3272.
    /// </summary>
    public decimal TasaIsc { get; set; }
}

public class TipoCambioDto
{
    public string MonedaOrigen { get; set; } = "USD";
    public string MonedaDestino { get; set; } = "PEN";
    public decimal Tasa { get; set; }
    public DateTime? Fecha { get; set; }
}

/// <summary>
/// Respuesta al aceptar un comprobante.
///
/// Se devuelve 202 Accepted, no 201 Created, y la diferencia importa: el
/// comprobante quedó registrado, pero TODAVÍA NO fue a SUNAT. Responder 201
/// daría a entender que ya está emitido, y ese malentendido termina en un
/// cliente que entrega una factura que SUNAT después rechazó.
/// </summary>
public record RespuestaComprobante(
    Guid Id,
    string Numero,
    string Estado,
    decimal ImporteTotal,
    string Moneda,
    bool Duplicado)
{
    public static RespuestaComprobante Desde(ComprobanteGuardado g, string moneda) =>
        new(g.Id, g.NumeroCompleto, g.Estado, g.ImporteTotal, moneda, g.YaExistia);
}

/// <summary>Estado de un comprobante.</summary>
public record RespuestaEstado(
    Guid Id,
    string Numero,
    string Tipo,
    DateTime FechaEmision,
    string Moneda,
    decimal ImporteTotal,
    string Estado,
    string? CodigoSunat,
    string? MensajeSunat,
    string? Ticket,
    DateTime CreadoEn)
{
    public static RespuestaEstado Desde(ResumenComprobante r) =>
        new(r.Id, r.NumeroCompleto, r.TipoComprobante, r.FechaEmision,
            r.Moneda, r.ImporteTotal, r.Estado, r.CodigoSunat,
            r.MensajeSunat, r.Ticket, r.CreadoEn);
}

/// <summary>
/// Error devuelto por la API.
///
/// Un mensaje que describe el hecho observado, no una suposición. Los errores
/// vagos mandan a quien depura en la dirección equivocada, y eso cuesta horas.
/// </summary>
public record RespuestaError(string Error, string? Detalle = null);