# =============================================================================
# Pruebas de la PARTE A — el webhook de la API (POST/GET /v1/webhook)
#
# Comprueba:
#   - Lo que TIENE QUE FALLAR: sin clave, clave inventada, URLs malas o
#     internas (10.x, 192.168.x, 169.254.169.254, nombres de la red interna).
#   - Registrar y volver a registrar: MISMO webhook, secreto NUEVO.
#   - GET nunca devuelve el secreto.
#   - El aviso llega firmado con el secreto NUEVO y no con el viejo (necesita
#     que pulses «Probar» en el panel; el script te avisa y espera).
#   - Reintentar las entregas agotadas.
#   - Con la clave de OTRA empresa (opcional): no ve ni toca el de la tuya.
#   - El secreto NO aparece en auditoria ni en webhook_cambios.
#
# QUÉ DEJA: un webhook de la API en MI EMPRESA apuntando a
# http://localhost:5999/prueba-webhook/ (un oyente que este mismo script abre
# y cierra), y sus filas en webhook_cambios. Al terminar te dice cómo
# desactivarlo en el panel. No crea comprobantes ni toca los que hay.
#
# Necesita: el servicio arrancado (API y worker) con la 023 aplicada y
# FACTURACION_WEBHOOKS_LOCALES=true en el .env.
#
# Se ejecuta desde cualquier carpeta:
#   .\pruebas-webhook-api.ps1
#
# LAS CLAVES SE PEGAN AQUÍ, EN POWERSHELL, NUNCA EN EL CHAT. No se escriben en
# ningún archivo ni se muestran.
# =============================================================================

$ErrorActionPreference = 'Stop'

$Base        = 'http://localhost:5100'
$PuertoOyente = 5999
$UrlPrueba   = "http://localhost:$PuertoOyente/prueba-webhook/"

$resultados = New-Object System.Collections.Generic.List[object]

function Leer-Clave([string]$pregunta) {
    $segura = Read-Host -Prompt $pregunta -AsSecureString
    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($segura)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
}

function Llamar([string]$metodo, [string]$ruta, $cuerpo = $null, [string]$clave = '') {
    $cabeceras = @{}
    if ($clave -ne '') { $cabeceras['Authorization'] = "Bearer $clave" }

    $p = @{ Uri = "$Base$ruta"; Method = $metodo; UseBasicParsing = $true; Headers = $cabeceras }
    if ($null -ne $cuerpo) {
        $p.Body = [System.Text.Encoding]::UTF8.GetBytes(($cuerpo | ConvertTo-Json -Depth 6 -Compress))
        $p.ContentType = 'application/json; charset=utf-8'
    }
    try {
        $r = Invoke-WebRequest @p
        $texto = [System.Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray())
        return [pscustomobject]@{ Codigo = [int]$r.StatusCode; Texto = $texto }
    }
    catch {
        $codigo = 0
        $texto = $_.Exception.Message
        $respuesta = $_.Exception.Response
        if ($respuesta) { $codigo = [int]$respuesta.StatusCode }

        if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
            $texto = $_.ErrorDetails.Message
        }
        elseif ($respuesta -and ($respuesta | Get-Member -Name GetResponseStream)) {
            try {
                $flujo = $respuesta.GetResponseStream()
                if ($flujo.CanSeek) { $flujo.Position = 0 }
                $lector = New-Object System.IO.StreamReader($flujo, [System.Text.Encoding]::UTF8)
                $leido = $lector.ReadToEnd()
                if ($leido) { $texto = $leido }
            }
            catch { }
        }
        return [pscustomobject]@{ Codigo = $codigo; Texto = $texto }
    }
}

function Anotar([string]$prueba, [bool]$ok, [string]$detalle = '') {
    $resultados.Add([pscustomobject]@{ Prueba = $prueba; Ok = $ok })
    $color = if ($ok) { 'Green' } else { 'Red' }
    $marca = if ($ok) { ' OK  ' } else { 'FALLA' }
    Write-Host ("  [{0}] {1}" -f $marca, $prueba) -ForegroundColor $color
    if (-not $ok -and $detalle) { Write-Host ("          {0}" -f $detalle) -ForegroundColor DarkYellow }
}

