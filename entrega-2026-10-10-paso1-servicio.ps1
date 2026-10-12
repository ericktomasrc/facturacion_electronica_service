# =============================================================================
# Entrega 2026-10-10 — Portal del receptor, PASO 1 (SERVICIO)
#
# Se ejecuta desde la raíz del servicio:
#   cd "D:\Reyban Consulting\facturacion electronica\facturacion_electronica_service"
#   .\entrega-2026-10-10-paso1-servicio.ps1
#
#   Contratos.cs                ReceptorDto gana `correo` (opcional) y su
#                               comprobación de forma
#   Program.cs                  POST /v1/comprobantes: 400 si el correo no tiene
#                               forma, y lo guarda. GET /v1/emisor: devuelve
#                               certificadoValidoHasta y certificadoDiasParaVencer
#   EndpointsNotas.cs           Lo mismo para notas de crédito y débito
#   RepositorioComprobantes.cs  Guarda el correo en comprobantes.correo_receptor
#                               (columna propia: nunca en el cpe ni en el XML)
#   AlmacenCertificados.cs      VencimientoActivoAsync: solo la fecha del activo
#   migraciones\019_correo_receptor.sql   NUEVO. No se aplica sola
#
# PROTECCIÓN: cada archivo solo se reemplaza si en tu disco sigue IGUAL al del
# .zip del 10 de octubre. Si alguno cambió, NO TOCA NADA. Todo o nada.
# UTF-8 sin BOM, .bak. La migración NO se aplica: se recuerda al final.
# =============================================================================

$ErrorActionPreference = 'Stop'
$raiz = (Get-Location).Path

if (-not (Test-Path (Join-Path $raiz 'Facturacion.Api')) -or -not (Test-Path (Join-Path $raiz 'migraciones'))) {
    Write-Host "No encuentro 'Facturacion.Api' y 'migraciones' aquí ($raiz)." -ForegroundColor Red
    Write-Host "Ejecuta el script desde la raíz del servicio (facturacion_electronica_service). No se tocó nada." -ForegroundColor Red
    exit 1
}

$utf8SinBom = New-Object System.Text.UTF8Encoding $false

function Normalizar([string]$t) { return $t.TrimStart([char]0xFEFF).Replace("`r", '').TrimEnd() }

function Huella([string]$t) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $bytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes((Normalizar $t)))
    return ([System.BitConverter]::ToString($bytes)).Replace('-', '')
}

function Respaldar([string]$completa) {
    $bak = "$completa.bak"
    if (Test-Path $bak) { $bak = "$completa.$(Get-Date -Format 'yyyyMMdd-HHmmss').bak" }
    Copy-Item $completa $bak -Force
    return (Split-Path $bak -Leaf)
}

$plan = New-Object System.Collections.Generic.List[object]

