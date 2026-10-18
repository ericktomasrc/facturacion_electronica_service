# =============================================================================
# Entrega 2026-10-14 — PRUEBA DE MADRUGADA: TEXTOS DEL CAMBIO
#
# Se ejecuta desde la raíz del servicio:
#   cd "D:\Reyban Consulting\facturacion electronica\facturacion_electronica_service"
#   .\entrega-2026-10-14-madrugada-textos.ps1
#
# «volvió a pasar» hacía pensar que el error seguía. Ahora:
#   antes falló y ahora funciona -> «ya funciona (antes falló)», en verde
#   antes funcionaba y ahora no   -> «ahora falla», en rojo
# También el correo: «… ya funciona (antes fallaba)».
#
# CAMBIA: Facturacion.Api\PruebaMadrugada.cs (1 trozo)
#         Facturacion.Api\wwwroot\vigilancia.html (4 trozos)
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
            return ("volvió a pasar", "atencion", $"Prueba de madrugada: «{nombre}» volvió a pasar");
'@
       Despues = @'
            return ("ya funciona", "atencion", $"Prueba de madrugada: «{nombre}» ya funciona (antes fallaba)");
'@ },
    @{ Ruta = 'Facturacion.Api\wwwroot\vigilancia.html'
       Antes = @'
  .pildora.atencion { color:var(--atencion); border-color:var(--atencion); }
'@
       Despues = @'
  .pildora.atencion { color:var(--atencion); border-color:var(--atencion); }
  .pildora.sano { color:var(--sano); border-color:var(--sano); }
'@ },
    @{ Ruta = 'Facturacion.Api\wwwroot\vigilancia.html'
       Antes = @'
      const marca = k && k.cambio && !["igual", "primera vez", "sin respuesta"].includes(k.cambio)
        ? ` <span class="pildora ${k.estado === "ok" || k.estado === "obs" ? "atencion" : "problema"}">${esc(k.cambio)}</span>` : "";
'@
       Despues = @'
      const marca = k && k.cambio && !["igual", "primera vez", "sin respuesta"].includes(k.cambio)
        ? ` <span class="pildora ${claseCambio(k)}">${esc(textoCambio(k.cambio))}</span>` : "";
'@ },
    @{ Ruta = 'Facturacion.Api\wwwroot\vigilancia.html'
       Antes = @'
        <dt>Contra la anterior</dt><dd>${esc(k.cambio || "todavía no se compara")}</dd>
'@
       Despues = @'
        <dt>Contra la anterior</dt><dd>${esc(k.cambio ? textoCambio(k.cambio) : "todavía no se compara")}</dd>
'@ },
    @{ Ruta = 'Facturacion.Api\wwwroot\vigilancia.html'
       Antes = @'
const diaCorto = v =>
'@
       Despues = @'
// Cómo se lee el cambio respecto a la corrida anterior. «volvió a pasar» era
// el texto de la primera versión: hacía pensar que el error seguía.
const TEXTO_CAMBIO = {
  "volvió a pasar": "ya funciona (antes falló)", "ya funciona": "ya funciona (antes falló)",
  "ahora rechaza": "ahora falla", "nuestra API falla": "ahora falla en nuestra API",
  "otro rechazo": "falla por otro motivo", "nueva observación": "observación nueva",
  "igual": "igual que la anterior", "primera vez": "primera vez que se prueba",
  "sin respuesta": "SUNAT no respondió"
};
const textoCambio = c => TEXTO_CAMBIO[c] || c;
const claseCambio = k => k.estado === "ok" ? "sano" : k.estado === "obs" ? "atencion" : "problema";

const diaCorto = v =>
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
Write-Host 'SIGUIENTE: recompila, reinicia la API y Ctrl + F5 en Vigilancia SUNAT.' -ForegroundColor Cyan
Write-Host ''
