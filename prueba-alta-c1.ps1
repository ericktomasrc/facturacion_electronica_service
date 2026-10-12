# =============================================================================
# Prueba de la PARTE C1 — el alta de un emisor con la clave de alta
#
# Hace a mano lo que en C2 hará la plataforma: crear una empresa de ejemplo
# en el servicio con la clave de alta (alt_), recibir su fac_, comprobar que
# sale «sin confirmar», confirmarla, y que todo lo que tiene que fallar falla.
#
# QUÉ DEJA: una empresa de ejemplo, «FERRETERIA DE PRUEBA C1 SAC», en beta,
# con un RUC inventado distinto en cada ejecución (con su dígito verificador
# bien puesto). Sin certificado ni series: no puede emitir nada. Nada se borra;
# al final te digo cómo desactivarla en el panel. La fac_ que recibe se usa
# aquí y se olvida: no se muestra ni se guarda.
#
# Necesita: el servicio con la 024 aplicada y la API reiniciada.
#
# Se ejecuta desde la carpeta del servicio (para poder mirar la bitácora):
#   cd "D:\Reyban Consulting\facturacion electronica\facturacion_electronica_service"
#   .\prueba-alta-c1.ps1
#
# LA CLAVE DE ALTA SE PEGA AQUÍ, EN POWERSHELL, NUNCA EN EL CHAT.
# =============================================================================

$ErrorActionPreference = 'Stop'

$Base = 'http://localhost:5100'
$UrlWebhook = 'http://localhost:5255/api/webhooks/facturacion/00000000-0000-0000-0000-0000000000c1'

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

function Recortar([string]$t) { if ($t.Length -gt 220) { return $t.Substring(0, 220) + '…' } return $t }

function Esperar([string]$prueba, $r, [int]$codigo) {
    Anotar $prueba ($r.Codigo -eq $codigo) ("Esperaba {0}, llegó {1}: {2}" -f $codigo, $r.Codigo, (Recortar $r.Texto))
    return $r
}

function Mensaje($r) {
    try { $o = $r.Texto | ConvertFrom-Json; return ("{0} {1}" -f $o.error, $o.detalle).Trim() } catch { return '' }
}

# Un RUC inventado, 20 + 8 cifras al azar + el dígito verificador de SUNAT.
function RucDePrueba {
    $azar = New-Object System.Random
    $cuerpo = '20' + (-join (1..8 | ForEach-Object { $azar.Next(0, 10) }))
    $pesos = 5, 4, 3, 2, 7, 6, 5, 4, 3, 2
    $suma = 0
    for ($i = 0; $i -lt 10; $i++) { $suma += [int]::Parse($cuerpo[$i]) * $pesos[$i] }
    $d = 11 - ($suma % 11)
    if ($d -eq 10) { $d = 0 }
    if ($d -eq 11) { $d = 1 }
    return "$cuerpo$d"
}

function Alta([string]$ruc, [string]$ubigeo = '040101', [string]$departamento = 'Arequipa ') {
    return @{
        ruc = $ruc
        razonSocial = 'FERRETERIA DE PRUEBA C1 SAC'
        nombreComercial = 'Ferretería Prueba C1'
        direccion = 'Av. Ejército 101'
        distrito = 'Arequipa'
        provincia = 'Arequipa'
        departamento = $departamento
        ubigeo = $ubigeo
        webhookUrl = $UrlWebhook
    }
}

Write-Host ''
Write-Host 'Prueba del alta de un emisor (C1)' -ForegroundColor Cyan
Write-Host ''

$Alt = Leer-Clave 'Pega la clave de ALTA (alt_...) (no se verá)'
if (-not $Alt.StartsWith('alt_')) { Write-Host 'Eso no parece una clave alt_. No se hizo nada.' -ForegroundColor Red; exit 1 }

$Ruc = RucDePrueba
Write-Host ("  RUC de prueba de esta vez: {0}" -f $Ruc) -ForegroundColor DarkGray

# --- 1. Lo que tiene que fallar sin crear nada ------------------------------

Write-Host ''
Write-Host '1. Lo que tiene que fallar (no crea nada)' -ForegroundColor Cyan