# Una ruta que empieza por '*' se busca por nombre dentro de reyban_plataforma_web\src.
function Planear([string]$ruta, [string]$esperada, [string]$texto) {
    $texto = $texto.Replace("`r", '')
    if ($ruta.StartsWith('*')) {
        $nombre = $ruta.Substring(1)
        $hallados = @(Get-ChildItem -Path (Join-Path $raiz 'reyban_plataforma_web\src') -Recurse -Filter $nombre -File |
            Where-Object { $_.FullName -notmatch '\\node_modules\\' })
        if ($hallados.Count -ne 1) {
            $plan.Add([pscustomobject]@{ Ruta = $nombre; Accion = 'conflicto'; Motivo = "lo encuentro $($hallados.Count) veces dentro de reyban_plataforma_web\src. Dime cuál es." })
            return
        }
        $completa = $hallados[0].FullName
        $ruta = $completa.Substring($raiz.Length).TrimStart('\')
    }
    else { $completa = Join-Path $raiz $ruta }

    $accion = ''; $motivo = ''; $crlf = $false
    if (-not (Test-Path $completa)) {
        if ($esperada -eq '') { $accion = 'nuevo' }
        else { $accion = 'conflicto'; $motivo = 'no existe. ¿Está en otra carpeta?' }
    }
    else {
        $actual = [System.IO.File]::ReadAllText($completa)
        $crlf = $actual.Contains("`r`n")
        if ((Normalizar $actual) -eq (Normalizar $texto)) { $accion = 'igual' }
        elseif ((Huella $actual) -ne $esperada) { $accion = 'conflicto'; $motivo = 'cambió desde que me lo pasaste. Pásamelo de nuevo.' }
        else { $accion = 'reemplazar' }
    }
    $plan.Add([pscustomobject]@{ Ruta = $ruta; Completa = $completa; Accion = $accion; Motivo = $motivo; Texto = $texto; Crlf = $crlf })
}

# --- Facturacion.Api\Contratos.cs
Planear 'Facturacion.Api\Contratos.cs' 'D1866399A19AD654ED4FA597FD450D31278F8D0ECCE44CDC2C96F8388C757EC0' @'
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
'@

# --- Facturacion.Api\Program.cs
Planear 'Facturacion.Api\Program.cs' 'AD2C0AA6AF091C9065FBAD9A85E5C69EC1291D940671A4221F6BCEAEA41940F3' @'
using System.ComponentModel.DataAnnotations;
using System.Text.Json;
using Facturacion.Api;
using Facturacion.Cpe;
using Facturacion.Persistencia;
using Microsoft.OpenApi.Models;

// Los secretos se leen del entorno, no de appsettings.json.
//
// En desarrollo vienen de un archivo .env en la raíz de la solución, que
// está en el .gitignore. En producción los pone el contenedor o el gestor
// de secretos, y este código no cambia.
ConfiguracionSecretos.CargarArchivoEnv();

var builder = WebApplication.CreateBuilder(args);

// --- Servicios -------------------------------------------------------------

var cadenaConexion = ConfiguracionSecretos.CadenaPostgres(
    "facturacion_app", "FACTURACION_APP_PASSWORD",
    "la conexión de la aplicación, sujeta a Row Level Security");

// El diagnóstico mira TODAS las empresas, así que usa el rol de operador.
// Es una vista de infraestructura, no de cliente, y por eso su endpoint
// está protegido con una clave distinta.
var cadenaOperador = ConfiguracionSecretos.CadenaPostgres(
    "facturacion_operador", "FACTURACION_OPERADOR_PASSWORD",
    "las consultas del panel, que ven todas las empresas");

builder.Services.AddSingleton(new FabricaSesiones(cadenaConexion));
builder.Services.AddSingleton(new RepositorioDiagnostico(cadenaOperador));
builder.Services.AddSingleton<RepositorioTenants>();
builder.Services.AddSingleton<RepositorioComprobantes>();

// ALMACÉN COMPARTIDO CON EL WORKER.
//
// Los dos procesos leen y escriben en el mismo sitio. Con carpetas locales
// eso era frágil: bastaba que cada uno apuntara a una ruta distinta para que
// el worker generara archivos y la API respondiera que no existen.
//
// Con S3 el problema desaparece: ambos apuntan al mismo servidor, y da igual
// desde qué máquina corran.
var opcionesAlmacen = new OpcionesAlmacen();
builder.Configuration.GetSection("Almacen").Bind(opcionesAlmacen);

// Las credenciales del almacén también son secretos.
if (opcionesAlmacen.Tipo.Equals("s3", StringComparison.OrdinalIgnoreCase))
{
    opcionesAlmacen.Usuario = ConfiguracionSecretos.Exigir(
        "ALMACEN_USUARIO", "el acceso al almacén de comprobantes");

    opcionesAlmacen.Clave = ConfiguracionSecretos.Exigir(
        "ALMACEN_CLAVE", "el acceso al almacén de comprobantes");
}

builder.Services.AddSingleton(opcionesAlmacen);
builder.Services.AddSingleton(FabricaAlmacen.Crear(opcionesAlmacen));

// Administración de empresas, series y claves.
builder.Services.AddSingleton(new RepositorioAdmin(cadenaOperador));
builder.Services.AddSingleton(new RepositorioWebhooks(cadenaOperador));
builder.Services.AddSingleton(new RepositorioConsultas(cadenaOperador));
builder.Services.AddSingleton(new RepositorioRoles(cadenaOperador));

// Las guías tienen su propio repositorio: otra tabla, otro canal y otro
// ritmo de reintentos.
builder.Services.AddSingleton(proveedor =>
    new RepositorioGuias(
        proveedor.GetRequiredService<FabricaSesiones>(),
        cadenaOperador));

// La baja escribe en la misma tabla que los resúmenes, con tipo 'RA'.
builder.Services.AddSingleton(proveedor =>
    new RepositorioBajas(
        proveedor.GetRequiredService<FabricaSesiones>(),
        cadenaOperador));

// --- Correo ----------------------------------------------------------------
//
// Las credenciales son secretos y salen del .env, como todo lo demás. Si no
// están configuradas, el sistema funciona igual: los correos simplemente no
// se envían y queda constancia en el log.
var opcionesCorreo = new OpcionesCorreo
{
    Host = ConfiguracionSecretos.Opcional("MAIL_HOST", ""),
    Puerto = int.TryParse(
        ConfiguracionSecretos.Opcional("MAIL_PORT", "587"), out var puertoCorreo)
        ? puertoCorreo : 587,
    Usuario = ConfiguracionSecretos.Opcional("MAIL_USUARIO", ""),
    Clave = ConfiguracionSecretos.Opcional("MAIL_CLAVE", ""),
    Desde = ConfiguracionSecretos.Opcional("MAIL_DESDE", ""),
    Nombre = ConfiguracionSecretos.Opcional("MAIL_NOMBRE", "Facturación electrónica"),
    UrlPanel = ConfiguracionSecretos.Opcional("PANEL_URL", "https://localhost:7295")
};

builder.Services.AddSingleton(opcionesCorreo);
builder.Services.AddSingleton<ServicioCorreo>();

// El repositorio de usuarios necesita el protector para cifrar el secreto
// del segundo factor, igual que los certificados.
builder.Services.AddSingleton(proveedor =>
    new RepositorioUsuarios(
        cadenaOperador,
        proveedor.GetRequiredService<IProtectorDeSecretos>()));

// El operador de cada petición. Con ámbito de petición, como el emisor.
builder.Services.AddScoped<ContextoOperador>();

// La API necesita la llave maestra porque cifra los certificados al cargarlos.
// Si falta la variable de entorno, el proceso no arranca: es preferible a
// descubrirlo cuando alguien intente subir un certificado.
builder.Services.AddSingleton<IProtectorDeSecretos>(_ => ProtectorAesGcm.DesdeEntorno());
builder.Services.AddSingleton<AlmacenCertificados>();

// El panel necesita comprobar si una empresa está lista para producción.
builder.Services.AddSingleton(proveedor =>
    new ProveedorCredenciales(
        cadenaOperador,
        proveedor.GetRequiredService<IProtectorDeSecretos>()));

// Con ámbito de petición: cada llamada tiene su propio emisor.
builder.Services.AddScoped<ContextoEmisor>();

builder.Services.ConfigureHttpJsonOptions(opciones =>
{
    opciones.SerializerOptions.PropertyNamingPolicy = JsonNamingPolicy.CamelCase;
    opciones.SerializerOptions.DefaultIgnoreCondition =
        System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull;
});

// --- Documentación interactiva ---------------------------------------------
//
// Swagger sirve para dos cosas distintas, y la segunda importa más:
//
//   1. Probar la API sin escribir un cliente.
//   2. Ser el contrato que le entregas a quien integra. Cuando un cliente
//      pregunte "¿qué campos acepta?", la respuesta es una URL, no un correo
//      con un ejemplo que quedará desactualizado.
//
// En producción conviene protegerlo o desactivarlo: expone la forma completa
// de la API a cualquiera que la alcance.

builder.Services.AddEndpointsApiExplorer();

builder.Services.AddSwaggerGen(opciones =>
{
    opciones.SwaggerDoc("v1", new OpenApiInfo
    {
        Title = "Servicio de facturación electrónica",
        Version = "v1",
        Description =
            "Emisión de comprobantes electrónicos para SUNAT.\n\n" +
            "Toda petición requiere una clave de acceso.\n\n" +
            "**Emisión y consulta** (`/v1/*`): la clave determina qué empresa " +
            "emite, así que el RUC del emisor NO se envía en el cuerpo. " +
            "En Authorize, campo `ApiKey`, escribe `Bearer` seguido de la " +
            "clave que se le entregó a esa empresa.\n\n" +
            "**Administración** (`/admin/*`): se entra con usuario y " +
            "contraseña desde el panel, y la sesión viaja en una cookie.\n\n" +
            "Ninguna clave aparece en esta documentación a propósito: si " +
            "estuviera aquí, estaría también en el repositorio."
    });

    // DOS ESQUEMAS DE AUTENTICACIÓN, Y ES A PROPÓSITO.
    //
    // Los emisores usan su clave en Authorization: Bearer. El panel usa
    // sesión con cookie, que el navegador envía sola.
    //
    // Declarar el primero en Swagger no es un detalle cosmético: sin él,
    // probar la API obligaría a escribir comandos a mano, y eso hace que se
    // pruebe menos.

    opciones.AddSecurityDefinition("ApiKey", new OpenApiSecurityScheme
    {
        Name = "Authorization",
        Type = SecuritySchemeType.ApiKey,
        In = ParameterLocation.Header,
        Description =
            "Clave del EMISOR. Escribe: Bearer {tu clave}\n\n" +
            "Sirve para /v1/*: emitir comprobantes, guías y consultarlos.",
        Scheme = "Bearer"
    });

    opciones.AddSecurityRequirement(new OpenApiSecurityRequirement
    {
        {
            new OpenApiSecurityScheme
            {
                Reference = new OpenApiReference
                {
                    Type = ReferenceType.SecurityScheme,
                    Id = "ApiKey"
                }
            },
            Array.Empty<string>()
        }
    });
});

var app = builder.Build();

// Comprobar el almacén AL ARRANCAR, no al primer uso.
//
// Descubrir que la configuración está mal cuando un cliente emite su primera
// factura es mucho peor que descubrirlo al encender el servicio.
if (app.Services.GetRequiredService<IAlmacenArchivos>() is AlmacenArchivosS3 almacenS3)
{
    var mensaje = await almacenS3.ComprobarAsync();
    app.Logger.LogInformation("{Mensaje}", mensaje);
}

// --- Middleware ------------------------------------------------------------

if (app.Environment.IsDevelopment())
{
    app.UseSwagger();

    app.UseSwaggerUI(opciones =>
    {
        opciones.SwaggerEndpoint("/swagger/v1/swagger.json", "Facturación v1");

        opciones.RoutePrefix = "docs";
        opciones.DocumentTitle = "Facturación electrónica";
    });
}

// Aviso si el correo no está configurado.
//
// No impide arrancar: el sistema funciona sin correo. Pero conviene saberlo
// antes de que alguien pida recuperar su contraseña y no le llegue nada.
if (!opcionesCorreo.Configurado)
{
    app.Logger.LogWarning(
        "El correo NO está configurado. La recuperación de contraseña y los " +
        "avisos no se enviarán. Rellena MAIL_HOST, MAIL_DESDE y las demás " +
        "variables en el .env.");
}

// Primer administrador, si todavía no hay ninguno.
//
// Sin usuarios no se puede entrar al panel, y sin entrar no se pueden crear
// usuarios. Alguien tiene que romper ese círculo, y es este arranque.
{
    var usuarios = app.Services.GetRequiredService<RepositorioUsuarios>();

    var correo = ConfiguracionSecretos.Opcional(
        "ADMIN_CORREO", "admin@localhost");

    var provisional = await usuarios.AsegurarPrimerAdministradorAsync(
        correo,
        Environment.GetEnvironmentVariable("ADMIN_CONTRASENA"));

    if (provisional is not null)
    {
        app.Logger.LogWarning(
            "PRIMER ADMINISTRADOR CREADO.\n" +
            "  Correo:     {Correo}\n" +
            "  Contraseña: {Clave}\n" +
            "Se pedirá cambiarla al entrar. Este mensaje NO se repite: " +
            "anótala ahora.",
            correo, provisional);
    }
}

// Sirve el panel desde wwwroot.
app.UseDefaultFiles();
app.UseStaticFiles();

// Registra en la bitácora toda acción que modifique algo.
app.UseMiddleware<AuditoriaPanel>();

app.UseMiddleware<AutenticacionApiKey>();

// --- Endpoints -------------------------------------------------------------

app.MapearSesion();
app.MapearRoles();
app.MapearDiagnostico();
app.MapearAdministracion();
app.MapearWebhooks();
app.MapearConsultas();
app.MapearNotas();
app.MapearDescargas();
app.MapearGuias();
app.MapearLiquidaciones();
app.MapearRetencionPercepcion();
app.MapearBajas();
app.MapearAnulacionBoletas();
app.MapearEstadoSunat();

app.MapGet("/health", () => Results.Ok(new { estado = "vivo" }))
   .WithName("Salud")
   .WithTags("Servicio")
   .WithSummary("Comprueba que el servicio responde. No requiere clave.");

// La raíz lleva al panel.
//
// Devolver un JSON informativo era cómodo para desarrollar y confuso para
// quien llega desde un correo: ve un texto técnico y no sabe qué hacer.
app.MapGet("/", () => Results.Redirect("/login.html"))
   .ExcludeFromDescription();


/// Emite un comprobante.
///
/// Responde 202 Accepted: el comprobante quedó registrado, pero TODAVÍA NO
/// fue a SUNAT. Eso lo hará el worker. Esperar aquí a SUNAT dejaría la
/// petición colgada varios segundos y el sistema caería cuando SUNAT caiga.
app.MapPost("/v1/comprobantes", async (
    PeticionComprobante peticion,
    HttpContext contexto,
    ContextoEmisor emisor,
    RepositorioComprobantes repositorio,
    ILogger<Program> registro,
    CancellationToken ct) =>
{
    var tenant = emisor.Exigir();

    // --- Validación del contrato ---
    var errores = new List<ValidationResult>();

    if (!Validator.TryValidateObject(
            peticion, new ValidationContext(peticion), errores, validateAllProperties: true))
    {
        return Results.BadRequest(new RespuestaError(
            "La petición no es válida.",
            string.Join(" ", errores.Select(e => e.ErrorMessage))));
    }

    if (peticion.Lineas.Count == 0)
        return Results.BadRequest(new RespuestaError(
            "El comprobante necesita al menos una línea."));

    // El correo del receptor es opcional, pero si viene tiene que tener forma
    // de correo: un comprobante aceptado cuyo correo rebota es un cliente que
    // cree que no le facturaron.
    if (peticion.Receptor.ProblemaCorreo() is { } problemaCorreo)
        return Results.BadRequest(new RespuestaError(
            "El correo del receptor no es válido.", problemaCorreo));

    if (peticion.Moneda != "PEN" && peticion.TipoCambio is null)
        return Results.BadRequest(new RespuestaError(
            "Falta el tipo de cambio.",
            "Los comprobantes en moneda distinta de PEN deben declararlo."));

    // La detracción solo existe en facturas.
    //
    // SUNAT no la admite en boletas porque no dan crédito fiscal, y el
    // sistema de detracciones está pensado para operaciones que sí lo dan.
    if (peticion.Detraccion is not null && peticion.Tipo != TipoComprobante.Factura)
    {
        return Results.BadRequest(new RespuestaError(
            "La detracción solo aplica a facturas.",
            "SUNAT no admite detracción en comprobantes que no dan crédito " +
            "fiscal, como las boletas."));
    }

    // Los anticipos, de momento, solo en facturas.
    //
    // SUNAT sí los admite en boletas, pero las boletas viajan por resumen
    // diario, que es otro formato con sus propias reglas y que no hemos
    // probado con anticipos. Rechazarlo es más honesto que aceptarlo y
    // emitir un comprobante donde el anticipo no aparece por ningún lado.
    if (peticion.Anticipos.Count > 0 && peticion.Tipo != TipoComprobante.Factura)
    {
        return Results.BadRequest(new RespuestaError(
            "Los anticipos solo están implementados en facturas.",
            "Las boletas viajan por resumen diario, y ese camino todavía no " +
            "declara anticipos."));
    }

    // La percepción, por lo mismo que los anticipos.
    if (peticion.Percepcion is not null && peticion.Tipo != TipoComprobante.Factura)
    {
        return Results.BadRequest(new RespuestaError(
            "La percepción solo está implementada en facturas.",
            "Las boletas viajan por resumen diario, y ese camino todavía no " +
            "declara percepción."));
    }

    // Las cuotas de crédito, lo mismo.
    //
    // SUNAT solo las exige cuando el receptor tiene RUC, y una boleta nunca
    // lo tiene, así que en rigor no harían falta. Pero el resumen diario no
    // las declara, y aceptarlas para después perderlas es peor que decir
    // que no están.
    if (peticion.Cuotas.Count > 0 && peticion.Tipo != TipoComprobante.Factura)
    {
        return Results.BadRequest(new RespuestaError(
            "Las cuotas de crédito solo están implementadas en facturas.",
            "Las boletas viajan por resumen diario, y ese formato no declara " +
            "cuotas."));
    }

    // --- Construcción del comprobante ---
    // El emisor sale del tenant, NUNCA de la petición.

    ComprobanteBase comprobante;

    try
    {
        comprobante = ConstruirComprobante(peticion, tenant);
    }
    catch (ArgumentException ex)
    {
        return Results.BadRequest(new RespuestaError("Datos inválidos.", ex.Message));
    }

    // LOS AVISOS DE PLAZO NO BLOQUEAN, PERO TIENEN QUE VERSE.
    //
    // Facturar el lunes una venta del sábado es legítimo y frecuente. Lo que
    // no puede pasar es que nadie sepa que ese comprobante vence hoy, porque
    // si el envío falla no hay segunda oportunidad: SUNAT lo rechaza con el
    // 2108 y queda emitido sin declarar.
    foreach (var aviso in ReglasFechaEmision.Avisos(comprobante)
                 .Concat(ReglasIsc.Avisos(comprobante))
                 .Concat(comprobante is Factura fx
                     ? ReglasHidrobiologicos.Revisar(fx)
                         .Where(p => p.StartsWith("Aviso:"))
                     : []))
        registro.LogWarning("{Serie}: {Aviso}", peticion.Serie, aviso);


    // --- Los anticipos tienen que existir de verdad ---
    //
    // SUNAT valida esto con las reglas 3218 y 3219, pero solo en producción:
    // en beta su listado de comprobantes está vacío y acepta cualquier
    // número inventado. Lo comprobamos aquí mientras el anticipo lo haya
    // emitido este mismo contribuyente, que es el caso normal.
    //
    // Si lo emitió otro RUC, SUNAT admite el caso y nosotros no tenemos
    // forma de verificarlo: se deja pasar y que decida SUNAT.

    foreach (var anticipo in peticion.Anticipos)
    {
        if (anticipo.RucEmisor != tenant.Ruc) continue;

        var partes = (anticipo.Numero ?? "").Split('-');

        if (partes.Length != 2 || !int.TryParse(partes[1], out var correlativoPrevio))
        {
            return Results.BadRequest(new RespuestaError(
                "El número del comprobante de anticipo no es válido.",
                $"'{anticipo.Numero}' debería tener la forma SERIE-CORRELATIVO."));
        }

        // CATÁLOGO 12 → CATÁLOGO 01, Y NO SON EL MISMO NÚMERO.
        //
        // En el bloque de anticipos, "02" significa factura. En nuestra base
        // la factura es "01". Buscar por "02" no encontraría nada, y el
        // error acusaría al usuario de algo que hizo bien.
        var tipoEnLaBase = anticipo.TipoComprobante == TipoComprobanteAnticipo.Factura
            ? TipoComprobante.Factura
            : TipoComprobante.Boleta;

        var previo = await repositorio.BuscarPorNumeroAsync(
            tenant.Id, tipoEnLaBase, partes[0], correlativoPrevio, ct);

        if (previo is null)
        {
            return Results.BadRequest(new RespuestaError(
                "El comprobante del anticipo no existe.",
                $"No se encontró {anticipo.Numero} entre los comprobantes de " +
                "este emisor. SUNAT lo rechazaría con el error 3218."));
        }

        if (previo.Estado is not ("ACEPTADO" or "ACEPTADO_CON_OBSERVACIONES"))
        {
            return Results.BadRequest(new RespuestaError(
                "El comprobante del anticipo todavía no fue aceptado.",
                $"{anticipo.Numero} está en estado {previo.Estado}. Solo se " +
                "puede descontar un anticipo que SUNAT ya aceptó (error 3219)."));
        }

        if (previo.Moneda != peticion.Moneda)
        {
            return Results.BadRequest(new RespuestaError(
                "El anticipo está en otra moneda.",
                $"{anticipo.Numero} se emitió en {previo.Moneda} y esta factura " +
                $"está en {peticion.Moneda}. SUNAT exige la misma moneda en " +
                "todo el documento."));
        }

        // SE PUEDE DESCONTAR MENOS, NUNCA MÁS.
        //
        // Aplicar solo una parte del anticipo es legítimo: un adelanto grande
        // puede repartirse entre dos entregas. Declarar más de lo que aquella
        // factura cobró no lo es nunca.
        //
        // Esta comprobación atrapa de paso el error más común del módulo:
        // mandar el monto SIN IGV. Como sale un 18% por debajo, no salta
        // aquí — pero si alguien manda el valor con IGV de una factura que
        // no lo llevaba, sí.
        if (anticipo.MontoTotal > previo.ImporteTotal)
        {
            return Results.BadRequest(new RespuestaError(
                "El anticipo declara más de lo que su factura cobró.",
                $"{anticipo.Numero} se emitió por {previo.ImporteTotal:0.00} y " +
                $"aquí se declaran {anticipo.MontoTotal:0.00}."));
        }
    }

    // --- Persistencia ---

    var idempotencyKey = contexto.Request.Headers["Idempotency-Key"].ToString();

    try
    {
        var guardado = await repositorio.CrearAsync(
            tenant.Id,
            comprobante,
            extraJson: peticion.Extra is null
                ? null
                : JsonSerializer.Serialize(peticion.Extra),
            idempotencyKey: string.IsNullOrWhiteSpace(idempotencyKey) ? null : idempotencyKey,
            correoReceptor: peticion.Receptor.CorreoLimpio(),
            ct: ct);

        var respuesta = RespuestaComprobante.Desde(guardado, peticion.Moneda);

        // Si la clave de idempotencia ya se había usado, no se creó nada:
        // se devuelve el comprobante original con 200, no con 202.
        return guardado.YaExistia
            ? Results.Ok(respuesta)
            : Results.Accepted($"/v1/comprobantes/{guardado.Id}", respuesta);
    }
    catch (InvalidOperationException ex)
    {
        // Serie inexistente o inactiva.
        return Results.BadRequest(new RespuestaError("No se pudo emitir.", ex.Message));
    }
})
.WithName("EmitirComprobante")
.WithTags("Comprobantes")
.WithSummary("Emite una factura o boleta")
.WithDescription(
    "Responde 202: el comprobante queda registrado, pero todavía NO fue a SUNAT. " +
    "Eso lo hace el worker.\n\n" +
    "Envía la cabecera Idempotency-Key para que un reintento no produzca un duplicado: " +
    "si la clave ya se usó, responde 200 con el comprobante original.\n\n" +
    "**Detracción:** si la operación está sujeta al SPOT, incluye el objeto " +
    "`detraccion`. El monto se calcula solo si no lo envías.\n\n" +
    "**Percepción:** solo si el emisor es agente de percepción designado, y " +
    "solo al contado. El importe total del comprobante sale SIN percepción: " +
    "el total con percepción viaja en un bloque aparte del XML.\n\n" +
    "**Crédito:** si la forma de pago es `Credito` y el receptor tiene RUC, " +
    "hay que enviar al menos una cuota en `cuotas`, con su monto y su fecha " +
    "de vencimiento. SUNAT lo exige desde 2022.\n\n" +
    "**Operaciones gratuitas:** lo que se entrega sin cobrar va en su propia " +
    "línea, con su valor referencial en `valorUnitario` y el código que " +
    "corresponda en `tipoAfectacionIgv` — el más habitual es `15`, " +
    "bonificaciones. No suman al importe total: el cliente paga lo mismo. " +
    "El IGV de esas líneas sí se declara, y lo asume el emisor.\n\n" +
    "**Cargos y descuentos globales:** en `cargosGlobales`, con el código " +
    "del catálogo 53 — `50` cargo, `03` descuento, `45` FISE, `46` recargo " +
    "al consumo. Esos cuatro no generan IGV ni entran en el valor de venta: " +
    "solo mueven el importe a pagar.\n\n" +
    "El `49` es la excepción: SÍ se suma a la base imponible y genera su " +
    "propio IGV. Para un descuento que reduzca el IGV, usa " +
    "`descuentoGlobalPorcentaje`.\n\n" +
    "**Detracción de pesca:** con `tipoOperacion` `1002` y código de bien " +
    "`004`, hay que enviar el bloque `hidrobiologicos` con los seis datos " +
    "del desembarque. SUNAT los cruza contra el parte de descarga.\n\n" +
    "**Retenciones:** `62` retención del IGV, que es informativa y no mueve " +
    "el importe total; `63` retención de renta de segunda categoría, que sí " +
    "resta. La `62` necesita `baseImponible` y `porcentaje`.\n\n" +
    "**ICBPER:** las bolsas de plástico van en su propia línea con " +
    "`afectoIcbper: true`. La cantidad de esa línea es el número de bolsas. " +
    "La tasa sale sola de la fecha de emisión —0.50 soles por bolsa desde " +
    "2023— y este impuesto SÍ sube el importe total.\n\n" +
    "**IVAP (arroz pilado):** afectación `17` en las líneas. Sustituye al " +
    "IGV con una tasa del 4%, y es excluyente: si una línea lo lleva, todas " +
    "tienen que llevarlo. No hace falta enviar `porcentajeIgv`.\n\n" +
    "**Plazo:** SUNAT da 3 días calendario para que una factura le llegue, " +
    "y 7 para una boleta. Pasado el plazo la rechaza con el error 2108 y el " +
    "correlativo se pierde, así que una petición con `fechaEmision` vencida " +
    "se rechaza aquí mismo.\n\n" +
    "**ISC:** en la línea, con `sistemaIsc` (catálogo 08) y `tasaIsc`. " +
    "A diferencia de los demás impuestos, el ISC **entra en la base del " +
    "IGV**: con 1000 de valor y 10% de ISC, el IGV sale sobre 1100.")
.Produces<RespuestaComprobante>(StatusCodes.Status202Accepted)
.Produces<RespuestaComprobante>(StatusCodes.Status200OK)
.Produces<RespuestaError>(StatusCodes.Status400BadRequest)
.Produces<RespuestaError>(StatusCodes.Status401Unauthorized);


/// Estado de un comprobante.
app.MapGet("/v1/comprobantes/{id:guid}", async (
    Guid id,
    ContextoEmisor emisor,
    RepositorioComprobantes repositorio,
    CancellationToken ct) =>
{
    var tenant = emisor.Exigir();

    var comprobante = await repositorio.ObtenerAsync(tenant.Id, id, ct);

    // Si el comprobante es de otra empresa, Row Level Security hace que
    // simplemente no exista para esta consulta. El 404 es correcto y además
    // no revela que el identificador pertenece a alguien más.
    return comprobante is null
        ? Results.NotFound(new RespuestaError("No se encontró el comprobante."))
        : Results.Ok(RespuestaEstado.Desde(comprobante));
})
.WithName("ConsultarComprobante")
.WithTags("Comprobantes")
.WithSummary("Estado de un comprobante")
.Produces<RespuestaEstado>()
.Produces<RespuestaError>(StatusCodes.Status404NotFound);


/// Lista los comprobantes del emisor.
app.MapGet("/v1/comprobantes", async (
    ContextoEmisor emisor,
    RepositorioComprobantes repositorio,
    int? limite,
    CancellationToken ct) =>
{
    var tenant = emisor.Exigir();

    var comprobantes = await repositorio.ListarAsync(
        tenant.Id, Math.Clamp(limite ?? 50, 1, 200), ct);

    return Results.Ok(comprobantes.Select(RespuestaEstado.Desde));
})
.WithName("ListarComprobantes")
.WithTags("Comprobantes")
.WithSummary("Lista los comprobantes del emisor")
.Produces<IEnumerable<RespuestaEstado>>();


/// Historial de intentos de un comprobante.
app.MapGet("/v1/comprobantes/{id:guid}/historial", async (
    Guid id,
    ContextoEmisor emisor,
    RepositorioComprobantes repositorio,
    CancellationToken ct) =>
{
    var tenant = emisor.Exigir();

    var historial = await repositorio.HistorialAsync(tenant.Id, id, ct);

    return Results.Ok(historial.Select(i => new
    {
        intento = i.IntentoNro,
        desde = i.EstadoAnterior,
        hasta = i.EstadoNuevo,
        codigoSunat = i.CodigoSunat,
        mensaje = i.Mensaje,
        duracionMs = i.DuracionMs,
        fecha = i.CreadoEn
    }));
})
.WithName("HistorialComprobante")
.WithTags("Comprobantes")
.WithSummary("Bitácora de un comprobante")
.WithDescription(
    "Cada cambio de estado, con su código de SUNAT y su duración. " +
    "La bitácora es append-only: nunca se modifica ni se borra.");


/// Datos del emisor autenticado. Útil para verificar que la clave funciona.
app.MapGet("/v1/emisor", async (
    ContextoEmisor emisor, AlmacenCertificados certificados, CancellationToken ct) =>
{
    var tenant = emisor.Exigir();

    // EL VENCIMIENTO DEL CERTIFICADO, para que quien integra avise antes.
    //
    // El dato existía, pero solo en `/admin/tenants/{id}/certificados`, que va
    // con la sesión del panel y cruza empresas: nadie de fuera puede ni debe
    // usar esa ruta. Aquí sale solo la fecha del activo de ESTA empresa.
    // Null si no tiene certificado cargado.
    var validoHasta = await certificados.VencimientoActivoAsync(tenant.Id, ct);

    return Results.Ok(new
    {
        ruc = tenant.Ruc,
        razonSocial = tenant.RazonSocial,
        ambiente = tenant.Ambiente,
        certificadoValidoHasta = validoHasta,
        certificadoDiasParaVencer = validoHasta is { } h
            ? (int?)Math.Ceiling((h - DateTime.UtcNow).TotalDays)
            : null
    });
})
.WithName("Emisor")
.WithTags("Servicio")
.WithSummary("Datos del emisor autenticado")
.WithDescription("Sirve para verificar que una clave de acceso funciona.");

app.Run();


// ---------------------------------------------------------------------------

static ComprobanteBase ConstruirComprobante(
    PeticionComprobante peticion, TenantResuelto tenant)
{
    var emisor = new Emisor
    {
        Ruc = tenant.Ruc,
        RazonSocial = tenant.RazonSocial,
        NombreComercial = tenant.NombreComercial,
        Ubigeo = tenant.Ubigeo,
        Direccion = tenant.Direccion,
        Distrito = tenant.Distrito,
        Provincia = tenant.Provincia,
        Departamento = tenant.Departamento
    };

    var receptor = new Receptor
    {
        TipoDocumento = peticion.Receptor.TipoDocumento,
        NumeroDocumento = peticion.Receptor.NumeroDocumento,
        RazonSocial = peticion.Receptor.RazonSocial,
        Direccion = peticion.Receptor.Direccion
    };

    // EL RECEPTOR SE REVISA LO PRIMERO, y antes de gastar un correlativo.
    //
    // Un RUC con el digito verificador cambiado no existe, y la factura
    // emitida a ese numero hay que anularla con una nota de credito. Eso
    // cuesta mas que este if.
    var problemasReceptor = ReglasReceptor.Errores(receptor);

    if (problemasReceptor.Count > 0)
        throw new ArgumentException(string.Join(" ", problemasReceptor));

    if (peticion.Tipo == TipoComprobante.Factura &&
    !TipoOperacion.EsExportacion(peticion.TipoOperacion ?? "") &&
    receptor.TipoDocumento != TipoDocIdentidad.Ruc)
    {
        throw new ArgumentException(
            $"Una factura solo se puede emitir a un RUC, y el receptor llego " +
            $"con documento de tipo '{receptor.TipoDocumento}'. Si el cliente " +
            $"no tiene RUC, el documento que le corresponde es una boleta de " +
            $"venta (tipo 03). La unica factura que admite otro documento es " +
            $"la de exportacion, y esa se declara con tipo de operacion " +
            $"0200-0208.");
    }

    var lineas = peticion.Lineas.Select((l, indice) => new LineaComprobante
    {
        Numero = indice + 1,
        CodigoProducto = l.CodigoProducto,
        Descripcion = l.Descripcion,
        UnidadMedida = l.UnidadMedida,
        Cantidad = l.Cantidad,
        ValorUnitario = l.ValorUnitario,
        DescuentoPorcentaje = l.DescuentoPorcentaje,
        TipoAfectacionIgv = l.TipoAfectacionIgv,
        PorcentajeIgv = l.PorcentajeIgv
            ?? AfectacionIgv.TasaPorDefecto(l.TipoAfectacionIgv),
        AfectoIcbper = l.AfectoIcbper,
        IcbperUnitario = l.IcbperUnitario,
        SistemaIsc = l.SistemaIsc,
        TasaIsc = l.TasaIsc
    }).ToList();

    // --- Que un dedazo en la afectación dé 400 y no 500 ---------------------
    //
    // Un "1O" con la letra O en vez del cero llegaba hasta el cálculo de
    // totales y reventaba allí con una excepción interna: el cliente de la
    // API recibía "error del servidor" y no tenía forma de saber qué había
    // puesto mal.
    //
    // Con quince códigos válidos en el catálogo 07 —los cuatro de siempre
    // más las once gratuitas— el dedazo ya no es raro.

    var afectacionesRaras = lineas
        .Where(l => !AfectacionIgv.Existe(l.TipoAfectacionIgv))
        .Select(l => $"la linea {l.Numero} llego con '{l.TipoAfectacionIgv}'")
        .ToList();

    if (afectacionesRaras.Count > 0)
    {
        throw new ArgumentException(
            "Hay afectaciones de IGV que no existen en el catalogo 07: " +
            $"{string.Join(", ", afectacionesRaras)}.");
    }

    var tipoCambio = peticion.TipoCambio is null ? null : new TipoCambio
    {
        MonedaOrigen = peticion.TipoCambio.MonedaOrigen,
        MonedaDestino = peticion.TipoCambio.MonedaDestino,
        Tasa = peticion.TipoCambio.Tasa,
        Fecha = peticion.TipoCambio.Fecha ?? RelojPeru.Hoy
    };

    var fecha = peticion.FechaEmision ?? RelojPeru.Ahora;

    // LA FACTURA SE CONSTRUYE APARTE porque puede llevar detracción, y eso
    // no cabe en un inicializador: el monto depende de los totales, y los
    // totales dependen de la factura ya completa.
    if (peticion.Tipo == TipoComprobante.Factura)
    {
        var factura = new Factura
        {
            Serie = peticion.Serie,
            FechaEmision = fecha,
            Moneda = peticion.Moneda,
            FormaPago = peticion.FormaPago,
            TipoOperacion = peticion.TipoOperacion,
            PaisDeUso = peticion.PaisDeUso,
            Drawback = peticion.Drawback,
            DescuentoGlobalPorcentaje = peticion.DescuentoGlobalPorcentaje,
            TipoCambio = tipoCambio,
            Emisor = emisor,
            Receptor = receptor,
            Lineas = lineas
        };

        // LOS CARGOS GLOBALES VAN LOS PRIMEROS, y el orden no es casual:
        // cambian el importe total, y la detracción, la percepción y las
        // cuotas se comprueban todas contra ese importe. Copiarlos después
        // haría que esas tres miraran un total que ya no es el final.
        factura.CargosGlobales = MapearCargosGlobales(peticion);

        // Las cuotas se copian antes que nada: la revisión de crédito mira
        // los totales, y los totales no cambian por las cuotas, pero sí las
        // demás revisiones miran la factura entera.
        factura.Cuotas = peticion.Cuotas.Select(c => new CuotaCredito
        {
            Numero = c.Numero,
            Monto = c.Monto,
            FechaVencimiento = c.FechaVencimiento
        }).ToList();

        if (peticion.Detraccion is not null)
            AplicarDetraccion(factura, peticion.Detraccion);

        // Los anticipos se copian ANTES de revisar nada, porque cambian
        // los totales y las dos revisiones miran totales.
        factura.Anticipos = peticion.Anticipos.Select(a => new Anticipo
        {
            IdentificadorPago = a.IdentificadorPago,
            TipoComprobante = a.TipoComprobante,
            Numero = a.Numero,
            RucEmisor = a.RucEmisor,
            MontoTotal = a.MontoTotal,
            FechaPago = a.FechaPago,
            TipoAfectacion = a.TipoAfectacion,
            PorcentajeIgv = a.PorcentajeIgv
        }).ToList();

        if (peticion.Percepcion is not null)
            AplicarPercepcion(factura, peticion.Percepcion);

        var problemasExportacion = Exportacion.Errores(factura);

        if (problemasExportacion.Count > 0)
            throw new ArgumentException(string.Join(" ", problemasExportacion));

        var problemasAnticipos = ReglasAnticipos.Errores(factura);

        if (problemasAnticipos.Count > 0)
            throw new ArgumentException(string.Join(" ", problemasAnticipos));

        var problemasPercepcion = ReglasPercepcion.Errores(factura);

        if (problemasPercepcion.Count > 0)
            throw new ArgumentException(string.Join(" ", problemasPercepcion));

        var problemasCredito = ReglasCredito.Errores(factura);

        if (problemasCredito.Count > 0)
            throw new ArgumentException(string.Join(" ", problemasCredito));

        // Las líneas gratuitas y los cargos globales se revisan lo mismo que
        // en la boleta de más abajo, y por eso están escritos dos veces en
        // vez de una: la factura sale por su propio return, unas líneas
        // antes de que exista el comprobante genérico.
        var problemasGratuitas = Gratuitas.Errores(factura);

        if (problemasGratuitas.Count > 0)
            throw new ArgumentException(string.Join(" ", problemasGratuitas));

        var problemasCargos = ReglasCargosGlobales.Errores(factura);

        if (problemasCargos.Count > 0)
            throw new ArgumentException(string.Join(" ", problemasCargos));

        var problemasIcbper = ReglasIcbper.Errores(factura);

        if (problemasIcbper.Count > 0)
            throw new ArgumentException(string.Join(" ", problemasIcbper));

        var problemasIvap = ReglasIvap.Errores(factura);

        if (problemasIvap.Count > 0)
            throw new ArgumentException(string.Join(" ", problemasIvap));

        // Los datos del desembarque se copian ANTES de revisar, porque la
        // revision los mira, y se vuelcan en la primera linea: SUNAT solo
        // comprueba que cada codigo exista en el comprobante.
        if (peticion.Hidrobiologicos is { } h)
        {
            factura.Hidrobiologicos = new RecursosHidrobiologicos(
                h.Matricula,
                h.NombreEmbarcacion,
                h.TipoEspecie,
                h.LugarDescarga,
                h.FechaDescarga,
                h.CantidadEspecie);

            if (factura.Lineas.Count > 0)
            {
                factura.Lineas[0].Propiedades =
                    factura.Hidrobiologicos.ComoPropiedades().ToList();
            }
        }

        var problemasHidro = ReglasHidrobiologicos.Errores(factura);

        if (problemasHidro.Count > 0)
            throw new ArgumentException(string.Join(" ", problemasHidro));

        var problemasIsc = ReglasIsc.Errores(factura);

        if (problemasIsc.Count > 0)
            throw new ArgumentException(string.Join(" ", problemasIsc));

        // La fecha, al final: necesita saber el tipo de comprobante, porque
        // el plazo de una factura no es el de una boleta.
        var problemasFecha = ReglasFechaEmision.Errores(factura);

        if (problemasFecha.Count > 0)
            throw new ArgumentException(string.Join(" ", problemasFecha));

        return factura;
    }

    var comprobante = peticion.Tipo switch
    {
        TipoComprobante.Boleta => new Boleta
        {
            Serie = peticion.Serie,
            FechaEmision = fecha,
            Moneda = peticion.Moneda,
            FormaPago = peticion.FormaPago,
            DescuentoGlobalPorcentaje = peticion.DescuentoGlobalPorcentaje,
            TipoCambio = tipoCambio,
            Emisor = emisor,
            Receptor = receptor,
            Lineas = lineas,
            CargosGlobales = MapearCargosGlobales(peticion)
        },

        _ => throw new ArgumentException(
            $"Tipo de comprobante no soportado por este endpoint: {peticion.Tipo}. " +
            "Las notas de crédito y débito tienen su propia ruta.")
    };

    // Una bonificación en una boleta es tan común como en una factura: el
    // "llévate 3 y paga 2" de mostrador va casi siempre a consumidor final.
    //
    // OJO: esto rechaza lo que está mal, pero las boletas todavía viajan por
    // resumen diario y ese camino no declara el total de gratuitas. Hasta
    // que lo haga, las bonificaciones conviene emitirlas en factura.
    var problemasGratuitasBoleta = Gratuitas.Errores(comprobante);

    if (problemasGratuitasBoleta.Count > 0)
        throw new ArgumentException(string.Join(" ", problemasGratuitasBoleta));

    // El recargo al consumo es el caso típico de boleta: un restaurante que
    // cobra el 10% a un consumidor final.
    var problemasCargosBoleta = ReglasCargosGlobales.Errores(comprobante);

    if (problemasCargosBoleta.Count > 0)
        throw new ArgumentException(string.Join(" ", problemasCargosBoleta));

    // EL ICBPER ES, SOBRE TODO, UN ASUNTO DE BOLETAS: grava las bolsas que
    // se entregan a un consumidor final, y el consumidor final compra con
    // boleta. Que funcione aqui importa mas que en la factura.
    var problemasIcbperBoleta = ReglasIcbper.Errores(comprobante);

    if (problemasIcbperBoleta.Count > 0)
        throw new ArgumentException(string.Join(" ", problemasIcbperBoleta));

    var problemasIvapBoleta = ReglasIvap.Errores(comprobante);

    if (problemasIvapBoleta.Count > 0)
        throw new ArgumentException(string.Join(" ", problemasIvapBoleta));

    var problemasIscBoleta = ReglasIsc.Errores(comprobante);

    if (problemasIscBoleta.Count > 0)
        throw new ArgumentException(string.Join(" ", problemasIscBoleta));

    var problemasFechaBoleta = ReglasFechaEmision.Errores(comprobante);

    if (problemasFechaBoleta.Count > 0)
        throw new ArgumentException(string.Join(" ", problemasFechaBoleta));

    return comprobante;
}

/// <summary>
/// Pasa los cargos y descuentos globales del DTO al modelo.
///
/// Está aparte porque lo usan las dos ramas —factura y boleta— y porque
/// duplicar un mapeo es la forma más silenciosa de que un campo nuevo se
/// copie en un sitio y en el otro no.
/// </summary>
static List<CargoGlobal> MapearCargosGlobales(PeticionComprobante peticion) =>
    peticion.CargosGlobales.Select(cg => new CargoGlobal
    {
        Codigo = cg.Codigo,
        Monto = cg.Monto,
        BaseImponible = cg.BaseImponible,
        Porcentaje = cg.Porcentaje,
        Descripcion = cg.Descripcion
    }).ToList();

/// <summary>
/// Añade los datos de detracción a una factura ya construida.
///
/// SE HACE APARTE Y NO EN EL INICIALIZADOR porque necesita los totales, y los
/// totales necesitan la factura completa. Calcularlo todo de una vez obligaría
/// a duplicar aquí la lógica del IGV y los descuentos, que es justo el tipo de
/// duplicación que termina divergiendo.
///
/// Lanza ArgumentException si los datos no sirven, para que el endpoint
/// responda 400 con el motivo en vez de dejar que SUNAT lo rechace después.
/// </summary>
static void AplicarDetraccion(Factura factura, DetraccionDto datos)
{
    var totales = CalculadoraTotales.Calcular(factura);

    factura.Detraccion = new Detraccion(
        datos.TipoOperacion,
        datos.CodigoBienServicio,
        datos.Porcentaje,

        // Si el cliente no manda el monto, se calcula.
        //
        // Es lo habitual: el porcentaje lo sabe, pero el redondeo al entero
        // que hace el Banco de la Nación no tiene por qué conocerlo.
        datos.Monto ?? Detraccion.CalcularMonto(
            totales.ImporteTotal, datos.Porcentaje),

        datos.CuentaBancoNacion,
        datos.MedioDePago);

    var problemas = factura.Detraccion.Revisar(totales.ImporteTotal, factura.Moneda);

    // Los avisos empiezan por "Aviso:" y NO impiden emitir.
    //
    // El del umbral de 700 soles es uno: hay operaciones que se detraen
    // igualmente por acuerdo o régimen especial. Bloquearlo haría que el
    // sistema decidiera por el contribuyente en un asunto que es suyo.
    var errores = problemas.Where(p => !p.StartsWith("Aviso:")).ToList();

    if (errores.Count > 0)
        throw new ArgumentException(string.Join(" ", errores));
}

/// <summary>
/// Añade la percepción a una factura ya construida.
///
/// SE HACE APARTE, como la detracción, porque necesita el importe total y
/// el importe total necesita la factura completa.
///
/// LA BASE VA SIEMPRE EN SOLES. Si la factura está en otra moneda hay que
/// convertirla: SUNAT exige la percepción en moneda nacional aunque todo lo
/// demás del documento esté en dólares. Es la única excepción que admite a
/// "la moneda debe ser la misma en todo el comprobante".
/// </summary>
static void AplicarPercepcion(Factura factura, PercepcionDto datos)
{
    if (!RegimenPercepcion.Existe(datos.Regimen))
    {
        throw new ArgumentException(
            $"El regimen de percepcion '{datos.Regimen}' no existe en el " +
            $"catalogo 22. Solo 01 (venta interna), 02 (combustible) y " +
            $"03 (agente con tasa especial).");
    }

    var totales = CalculadoraTotales.Calcular(factura);

    // El importe total, convertido a soles si hace falta.
    //
    // La tasa que corresponde es la que YA se declaró en este comprobante,
    // no otra consultada aparte: si se usara una distinta, el XML diría dos
    // cosas diferentes sobre el mismo día y el mismo documento.
    var baseEnSoles = factura.Moneda == "PEN"
        ? totales.ImporteTotal
        : CalculadoraTotales.Redondear(
            totales.ImporteTotal * (factura.TipoCambio?.Tasa ?? 0m));

    var porcentaje = datos.Porcentaje
        ?? RegimenPercepcion.TasaReferencia(datos.Regimen);

    factura.Percepcion = new Percepcion(
        datos.Regimen,
        porcentaje,
        baseEnSoles,

        // Si el cliente no manda el monto, se calcula. Es lo habitual: el
        // régimen lo sabe, el redondeo no tiene por qué conocerlo.
        datos.Monto ?? Percepcion.CalcularMonto(baseEnSoles, porcentaje));
}
'@

# --- Facturacion.Api\EndpointsNotas.cs
Planear 'Facturacion.Api\EndpointsNotas.cs' 'C35A845D1B654DB36D24FC036F671A2E01AA3C8D0556E27FE6BAA56676256819' @'
using System.ComponentModel.DataAnnotations;
using System.Text.Json;
using Facturacion.Cpe;
using Facturacion.Persistencia;

namespace Facturacion.Api;

/// <summary>
/// Petición para emitir una nota de crédito o de débito.
///
/// Igual que en la factura, el emisor NO viene aquí: lo determina la clave
/// de acceso. Lo que sí viene, y es obligatorio, es a qué comprobante afecta.
/// </summary>
public class PeticionNota
{
    /// <summary>
    /// Serie de la nota.
    ///
    /// DEBE EMPEZAR CON LA MISMA LETRA del documento que modifica: F para
    /// notas sobre facturas, B para notas sobre boletas. SUNAT lo valida.
    /// </summary>
    [Required]
    public string Serie { get; set; } = "";

    public DateTime? FechaEmision { get; set; }

    public string Moneda { get; set; } = "PEN";

    public TipoCambioDto? TipoCambio { get; set; }

    /// <summary>
    /// Catálogo 09 para notas de crédito, catálogo 10 para las de débito.
    ///
    /// Crédito: 01 anulación, 02 error en el RUC, 03 corrección de descripción,
    /// 04 descuento global, 06 devolución total, 09 disminución en el valor.
    ///
    /// Débito: 01 interés por mora, 02 aumento en el valor, 03 penalidades.
    /// </summary>
    [Required]
    public string CodigoMotivo { get; set; } = "";

    /// <summary>Texto libre. Si se omite, se usa la descripción del catálogo.</summary>
    public string DescripcionMotivo { get; set; } = "";

    [Required]
    public DocumentoAfectadoDto Afectado { get; set; } = new();

    [Required]
    public ReceptorDto Receptor { get; set; } = new();

    [Required]
    [MinLength(1, ErrorMessage = "La nota necesita al menos una línea.")]
    public List<LineaDto> Lineas { get; set; } = [];

    public Dictionary<string, object>? Extra { get; set; }
}

/// <summary>El comprobante al que la nota afecta.</summary>
public class DocumentoAfectadoDto
{
    /// <summary>Catálogo 01. "01" factura, "03" boleta.</summary>
    public string TipoDocumento { get; set; } = TipoComprobante.Factura;

    /// <summary>Serie del documento original. Ej: F001</summary>
    [Required]
    public string Serie { get; set; } = "";

    /// <summary>Correlativo del documento original, sin ceros a la izquierda.</summary>
    [Range(1, int.MaxValue)]
    public int Correlativo { get; set; }

    public string NumeroCompleto => $"{Serie}-{Correlativo:D8}";
}

/// <summary>
/// Emisión de notas de crédito y de débito.
///
/// POR QUÉ SON IMPRESCINDIBLES: una vez que SUNAT acepta un comprobante, no
/// se puede modificar ni borrar. La nota es la única forma de corregir un
/// error, aplicar una devolución o cobrar intereses. Un servicio que solo
/// emite facturas no sirve para operar de verdad: basta un error de digitación
/// el primer día para bloquear al cliente.
/// </summary>
public static class EndpointsNotas
{
    public static void MapearNotas(this WebApplication app)
    {
        var grupo = app.MapGroup("/v1").WithTags("Notas");

        grupo.MapPost("/notas-credito", (
            PeticionNota peticion, HttpContext contexto, ContextoEmisor emisor,
            RepositorioComprobantes repositorio, CancellationToken ct) =>
            Emitir(peticion, contexto, emisor, repositorio, esCredito: true, ct))
            .WithSummary("Emite una nota de crédito")
            .WithDescription(
                "Disminuye o anula un comprobante ya emitido: devoluciones, " +
                "descuentos posteriores, errores en el monto.\\n\\n" +
                "La serie debe empezar con la misma letra del documento que " +
                "modifica: F para notas sobre facturas, B para boletas.")
            .Produces<RespuestaComprobante>(StatusCodes.Status202Accepted)
            .Produces<RespuestaError>(StatusCodes.Status400BadRequest);

        grupo.MapPost("/notas-debito", (
            PeticionNota peticion, HttpContext contexto, ContextoEmisor emisor,
            RepositorioComprobantes repositorio, CancellationToken ct) =>
            Emitir(peticion, contexto, emisor, repositorio, esCredito: false, ct))
            .WithSummary("Emite una nota de débito")
            .WithDescription(
                "Aumenta el importe de un comprobante ya emitido: intereses " +
                "por mora, penalidades, aumento de valor.")
            .Produces<RespuestaComprobante>(StatusCodes.Status202Accepted)
            .Produces<RespuestaError>(StatusCodes.Status400BadRequest);
    }

    private static async Task<IResult> Emitir(
        PeticionNota peticion,
        HttpContext contexto,
        ContextoEmisor emisor,
        RepositorioComprobantes repositorio,
        bool esCredito,
        CancellationToken ct)
    {
        var tenant = emisor.Exigir();

        // --- Validación del contrato ---

        var errores = new List<ValidationResult>();

        if (!Validator.TryValidateObject(
                peticion, new ValidationContext(peticion), errores, true))
        {
            return Results.BadRequest(new RespuestaError(
                "La petición no es válida.",
                string.Join(" ", errores.Select(e => e.ErrorMessage))));
        }

        if (peticion.Lineas.Count == 0)
            return Results.BadRequest(new RespuestaError(
                "La nota necesita al menos una línea."));

        if (peticion.Receptor.ProblemaCorreo() is { } problemaCorreo)
            return Results.BadRequest(new RespuestaError(
                "El correo del receptor no es válido.", problemaCorreo));

        if (peticion.Moneda != "PEN" && peticion.TipoCambio is null)
            return Results.BadRequest(new RespuestaError(
                "Falta el tipo de cambio.",
                "Las notas en moneda distinta de PEN deben declararlo."));

        // --- La serie debe corresponder al documento afectado ---
        //
        // SUNAT valida esto, y el error que devuelve no menciona la serie.
        // Comprobarlo aquí convierte un rechazo desconcertante en un mensaje
        // que dice exactamente qué corregir.

        var letraEsperada = peticion.Afectado.TipoDocumento == TipoComprobante.Boleta
            ? 'B' : 'F';

        if (peticion.Serie.Length != 4 ||
            char.ToUpperInvariant(peticion.Serie[0]) != letraEsperada)
        {
            return Results.BadRequest(new RespuestaError(
                "La serie de la nota no corresponde al documento que modifica.",
                $"Como afecta a {(letraEsperada == 'B' ? "una boleta" : "una factura")}, " +
                $"su serie debe empezar con '{letraEsperada}' y tener 4 caracteres. " +
                $"Recibido: '{peticion.Serie}'."));
        }

        // --- El documento afectado tiene que existir ---
        //
        // Emitir una nota sobre algo inexistente termina en rechazo de SUNAT,
        // y para entonces ya se quemó un correlativo de la serie de notas.

        var afectado = await repositorio.BuscarPorNumeroAsync(
            tenant.Id,
            peticion.Afectado.TipoDocumento,
            peticion.Afectado.Serie,
            peticion.Afectado.Correlativo,
            ct);

        if (afectado is null)
        {
            return Results.BadRequest(new RespuestaError(
                "El comprobante que la nota modifica no existe.",
                $"No se encontró {peticion.Afectado.NumeroCompleto} entre los " +
                "comprobantes de este emisor."));
        }

        if (afectado.Estado is not ("ACEPTADO" or "ACEPTADO_CON_OBSERVACIONES"))
        {
            // Una nota sobre un comprobante que SUNAT no aceptó no tiene
            // sentido: no hay nada que corregir todavía.
            return Results.BadRequest(new RespuestaError(
                "El comprobante que la nota modifica todavía no fue aceptado.",
                $"{afectado.NumeroCompleto} está en estado {afectado.Estado}. " +
                "Espera a que SUNAT lo acepte, o corrígelo si fue rechazado: " +
                "un comprobante rechazado no existe para SUNAT y no hay nada " +
                "que anular."));
        }

        // --- Construcción ---

        ComprobanteBase nota = esCredito
            ? ConstruirCredito(peticion, tenant)
            : ConstruirDebito(peticion, tenant);

        // --- Persistencia ---

        var idempotencyKey = contexto.Request.Headers["Idempotency-Key"].ToString();

        try
        {
            var guardado = await repositorio.CrearAsync(
                tenant.Id,
                nota,
                extraJson: peticion.Extra is null
                    ? null
                    : JsonSerializer.Serialize(peticion.Extra),
                idempotencyKey: string.IsNullOrWhiteSpace(idempotencyKey)
                    ? null : idempotencyKey,
                correoReceptor: peticion.Receptor.CorreoLimpio(),
                ct: ct);

            var respuesta = RespuestaComprobante.Desde(guardado, peticion.Moneda);

            return guardado.YaExistia
                ? Results.Ok(respuesta)
                : Results.Accepted($"/v1/comprobantes/{guardado.Id}", respuesta);
        }
        catch (InvalidOperationException ex)
        {
            return Results.BadRequest(new RespuestaError("No se pudo emitir.", ex.Message));
        }
    }

    // ------------------------------------------------------------------ armado

    private static NotaCredito ConstruirCredito(PeticionNota p, TenantResuelto t) => new()
    {
        Serie = p.Serie.ToUpperInvariant(),
        FechaEmision = p.FechaEmision ?? RelojPeru.Ahora,
        Moneda = p.Moneda,
        TipoCambio = MapearTipoCambio(p.TipoCambio),
        CodigoMotivo = p.CodigoMotivo,
        DescripcionMotivo = p.DescripcionMotivo,
        Afectado = new DocumentoAfectado
        {
            Numero = p.Afectado.NumeroCompleto,
            TipoDocumento = p.Afectado.TipoDocumento
        },
        Emisor = MapearEmisor(t),
        Receptor = MapearReceptor(p.Receptor),
        Lineas = MapearLineas(p.Lineas)
    };

    private static NotaDebito ConstruirDebito(PeticionNota p, TenantResuelto t) => new()
    {
        Serie = p.Serie.ToUpperInvariant(),
        FechaEmision = p.FechaEmision ?? RelojPeru.Ahora,
        Moneda = p.Moneda,
        TipoCambio = MapearTipoCambio(p.TipoCambio),
        CodigoMotivo = p.CodigoMotivo,
        DescripcionMotivo = p.DescripcionMotivo,
        Afectado = new DocumentoAfectado
        {
            Numero = p.Afectado.NumeroCompleto,
            TipoDocumento = p.Afectado.TipoDocumento
        },
        Emisor = MapearEmisor(t),
        Receptor = MapearReceptor(p.Receptor),
        Lineas = MapearLineas(p.Lineas)
    };

    private static Emisor MapearEmisor(TenantResuelto t) => new()
    {
        Ruc = t.Ruc,
        RazonSocial = t.RazonSocial,
        NombreComercial = t.NombreComercial,
        Ubigeo = t.Ubigeo,
        Direccion = t.Direccion,
        Distrito = t.Distrito,
        Provincia = t.Provincia,
        Departamento = t.Departamento
    };

    private static Receptor MapearReceptor(ReceptorDto r) => new()
    {
        TipoDocumento = r.TipoDocumento,
        NumeroDocumento = r.NumeroDocumento,
        RazonSocial = r.RazonSocial,
        Direccion = r.Direccion
    };

    private static List<LineaComprobante> MapearLineas(List<LineaDto> lineas) =>
        lineas.Select((l, indice) => new LineaComprobante
        {
            Numero = indice + 1,
            CodigoProducto = l.CodigoProducto,
            Descripcion = l.Descripcion,
            UnidadMedida = l.UnidadMedida,
            Cantidad = l.Cantidad,
            ValorUnitario = l.ValorUnitario,
            DescuentoPorcentaje = l.DescuentoPorcentaje,
            TipoAfectacionIgv = l.TipoAfectacionIgv,

            // La tasa la decide la afectación: 4% el arroz pilado, 18% el
            // resto. Si el cliente la manda, manda la suya.
            PorcentajeIgv = l.PorcentajeIgv
                ?? AfectacionIgv.TasaPorDefecto(l.TipoAfectacionIgv),

            AfectoIcbper = l.AfectoIcbper,
            IcbperUnitario = l.IcbperUnitario,
            SistemaIsc = l.SistemaIsc,
            TasaIsc = l.TasaIsc
        }).ToList();

    private static TipoCambio? MapearTipoCambio(TipoCambioDto? dto) =>
        dto is null ? null : new TipoCambio
        {
            MonedaOrigen = dto.MonedaOrigen,
            MonedaDestino = dto.MonedaDestino,
            Tasa = dto.Tasa,
            Fecha = dto.Fecha ?? RelojPeru.Hoy
        };
}

'@

# --- Facturacion.Persistencia\RepositorioComprobantes.cs
Planear 'Facturacion.Persistencia\RepositorioComprobantes.cs' 'A94F558E2A0C06E4F3E6A93B69381679152ED466419FC50D342523DF889EECAA' @'
using System.Text.Json;
using Dapper;
using Facturacion.Cpe;

namespace Facturacion.Persistencia;

/// <summary>
/// Guarda y consulta comprobantes.
///
/// TODO lo que hace pasa por SesionTenant, así que Row Level Security está
/// siempre activo: no existe una ruta para leer o escribir sin declarar de
/// qué empresa se trata.
/// </summary>
public sealed class RepositorioComprobantes
{
    private static readonly JsonSerializerOptions OpcionesJson = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        WriteIndented = false
    };

    private readonly FabricaSesiones _sesiones;

    public RepositorioComprobantes(FabricaSesiones sesiones)
    {
        _sesiones = sesiones ?? throw new ArgumentNullException(nameof(sesiones));
    }

    /// <summary>
    /// Crea un comprobante, asignándole el correlativo que corresponda.
    ///
    /// EL COMPROBANTE ENTRA SIN CORRELATIVO. Lo asigna la base, no el llamador:
    /// permitir que venga desde afuera abriría la puerta a duplicados y saltos.
    ///
    /// Todo ocurre en una sola transacción:
    ///   1. Si hay clave de idempotencia y ya se usó, devuelve el original.
    ///   2. Reserva el siguiente correlativo de la serie.
    ///   3. Inserta el comprobante.
    ///   4. Escribe el primer asiento de la bitácora.
    ///
    /// Si algo falla, nada de eso queda: ni un correlativo quemado ni una
    /// fila a medias.
    /// </summary>
    public async Task<ComprobanteGuardado> CrearAsync(
        Guid tenantId,
        ComprobanteBase comprobante,
        string? extraJson = null,
        string? idempotencyKey = null,
        string? correoReceptor = null,
        CancellationToken ct = default)
    {
        ArgumentNullException.ThrowIfNull(comprobante);

        // HAY COMPROBANTES QUE NO TIENEN LÍNEAS, Y ESTÁ BIEN.
        //
        // El de retención y el de percepción no venden nada: su detalle son
        // las facturas de otro sobre las que se retuvo o percibió. Exigirles
        // líneas de producto sería exigirles algo que el documento no tiene.
        //
        // Se reconocen por la interfaz y no por el tipo, para que el día que
        // aparezca el cuarto documento sin líneas no haya que volver aquí.
        if (comprobante.Lineas.Count == 0 && comprobante is not IComprobanteSinLineas)
            throw new ArgumentException(
                "El comprobante no tiene líneas.", nameof(comprobante));

        await using var sesion = await _sesiones.AbrirAsync(tenantId, ct);

        // --- 1. Idempotencia --------------------------------------------------
        // Un doble clic del usuario, o un reintento del cliente tras un timeout,
        // no deben producir dos comprobantes. Se comprueba ANTES de reservar
        // correlativo: si no, cada reintento quemaría un número.

        if (!string.IsNullOrWhiteSpace(idempotencyKey))
        {
            var existente = await sesion.Conexion.QuerySingleOrDefaultAsync<ComprobanteGuardado?>(
                new CommandDefinition(
                    """
                    SELECT id               AS "Id",
                           tenant_id        AS "TenantId",
                           tipo_comprobante AS "TipoComprobante",
                           serie            AS "Serie",
                           correlativo      AS "Correlativo",
                           estado           AS "Estado",
                           importe_total    AS "ImporteTotal",
                           true             AS "YaExistia"
                      FROM comprobantes
                     WHERE tenant_id = @tenantId
                       AND idempotency_key = @idempotencyKey
                    """,
                    new { tenantId, idempotencyKey },
                    sesion.Transaccion, cancellationToken: ct));

            if (existente is not null)
            {
                await sesion.ConfirmarAsync(ct);
                return existente;
            }
        }

        // --- 2. Reservar el correlativo ---------------------------------------
        //
        // UPDATE ... RETURNING en una sola sentencia.
        //
        // POR QUÉ ASÍ Y NO CON MAX(correlativo) + 1: entre leer el máximo y
        // escribir el nuevo valor hay una ventana en la que otra transacción
        // puede leer el mismo número. Bajo carga eso pasa, y produce el error
        // más caro del sistema: dos comprobantes con el mismo número.
        //
        // El UPDATE toma el candado de la fila por sí mismo. Una transacción
        // simultánea sobre la misma serie espera hasta que esta confirme, y
        // entonces lee el valor ya incrementado. Sin ventana.

        var correlativo = await sesion.Conexion.ExecuteScalarAsync<int?>(
            new CommandDefinition(
                """
                UPDATE series
                   SET ultimo_correlativo = ultimo_correlativo + 1
                 WHERE tenant_id = @tenantId
                   AND tipo_comprobante = @tipo
                   AND serie = @serie
                   AND activo
                RETURNING ultimo_correlativo
                """,
                new
                {
                    tenantId,
                    tipo = comprobante.TipoComprobante,
                    serie = comprobante.Serie
                },
                sesion.Transaccion, cancellationToken: ct));

        if (correlativo is null)
            throw new InvalidOperationException(
                $"No existe la serie {comprobante.Serie} para el tipo " +
                $"{comprobante.TipoComprobante}, o está inactiva. " +
                "Hay que darla de alta antes de emitir.");

        comprobante.Correlativo = correlativo.Value;

        // --- 3. Insertar el comprobante ---------------------------------------

        // EL IMPORTE DE UNA LIQUIDACIÓN NO SE CALCULA COMO EL DE UNA FACTURA.
        //
        // En una factura el importe total es lo que el CLIENTE PAGA: valor de
        // venta más impuestos. En una liquidación de compra es lo que el
        // VENDEDOR COBRA, que es el valor de compra menos el IGV —que asume
        // el comprador como crédito fiscal— menos la retención de renta.
        //
        // Son dos números distintos y la diferencia es grande: en una compra
        // de 6 000 soles, 7 080 contra 5 910. Usar aquí CalculadoraTotales
        // dejaría en la base, en el panel y en los listados un importe un 20%
        // más alto que el que de verdad se pagó.

        var importeTotal = comprobante switch
        {
            LiquidacionCompra liquidacion =>
                CalculadoraLiquidacion.Calcular(liquidacion).ImporteAPagar,

            // El importe de un comprobante de retención o percepción es lo
            // retenido o percibido, no lo pagado. Cada documento sabe cuál de
            // sus números lo representa.
            IComprobanteSinLineas sinLineas => sinLineas.ImporteDeclarado,

            _ => CalculadoraTotales.Calcular(comprobante).ImporteTotal
        };

        var cpeJson = JsonSerializer.Serialize(
            comprobante, comprobante.GetType(), OpcionesJson);

        var id = await sesion.Conexion.ExecuteScalarAsync<Guid>(
            new CommandDefinition(
                """
                INSERT INTO comprobantes
                    (tenant_id, tipo_comprobante, serie, correlativo,
                     fecha_emision, moneda, importe_total, estado,
                     cpe, extra, idempotency_key, correo_receptor)
                VALUES
                    (@tenantId, @tipo, @serie, @correlativo,
                     @fechaEmision, @moneda, @importeTotal, @estado,
                     CAST(@cpe AS jsonb), CAST(@extra AS jsonb), @idempotencyKey,
                     @correoReceptor)
                RETURNING id
                """,
                new
                {
                    tenantId,
                    tipo = comprobante.TipoComprobante,
                    serie = comprobante.Serie,
                    correlativo = correlativo.Value,
                    fechaEmision = DateOnly.FromDateTime(comprobante.FechaEmision),
                    moneda = comprobante.Moneda,
                    importeTotal,
                    estado = EstadoCpe.Borrador,
                    cpe = cpeJson,
                    extra = string.IsNullOrWhiteSpace(extraJson) ? "{}" : extraJson,
                    idempotencyKey,

                    // Fuera del `cpe` a propósito: no es tributario y no se firma.
                    correoReceptor = string.IsNullOrWhiteSpace(correoReceptor)
                        ? null
                        : correoReceptor.Trim()
                },
                sesion.Transaccion, cancellationToken: ct));

        // --- 4. Primer asiento de la bitácora ---------------------------------

        await InsertarIntentoAsync(
            sesion, tenantId, id, 1, null,
            new CambioEstado(EstadoCpe.Borrador, Mensaje: "Comprobante creado."),
            ct);

        await sesion.ConfirmarAsync(ct);

        return new ComprobanteGuardado(
            id, tenantId,
            comprobante.TipoComprobante, comprobante.Serie, correlativo.Value,
            EstadoCpe.Borrador, importeTotal, YaExistia: false);
    }

    /// <summary>
    /// Registra un cambio de estado y su asiento en la bitácora.
    ///
    /// Las dos cosas van juntas a propósito: un estado que cambia sin dejar
    /// rastro es exactamente lo que no se puede explicar cuando un cliente
    /// pregunta qué pasó con su factura de hace tres meses.
    /// </summary>
    public async Task RegistrarCambioAsync(
        Guid tenantId,
        Guid comprobanteId,
        CambioEstado cambio,
        CancellationToken ct = default)
    {
        ArgumentNullException.ThrowIfNull(cambio);

        await using var sesion = await _sesiones.AbrirAsync(tenantId, ct);

        var anterior = await sesion.Conexion.QuerySingleOrDefaultAsync<string>(
            new CommandDefinition(
                "SELECT estado FROM comprobantes WHERE id = @comprobanteId FOR UPDATE",
                new { comprobanteId },
                sesion.Transaccion, cancellationToken: ct));

        if (anterior is null)
            throw new InvalidOperationException(
                $"No existe el comprobante {comprobanteId} para este tenant.");

        var intentoNro = await sesion.Conexion.ExecuteScalarAsync<short>(
            new CommandDefinition(
                """
                SELECT COALESCE(MAX(intento_nro), 0) + 1
                  FROM envio_intentos
                 WHERE comprobante_id = @comprobanteId
                """,
                new { comprobanteId },
                sesion.Transaccion, cancellationToken: ct));

        await sesion.Conexion.ExecuteAsync(new CommandDefinition(
            """
            UPDATE comprobantes
               SET estado        = @estado,
                   codigo_sunat  = COALESCE(@codigoSunat, codigo_sunat),
                   mensaje_sunat = COALESCE(@mensaje, mensaje_sunat),
                   ticket        = COALESCE(@ticket, ticket)
             WHERE id = @comprobanteId
            """,
            new
            {
                comprobanteId,
                estado = cambio.EstadoNuevo,
                codigoSunat = cambio.CodigoSunat,
                mensaje = cambio.Mensaje,
                ticket = cambio.Ticket
            },
            sesion.Transaccion, cancellationToken: ct));

        await InsertarIntentoAsync(
            sesion, tenantId, comprobanteId, intentoNro, anterior, cambio, ct);

        await sesion.ConfirmarAsync(ct);
    }

    /// <summary>Guarda las rutas de los archivos generados.</summary>
    public async Task GuardarRutasAsync(
        Guid tenantId,
        Guid comprobanteId,
        string? rutaXml = null,
        string? rutaCdr = null,
        string? rutaPdf = null,
        string? hashCpe = null,
        CancellationToken ct = default)
    {
        await using var sesion = await _sesiones.AbrirAsync(tenantId, ct);

        await sesion.Conexion.ExecuteAsync(new CommandDefinition(
            """
            UPDATE comprobantes
               SET ruta_xml = COALESCE(@rutaXml, ruta_xml),
                   ruta_cdr = COALESCE(@rutaCdr, ruta_cdr),
                   ruta_pdf = COALESCE(@rutaPdf, ruta_pdf),
                   hash_cpe = COALESCE(@hashCpe, hash_cpe)
             WHERE id = @comprobanteId
            """,
            new { comprobanteId, rutaXml, rutaCdr, rutaPdf, hashCpe },
            sesion.Transaccion, cancellationToken: ct));

        await sesion.ConfirmarAsync(ct);
    }

    public async Task<ResumenComprobante?> ObtenerAsync(
        Guid tenantId, Guid comprobanteId, CancellationToken ct = default)
    {
        await using var sesion = await _sesiones.AbrirAsync(tenantId, ct);

        var fila = await sesion.Conexion.QuerySingleOrDefaultAsync<ResumenComprobante?>(
            new CommandDefinition(ConsultaResumen + " WHERE id = @comprobanteId",
                new { comprobanteId },
                sesion.Transaccion, cancellationToken: ct));

        await sesion.ConfirmarAsync(ct);
        return fila;
    }

    public async Task<IReadOnlyList<ResumenComprobante>> ListarAsync(
        Guid tenantId, int limite = 50, CancellationToken ct = default)
    {
        await using var sesion = await _sesiones.AbrirAsync(tenantId, ct);

        var filas = await sesion.Conexion.QueryAsync<ResumenComprobante>(
            new CommandDefinition(
                ConsultaResumen + " ORDER BY creado_en DESC LIMIT @limite",
                new { limite },
                sesion.Transaccion, cancellationToken: ct));

        await sesion.ConfirmarAsync(ct);
        return filas.ToList();
    }

    /// <summary>Historial completo de intentos de un comprobante.</summary>
    public async Task<IReadOnlyList<IntentoEnvio>> HistorialAsync(
        Guid tenantId, Guid comprobanteId, CancellationToken ct = default)
    {
        await using var sesion = await _sesiones.AbrirAsync(tenantId, ct);

        var filas = await sesion.Conexion.QueryAsync<IntentoEnvio>(
            new CommandDefinition(
                """
                SELECT id              AS "Id",
                       comprobante_id  AS "ComprobanteId",
                       intento_nro     AS "IntentoNro",
                       estado_anterior AS "EstadoAnterior",
                       estado_nuevo    AS "EstadoNuevo",
                       codigo_sunat    AS "CodigoSunat",
                       mensaje         AS "Mensaje",
                       duracion_ms     AS "DuracionMs",
                       worker          AS "Worker",
                       creado_en       AS "CreadoEn"
                  FROM envio_intentos
                 WHERE comprobante_id = @comprobanteId
                 ORDER BY intento_nro
                """,
                new { comprobanteId },
                sesion.Transaccion, cancellationToken: ct));

        await sesion.ConfirmarAsync(ct);
        return filas.ToList();
    }

    /// <summary>
    /// Rutas de los archivos de un comprobante.
    ///
    /// Va por sesión de tenant, así que Row Level Security garantiza que
    /// nadie pueda pedir las rutas de otra empresa. Eso importa más de lo
    /// que parece: si este método no filtrara por tenant, bastaría adivinar
    /// un identificador para descargar la factura de un competidor.
    /// </summary>
    public async Task<ArchivosComprobante?> ObtenerRutasAsync(
        Guid tenantId, Guid comprobanteId, CancellationToken ct = default)
    {
        await using var sesion = await _sesiones.AbrirAsync(tenantId, ct);

        var fila = await sesion.Conexion.QuerySingleOrDefaultAsync<ArchivosComprobante?>(
            new CommandDefinition(
                """
                SELECT serie || '-' || lpad(correlativo::text, 8, '0') AS "Numero",
                       tipo_comprobante AS "TipoComprobante",
                       estado           AS "Estado",
                       ruta_xml         AS "RutaXml",
                       ruta_cdr         AS "RutaCdr",
                       ruta_pdf         AS "RutaPdf"
                  FROM comprobantes
                 WHERE id = @comprobanteId
                """,
                new { comprobanteId },
                sesion.Transaccion, cancellationToken: ct));

        await sesion.ConfirmarAsync(ct);
        return fila;
    }

    /// <summary>
    /// Busca un comprobante por su número. Devuelve null si no existe para
    /// este emisor.
    ///
    /// SE USA PARA VALIDAR LAS NOTAS antes de emitirlas: una nota que apunta
    /// a un comprobante inexistente la rechaza SUNAT, y para entonces ya
    /// quemaste un correlativo de la serie de notas. Comprobarlo aquí cuesta
    /// una consulta y evita ese desperdicio.
    /// </summary>
    public async Task<ResumenComprobante?> BuscarPorNumeroAsync(
        Guid tenantId,
        string tipoComprobante,
        string serie,
        int correlativo,
        CancellationToken ct = default)
    {
        await using var sesion = await _sesiones.AbrirAsync(tenantId, ct);

        var fila = await sesion.Conexion.QuerySingleOrDefaultAsync<ResumenComprobante?>(
            new CommandDefinition(
                ConsultaResumen + """
                 WHERE tipo_comprobante = @tipoComprobante
                   AND serie = @serie
                   AND correlativo = @correlativo
                """,
                new { tipoComprobante, serie, correlativo },
                sesion.Transaccion, cancellationToken: ct));

        await sesion.ConfirmarAsync(ct);
        return fila;
    }

    /// <summary>
    /// Todo lo necesario para regenerar el PDF de un comprobante.
    ///
    /// POR QUÉ EL PDF NO SE GUARDA:
    ///
    /// Es el 80% del peso del almacén y el único de los tres archivos que se
    /// puede reconstruir. El XML y el CDR son irreemplazables; el PDF sale del
    /// mismo cpe que ya está aquí.
    ///
    /// Con cien mil comprobantes diarios, guardarlo son más de dos terabytes
    /// al año. Generarlo cuando alguien lo pide reduce eso a menos de la
    /// cuarta parte, y cuesta unas décimas de segundo.
    /// </summary>
    public async Task<DatosParaPdf?> ObtenerParaPdfAsync(
        Guid tenantId, Guid comprobanteId, CancellationToken ct = default)
    {
        await using var sesion = await _sesiones.AbrirAsync(tenantId, ct);

        var fila = await sesion.Conexion.QuerySingleOrDefaultAsync<DatosParaPdf?>(
            new CommandDefinition(
                """
                SELECT serie || '-' || lpad(correlativo::text, 8, '0') AS "Numero",
                       tipo_comprobante AS "TipoComprobante",
                       estado           AS "Estado",
                       codigo_sunat     AS "CodigoSunat",
                       mensaje_sunat    AS "MensajeSunat",
                       cpe::text        AS "CpeJson",
                       ruta_xml         AS "RutaXml",
                       extra::text      AS "ExtraJson"
                  FROM comprobantes
                 WHERE id = @comprobanteId
                """,
                new { comprobanteId },
                sesion.Transaccion, cancellationToken: ct));

        await sesion.ConfirmarAsync(ct);
        return fila;
    }

    /// <summary>
    /// Da de alta una serie si no existe. Pensado para el arranque y las
    /// pruebas; en producción esto lo hace el panel de administración.
    /// </summary>
    public async Task AsegurarSerieAsync(
        Guid tenantId,
        string tipoComprobante,
        string serie,
        CancellationToken ct = default)
    {
        await using var sesion = await _sesiones.AbrirAsync(tenantId, ct);

        await sesion.Conexion.ExecuteAsync(new CommandDefinition(
            """
            INSERT INTO series (tenant_id, tipo_comprobante, serie)
            VALUES (@tenantId, @tipo, @serie)
            ON CONFLICT (tenant_id, tipo_comprobante, serie) DO NOTHING
            """,
            new { tenantId, tipo = tipoComprobante, serie },
            sesion.Transaccion, cancellationToken: ct));

        await sesion.ConfirmarAsync(ct);
    }

    // ------------------------------------------------------------------ interno

    private const string ConsultaResumen =
        """
        SELECT id               AS "Id",
               tipo_comprobante AS "TipoComprobante",
               serie            AS "Serie",
               correlativo      AS "Correlativo",
               fecha_emision    AS "FechaEmision",
               moneda           AS "Moneda",
               importe_total    AS "ImporteTotal",
               estado           AS "Estado",
               codigo_sunat     AS "CodigoSunat",
               mensaje_sunat    AS "MensajeSunat",
               ticket           AS "Ticket",
               creado_en        AS "CreadoEn"
          FROM comprobantes
        """;

    private static Task InsertarIntentoAsync(
        SesionTenant sesion,
        Guid tenantId,
        Guid comprobanteId,
        short intentoNro,
        string? estadoAnterior,
        CambioEstado cambio,
        CancellationToken ct) =>
        sesion.Conexion.ExecuteAsync(new CommandDefinition(
            """
            INSERT INTO envio_intentos
                (tenant_id, comprobante_id, intento_nro,
                 estado_anterior, estado_nuevo,
                 codigo_sunat, mensaje, request_raw, response_raw,
                 duracion_ms, worker)
            VALUES
                (@tenantId, @comprobanteId, @intentoNro,
                 @estadoAnterior, @estadoNuevo,
                 @codigoSunat, @mensaje, @requestRaw, @responseRaw,
                 @duracionMs, @worker)
            """,
            new
            {
                tenantId,
                comprobanteId,
                intentoNro,
                estadoAnterior,
                estadoNuevo = cambio.EstadoNuevo,
                codigoSunat = cambio.CodigoSunat,
                mensaje = cambio.Mensaje,
                requestRaw = cambio.RequestRaw,
                responseRaw = cambio.ResponseRaw,
                duracionMs = cambio.DuracionMs,
                worker = cambio.Worker ?? Environment.MachineName
            },
            sesion.Transaccion, cancellationToken: ct));

    private static Task InsertarIntentoAsync(
        SesionTenant sesion, Guid tenantId, Guid comprobanteId,
        int intentoNro, string? estadoAnterior, CambioEstado cambio,
        CancellationToken ct) =>
        InsertarIntentoAsync(
            sesion, tenantId, comprobanteId, (short)intentoNro,
            estadoAnterior, cambio, ct);
}
'@

