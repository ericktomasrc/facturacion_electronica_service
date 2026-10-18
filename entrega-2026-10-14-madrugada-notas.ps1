# =============================================================================
# Entrega 2026-10-14 — PRUEBA DE MADRUGADA: LAS NOTAS ESPERAN A SU FACTURA
#
# Se ejecuta desde la raíz del servicio:
#   cd "D:\Reyban Consulting\facturacion electronica\facturacion_electronica_service"
#   .\entrega-2026-10-14-madrugada-notas.ps1
#
# CAMBIA: Facturacion.Api\PruebaMadrugada.cs (3 trozos)
#   La nota de crédito y la de débito se emitían en el mismo segundo que su
#   factura, y nuestra API (con razón) no deja emitir una nota sobre una
#   factura que SUNAT todavía no aceptó. Ahora esperan, como la baja.
#
# Comprueba todo antes de escribir; si algo no cuadra, NO TOCA NADA. Copia
# .bak. No pregunta nada.
# =============================================================================

$ErrorActionPreference = 'Stop'
$raiz = (Get-Location).Path

if (-not (Test-Path (Join-Path $raiz 'Facturacion.Api\PruebaMadrugada.cs'))) {
    Write-Host "No encuentro 'Facturacion.Api\PruebaMadrugada.cs' aquí ($raiz). Ejecútalo desde la raíz del servicio. No se tocó nada." -ForegroundColor Red
    exit 1
}

$utf8SinBom = New-Object System.Text.UTF8Encoding $false

$nuevos = @()

$reemplazos = @(
    @{ Ruta = 'Facturacion.Api\PruebaMadrugada.cs'
       Antes = @'
                lineas = new[] { Linea("PM-001", "SERVICIO DE PRUEBA DE MADRUGADA", 1, 100m) }
            }, Depende: "factura-simple"),
'@
       Despues = @'
                lineas = new[] { Linea("PM-001", "SERVICIO DE PRUEBA DE MADRUGADA", 1, 100m) }
            }, Depende: "factura-simple", EsperaAceptado: true),
'@ },
    @{ Ruta = 'Facturacion.Api\PruebaMadrugada.cs'
       Antes = @'
                lineas = new[] { Linea("PM-006", "INTERESES POR MORA", 1, 10m) }
            }, Depende: "factura-simple"),
'@
       Despues = @'
                lineas = new[] { Linea("PM-006", "INTERESES POR MORA", 1, 10m) }
            }, Depende: "factura-simple", EsperaAceptado: true),
'@ },
    @{ Ruta = 'Facturacion.Api\PruebaMadrugada.cs'
       Antes = @'
/// Van en este orden porque algunos dependen de otros: las notas modifican la
/// «factura simple» de esa misma noche, y la baja se pide sobre una factura
/// que SUNAT ya aceptó (la espera hasta 5 minutos).
'@
       Despues = @'
/// Van en este orden porque algunos dependen de otros: las notas modifican la
/// «factura simple» de esa misma noche, y la baja se pide sobre otra factura.
/// Las tres ESPERAN (hasta 5 minutos) a que SUNAT acepte su factura: nuestra
/// API no deja emitir una nota ni una baja sobre algo que SUNAT no aceptó
/// todavía (corregido el 14 oct, tras la primera corrida).
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
Write-Host 'SIGUIENTE: recompila, reinicia la API y pulsa «Correr ahora» en Vigilancia SUNAT.' -ForegroundColor Cyan
Write-Host ''