$null = Esperar 'Sin clave -> 401' (Llamar 'POST' '/alta/emisores' (Alta $Ruc)) 401
$null = Esperar 'Con una clave inventada -> 401' (Llamar 'POST' '/alta/emisores' (Alta $Ruc) 'alt_estaclavenoexiste000000000000000') 401
$null = Esperar 'Con una clave fac_ inventada -> 401' (Llamar 'POST' '/alta/emisores' (Alta $Ruc) 'fac_test_estaclavenoexiste0000000000') 401

$r = Esperar 'Ubigeo de Lima con departamento Arequipa -> 400' (Llamar 'POST' '/alta/emisores' (Alta $Ruc '150101' 'AREQUIPA') $Alt) 400
Write-Host ("          dice: {0}" -f (Mensaje $r)) -ForegroundColor DarkGray

$r = Esperar 'RUC con el último dígito mal -> 400' (Llamar 'POST' '/alta/emisores' (Alta ($Ruc.Substring(0, 10) + (([int]::Parse($Ruc[10]) + 1) % 10))) $Alt) 400
Write-Host ("          dice: {0}" -f (Mensaje $r)) -ForegroundColor DarkGray

$sinDireccion = Alta $Ruc; $sinDireccion.direccion = ''
$null = Esperar 'Sin dirección -> 400' (Llamar 'POST' '/alta/emisores' $sinDireccion $Alt) 400

$urlInterna = Alta $Ruc; $urlInterna.webhookUrl = 'http://192.168.1.10/avisos'
$null = Esperar 'Webhook a una IP interna -> 400' (Llamar 'POST' '/alta/emisores' $urlInterna $Alt) 400

# --- 2. El alta de verdad ----------------------------------------------------

Write-Host ''
Write-Host '2. El alta (departamento escrito «Arequipa » con espacio: tiene que valer)' -ForegroundColor Cyan

$r = Esperar 'POST /alta/emisores -> 200' (Llamar 'POST' '/alta/emisores' (Alta $Ruc) $Alt) 200

if ($r.Codigo -ne 200) {
    Write-Host ''
    Write-Host 'El alta no se creó. Para aquí: mándame esta salida.' -ForegroundColor Red
    exit 1
}

$alta = $r.Texto | ConvertFrom-Json
$Fac = $alta.clave

Anotar 'Sale «sin_confirmar»' ($alta.estado -eq 'sin_confirmar') $alta.estado
Anotar 'En beta' ($alta.ambiente -eq 'beta') $alta.ambiente
Anotar 'Trae una clave fac_test_' ($Fac -like 'fac_test_*') ''
Anotar 'Trae el secreto del webhook (whsec_)' ($alta.webhook.secreto -like 'whsec_*') ''
Anotar 'El webhook apunta a la URL pedida' ($alta.webhook.url -eq $UrlWebhook) $alta.webhook.url
Write-Host ("          emisor {0} · clave {1}… (el resto no se muestra)" -f $alta.emisorId, $Fac.Substring(0, 12)) -ForegroundColor DarkGray

# --- 3. Otra vez el mismo RUC, enseguida ------------------------------------

Write-Host ''
Write-Host '3. El mismo RUC otra vez, enseguida (el doble clic)' -ForegroundColor Cyan

$r = Esperar 'Mismo RUC sin confirmar, hace segundos -> 409 «en curso»' (Llamar 'POST' '/alta/emisores' (Alta $Ruc) $Alt) 409
Write-Host ("          dice: {0}" -f (Mensaje $r)) -ForegroundColor DarkGray

# --- 4. Lo que ve la fac_ nueva ---------------------------------------------

Write-Host ''
Write-Host '4. GET /v1/emisor con la fac_ recibida' -ForegroundColor Cyan

$r = Esperar 'GET /v1/emisor -> 200' (Llamar 'GET' '/v1/emisor' $null $Fac) 200
$e = $r.Texto | ConvertFrom-Json

Anotar 'Es el RUC de prueba' ($e.ruc -eq $Ruc) $e.ruc
Anotar 'alta.estado = sin_confirmar' ($e.alta.estado -eq 'sin_confirmar') $e.alta.estado
Anotar 'La dirección cuenta como revisada' ($e.listo.direccion -eq $true) ''
Anotar 'No está lista para emitir (sin certificado, SOL ni series)' ($e.listo.paraEmitir -eq $false) ''
Anotar 'Sin correos al receptor (no tiene identificador ni correo)' ($e.portal.correosAlReceptor -eq $false) ''
Write-Host '          Le falta:' -ForegroundColor DarkGray
foreach ($f in $e.listo.faltan) { Write-Host ("            - {0}" -f $f) -ForegroundColor DarkGray }