# --- Facturacion.Persistencia\AlmacenCertificados.cs
Planear 'Facturacion.Persistencia\AlmacenCertificados.cs' '4C285A6EE54A66D57986D7E48D786A6C959E7FA2598D51A3FE777C678EE428E8' @'
using System.Security.Cryptography.X509Certificates;
using Dapper;

namespace Facturacion.Persistencia;

/// <summary>Datos legibles de un certificado, para mostrar en el panel.</summary>
/// <param name="ComprobantesFirmados">
/// Cuántos comprobantes se firmaron mientras este certificado estuvo activo.
/// Determina si se puede eliminar.
/// </param>
public record CertificadoInfo(
    Guid Id,
    string Subject,
    string Huella,
    DateTime? ValidoDesde,
    DateTime ValidoHasta,
    bool Activo,
    int ComprobantesFirmados)
{
    /// <summary>
    /// Un certificado que nunca firmó nada se puede borrar: típicamente se
    /// cargó por error y se reemplazó enseguida.
    ///
    /// Uno que sí firmó hay que conservarlo. Sin él no se puede verificar la
    /// firma de esos comprobantes, y esa verificación puede hacer falta años
    /// después, durante una fiscalización.
    /// </summary>
    public bool SePuedeEliminar => ComprobantesFirmados == 0 && !Activo;

    public bool EstaVencido => ValidoHasta < DateTime.UtcNow;

    public int DiasParaVencer =>
        (int)Math.Ceiling((ValidoHasta - DateTime.UtcNow).TotalDays);

    /// <summary>
    /// Un certificado vencido detiene por completo la facturación del cliente,
    /// y el aviso nunca llega solo. Conviene alertar con semanas de margen:
    /// renovar uno toma días, no horas.
    /// </summary>
    public bool RequiereAlerta(int diasDeAviso = 30) =>
        Activo && DiasParaVencer <= diasDeAviso;
}

