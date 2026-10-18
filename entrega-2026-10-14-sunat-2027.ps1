# =============================================================================
# Entrega 2026-10-14 — CAMBIOS DE SUNAT DE 2027 (PARTE 1) (SERVICIO)
#
# Se ejecuta desde la raíz del servicio:
#   cd "D:\Reyban Consulting\facturacion electronica\facturacion_electronica_service"
#   .\entrega-2026-10-14-sunat-2027.ps1
#
# Detalle: documento del proyecto «cambios-sunat-2027.md».
#
# NUEVOS
#   Facturacion.Cpe\VigenciaSunat.cs        Desde cuándo rigen las reglas de
#                                           2027: 2027-01-01, cambiable con
#                                           SUNAT_REGLAS_2027_DESDE
#   Facturacion.Cpe.Tests\Reglas2027Tests.cs 6 pruebas nuevas
# CAMBIOS PUNTUALES
#   Facturacion.Cpe\ResumenDiario.cs         Catálogo 11: códigos 06–09
#   Facturacion.Cpe\GeneradorResumenXml.cs   Gratuitas: 05 hasta 2027, por
#                                           clase desde 2027
#   Facturacion.Cpe\ComunicacionBaja.cs      La liquidación de compra (04) se
#                                           revierte con RR, serie L, 5 días
#   Facturacion.Api\EndpointsNotas.cs        La NC no puede superar al
#                                           documento (error 3286)
#   Facturacion.Api\EndpointsBajas.cs        Texto de /v1/reversiones
#   Facturacion.Api\PruebaMadrugada.cs       Caso nuevo: boleta con bonificación
#   Facturacion.Worker\Program.cs            Lee SUNAT_REGLAS_2027_DESDE y
#                                           lo dice al arrancar
#
# NO hay migración. Comprueba TODO antes de escribir; si algo no cuadra, NO
# TOCA NADA. Copia .bak de lo que cambia. No pregunta nada.
# =============================================================================

$ErrorActionPreference = 'Stop'
$raiz = (Get-Location).Path

if (-not (Test-Path (Join-Path $raiz 'Facturacion.Cpe')) -or -not (Test-Path (Join-Path $raiz 'Facturacion.Api'))) {
    Write-Host "No encuentro 'Facturacion.Cpe' y 'Facturacion.Api' aquí ($raiz)." -ForegroundColor Red
    Write-Host "Ejecuta el script desde la raíz del servicio (facturacion_electronica_service). No se tocó nada." -ForegroundColor Red
    exit 1
}

$utf8SinBom = New-Object System.Text.UTF8Encoding $false