# --- 5. Confirmar ------------------------------------------------------------

Write-Host ''
Write-Host '5. Confirmar (lo que hará la plataforma después de guardar)' -ForegroundColor Cyan

$r = Esperar 'POST /v1/alta/confirmar -> 200' (Llamar 'POST' '/v1/alta/confirmar' $null $Fac) 200
Anotar 'Queda «confirmada»' ((($r.Texto | ConvertFrom-Json).estado) -eq 'confirmada') $r.Texto
$r = Esperar 'Confirmar otra vez no cambia nada -> 200' (Llamar 'POST' '/v1/alta/confirmar' $null $Fac) 200

$r = Esperar 'Mismo RUC ya confirmado -> 409 «ya registrado»' (Llamar 'POST' '/alta/emisores' (Alta $Ruc) $Alt) 409
Write-Host ("          dice: {0}" -f (Mensaje $r)) -ForegroundColor DarkGray

# --- 6. Cada llave abre solo su puerta --------------------------------------

Write-Host ''
Write-Host '6. Cada llave abre solo su puerta' -ForegroundColor Cyan

$null = Esperar 'La clave de alta en /v1/emisor -> 401' (Llamar 'GET' '/v1/emisor' $null $Alt) 401
$null = Esperar 'La clave de alta en /v1/comprobantes -> 401' (Llamar 'GET' '/v1/comprobantes' $null $Alt) 401
$null = Esperar 'La clave de alta en /admin/tenants -> 401' (Llamar 'GET' '/admin/tenants' $null $Alt) 401
$null = Esperar 'La fac_ nueva en /alta/emisores -> 401' (Llamar 'POST' '/alta/emisores' (Alta (RucDePrueba)) $Fac) 401

$Fac = $null

# --- 7. La bitácora ----------------------------------------------------------

Write-Host ''
Write-Host '7. La bitácora (las últimas acciones de la clave de alta)' -ForegroundColor Cyan

if (Test-Path 'docker-compose.yml') {
    $sql = "SELECT to_char(creado_en AT TIME ZONE 'America/Lima','HH24:MI:SS') AS hora, correo, codigo_respuesta, tenant_id IS NOT NULL AS con_empresa FROM auditoria WHERE correo LIKE 'clave-alta:%' ORDER BY id DESC LIMIT 8;"
    $sql | docker compose exec -T postgres psql -U facturacion_owner -d facturacion

    $fuga = "SELECT count(*) FROM auditoria WHERE ruta LIKE '%alt\_%' OR ruta LIKE '%fac\_%' OR ruta LIKE '%whsec\_%' OR correo LIKE '%whsec\_%';"
    $n = ($fuga | docker compose exec -T postgres psql -U facturacion_owner -d facturacion -At).Trim()
    Anotar 'Ninguna clave ni secreto en la bitácora' ($n -eq '0') "aparecen $n filas"
}
else {
    Write-Host '  (No estás en la carpeta del servicio: me salto la bitácora.)' -ForegroundColor DarkYellow
}

# --- Resumen -----------------------------------------------------------------

$fallas = @($resultados | Where-Object { -not $_.Ok }).Count
Write-Host ''
if ($fallas -eq 0) {
    Write-Host ("TODO EN VERDE: {0} de {0}." -f $resultados.Count) -ForegroundColor Green
}
else {
    Write-Host ("{0} FALLAS de {1}. Mándame esta salida." -f $fallas, $resultados.Count) -ForegroundColor Red
}

Write-Host ''
Write-Host 'En el panel del servicio (Empresas), mira:' -ForegroundColor Cyan
Write-Host ("  - «FERRETERIA DE PRUEBA C1 SAC» ({0}), creada por la clave de alta, confirmada." -f $Ruc)
Write-Host '  - En «Claves de alta»: Hoy 1 de 20, y el último uso de ahora.'
Write-Host '  - Después desactívala (botón Desactivar del detalle): es solo de ejemplo.'
Write-Host ''