/// <summary>
/// Guarda y recupera los certificados digitales de cada empresa.
///
/// EL CERTIFICADO ES LA LLAVE CON LA QUE SE FIRMA EN NOMBRE DE OTRO. Por eso
/// aquí nunca aparece en claro: entra cifrado, sale descifrado solo en memoria
/// y solo cuando hay que firmar, y jamás se escribe a disco.
///
/// El esquema garantiza además que haya un único certificado activo por
/// empresa. Dos activos significarían que nadie sabe con cuál se está firmando.
/// </summary>
public sealed class AlmacenCertificados
{
    private readonly FabricaSesiones _sesiones;
    private readonly IProtectorDeSecretos _protector;

    public AlmacenCertificados(FabricaSesiones sesiones, IProtectorDeSecretos protector)
    {
        _sesiones = sesiones ?? throw new ArgumentNullException(nameof(sesiones));
        _protector = protector ?? throw new ArgumentNullException(nameof(protector));
    }

    /// <summary>
    /// Guarda un certificado y lo deja como el activo del tenant.
    ///
    /// Desactiva el anterior en la misma transacción: el esquema no admite dos
    /// activos, y hacerlo en pasos separados dejaría una ventana donde el
    /// cliente no tiene ninguno.
    /// </summary>
    public async Task<Guid> GuardarAsync(
        Guid tenantId,
        byte[] contenidoPfx,
        string clavePfx,
        CancellationToken ct = default)
    {
        ArgumentNullException.ThrowIfNull(contenidoPfx);

        // Se abre aquí para extraer los datos legibles y, de paso, verificar
        // que el archivo y la clave son correctos ANTES de guardar nada.
        using var certificado = AbrirPfx(contenidoPfx, clavePfx);

        if (!certificado.HasPrivateKey)
            throw new InvalidOperationException(
                "El archivo no contiene la llave privada. Sin ella no se puede " +
                "firmar: necesitas el .pfx completo, no solo el certificado público.");

        if (certificado.NotAfter.ToUniversalTime() < DateTime.UtcNow)
            throw new InvalidOperationException(
                $"El certificado venció el {certificado.NotAfter:yyyy-MM-dd}. " +
                "SUNAT rechaza todo lo firmado con un certificado vencido.");

        var pfxCifrado = _protector.Proteger(contenidoPfx);
        var claveCifrada = _protector.ProtegerTexto(clavePfx);

        await using var sesion = await _sesiones.AbrirAsync(tenantId, ct);

        await sesion.Conexion.ExecuteAsync(new CommandDefinition(
            """
            UPDATE certificados
               SET activo = false
             WHERE tenant_id = @tenantId AND activo
            """,
            new { tenantId },
            sesion.Transaccion, cancellationToken: ct));

        var id = await sesion.Conexion.ExecuteScalarAsync<Guid>(new CommandDefinition(
            """
            INSERT INTO certificados
                (tenant_id, pfx_cifrado, clave_cifrada, subject, huella,
                 valido_desde, valido_hasta, activo)
            VALUES
                (@tenantId, @pfxCifrado, @claveCifrada, @subject, @huella,
                 @validoDesde, @validoHasta, true)
            RETURNING id
            """,
            new
            {
                tenantId,
                pfxCifrado,
                claveCifrada,
                subject = certificado.Subject,
                huella = certificado.Thumbprint,
                validoDesde = certificado.NotBefore.ToUniversalTime(),
                validoHasta = certificado.NotAfter.ToUniversalTime()
            },
            sesion.Transaccion, cancellationToken: ct));

        await sesion.ConfirmarAsync(ct);

        return id;
    }

