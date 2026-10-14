# =============================================================================
# Entrega 2026-10-13 - La prueba de referencia de la firma
#
# Se ejecuta desde la raiz del SERVICIO:
#   D:\Reyban Consulting\facturacion electronica\facturacion_electronica_service
#   .\entrega-2026-10-13-prueba-firma.ps1
#
#   Facturacion.Cpe.Tests\FirmaReferenciaTests.cs   NUEVO. Firma siempre los
#       mismos XML con el mismo certificado de prueba y compara BYTE A BYTE
#       con lo que guardo la primera vez. Antes y despues de .NET 10.
#
# La referencia y su certificado de prueba se guardan FUERA del repositorio:
#   %LOCALAPPDATA%\reyban\firma-referencia
#
# No cambia nada del servicio. Todo o nada, con huellas. No pregunta nada.
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

# --- Facturacion.Cpe.Tests\FirmaReferenciaTests.cs
Planear 'Facturacion.Cpe.Tests\FirmaReferenciaTests.cs' '' @'
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Security.Cryptography.Xml;
using System.Text;
using System.Xml.Linq;
using Facturacion.Cpe;
using Xunit.Abstractions;

namespace Facturacion.Tests;

/// <summary>
/// LA FIRMA NO PUEDE CAMBIAR SIN QUE NOS ENTEREMOS (13 de octubre de 2026).
///
/// Para qué: antes de subir el runtime o System.Security.Cryptography.Xml (el
/// paso a .NET 10), se guarda cómo firma HOY el servicio. Después de cambiar,
/// la misma prueba vuelve a firmar exactamente lo mismo y compara BYTE A BYTE.
///
/// POR QUÉ BYTE A BYTE SIRVE: la firma que usamos (RSA PKCS#1 v1.5) es
/// determinista. Mismo XML, misma llave → mismos bytes, siempre. Si algo sale
/// distinto, cambió la canonicalización, el digest, la serialización o la
/// firma misma, y el mensaje de error dice dónde.
///
/// DÓNDE SE GUARDA LA REFERENCIA: FUERA del repositorio, en
/// %LOCALAPPDATA%\reyban\firma-referencia (o en la carpeta que diga la
/// variable REYBAN_FIRMA_REFERENCIA). Ahí va también el certificado de prueba
/// con el que se firma: es autofirmado y no vale nada, pero la regla del
/// proyecto es que ningún certificado entra a git, y se cumple.
///
/// LA PRIMERA VEZ crea el certificado y la referencia, y pasa. Las siguientes,
/// compara. Para empezar de cero, se borra esa carpeta.
/// </summary>
public class FirmaReferenciaTests
{
    private const string ClavePfx = "referencia-firma";

    private readonly ITestOutputHelper salida;

    public FirmaReferenciaTests(ITestOutputHelper salida) => this.salida = salida;

    /// <summary>Los casos que se firman. El nombre es el del archivo de referencia.</summary>
    private static IEnumerable<(string Nombre, Func<XDocument> Xml)> Casos()
    {
        yield return ("factura-una-linea", () => GeneradorFacturaXml.Generar(Datos.Factura()));

        yield return ("factura-tres-lineas", () => GeneradorFacturaXml.Generar(Datos.Factura(
            Datos.Linea(cantidad: 1, valorUnitario: 25.4567m, numero: 1),
            Datos.Linea(cantidad: 1000, valorUnitario: 0.35m, numero: 2),
            Datos.Linea(cantidad: 3, valorUnitario: 1999.99m, numero: 3))));

        yield return ("nota-credito", () => GeneradorNotaXml.Generar(Datos.NotaCredito()));

        // Sin pasar por los generadores: tildes, eñes, «&», comillas y espacios
        // entre etiquetas. Es lo que más castiga a la canonicalización.
        yield return ("xml-con-caracteres-especiales", XmlConCaracteresEspeciales);
    }

