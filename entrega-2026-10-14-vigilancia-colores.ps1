# =============================================================================
# Entrega 2026-10-14 — VIGILANCIA SUNAT: COLORES POR RESULTADO
#
# Se ejecuta desde la raíz del servicio:
#   cd "D:\Reyban Consulting\facturacion electronica\facturacion_electronica_service"
#   .\entrega-2026-10-14-vigilancia-colores.ps1
#
# CAMBIA: Facturacion.Api\wwwroot\vigilancia.html (4 trozos)
#   Verde: aceptado (0). Ámbar: observación (4000 en adelante).
#   Rojo: rechazado (2000-3999) o error del envío (0100-1999). El código y la
#   fila entera llevan el color, y arriba de la tabla va la leyenda.
#
# Comprueba todo antes de escribir; si algo no cuadra, NO TOCA NADA. Copia
# .bak. No pregunta nada.
# =============================================================================

$ErrorActionPreference = 'Stop'
$raiz = (Get-Location).Path

if (-not (Test-Path (Join-Path $raiz 'Facturacion.Api\wwwroot\vigilancia.html'))) {
    Write-Host "No encuentro 'Facturacion.Api\wwwroot\vigilancia.html' aquí ($raiz). Ejecútalo desde la raíz del servicio. No se tocó nada." -ForegroundColor Red
    exit 1
}

$utf8SinBom = New-Object System.Text.UTF8Encoding $false

$nuevos = @()

$reemplazos = @(
    @{ Ruta = 'Facturacion.Api\wwwroot\vigilancia.html'
       Antes = @'
  .mensaje { max-width:420px; overflow-wrap:anywhere; }
'@
       Despues = @'
  .mensaje { max-width:420px; overflow-wrap:anywhere; }

  /* Color según lo que dijo SUNAT (14 oct): verde aceptado, rojo rechazo o
     error, ámbar observación. La fila entera lleva un tinte del mismo color. */
  .codigo { font-family:ui-monospace, Consolas, monospace; font-size:13px; font-weight:600;
            border-radius:6px; padding:1px 7px; border:1px solid currentColor; }
  .codigo.ok  { color:var(--sano); }
  .codigo.mal { color:var(--problema); }
  .codigo.obs { color:var(--atencion); }
  .codigo.neutro { color:var(--tenue); }
  tr.fila-ok  td { background:color-mix(in srgb, var(--sano) 7%, transparent); }
  tr.fila-mal td { background:color-mix(in srgb, var(--problema) 8%, transparent); }
  tr.fila-obs td { background:color-mix(in srgb, var(--atencion) 8%, transparent); }
  tr.fila-ok  td:first-child { box-shadow:inset 3px 0 0 var(--sano); }
  tr.fila-mal td:first-child { box-shadow:inset 3px 0 0 var(--problema); }
  tr.fila-obs td:first-child { box-shadow:inset 3px 0 0 var(--atencion); }
  tr.fila-mal .mensaje { color:var(--problema); }
  .leyenda { display:flex; gap:14px; flex-wrap:wrap; font-size:13px; color:var(--tenue); margin:0 0 12px; }
  .leyenda span { display:inline-flex; align-items:center; gap:6px; }
  .leyenda i { width:12px; height:12px; border-radius:3px; display:inline-block; }
'@ },
    @{ Ruta = 'Facturacion.Api\wwwroot\vigilancia.html'
       Antes = @'
    const etiqueta = c.nuevo
      ? ` <span class="pildora ${c.gravedad}">nuevo</span>`
      : (c.origen === "historico" && !c.revisadoEn ? ` <span class="pildora">conocido</span>` : "");

    return `
      <tr class="${c.nuevo ? "nuevo " + c.gravedad : ""}">
        <td class="mono">${esc(c.codigo)}${etiqueta}<div class="sub">${clase}</div></td>
'@
       Despues = @'
    const etiqueta = c.nuevo
      ? ` <span class="pildora ${c.gravedad}">nuevo</span>`
      : (c.origen === "historico" && !c.revisadoEn ? ` <span class="pildora">conocido</span>` : "");
    const t = tipoCodigo(c);

    return `
      <tr class="fila-${t.clase}${c.nuevo ? " nuevo" : ""}">
        <td><span class="codigo ${t.clase}">${esc(c.codigo)}</span>${etiqueta}<div class="sub">${t.texto}</div></td>
'@ },
    @{ Ruta = 'Facturacion.Api\wwwroot\vigilancia.html'
       Antes = @'
      <div class="filtros">
'@
       Despues = @'
      <div class="leyenda">
        <span><i style="background:var(--sano)"></i>Aceptado</span>
        <span><i style="background:var(--atencion)"></i>Aceptado con observación</span>
        <span><i style="background:var(--problema)"></i>Rechazado o error del envío</span>
      </div>
      <div class="filtros">
'@ },
    @{ Ruta = 'Facturacion.Api\wwwroot\vigilancia.html'
       Antes = @'
// --------------------------------------------------------------- revisado
'@
       Despues = @'
// Qué significa cada código: 0 aceptado; 0100-1999 SUNAT no pudo recibirlo;
// 2000-3999 rechazado; 4000 en adelante, observación (el comprobante pasa).
function tipoCodigo(c) {
  if (c.clase === "observacion") return { clase: "obs", texto: "observación · aceptado" };
  const m = String(c.codigo).match(/(\d+)$/);
  const n = m ? parseInt(m[1], 10) : NaN;
  if (n === 0) return { clase: "ok", texto: "aceptado" };
  if (n >= 100 && n < 2000) return { clase: "mal", texto: "error del envío" };
  if (n >= 2000 && n < 4000) return { clase: "mal", texto: "rechazado" };
  if (n >= 4000) return { clase: "obs", texto: "observación" };
  return { clase: "neutro", texto: "respuesta" };
}

// --------------------------------------------------------------- revisado
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
Write-Host 'SIGUIENTE: en el navegador, Ctrl + F5 en Vigilancia SUNAT (no hace falta reiniciar la API).' -ForegroundColor Cyan
Write-Host ''