    /// <summary>
    /// Recupera el certificado activo del tenant, listo para firmar.
    ///
    /// Quien lo reciba es responsable de liberarlo. Contiene material
    /// criptográfico sensible y no debe quedar vivo más de lo necesario.
    /// </summary>
    public async Task<X509Certificate2?> ObtenerActivoAsync(
        Guid tenantId, CancellationToken ct = default)
    {
        await using var sesion = await _sesiones.AbrirAsync(tenantId, ct);

        var fila = await sesion.Conexion.QuerySingleOrDefaultAsync<(byte[] Pfx, byte[] Clave)?>(
            new CommandDefinition(
                """
                SELECT pfx_cifrado AS "Pfx", clave_cifrada AS "Clave"
                  FROM certificados
                 WHERE tenant_id = @tenantId AND activo
                 LIMIT 1
                """,
                new { tenantId },
                sesion.Transaccion, cancellationToken: ct));

        await sesion.ConfirmarAsync(ct);

        if (fila is null) return null;

        var pfx = _protector.Desproteger(fila.Value.Pfx);
        var clave = _protector.DesprotegerTexto(fila.Value.Clave);

        return AbrirPfx(pfx, clave);
    }

    /// <summary>
    /// Hasta cuándo vale el certificado ACTIVO de la empresa, o null si no
    /// tiene ninguno.
    ///
    /// EXISTE PARA `GET /v1/emisor`: es lo que necesita quien integra —la
    /// plataforma, o cualquier otro— para avisar antes de que venza. Cuando
    /// vence, la emisión se detiene en seco y descubrir por qué lleva una hora.
    /// Solo la fecha: nada del certificado en sí sale de aquí.
    /// </summary>
    public async Task<DateTime?> VencimientoActivoAsync(
        Guid tenantId, CancellationToken ct = default)
    {
        await using var sesion = await _sesiones.AbrirAsync(tenantId, ct);

        var hasta = await sesion.Conexion.ExecuteScalarAsync<DateTime?>(
            new CommandDefinition(
                """
                SELECT valido_hasta
                  FROM certificados
                 WHERE tenant_id = @tenantId
                   AND activo
                """,
                new { tenantId },
                sesion.Transaccion, cancellationToken: ct));

        await sesion.ConfirmarAsync(ct);

        return hasta;
    }

