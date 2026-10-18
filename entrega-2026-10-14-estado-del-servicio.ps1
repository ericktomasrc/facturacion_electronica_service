# =============================================================================
# Entrega 2026-10-14 — ESTADO DEL SERVICIO: LAS TARJETAS ARRIBA
#
# Se ejecuta desde la raíz del servicio:
#   cd "D:\Reyban Consulting\facturacion electronica\facturacion_electronica_service"
#   .\entrega-2026-10-14-estado-del-servicio.ps1
#
# CAMBIA: Facturacion.Api\wwwroot\diagnostico.html (3 trozos)
#   - Las seis tarjetas van primero; el estado general y su lista de avisos,
#     debajo.
#   - Cada tarjeta explica qué cuenta y se pinta cuando pide atención: verde
#     lo bueno, ámbar lo que hay que mirar, rojo lo que no sale solo.
#   - Los avisos van uno por fila, con el color del estado general.
#
# Comprueba todo antes de escribir; si algo no cuadra, NO TOCA NADA. Copia
# .bak. No pregunta nada.
# =============================================================================

$ErrorActionPreference = 'Stop'
$raiz = (Get-Location).Path

if (-not (Test-Path (Join-Path $raiz 'Facturacion.Api\wwwroot\diagnostico.html'))) {
    Write-Host "No encuentro 'Facturacion.Api\wwwroot\diagnostico.html' aquí ($raiz). Ejecútalo desde la raíz del servicio. No se tocó nada." -ForegroundColor Red
    exit 1
}

$utf8SinBom = New-Object System.Text.UTF8Encoding $false

$nuevos = @()

$reemplazos = @(
    @{ Ruta = 'Facturacion.Api\wwwroot\diagnostico.html'
       Antes = @'
  partes.push(`
    <div class="semaforo ${d.nivel}">
      <span class="punto"></span>
      <div>
        <div class="etiqueta">${textoNivel(d.nivel)}</div>
        <ul class="alertas">${d.alertas.map(a => `<li>${escapar(a)}</li>`).join("")}</ul>
      </div>
    </div>`);

  partes.push(`
    <div class="tarjetas">
      ${tarjeta(d.cola.pendientes, "En cola")}
      ${tarjeta(d.cola.esperandoReintento, "Esperando reintento")}
      ${tarjeta(d.cola.requierenRevision, "Requieren revisión")}
      ${tarjeta(d.hoy.aceptados, "Aceptados hoy")}
      ${tarjeta(d.hoy.rechazados, "Rechazados hoy")}
      ${tarjeta(d.hoy.tasaExito + "%", "Tasa de éxito")}
    </div>`);
'@
       Despues = @'
  // PRIMERO LOS NÚMEROS, que se leen de un vistazo; debajo, el estado general
  // con su lista de avisos, que puede ser larga (14 oct). Cada tarjeta se
  // pinta de su color cuando pide atención.
  const tasa = d.hoy.tasaExito;

  partes.push(`
    <div class="tarjetas">
      ${tarjeta(d.cola.pendientes, "En cola", "por enviar a SUNAT",
                d.cola.pendientes > 100 ? "atencion" : "")}
      ${tarjeta(d.cola.esperandoReintento, "Esperando reintento", "fallaron; se reintentan solos",
                d.cola.esperandoReintento > 0 ? "atencion" : "")}
      ${tarjeta(d.cola.requierenRevision, "Requieren revisión", "no van a salir solos",
                d.cola.requierenRevision > 0 ? "problema" : "")}
      ${tarjeta(d.hoy.aceptados, "Aceptados hoy", "por SUNAT",
                d.hoy.aceptados > 0 ? "sano" : "")}
      ${tarjeta(d.hoy.rechazados, "Rechazados hoy", "necesitan un comprobante nuevo",
                d.hoy.rechazados > 0 ? "problema" : "")}
      ${tarjeta(tasa + "%", "Tasa de éxito", "aceptados entre los de hoy",
                tasa < 80 ? "problema" : tasa < 95 ? "atencion" : "sano")}
    </div>`);

  const sinAvisos = d.alertas.length === 1 && d.alertas[0] === "Todo en orden.";

  partes.push(`
    <section class="semaforo ${d.nivel}">
      <div class="cabeza-estado">
        <span class="punto"></span>
        <div>
          <div class="etiqueta">${textoNivel(d.nivel)}</div>
          <div class="detalle-estado">${sinAvisos
            ? "No hay nada que atender."
            : d.alertas.length === 1 ? "Hay 1 cosa que atender:" : `Hay ${d.alertas.length} cosas que atender:`}</div>
        </div>
      </div>
      ${sinAvisos ? "" : `<ul class="alertas">${d.alertas.map(a => `<li>${escapar(a)}</li>`).join("")}</ul>`}
    </section>`);
'@ },
    @{ Ruta = 'Facturacion.Api\wwwroot\diagnostico.html'
       Antes = @'
const tarjeta = (valor, nombre) =>
  `<div class="tarjeta"><div class="valor">${valor}</div><div class="nombre">${nombre}</div></div>`;
'@
       Despues = @'
const tarjeta = (valor, nombre, pista = "", estado = "") =>
  `<div class="tarjeta ${estado}"><div class="valor">${valor}</div>` +
  `<div class="nombre">${nombre}</div>` +
  (pista ? `<div class="pista">${pista}</div>` : "") + `</div>`;
'@ },
    @{ Ruta = 'Facturacion.Api\wwwroot\diagnostico.html'
       Antes = @'
  .alertas li { margin:5px 0; }
'@
       Despues = @'
  .alertas li { margin:5px 0; }

  /* Estado del servicio (14 oct): las tarjetas arriba, el estado debajo. */
  .tarjeta { border:1px solid transparent; }
  .tarjeta .valor { font-variant-numeric:tabular-nums; }
  .tarjeta .pista { color:var(--tenue); font-size:12px; margin-top:2px; opacity:.85; }
  .tarjeta.sano .valor { color:var(--sano); }
  .tarjeta.atencion { border-color:var(--atencion); }
  .tarjeta.atencion .valor { color:var(--atencion); }
  .tarjeta.problema { border-color:var(--problema); }
  .tarjeta.problema .valor { color:var(--problema); }
  section.semaforo { display:block; padding:16px 18px; }
  section.semaforo.Sano { border-left:4px solid var(--sano); }
  section.semaforo.Atencion { border-left:4px solid var(--atencion); }
  section.semaforo.Problema { border-left:4px solid var(--problema); }
  .cabeza-estado { display:flex; align-items:center; gap:12px; }
  .detalle-estado { color:var(--tenue); font-size:13.5px; }
  .semaforo .alertas { list-style:none; padding:0; margin:14px 0 0; display:grid; gap:8px; }
  .semaforo .alertas li { margin:0; padding:10px 12px; border-radius:8px; background:var(--sutil);
                          border-left:3px solid var(--borde); }
  .Atencion .alertas li { border-left-color:var(--atencion); }
  .Problema .alertas li { border-left-color:var(--problema); }
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
Write-Host 'SIGUIENTE: en el navegador, Ctrl + F5 en Estado del servicio (no hace falta reiniciar la API).' -ForegroundColor Cyan
Write-Host ''