    [Fact]
    public void Firmar_dos_veces_lo_mismo_da_los_mismos_bytes()
    {
        // Si esto falla, la comparación con la referencia no tendría sentido:
        // algo del XML cambia solo (una fecha, un id al azar).
        using var certificado = CertificadoDeReferencia(Carpeta());

        foreach (var (nombre, xml) in Casos())
        {
            var a = FirmarYGuardar(xml(), certificado);
            var b = FirmarYGuardar(xml(), certificado);
            Assert.True(a.AsSpan().SequenceEqual(b), $"«{nombre}»: dos firmas seguidas no dieron los mismos bytes.");
        }
    }

    [Fact]
    public void La_firma_es_identica_a_la_referencia_guardada()
    {
        var carpeta = Carpeta();
        using var certificado = CertificadoDeReferencia(carpeta);

        var creados = new List<string>();
        var distintos = new List<string>();

        foreach (var (nombre, xml) in Casos())
        {
            var actual = FirmarYGuardar(xml(), certificado);

            // Además de idéntica, tiene que verificar.
            var releido = new System.Xml.XmlDocument { PreserveWhitespace = true };
            using (var ms = new MemoryStream(actual)) releido.Load(ms);
            Assert.True(FirmadorXml.VerificarFirma(releido), $"«{nombre}»: la firma no verifica.");

            var ruta = Path.Combine(carpeta, nombre + ".xml");
            if (!File.Exists(ruta))
            {
                File.WriteAllBytes(ruta, actual);
                creados.Add(nombre);
                continue;
            }

            var referencia = File.ReadAllBytes(ruta);
            if (referencia.AsSpan().SequenceEqual(actual)) continue;

            File.WriteAllBytes(Path.Combine(carpeta, nombre + ".DISTINTO.xml"), actual);
            distintos.Add(Diferencia(nombre, referencia, actual));
        }

        // La versión del ARCHIVO (8.0.x, 10.0.x), no la del ensamblado (siempre x.0.0.0).
        var xmlDll = typeof(SignedXml).Assembly;
        var entorno = $"{RuntimeInformation.FrameworkDescription} · System.Security.Cryptography.Xml " +
                      $"{System.Diagnostics.FileVersionInfo.GetVersionInfo(xmlDll.Location).FileVersion ?? xmlDll.GetName().Version?.ToString()}";

        if (creados.Count > 0)
        {
            File.AppendAllText(Path.Combine(carpeta, "LEEME.txt"),
                $"{DateTime.Now:yyyy-MM-dd HH:mm} referencia creada con {entorno}: {string.Join(", ", creados)}{Environment.NewLine}",
                new UTF8Encoding(false));
            salida.WriteLine($"Referencia CREADA en {carpeta} ({entorno}): {string.Join(", ", creados)}");
        }

        Assert.True(distintos.Count == 0,
            $"LA FIRMA CAMBIÓ con {entorno}.{Environment.NewLine}{string.Join(Environment.NewLine, distintos)}" +
            $"{Environment.NewLine}Lo nuevo quedó en los archivos *.DISTINTO.xml de {carpeta}.");

        salida.WriteLine($"Firma idéntica a la referencia ({entorno}). Carpeta: {carpeta}");
    }

    // ------------------------------------------------------------------ interno

    private static byte[] FirmarYGuardar(XDocument xml, X509Certificate2 certificado)
    {
        var firmado = FirmadorXml.Firmar(xml, certificado);

        // Por el mismo camino que el servicio: FirmadorXml.Guardar.
        var ruta = Path.Combine(Path.GetTempPath(), $"{Guid.NewGuid()}.xml");
        try
        {
            FirmadorXml.Guardar(firmado, ruta);
            return File.ReadAllBytes(ruta);
        }
        finally
        {
            if (File.Exists(ruta)) File.Delete(ruta);
        }
    }