    /// <summary>Lista los certificados del tenant, sin material sensible.</summary>
    public async Task<IReadOnlyList<CertificadoInfo>> ListarAsync(
        Guid tenantId, CancellationToken ct = default)
    {
        await using var sesion = await _sesiones.AbrirAsync(tenantId, ct);

        var filas = await sesion.Conexion.QueryAsync<CertificadoInfo>(
            new CommandDefinition(
                """
                SELECT c.id           AS "Id",
                       c.subject      AS "Subject",
                       c.huella       AS "Huella",
                       c.valido_desde AS "ValidoDesde",
                       c.valido_hasta AS "ValidoHasta",
                       c.activo       AS "Activo",

                       -- Comprobantes firmados mientras este certificado
                       -- estuvo vigente. Se aproxima por la ventana de
                       -- tiempo: desde que se cargó hasta que se reemplazó.
                       (SELECT count(*)::int
                          FROM comprobantes co
                         WHERE co.tenant_id = c.tenant_id
                           AND co.estado <> 'BORRADOR'
                           AND co.creado_en >= c.creado_en
                           AND (c.activo OR co.creado_en < COALESCE(
                                 (SELECT min(c2.creado_en) FROM certificados c2
                                   WHERE c2.tenant_id = c.tenant_id
                                     AND c2.creado_en > c.creado_en),
                                 'infinity'::timestamptz)))
                                                  AS "ComprobantesFirmados"

                  FROM certificados c
                 WHERE c.tenant_id = @tenantId
                 ORDER BY c.creado_en DESC
                """,
                new { tenantId },
                sesion.Transaccion, cancellationToken: ct));

        await sesion.ConfirmarAsync(ct);

        return filas.ToList();
    }