function Recortar([string]$t) { if ($t.Length -gt 200) { return $t.Substring(0, 200) + '…' } return $t }

function Esperar([string]$prueba, $r, [int]$codigo) {
    Anotar $prueba ($r.Codigo -eq $codigo) ("Esperaba {0}, llegó {1}: {2}" -f $codigo, $r.Codigo, (Recortar $r.Texto))
}

function Hmac([string]$secreto, [string]$texto) {
    $h = New-Object System.Security.Cryptography.HMACSHA256 (,[System.Text.Encoding]::UTF8.GetBytes($secreto))
    try {
        $b = $h.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($texto))
        return (([System.BitConverter]::ToString($b)).Replace('-', '')).ToLowerInvariant()
    }
    finally { $h.Dispose() }
}

Write-Host ''
Write-Host 'Pruebas del webhook de la API' -ForegroundColor Cyan
Write-Host ''

$ClaveA = Leer-Clave 'Pega la clave fac_ de MI EMPRESA (no se verá)'
if (-not $ClaveA.StartsWith('fac_')) { Write-Host 'Eso no parece una clave fac_. No se hizo nada.' -ForegroundColor Red; exit 1 }

# --- 1. Sin clave, clave inventada ----------------------------------------

Write-Host ''
Write-Host '1. Sin clave o con una inventada' -ForegroundColor Cyan

Esperar 'GET /v1/webhook sin clave -> 401' (Llamar 'GET' '/v1/webhook') 401
Esperar 'POST /v1/webhook sin clave -> 401' (Llamar 'POST' '/v1/webhook' @{ url = $UrlPrueba }) 401
Esperar 'GET /v1/webhook con clave inventada -> 401' (Llamar 'GET' '/v1/webhook' $null 'fac_test_estaclavenoexiste0000000000') 401
Esperar 'POST /v1/webhook/reintentar sin clave -> 401' (Llamar 'POST' '/v1/webhook/reintentar') 401

# --- 2. URLs que se rechazan ----------------------------------------------

Write-Host ''
Write-Host '2. URLs que se tienen que rechazar (incluso en desarrollo)' -ForegroundColor Cyan

$malas = [ordered]@{
    'sin URL'                              = ''
    'ftp://'                               = 'ftp://ejemplo.pe/avisos'
    'usuario y clave en la URL'            = 'https://usuario:clave@ejemplo.pe/avisos'
    'IP privada 10.x'                      = 'http://10.0.0.5/avisos'
    'IP privada 192.168.x'                 = 'http://192.168.1.10:8080/avisos'
    'IP privada 172.16.x'                  = 'https://172.16.0.1/avisos'
    'metadatos de la nube 169.254.169.254' = 'http://169.254.169.254/latest/meta-data/'
    'nombre de la red interna (postgres)'  = 'http://postgres:5432/'
    'nombre .internal'                     = 'https://minio.internal/avisos'
}

foreach ($caso in $malas.GetEnumerator()) {
    $r = Llamar 'POST' '/v1/webhook' @{ url = $caso.Value } $ClaveA
    Esperar ("rechaza {0} -> 400" -f $caso.Key) $r 400
}

# --- 3. Registrar, y volver a registrar ------------------------------------

Write-Host ''
Write-Host '3. Registrar y volver a registrar: mismo webhook, secreto nuevo' -ForegroundColor Cyan

$antes = Llamar 'GET' '/v1/webhook' $null $ClaveA
Esperar 'GET /v1/webhook con tu clave -> 200' $antes 200

$r1 = Llamar 'POST' '/v1/webhook' @{ url = $UrlPrueba } $ClaveA
Esperar 'POST /v1/webhook -> 200' $r1 200
if ($r1.Codigo -ne 200) { Write-Host 'Sin registro no se puede seguir.' -ForegroundColor Red; exit 1 }
$j1 = $r1.Texto | ConvertFrom-Json
Anotar 'devuelve un secreto whsec_' ($j1.secreto -like 'whsec_*')
Anotar 'la URL guardada es la enviada' ($j1.url -eq $UrlPrueba) $j1.url
Write-Host ("          {0} · id {1}" -f $(if ($j1.creado) { 'creado' } else { 'ya existía: rotado' }), $j1.id) -ForegroundColor DarkGray

