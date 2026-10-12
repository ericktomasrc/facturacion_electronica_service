# =============================================================================
# Entrega 2026-10-11 - Retirar la empresa de ejemplo de la 001 (servicio)
#
# Se ejecuta desde la carpeta del servicio:
#   D:\Reyban Consulting\facturacion electronica\facturacion_electronica_service
#   .\entrega-2026-10-11-retirar-ejemplo.ps1
#
#   migraciones\025_retirar_empresa_ejemplo.sql   NUEVO. Desactiva la empresa de
#        ejemplo (RUC 20601234567), revoca su clave y desactiva sus series.
#        Nada se borra. Solo si no tiene comprobantes ni guias. No se aplica sola
#
# Todo o nada. UTF-8 sin BOM.
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

# --- migraciones\025_retirar_empresa_ejemplo.sql
Planear 'migraciones\025_retirar_empresa_ejemplo.sql' '' @'
-- =============================================================================
-- 025 - SE RETIRA LA EMPRESA DE EJEMPLO DE LA 001
--
-- La 001 mete una empresa de ejemplo (RUC 20601234567, MI EMPRESA SAC) y la 002
-- le crea una clave de acceso cuyo texto quedo en los archivos de entonces.
-- Desde el alta por la plataforma (parte C), toda empresa nace en la
-- plataforma: una empresa que no esta alli no deberia estar activa aqui.
--
-- NADA SE BORRA: la empresa, sus series y su clave quedan DESACTIVADAS (la
-- clave, ademas, revocada). La 001 y la 002 no se tocan: son el registro de
-- como empezo la base.
--
-- Solo si sigue siendo la de ejemplo: ese RUC, esa razon social y ningun
-- comprobante ni guia. Si alguien la uso de verdad, no se toca y se avisa.
--
-- Se puede correr dos veces: la segunda no cambia nada.
-- Sin tildes a proposito: PowerShell 5.1 la manda a psql en ASCII.
-- =============================================================================

BEGIN;

DO $$
DECLARE
    v_id     uuid;
    v_usada  boolean;
    v_claves integer;
    v_series integer;
BEGIN
    SELECT id INTO v_id
      FROM tenants
     WHERE ruc = '20601234567'
       AND razon_social = 'MI EMPRESA SAC';

    IF v_id IS NULL THEN
        RAISE NOTICE '025: no hay empresa de ejemplo. Nada que hacer.';
        RETURN;
    END IF;

    SELECT EXISTS (SELECT 1 FROM comprobantes WHERE tenant_id = v_id)
        OR EXISTS (SELECT 1 FROM guias WHERE tenant_id = v_id)
      INTO v_usada;

    IF v_usada THEN
        RAISE NOTICE '025: la empresa 20601234567 tiene comprobantes o guias: NO se toca. Revisala en el panel.';
        RETURN;
    END IF;

    UPDATE api_keys
       SET activo = false,
           revocado_en = COALESCE(revocado_en, now())
     WHERE tenant_id = v_id
       AND (activo OR revocado_en IS NULL);
    GET DIAGNOSTICS v_claves = ROW_COUNT;

    UPDATE series
       SET activo = false
     WHERE tenant_id = v_id
       AND activo;
    GET DIAGNOSTICS v_series = ROW_COUNT;

    UPDATE tenants
       SET activo = false
     WHERE id = v_id
       AND activo;

    RAISE NOTICE '025: empresa de ejemplo 20601234567 desactivada (% claves revocadas, % series desactivadas). Nada se borro.',
                 v_claves, v_series;
END $$;

-- La comprobacion: si sigue ahi sin uso, no puede quedar nada activo.
DO $$
BEGIN
    IF EXISTS (
        SELECT 1
          FROM tenants t
         WHERE t.ruc = '20601234567'
           AND t.razon_social = 'MI EMPRESA SAC'
           AND NOT EXISTS (SELECT 1 FROM comprobantes c WHERE c.tenant_id = t.id)
           AND NOT EXISTS (SELECT 1 FROM guias g WHERE g.tenant_id = t.id)
           AND (t.activo
                OR EXISTS (SELECT 1 FROM api_keys k WHERE k.tenant_id = t.id AND (k.activo OR k.revocado_en IS NULL))
                OR EXISTS (SELECT 1 FROM series s WHERE s.tenant_id = t.id AND s.activo))) THEN
        RAISE EXCEPTION '025: la empresa de ejemplo sigue con algo activo.';
    END IF;
END $$;

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
Write-Host 'FALTA APLICAR LA 025. Desde esta misma carpeta:' -ForegroundColor Yellow
Write-Host '    Get-Content migraciones\025_retirar_empresa_ejemplo.sql -Raw | docker compose exec -T postgres psql -U facturacion_owner -d facturacion -v ON_ERROR_STOP=1' -ForegroundColor Yellow
Write-Host 'Tiene que decir: «025: empresa de ejemplo 20601234567 desactivada (1 claves revocadas, 4 series desactivadas)».' -ForegroundColor Cyan
Write-Host ''