    /// <summary>
    /// Elimina un certificado, pero SOLO si nunca firmó nada y no es el activo.
    ///
    /// Sirve para el caso real de cargar el archivo equivocado y darse cuenta
    /// enseguida. Un certificado que ya firmó comprobantes se conserva
    /// siempre: sin él no se puede verificar esas firmas, y esa verificación
    /// puede hacer falta durante una fiscalización años después.
    /// </summary>
    public async Task<bool> EliminarAsync(
        Guid tenantId, Guid certificadoId, CancellationToken ct = default)
    {
        var lista = await ListarAsync(tenantId, ct);

        var certificado = lista.FirstOrDefault(c => c.Id == certificadoId);

        if (certificado is null || !certificado.SePuedeEliminar)
            return false;

        await using var sesion = await _sesiones.AbrirAsync(tenantId, ct);

        var filas = await sesion.Conexion.ExecuteAsync(new CommandDefinition(
            "DELETE FROM certificados WHERE id = @certificadoId AND NOT activo",
            new { certificadoId },
            sesion.Transaccion, cancellationToken: ct));

        await sesion.ConfirmarAsync(ct);

        return filas > 0;
    }

    /// <summary>
    /// Abre el PFX.
    ///
    /// POR QUÉ SE PRUEBAN VARIAS FORMAS DE CARGARLO:
    ///
    /// En Windows, abrir un PFX puede exigir escribir la llave privada en un
    /// almacén del sistema, y el proceso no siempre tiene permiso para el
    /// almacén de máquina. Cuando eso ocurre, .NET lanza exactamente la misma
    /// excepción que cuando la contraseña es incorrecta.
    ///
    /// Una versión anterior de este método daba por hecho que era la
    /// contraseña. El mensaje sonaba útil y mandaba a buscar en la dirección
    /// equivocada: la contraseña estaba bien y el problema eran los permisos.
    ///
    /// Ahora se intentan varias combinaciones y, si todas fallan, se incluye
    /// el mensaje REAL del sistema en vez de una conjetura.
    /// </summary>
    private static X509Certificate2 AbrirPfx(byte[] contenido, string clave)
    {
        // Un PFX es una estructura DER y siempre empieza con 0x30 0x82.
        // Comprobarlo permite afirmar con certeza que el archivo no es un
        // certificado, en vez de culpar a la contraseña.
        if (contenido.Length < 2 || contenido[0] != 0x30 || contenido[1] != 0x82)
            throw new InvalidOperationException(
                "El archivo no parece un certificado PFX. Comprueba que sea el " +
                "archivo .pfx o .p12 que entregó la entidad certificadora, y no " +
                "un .cer, un .pem o un comprimido.");

        // En orden de preferencia:
        //
        //   Ephemeral  la llave vive solo en memoria y no toca ningún almacén.
        //              Es lo que queremos: el certificado ya se guarda cifrado
        //              en la base, no hace falta dejar rastro en el sistema.
        //
        //   UserKeySet almacén del usuario que ejecuta el proceso. Casi
        //              siempre disponible.
        //
        //   MachineKeySet  almacén de máquina. Puede requerir permisos
        //              elevados, y ahí es donde suele fallar.
        var intentos = new[]
        {
            X509KeyStorageFlags.Exportable | X509KeyStorageFlags.EphemeralKeySet,
            X509KeyStorageFlags.Exportable | X509KeyStorageFlags.UserKeySet,
            X509KeyStorageFlags.Exportable | X509KeyStorageFlags.MachineKeySet,
            X509KeyStorageFlags.Exportable
        };

        Exception? ultimoError = null;

        foreach (var opciones in intentos)
        {
            try
            {
                var certificado = new X509Certificate2(contenido, clave, opciones);

                // EphemeralKeySet a veces devuelve un certificado cuya llave
                // privada no sirve para firmar. Se comprueba antes de darlo
                // por bueno: descubrirlo aquí es barato, descubrirlo al firmar
                // una factura real no lo es.
                if (certificado.HasPrivateKey && certificado.GetRSAPrivateKey() is not null)
                    return certificado;

                certificado.Dispose();

                ultimoError ??= new InvalidOperationException(
                    "El certificado se abrió pero su llave privada no es " +
                    "utilizable para firmar.");
            }
            catch (Exception ex)
            {
                ultimoError = ex;
            }
        }

        // Ninguna forma funcionó. Se entrega el mensaje real del sistema,
        // sin interpretarlo: adivinar la causa es lo que nos hizo perder
        // tiempo la vez anterior.
        throw new InvalidOperationException(
            "No se pudo abrir el certificado. El sistema respondió: " +
            (ultimoError?.Message ?? "sin detalle") +
            ". Si la contraseña es correcta, revisa los permisos del proceso " +
            "sobre el almacén de certificados de Windows.",
            ultimoError);
    }
}