    private static string Carpeta()
    {
        var carpeta = Environment.GetEnvironmentVariable("REYBAN_FIRMA_REFERENCIA");
        if (string.IsNullOrWhiteSpace(carpeta))
            carpeta = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "reyban", "firma-referencia");
        Directory.CreateDirectory(carpeta);
        return carpeta;
    }

    /// <summary>
    /// El certificado con el que se firma la referencia. Se crea UNA vez y se
    /// guarda en la carpeta de la referencia: con otro certificado los bytes
    /// cambiarían siempre y la comparación no serviría.
    /// </summary>
    private static X509Certificate2 CertificadoDeReferencia(string carpeta)
    {
        var ruta = Path.Combine(carpeta, "certificado-referencia.pfx");

        if (!File.Exists(ruta))
        {
            using var rsa = RSA.Create(2048);
            var peticion = new CertificateRequest(
                "CN=REFERENCIA FIRMA REYBAN", rsa, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
            using var generado = peticion.CreateSelfSigned(
                new DateTimeOffset(2026, 1, 1, 0, 0, 0, TimeSpan.Zero),
                new DateTimeOffset(2036, 1, 1, 0, 0, 0, TimeSpan.Zero));
            File.WriteAllBytes(ruta, generado.Export(X509ContentType.Pfx, ClavePfx));
        }

        return new X509Certificate2(File.ReadAllBytes(ruta), ClavePfx, X509KeyStorageFlags.Exportable);
    }

    private static XDocument XmlConCaracteresEspeciales()
    {
        XNamespace inv = "urn:oasis:names:specification:ubl:schema:xsd:Invoice-2";
        XNamespace ext = "urn:oasis:names:specification:ubl:schema:xsd:CommonExtensionComponents-2";
        XNamespace cbc = "urn:oasis:names:specification:ubl:schema:xsd:CommonBasicComponents-2";

        return new XDocument(
            new XDeclaration("1.0", "UTF-8", "no"),
            new XElement(inv + "Invoice",
                new XAttribute(XNamespace.Xmlns + "ext", ext),
                new XAttribute(XNamespace.Xmlns + "cbc", cbc),
                new XElement(ext + "UBLExtensions",
                    new XElement(ext + "UBLExtension", new XElement(ext + "ExtensionContent"))),
                new XElement(cbc + "ID", "F001-00000001"),
                new XElement(cbc + "Note", new XAttribute("languageLocaleID", "1000"),
                    "CIENTO VEINTE Y 50/100 SOLES"),
                new XElement(cbc + "Note", "Año 2026 · señal «ÁÉÍÓÚ ñ ü» & <cosas> \"entre\" comillas 'simples'"),
                new XElement(cbc + "Description", "  espacios   al inicio y al final  "),
                new XElement(cbc + "PayableAmount", new XAttribute("currencyID", "PEN"), "120.50")));
    }

    /// <summary>Dónde empieza la diferencia, con un poco de contexto de cada lado.</summary>
    private static string Diferencia(string nombre, byte[] referencia, byte[] actual)
    {
        var n = Math.Min(referencia.Length, actual.Length);
        var i = 0;
        while (i < n && referencia[i] == actual[i]) i++;

        static string Trozo(byte[] b, int desde) =>
            Encoding.UTF8.GetString(b, Math.Max(0, desde - 60), Math.Min(b.Length - Math.Max(0, desde - 60), 160));

        return $"  «{nombre}»: distinto desde el byte {i} (referencia {referencia.Length} bytes, ahora {actual.Length}).{Environment.NewLine}" +
               $"    referencia: …{Trozo(referencia, i)}…{Environment.NewLine}" +
               $"    ahora:      …{Trozo(actual, i)}…";
    }
}
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
Write-Host 'SIGUIENTE: corre las pruebas DOS veces (los comandos estan en el mensaje de Claude).' -ForegroundColor Yellow
Write-Host '  La 1.a crea la referencia; la 2.a tiene que decir "Firma identica a la referencia".' -ForegroundColor Yellow
Write-Host ''