# El cuerpo puede traer otra empresa: se ignora. La empresa sale de la clave.
$r2 = Llamar 'POST' '/v1/webhook' @{ url = $UrlPrueba; tenantId = '00000000-0000-0000-0000-000000000001' } $ClaveA
Esperar 'POST /v1/webhook otra vez (con un tenantId inventado en el cuerpo) -> 200' $r2 200
$j2 = $r2.Texto | ConvertFrom-Json
Anotar 'es el MISMO webhook (mismo id)' ($j2.id -eq $j1.id) ("{0} / {1}" -f $j1.id, $j2.id)
Anotar 'creado = false (se actualizó, no se creó otro)' ($j2.creado -eq $false)
Anotar 'el secreto es NUEVO' ($j2.secreto -like 'whsec_*' -and $j2.secreto -ne $j1.secreto)
Anotar 'avisa de que el anterior dejó de valer' ($j2.aviso -like '*anterior*')

$g = Llamar 'GET' '/v1/webhook' $null $ClaveA
Esperar 'GET /v1/webhook -> 200' $g 200
$jg = $g.Texto | ConvertFrom-Json
Anotar 'GET: registrado, mismo id y misma URL' ($jg.registrado -and $jg.id -eq $j1.id -and $jg.url -eq $UrlPrueba)
Anotar 'GET: NO trae ningún secreto' (-not ($g.Texto -like '*whsec_*') -and -not ($g.Texto -like '*secreto"*'))
Anotar 'GET: el último cambio es una rotación hecha por la API' ($jg.ultimoCambio.accion -eq 'rotacion' -and $jg.ultimoCambio.hechoDesde -eq 'api')
Anotar 'GET: el prefijo de la clave es el de tu clave' ($jg.ultimoCambio.prefijoClave -eq $ClaveA.Substring(0, [Math]::Min(20, $ClaveA.Length)))

# --- 4. El aviso llega firmado con el secreto nuevo -----------------------

Write-Host ''
Write-Host '4. El aviso llega firmado con el secreto NUEVO' -ForegroundColor Cyan

$oyente = New-Object System.Net.HttpListener
$oyente.Prefixes.Add($UrlPrueba)
$recibido = $null

try {
    $oyente.Start()

    Write-Host ''
    Write-Host '  AHORA: en el panel del servicio, empresa MI EMPRESA, pestaña Webhooks,' -ForegroundColor Yellow
    Write-Host '  pulsa «Probar» en el que dice «registrado por la API».' -ForegroundColor Yellow
    Write-Host '  Espero hasta 90 segundos...' -ForegroundColor Yellow

    $espera = $oyente.BeginGetContext($null, $null)

    if ($espera.AsyncWaitHandle.WaitOne([TimeSpan]::FromSeconds(90))) {
        $ctx = $oyente.EndGetContext($espera)
        $lector = New-Object System.IO.StreamReader($ctx.Request.InputStream, [System.Text.Encoding]::UTF8)
        $cuerpo = $lector.ReadToEnd()

        $recibido = [pscustomobject]@{
            Marca  = $ctx.Request.Headers['X-Facturacion-Timestamp']
            Firma  = $ctx.Request.Headers['X-Facturacion-Firma']
            Tipo   = $ctx.Request.Headers['X-Facturacion-Tipo']
            Cuerpo = $cuerpo
        }

        $ctx.Response.StatusCode = 200
        $ctx.Response.Close()
    }
}
finally {
    $oyente.Stop()
    $oyente.Close()
}

if ($null -eq $recibido) {
    Anotar 'llegó el aviso de prueba' $false 'No llegó nada en 90 s. ¿El worker está arrancado y su registro dice "destinos LOCALES PERMITIDOS"?'
}
else {
    Anotar ("llegó el aviso de prueba (tipo {0})" -f $recibido.Tipo) $true
    $conNuevo = Hmac $j2.secreto ("{0}.{1}" -f $recibido.Marca, $recibido.Cuerpo)
    $conViejo = Hmac $j1.secreto ("{0}.{1}" -f $recibido.Marca, $recibido.Cuerpo)
    Anotar 'la firma cuadra con el secreto NUEVO' ($recibido.Firma -eq $conNuevo)
    Anotar 'la firma NO cuadra con el secreto viejo' ($recibido.Firma -ne $conViejo)
}