'@

# --- migraciones\019_correo_receptor.sql
Planear 'migraciones\019_correo_receptor.sql' '' @'
-- ===========================================================================
-- 019 — El correo del receptor
--
-- POR QUÉ HACE FALTA:
--
-- El portal del receptor y el correo de entrega viven en este servicio
-- (decisión del 9 de octubre de 2026: un contribuyente que integra por API
-- sin usar la plataforma necesita igual que su cliente reciba el
-- comprobante). Para mandarlo, el servicio tiene que saber a dónde, y hasta
-- ahora `POST /v1/comprobantes` no recibía ningún correo.
--
--
-- VA EN SU PROPIA COLUMNA, NO DENTRO DEL `cpe`, Y ES LO IMPORTANTE:
--
-- El `cpe` es el comprobante tal como se firma y viaja a SUNAT. El correo no
-- es un dato tributario y no pinta nada ahí: meterlo dentro sería arriesgarse
-- a que un generador lo serialice algún día en el XML.
--
--
-- LA COMPROBACIÓN DE LA BASE ES FLOJA A PROPÓSITO. La de forma de verdad está
-- en la API (ReceptorDto.ProblemaCorreo), donde puede devolver un mensaje que
-- se entienda. Aquí solo se ataja lo que nunca puede ser un correo: vacío,
-- con espacios, sin arroba o más largo que el máximo del estándar.
--
-- No necesita GRANT nuevo: facturacion_app tiene INSERT y UPDATE sobre la
-- tabla entera, y eso incluye las columnas que se añadan.
-- ===========================================================================

BEGIN;

ALTER TABLE comprobantes ADD COLUMN IF NOT EXISTS correo_receptor text;

ALTER TABLE comprobantes DROP CONSTRAINT IF EXISTS ck_comprobantes_correo_receptor;

ALTER TABLE comprobantes ADD CONSTRAINT ck_comprobantes_correo_receptor
    CHECK (
        correo_receptor IS NULL OR (
            length(correo_receptor) BETWEEN 3 AND 254
            AND correo_receptor !~ '\s'
            AND position('@' IN correo_receptor) > 1
        )
    );

-- El texto del comentario va sin tildes a proposito: PowerShell 5.1 manda
-- el archivo a psql en ASCII y las convertiria en '?'.
COMMENT ON COLUMN comprobantes.correo_receptor IS
    'A donde se manda el comprobante al ser aceptado (PDF + enlace al portal). '
    'Opcional. No es tributario: nunca va al cpe ni al XML.';

COMMIT;
'@

# --- Todo o nada -------------------------------------------------------------
$conflictos = @($plan | Where-Object { $_.Accion -eq 'conflicto' })
if ($conflictos.Count -gt 0) {
    Write-Host ''
    Write-Host 'NO SE TOCÓ NINGÚN ARCHIVO. Esto no cuadra:' -ForegroundColor Red
    foreach ($c in $conflictos) { Write-Host "  $($c.Ruta)`n      $($c.Motivo)" -ForegroundColor Red }
    Write-Host ''
    exit 2
}

Write-Host ''
foreach ($p in $plan) {
    if ($p.Accion -eq 'reemplazar') {
        $copia = Respaldar $p.Completa
        $salida = if ($p.Crlf) { $p.Texto.Replace("`n", "`r`n") } else { $p.Texto }
        [System.IO.File]::WriteAllText($p.Completa, $salida, $utf8SinBom)
        Write-Host "  REEMPLAZADO  $($p.Ruta)  (copia: $copia)" -ForegroundColor Green
    }
    elseif ($p.Accion -eq 'nuevo') {
        New-Item -ItemType Directory -Path (Split-Path $p.Completa) -Force | Out-Null
        [System.IO.File]::WriteAllText($p.Completa, $p.Texto.Replace("`n", "`r`n"), $utf8SinBom)
        Write-Host "  NUEVO        $($p.Ruta)" -ForegroundColor Green
    }
    else {
        Write-Host "  IGUAL        $($p.Ruta)  (sin cambios)" -ForegroundColor DarkGray
    }
}

Write-Host ''
Write-Host 'FALTA APLICAR LA MIGRACIÓN 019 (este script NO la aplica). Desde esta carpeta:' -ForegroundColor Cyan
Write-Host ''
Write-Host '  Get-Content migraciones\019_correo_receptor.sql -Raw | docker compose exec -T postgres psql -U facturacion_owner -d facturacion -v ON_ERROR_STOP=1' -ForegroundColor White
Write-Host ''
Write-Host 'Tiene que terminar en COMMIT. Después, reinicia la API del servicio.' -ForegroundColor Cyan
Write-Host ''