$nuevos = @(
    @{ Ruta = 'Facturacion.Cpe\VigenciaSunat.cs'; Texto = @'
namespace Facturacion.Cpe;

/// <summary>
/// DESDE CUÁNDO RIGEN LAS REGLAS NUEVAS DE SUNAT (14 de octubre de 2026).
///
/// SUNAT publicó un paquete de validaciones para el 01/08/2026 y lo postergó
/// al 01/01/2027 (Reglas de validación, hoja «Control de cambios», ajuste del
/// 24/07/2026). YA LO POSTERGÓ UNA VEZ, y puede volver a hacerlo: por eso la
/// fecha no va escrita en cada sitio que la usa, sino aquí, y el worker la
/// puede cambiar con SUNAT_REGLAS_2027_DESDE (formato yyyy-MM-dd) sin tocar
/// el código.
///
/// Lo que hoy depende de esta fecha:
///   - Resumen diario: las gratuitas se informan por clase (06, 07, 08, 09)
///     en vez de todas juntas en el 05, que SUNAT desactiva.
///
/// Detalle completo en el documento del proyecto «cambios-sunat-2027.md».
/// </summary>
public static class VigenciaSunat
{
    /// <summary>La fecha oficial, mientras SUNAT no diga otra cosa.</summary>
    public static readonly DateTime FechaOficial2027 = new(2027, 1, 1);

    /// <summary>Desde cuándo se generan los documentos con las reglas de 2027.</summary>
    public static DateTime Reglas2027Desde { get; set; } = FechaOficial2027;

    /// <summary>¿Un documento generado en esta fecha va con las reglas de 2027?</summary>
    public static bool Rigen2027(DateTime fechaGeneracion) =>
        fechaGeneracion.Date >= Reglas2027Desde.Date;

    /// <summary>Lo que se dice al arrancar, para que nadie tenga que adivinarlo.</summary>
    public static string Diagnostico() =>
        Reglas2027Desde.Date == FechaOficial2027
            ? "Reglas SUNAT 2027: rigen desde el 2027-01-01 (fecha oficial)."
            : $"Reglas SUNAT 2027: rigen desde el {Reglas2027Desde:yyyy-MM-dd} " +
              "(cambiada con SUNAT_REGLAS_2027_DESDE; la oficial es 2027-01-01).";
}
'@ },
    @{ Ruta = 'Facturacion.Cpe.Tests\Reglas2027Tests.cs'; Texto = @'
using System.Text.RegularExpressions;
using Facturacion.Cpe;

namespace Facturacion.Tests;

/// <summary>
/// LAS REGLAS DE SUNAT DE 2027 (14 de octubre de 2026). Detalle en el
/// documento del proyecto «cambios-sunat-2027.md».
///
/// Las fechas van escritas en cada prueba y no se toca VigenciaSunat: así
/// estas pruebas dan lo mismo hoy que el día que rijan las reglas.
/// </summary>
public class Reglas2027Tests
{
    private static LineaResumen LineaConGratuitas() => new()
    {
        Orden = 1,
        TipoComprobante = TipoComprobante.Boleta,
        Numero = "B001-00000001",
        Receptor = new Receptor { TipoDocumento = "1", NumeroDocumento = "12345678", RazonSocial = "CLIENTE" },
        TotalGravado = 100m,
        TotalIgv = 18m,
        TasaIgv = 18m,
        TotalGratuitoGravado = 20m,
        TotalGratuitoInafecto = 5m,
        TotalIgvGratuitas = 3.6m,
        ImporteTotal = 118m
    };

    private static List<string> CodigosDelResumen(DateTime fechaGeneracion)
    {
        var resumen = new ResumenDiario
        {
            Emisor = new Emisor { Ruc = "20999999990", RazonSocial = "PRUEBA" },
            FechaReferencia = fechaGeneracion.AddDays(-1),
            FechaGeneracion = fechaGeneracion,
            Lineas = [LineaConGratuitas()]
        };

        var xml = GeneradorResumenXml.Generar(resumen).ToString();

        return Regex.Matches(xml, @"InstructionID>(\d\d)<").Select(m => m.Groups[1].Value).ToList();
    }

    [Fact]
    public void Antes_de_2027_las_gratuitas_van_juntas_en_el_05()
    {
        Assert.Equal(["01", "05"], CodigosDelResumen(new DateTime(2026, 12, 31)));
    }

    [Fact]
    public void Desde_2027_las_gratuitas_van_por_clase()
    {
        // 20 gravadas → 06; 5 inafectas → 08. El 05 ya no aparece.
        Assert.Equal(["01", "06", "08"], CodigosDelResumen(new DateTime(2027, 1, 1)));
    }

    [Fact]
    public void El_resumen_lleva_la_tasa_y_el_igv_de_las_gratuitas()
    {
        var resumen = new ResumenDiario
        {
            Emisor = new Emisor { Ruc = "20999999990", RazonSocial = "PRUEBA" },
            FechaGeneracion = new DateTime(2027, 1, 1),
            FechaReferencia = new DateTime(2026, 12, 31),
            Lineas = [LineaConGratuitas()]
        };

        var xml = GeneradorResumenXml.Generar(resumen).ToString();

        Assert.Contains("Percent>18.00<", xml);   // 2992
        Assert.Contains(">GRA<", xml);            // tributo 9996
    }

    [Fact]
    public void La_liquidacion_de_compra_se_revierte_con_un_RR()
    {
        var rr = new ComunicacionBaja
        {
            Tipo = TipoComunicacionBaja.Reversion,
            FechaReferencia = RelojPeru.Hoy,
            Lineas = [new LineaBaja { Orden = 1, TipoComprobante = "04", Serie = "L001", Numero = 1, Motivo = "Error de digitacion" }]
        };

        Assert.Empty(ReglasBaja.Errores(rr));
    }

    [Fact]
    public void La_liquidacion_de_compra_no_va_en_una_comunicacion_de_baja()
    {
        var ra = new ComunicacionBaja
        {
            Tipo = TipoComunicacionBaja.Baja,
            FechaReferencia = RelojPeru.Hoy,
            Lineas = [new LineaBaja { Orden = 1, TipoComprobante = "04", Serie = "L001", Numero = 1, Motivo = "Error de digitacion" }]
        };

        Assert.Contains(ReglasBaja.Errores(ra), p => p.Contains("resumen de reversiones"));
    }

    [Fact]
    public void La_serie_de_una_liquidacion_empieza_con_L()
    {
        var rr = new ComunicacionBaja
        {
            Tipo = TipoComunicacionBaja.Reversion,
            FechaReferencia = RelojPeru.Hoy,
            Lineas = [new LineaBaja { Orden = 1, TipoComprobante = "04", Serie = "F001", Numero = 1, Motivo = "Error de digitacion" }]
        };

        Assert.Contains(ReglasBaja.Errores(rr), p => p.Contains("empieza por L"));
    }
}
'@ }
)

$reemplazos = @(
    @{ Ruta = 'Facturacion.Cpe\ResumenDiario.cs'
       Antes = @'
/// <summary>
/// Catálogo 11: identificador del tipo de monto en el resumen.
///
/// SON CINCO VALORES Y NO HAY MÁS. Los cinco están aquí abajo.
///
/// ESTA CLASE TUVO DOS ERRORES, Y EL SEGUNDO COSTÓ UN RECHAZO:
///
/// 1. Tenía un "05 = ISC" que no existe. El ISC no se declara en el catálogo
///    11 en absoluto: va en su propio cac:TaxTotal con el tributo 2000,
///    igual que el IGV.
///
/// 2. Después se le añadieron un 06, un 07, un 08 y un 09 para desglosar las
///    gratuitas por clase. Esos cuatro códigos NO EXISTEN. SUNAT rechazó el
///    resumen con el error 2256:
///
///        Valor no se encuentra en el catalogo: 11
///        (nodo: "sac:BillingPayment/cbc:InstructionID" valor: "06")
///
///    La confusión venía de la factura, donde cada clase de gratuita sí
///    tiene su afectación propia en el catálogo 07. El resumen no distingue:
///    solo quiere saber cuánto se entregó sin cobrar.
///
/// SI ALGUIEN VUELVE A NECESITAR UN CÓDIGO QUE NO ESTÉ AQUÍ, es que no
/// existe. El catálogo 11 no ha crecido desde que se publicó.
/// </summary>
public static class TipoMontoResumen
{
    public const string Gravado = "01";
    public const string Exonerado = "02";
    public const string Inafecto = "03";
    public const string Exportacion = "04";

    /// <summary>
    /// 05 - Gratuitas, todas juntas. No se desglosan por clase: el catálogo
    /// no tiene con qué.
    /// </summary>
    public const string Gratuitas = "05";
}
'@
       Despues = @'
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
'@ },
    @{ Ruta = 'Facturacion.Cpe\GeneradorResumenXml.cs'
       Antes = @'
        // LAS GRATUITAS VAN EN UN SOLO IMPORTE, con el código 05.
        //
        // El desglose por clase que hace LineaResumen sigue existiendo y
        // sigue siendo útil —el PDF y el panel lo aprovechan— pero el
        // resumen no tiene dónde ponerlo: el catálogo 11 no distingue entre
        // una bonificación gravada y una muestra médica inafecta. Suma las
        // cuatro y declara una sola cifra.
        var gratuitas =
            l.TotalGratuitoGravado + l.TotalGratuitoExonerado +
            l.TotalGratuitoInafecto + l.TotalGratuitoExportacion;

        if (gratuitas > 0)
            nodo.Add(Monto(l.Moneda, gratuitas, TipoMontoResumen.Gratuitas));
'@
       Despues = @'
        // LAS GRATUITAS: UN SOLO IMPORTE HASTA 2027, DESGLOSADAS DESDE 2027.
        //
        // Hasta que rigen las reglas de 2027, el catálogo 11 solo tiene el 05:
        // se suman las cuatro clases y se declara una cifra. Desde entonces
        // SUNAT desactiva el 05 y pide cada clase con su código (06 gravadas,
        // 07 exoneradas, 08 inafectas, 09 exportación). El desglose ya lo
        // hacía LineaResumen; ahora también se declara.
        //
        // Lo decide la fecha de GENERACIÓN del resumen, que es la que SUNAT
        // ve al recibirlo: un resumen generado el 2 de enero con boletas del
        // 31 de diciembre ya va con las reglas nuevas.
        if (VigenciaSunat.Rigen2027(fechaGeneracion))
        {
            if (l.TotalGratuitoGravado > 0)
                nodo.Add(Monto(l.Moneda, l.TotalGratuitoGravado, TipoMontoResumen.GratuitasGravadas));

            if (l.TotalGratuitoExonerado > 0)
                nodo.Add(Monto(l.Moneda, l.TotalGratuitoExonerado, TipoMontoResumen.GratuitasExoneradas));

            if (l.TotalGratuitoInafecto > 0)
                nodo.Add(Monto(l.Moneda, l.TotalGratuitoInafecto, TipoMontoResumen.GratuitasInafectas));

            if (l.TotalGratuitoExportacion > 0)
                nodo.Add(Monto(l.Moneda, l.TotalGratuitoExportacion, TipoMontoResumen.GratuitasExportacion));
        }
        else
        {
            var gratuitas =
                l.TotalGratuitoGravado + l.TotalGratuitoExonerado +
                l.TotalGratuitoInafecto + l.TotalGratuitoExportacion;

            if (gratuitas > 0)
                nodo.Add(Monto(l.Moneda, gratuitas, TipoMontoResumen.Gratuitas));
        }
'@ },
    @{ Ruta = 'Facturacion.Cpe\GeneradorResumenXml.cs'
       Antes = @'
        foreach (var linea in r.Lineas.OrderBy(l => l.Orden))
            raiz.Add(BloqueLinea(linea));
'@
       Despues = @'
        foreach (var linea in r.Lineas.OrderBy(l => l.Orden))
            raiz.Add(BloqueLinea(linea, r.FechaGeneracion));
'@ },
    @{ Ruta = 'Facturacion.Cpe\GeneradorResumenXml.cs'
       Antes = @'
    private static XElement BloqueLinea(LineaResumen l)
'@
       Despues = @'
    private static XElement BloqueLinea(LineaResumen l, DateTime fechaGeneracion)
'@ },
    @{ Ruta = 'Facturacion.Cpe\GeneradorResumenXml.cs'
       Antes = @'
/// 2. LAS GRATUITAS VAN TODAS JUNTAS, en el código 05 del catálogo 11. En la
///    factura cada clase tiene su afectación propia; aquí el resumen solo
///    quiere saber cuánto se entregó sin cobrar, no de qué clase era.
///
///    ESTO ESTUVO MAL Y SUNAT LO RECHAZÓ con el error 2256: se emitían
///    cuatro códigos —06 gravada, 07 exonerada, 08 inafecta, 09
///    exportación— que sencillamente no existen. El catálogo 11 entero son
///    cinco valores: 01 gravadas, 02 exoneradas, 03 inafectas, 04
///    exportación y 05 gratuitas. No hay más.
'@
       Despues = @'
/// 2. LAS GRATUITAS: hasta que rigen las reglas de 2027 van todas juntas, en
///    el código 05 del catálogo 11 (mandar 06–09 antes era el error 2256).
///    Desde entonces SUNAT desactiva el 05 y pide cada clase con su código:
///    06 gravadas, 07 exoneradas, 08 inafectas, 09 exportación. Ver
///    VigenciaSunat y TipoMontoResumen.
'@ },
    @{ Ruta = 'Facturacion.Cpe\ComunicacionBaja.cs'
       Antes = @'
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
'@
       Despues = @'
    /// <summary>
    /// Los tipos que admite un resumen de REVERSIONES (RR): retención (20),
    /// percepción (40) y liquidación de compra (04).
    ///
    /// LA LIQUIDACIÓN SE AGREGÓ EL 14 DE OCTUBRE DE 2026. Antes no se sabía
    /// por cuál vía se anulaba; las Reglas de validación de SUNAT (hoja
    /// «Resumen de reversiones», regla 2308) admiten "20", "40" y "04", con
    /// serie L### (2345) y cinco días de plazo desde el CDR (2958, vigente
    /// desde el 01/08/2026).
    /// </summary>
    private static readonly string[] TiposDeReversion = ["20", "40", "04"];

    /// <summary>Días para revertir una liquidación de compra (error 2958).</summary>
    public const int DiasParaRevertirLiquidacion = 5;
'@ },
    @{ Ruta = 'Facturacion.Cpe\ComunicacionBaja.cs'
       Antes = @'
                        $"'{l.TipoComprobante}' ({l.NumeroCompleto}) y un resumen " +
                        $"de reversiones solo admite comprobantes de retencion " +
                        $"(20) y de percepcion (40). Una factura o una nota se " +
                        $"anulan con una comunicacion de baja (error 2308).");
'@
       Despues = @'
                        $"'{l.TipoComprobante}' ({l.NumeroCompleto}) y un resumen " +
                        $"de reversiones solo admite comprobantes de retencion " +
                        $"(20), de percepcion (40) y liquidaciones de compra (04). " +
                        $"Una factura o una nota se anulan con una comunicacion " +
                        $"de baja (error 2308).");
'@ },
    @{ Ruta = 'Facturacion.Cpe\ComunicacionBaja.cs'
       Antes = @'
                else if (l.TipoComprobante is "20" or "40")
                {
'@
       Despues = @'
                else if (l.TipoComprobante == "04")
                {
                    problemas.Add(
                        $"La linea {l.Orden} es una liquidacion de compra " +
                        $"({l.NumeroCompleto}). No se da de baja: se anula con un " +
                        $"resumen de reversiones, dentro de los " +
                        $"{DiasParaRevertirLiquidacion} dias desde que SUNAT la " +
                        $"acepto (error 2958).");
                }
                else if (l.TipoComprobante is "20" or "40")
                {
'@ },
    @{ Ruta = 'Facturacion.Cpe\ComunicacionBaja.cs'
       Antes = @'
        "20" => 'R',
        "40" => 'P',
'@
       Despues = @'
        "20" => 'R',
        "40" => 'P',
        "04" => 'L',
'@ },
    @{ Ruta = 'Facturacion.Cpe\ComunicacionBaja.cs'
       Antes = @'
        if (!esReversion)
        {
            var limite = b.FechaReferencia.Date.AddDays(DiasParaDarDeBaja);
'@
       Despues = @'
        // LA LIQUIDACION DE COMPRA SI TIENE PLAZO EN EL RR: cinco dias desde el
        // CDR que la acepto (2958). Aqui solo se conoce la fecha de emision, y
        // el CDR llega ese dia o despues: por eso es un AVISO y no un error.
        // Un error bloquearia reversiones que todavia estan en plazo.
        if (esReversion && b.Lineas.Any(l => l.TipoComprobante == "04"))
        {
            var limiteLiq = b.FechaReferencia.Date.AddDays(DiasParaRevertirLiquidacion);

            if (RelojPeru.Hoy > limiteLiq)
            {
                problemas.Add(
                    $"Aviso: las liquidaciones de compra se emitieron el " +
                    $"{b.FechaReferencia:yyyy-MM-dd} y SUNAT da {DiasParaRevertirLiquidacion} " +
                    $"dias desde que las acepto para revertirlas. Si ya pasaron, " +
                    $"rechazara con el error 2958.");
            }
        }

        if (!esReversion)
        {
            var limite = b.FechaReferencia.Date.AddDays(DiasParaDarDeBaja);
'@ },
    @{ Ruta = 'Facturacion.Cpe\ComunicacionBaja.cs'
       Antes = @'
                $"'RA' para facturas y notas, y 'RR' para retenciones y " +
                $"percepciones.");
'@
       Despues = @'
                $"'RA' para facturas y notas, y 'RR' para retenciones, " +
                $"percepciones y liquidaciones de compra.");
'@ },
    @{ Ruta = 'Facturacion.Worker\Program.cs'
       Antes = @'
ValidacionPrevia.Bloquea = ConfiguracionSecretos
    .Opcional("FACTURACION_XSD_BLOQUEA", "false")
    .Equals("true", StringComparison.OrdinalIgnoreCase);
'@
       Despues = @'
ValidacionPrevia.Bloquea = ConfiguracionSecretos
    .Opcional("FACTURACION_XSD_BLOQUEA", "false")
    .Equals("true", StringComparison.OrdinalIgnoreCase);

// REGLAS DE SUNAT DE 2027 (14 oct 2026): desde qué fecha se generan los
// documentos con ellas. La oficial es el 2027-01-01; SUNAT ya la postergó una
// vez, así que se puede cambiar aquí sin tocar el código. Ver VigenciaSunat.
if (DateTime.TryParseExact(
        ConfiguracionSecretos.Opcional("SUNAT_REGLAS_2027_DESDE", ""),
        "yyyy-MM-dd", System.Globalization.CultureInfo.InvariantCulture,
        System.Globalization.DateTimeStyles.None, out var reglas2027))
{
    VigenciaSunat.Reglas2027Desde = reglas2027;
}
'@ },
    @{ Ruta = 'Facturacion.Worker\Program.cs'
       Antes = @'
    .CreateLogger("ValidacionPrevia")
    .LogInformation("{Diagnostico}", ValidacionPrevia.Diagnostico());
'@
       Despues = @'
    .CreateLogger("ValidacionPrevia")
    .LogInformation("{Diagnostico}", ValidacionPrevia.Diagnostico());

host.Services.GetRequiredService<ILoggerFactory>()
    .CreateLogger("ReglasSunat")
    .LogInformation("{Diagnostico}", VigenciaSunat.Diagnostico());
'@ },
    @{ Ruta = 'Facturacion.Api\EndpointsNotas.cs'
       Antes = @'
        ComprobanteBase nota = esCredito
            ? ConstruirCredito(peticion, tenant)
            : ConstruirDebito(peticion, tenant);
'@
       Despues = @'
        ComprobanteBase nota = esCredito
            ? ConstruirCredito(peticion, tenant)
            : ConstruirDebito(peticion, tenant);

        // --- La nota de crédito no puede superar al documento ---
        //
        // SUNAT lo rechaza (3286 en facturas; en boletas, la observación 4028
        // pasa a ser el error 3286 desde el 01/01/2027, con +1 de tolerancia).
        // El motivo 10 «Otros conceptos» está exento, y si las monedas son
        // distintas no se puede comparar. Decirlo aquí evita quemar un
        // correlativo de la serie de notas en un rechazo seguro.
        if (esCredito &&
            peticion.CodigoMotivo != "10" &&
            string.Equals(peticion.Moneda, afectado.Moneda, StringComparison.OrdinalIgnoreCase))
        {
            var totalNota = CalculadoraTotales.Calcular(nota).ImporteTotal;
            var tolerancia = peticion.Afectado.TipoDocumento == TipoComprobante.Boleta ? 1m : 0m;

            if (totalNota > afectado.ImporteTotal + tolerancia)
            {
                return Results.BadRequest(new RespuestaError(
                    "La nota de crédito supera al comprobante que modifica.",
                    $"La nota suma {totalNota:0.00} {peticion.Moneda} y " +
                    $"{afectado.NumeroCompleto} fue por {afectado.ImporteTotal:0.00}. " +
                    "SUNAT la rechazaría (error 3286). Si de verdad corresponde " +
                    "un monto mayor, usa el motivo 10 «Otros conceptos»."));
            }
        }
'@ },
    @{ Ruta = 'Facturacion.Api\EndpointsBajas.cs'
       Antes = @'
            .WithSummary("Revierte comprobantes de retención y percepción")
'@
       Despues = @'
            .WithSummary("Revierte retenciones, percepciones y liquidaciones de compra")
'@ },
    @{ Ruta = 'Facturacion.Api\EndpointsBajas.cs'
       Antes = @'
                "**Solo retenciones (20) y percepciones (40).** Las facturas y " +
'@
       Despues = @'
                "**Solo retenciones (20), percepciones (40) y liquidaciones " +
                "de compra (04, cinco días desde su aceptación).** Las facturas y " +
'@ },
    @{ Ruta = 'Facturacion.Api\PruebaMadrugada.cs'
       Antes = @'
            lineas = new[] { Linea("PM-005", "VENTA DE PRUEBA", 1, 50m) }
        }),
'@
       Despues = @'
            lineas = new[] { Linea("PM-005", "VENTA DE PRUEBA", 1, 50m) }
        }),

        // Las gratuitas de una boleta viajan en el resumen diario, y su forma
        // cambia con las reglas de 2027 (06–09 en vez del 05). Este caso es el
        // que avisa si SUNAT beta lo activa antes, o si nuestro cambio falla.
        new("boleta-bonificacion", "Boleta con bonificación (gratuitas en el resumen)", "/v1/comprobantes", (hoy, _) => new
        {
            tipo = "03", serie = "B900", fechaEmision = F(hoy), moneda = "PEN",
            receptor = new { tipoDocumento = "1", numeroDocumento = "12345678",
                             razonSocial = "CLIENTE DE PRUEBA", direccion = "LIMA" },
            lineas = new[]
            {
                Linea("PM-008", "VENTA DE PRUEBA", 1, 50m),
                Linea("PM-009", "PRODUCTO DE REGALO (BONIFICACION)", 1, 10m, afectacion: "15")
            }
        }),
'@ }
)

$lineas = @()

# --- 1. Comprobar todo, sin escribir nada ----------------------------------
$problemas = New-Object System.Collections.Generic.List[string]
$archivos = @{}   # ruta -> @{ Texto (con \n); Crlf; Original }

function Cargar([string]$ruta) {
    if ($archivos.ContainsKey($ruta)) { return $archivos[$ruta] }
    $completa = Join-Path $raiz $ruta
    if (-not (Test-Path $completa)) { return $null }
    $original = [System.IO.File]::ReadAllText($completa)
    $a = @{ Completa = $completa; Original = $original; Crlf = $original.Contains("`r`n"); Texto = $original.Replace("`r`n", "`n") }
    $archivos[$ruta] = $a
    return $a
}

foreach ($n in $nuevos) {
    $completa = Join-Path $raiz $n.Ruta
    if (Test-Path $completa) {
        $actual = [System.IO.File]::ReadAllText($completa).Replace("`r", '').TrimEnd()
        if ($actual -ne $n.Texto.Replace("`r", '').TrimEnd()) {
            $problemas.Add("$($n.Ruta) ya existe y es distinto. ¿Ya se aplicó otra versión?")
        }
    }
}

foreach ($r in $reemplazos) {
    $a = Cargar $r.Ruta
    if ($null -eq $a) { $problemas.Add("No existe $($r.Ruta)."); continue }
    $antes = $r.Antes.Replace("`r", '')
    $despues = $r.Despues.Replace("`r", '')
    if ($a.Texto.Contains($despues)) { continue }   # ya estaba aplicado
    $n = ([regex]::Matches($a.Texto, [regex]::Escape($antes))).Count
    if ($n -ne 1) {
        $problemas.Add("En $($r.Ruta) esperaba UNA vez:`n      $(($antes -split "`n")[0].Trim())`n    y aparece $n veces.")
        continue
    }
    $a.Texto = $a.Texto.Replace($antes, $despues)
}

foreach ($l in $lineas) {
    $a = Cargar $l.Ruta
    if ($null -eq $a) { $problemas.Add("No existe $($l.Ruta)."); continue }
    $ancla = $l.Ancla.Replace("`r", '')
    $nueva = $l.Nueva.Replace("`r", '')
    if ($a.Texto.Contains($nueva)) { continue }   # ya estaba
    $patron = '(?m)^([ \t]*)' + [regex]::Escape($ancla) + '[ \t]*$'
    $m = [regex]::Matches($a.Texto, $patron)
    if ($m.Count -ne 1) {
        $problemas.Add("En $($l.Ruta) esperaba UNA vez la línea del menú:`n      $ancla`n    y aparece $($m.Count) veces.")
        continue
    }
    $sangria = $m[0].Groups[1].Value
    $fin = $m[0].Index + $m[0].Length
    $a.Texto = $a.Texto.Substring(0, $fin) + "`n" + $sangria + $nueva + $a.Texto.Substring($fin)
}

if ($problemas.Count -gt 0) {
    Write-Host ''
    Write-Host 'NO SE TOCÓ NINGÚN ARCHIVO. Esto no cuadra:' -ForegroundColor Red
    foreach ($p in $problemas) { Write-Host "  - $p" -ForegroundColor Red }
    Write-Host ''
    exit 2
}

# --- 2. Escribir ------------------------------------------------------------
Write-Host ''
foreach ($n in $nuevos) {
    $completa = Join-Path $raiz $n.Ruta
    if (Test-Path $completa) { Write-Host "  IGUAL        $($n.Ruta)" -ForegroundColor DarkGray; continue }
    New-Item -ItemType Directory -Path (Split-Path $completa) -Force | Out-Null
    [System.IO.File]::WriteAllText($completa, $n.Texto.Replace("`r", '').Replace("`n", "`r`n"), $utf8SinBom)
    Write-Host "  NUEVO        $($n.Ruta)" -ForegroundColor Green
}

foreach ($ruta in $archivos.Keys) {
    $a = $archivos[$ruta]
    $salida = if ($a.Crlf) { $a.Texto.Replace("`n", "`r`n") } else { $a.Texto }
    if ($salida -eq $a.Original) { Write-Host "  IGUAL        $ruta" -ForegroundColor DarkGray; continue }
    $bak = "$($a.Completa).bak"
    if (Test-Path $bak) { $bak = "$($a.Completa).$(Get-Date -Format 'yyyyMMdd-HHmmss').bak" }
    Copy-Item $a.Completa $bak -Force
    [System.IO.File]::WriteAllText($a.Completa, $salida, $utf8SinBom)
    Write-Host "  CAMBIADO     $ruta  (copia: $(Split-Path $bak -Leaf))" -ForegroundColor Green
}

Write-Host ''
Write-Host 'SIGUIENTE: recompila, corre las pruebas del motor y reinicia el worker y la API (los comandos están en el mensaje de Claude).' -ForegroundColor Cyan
Write-Host ''