# --- 5. Reintentar las agotadas -------------------------------------------

Write-Host ''
Write-Host '5. Reintentar las entregas agotadas' -ForegroundColor Cyan

$ri = Llamar 'POST' '/v1/webhook/reintentar?dias=7' $null $ClaveA
Esperar 'POST /v1/webhook/reintentar -> 200' $ri 200
if ($ri.Codigo -eq 200) { Write-Host ("          {0}" -f ($ri.Texto | ConvertFrom-Json).mensaje) -ForegroundColor DarkGray }

# --- 6. Otra empresa (opcional) -------------------------------------------

Write-Host ''
Write-Host '6. Con la clave de OTRA empresa (opcional)' -ForegroundColor Cyan

$ClaveB = Leer-Clave 'Pega la clave fac_ de OTRA empresa, o pulsa Enter para saltar'

if ($ClaveB -eq '') {
    Write-Host '  (saltado)' -ForegroundColor DarkGray
}
else {
    $gb = Llamar 'GET' '/v1/webhook' $null $ClaveB
    Esperar 'GET /v1/webhook con la otra clave -> 200' $gb 200
    $jb = $gb.Texto | ConvertFrom-Json
    Anotar 'la otra empresa NO ve tu webhook' (-not $jb.registrado -or $jb.id -ne $j1.id) $gb.Texto
    Anotar 'ni tu URL de prueba' (-not ($gb.Texto -like "*$PuertoOyente*"))

    $rb = Llamar 'POST' '/v1/webhook/reintentar' $null $ClaveB
    Esperar 'reintentar con la otra clave -> 200 (solo toca lo suyo)' $rb 200

    $ga = Llamar 'GET' '/v1/webhook' $null $ClaveA
    $ja = $ga.Texto | ConvertFrom-Json
    Anotar 'tu webhook sigue igual después' ($ja.id -eq $j1.id -and $ja.url -eq $UrlPrueba)
}

# --- 7. El secreto no está en la bitácora ---------------------------------

Write-Host ''
Write-Host '7. El secreto no aparece en auditoria ni en webhook_cambios' -ForegroundColor Cyan

try {
    $sql = "SELECT (SELECT count(*) FROM auditoria a WHERE a::text LIKE '%whsec_%') || ' ' || (SELECT count(*) FROM webhook_cambios c WHERE c::text LIKE '%whsec_%');"
    $salida = (docker exec facturacion-db psql -U facturacion_owner -d facturacion -t -A -c $sql) | Out-String
    $partes = $salida.Trim().Split(' ')
    Anotar 'whsec_ en auditoria: 0' ($partes[0] -eq '0') "Encontradas: $($partes[0])"
    Anotar 'whsec_ en webhook_cambios: 0' ($partes[1] -eq '0') "Encontradas: $($partes[1])"
}
catch {
    Anotar 'consulta a la base (docker)' $false $_.Exception.Message
}

# --- Resumen --------------------------------------------------------------

$ClaveA = $null; $ClaveB = $null

$fallos = @($resultados | Where-Object { -not $_.Ok }).Count
Write-Host ''
if ($fallos -eq 0) {
    Write-Host ("TODO BIEN: {0} de {0}." -f $resultados.Count) -ForegroundColor Green
}
else {
    Write-Host ("{0} FALLAS de {1}. Pásame esta salida." -f $fallos, $resultados.Count) -ForegroundColor Red
}

Write-Host ''
Write-Host 'PARA TERMINAR: en el panel, pestaña Webhooks de MI EMPRESA, pulsa «Desactivar»' -ForegroundColor Cyan
Write-Host 'en el que dice «registrado por la API» (apunta a este script, que ya se cerró).' -ForegroundColor Cyan
Write-Host 'No se borra: queda desactivado, con su historial. La parte B creará el bueno.' -ForegroundColor Cyan
Write-Host ''
