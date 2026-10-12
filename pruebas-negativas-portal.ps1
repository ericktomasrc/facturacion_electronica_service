# =============================================================================
# Pruebas negativas del portal del receptor — PASO 5
#
# Comprueba lo que TIENE QUE FALLAR: datos que no cuadran, enlaces inventados,
# otra empresa, boletas pidiendo XML, el bloqueo por intentos, las cabeceras
# de seguridad. También unas pocas que tienen que funcionar, para saber que
# el servicio está vivo y que un fallo no es casualidad.
#
# NO MODIFICA NADA: no crea comprobantes, no cambia empresas ni toca la base.
# Lo único que deja son filas en portal_intentos y portal_accesos, que es lo
# mismo que deja cualquier visita al portal.
#
# Se ejecuta con el servicio arrancado, desde cualquier carpeta:
#   .\pruebas-negativas-portal.ps1
#
# NO LO EJECUTES MÁS DE 3 VECES EN UNA HORA: cada vuelta suma 8 intentos
# fallidos a tu IP, y a los 30 en una hora el portal te bloquea una hora
# (que es justo lo que se está probando).
# =============================================================================

$ErrorActionPreference = 'Stop'

$Base    = 'http://localhost:5100'
$Empresa = 'mi-empresa'

# Comprobantes reales de MI EMPRESA SAC en beta. Solo se leen.
$Factura = @{ tipoDocumento = '6'; numeroDocumento = '20512345671'; serie = 'F001'; numero = '96'; fechaEmision = '2026-10-10'; importeTotal = '100.01' }
$Boleta  = @{ tipoDocumento = '1'; numeroDocumento = '44556677';    serie = 'B001'; numero = '5';  fechaEmision = '2026-10-09'; importeTotal = '100.01' }

$resultados = New-Object System.Collections.Generic.List[object]

function Llamar([string]$metodo, [string]$ruta, $cuerpo = $null, [hashtable]$cabeceras = @{}) {
    $p = @{ Uri = "$Base$ruta"; Method = $metodo; UseBasicParsing = $true; Headers = $cabeceras }
    if ($null -ne $cuerpo) {
        $p.Body = [System.Text.Encoding]::UTF8.GetBytes(($cuerpo | ConvertTo-Json -Depth 6 -Compress))
        $p.ContentType = 'application/json; charset=utf-8'
    }
    try {
        $r = Invoke-WebRequest @p
        return [pscustomobject]@{ Codigo = [int]$r.StatusCode; Texto = [string]$r.Content; Cabeceras = $r.Headers }
    }
    catch {
        $codigo = 0
        $texto = $_.Exception.Message
        $respuesta = $_.Exception.Response
        if ($respuesta) { $codigo = [int]$respuesta.StatusCode }

        # El MENSAJE del servidor va en el cuerpo de la respuesta de error.
        # PowerShell 7 lo deja en ErrorDetails; PowerShell 5.1 no, y hay que
        # leerlo del flujo de la respuesta. Sin esto, en 5.1 solo se ve
        # "Error en el servidor remoto: (404)".
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

        return [pscustomobject]@{ Codigo = $codigo; Texto = $texto; Cabeceras = $null }
    }
}

function Anotar([string]$prueba, [bool]$ok, [string]$detalle) {
    $resultados.Add([pscustomobject]@{ Prueba = $prueba; Ok = $ok; Detalle = $detalle })
    $color = if ($ok) { 'Green' } else { 'Red' }
    $marca = if ($ok) { ' OK  ' } else { 'FALLA' }
    Write-Host ("  [{0}] {1}" -f $marca, $prueba) -ForegroundColor $color
    if (-not $ok) { Write-Host ("          {0}" -f $detalle) -ForegroundColor DarkYellow }
}

function Esperar([string]$prueba, $r, [int]$codigo, [string]$contiene = '') {
    $ok = ($r.Codigo -eq $codigo) -and ($contiene -eq '' -or $r.Texto -like "*$contiene*")
    $texto = if ($r.Texto.Length -gt 160) { $r.Texto.Substring(0, 160) + '…' } else { $r.Texto }
    Anotar $prueba $ok ("Esperaba {0}{1}; llegó {2}: {3}" -f $codigo, $(if ($contiene) { " con «$contiene»" } else { '' }), $r.Codigo, $texto)
}

function Copia([hashtable]$h) { $n = @{}; foreach ($k in $h.Keys) { $n[$k] = $h[$k] }; return $n }

Write-Host ''
Write-Host "Pruebas negativas del portal contra $Base/portal/$Empresa" -ForegroundColor Cyan
Write-Host ''

# --- 0. Que el servicio responde -------------------------------------------
$salud = Llamar GET '/health'
if ($salud.Codigo -ne 200) {
    Write-Host "El servicio no responde en $Base ($($salud.Texto)). Arráncalo y vuelve a ejecutar." -ForegroundColor Red
    exit 1
}

# --- 1. La empresa sale de la dirección ------------------------------------
Write-Host 'Empresa y dirección' -ForegroundColor White
Esperar 'Empresa que no existe: 404'                       (Llamar GET '/portal/api/no-existe-zz9')            404
Esperar 'Identificador reservado «api»: 404'              (Llamar GET '/portal/api/api')                      404
Esperar 'La empresa real responde (control)'               (Llamar GET "/portal/api/$Empresa")                 200 'razonSocial'
Esperar 'Por /portal no se llega a la API de emisores: 404' (Llamar GET '/portal/v1/emisor')                    404

# --- 2. Cabeceras de seguridad ----------------------------------------------
Write-Host ''
Write-Host 'Cabeceras de la página' -ForegroundColor White
$pagina = Llamar GET "/portal/$Empresa"
if ($pagina.Codigo -eq 200 -and $pagina.Cabeceras) {
    $h = $pagina.Cabeceras
    Anotar 'Cache-Control: no-store'      ([string]$h['Cache-Control'] -like '*no-store*')        "Llegó: $($h['Cache-Control'])"
    Anotar 'Referrer-Policy: no-referrer' ([string]$h['Referrer-Policy'] -eq 'no-referrer')        "Llegó: $($h['Referrer-Policy'])"
    Anotar 'X-Robots-Tag: noindex'        ([string]$h['X-Robots-Tag'] -like '*noindex*')          "Llegó: $($h['X-Robots-Tag'])"
    Anotar 'Content-Security-Policy'      ([string]$h['Content-Security-Policy'] -like "*default-src 'none'*") "Llegó: $($h['Content-Security-Policy'])"
}
else { Anotar 'La página del portal abre' $false "Llegó $($pagina.Codigo)" }

# --- 3. Búsqueda: un dato que no cuadra no encuentra nada -------------------
Write-Host ''
Write-Host 'Búsqueda con los cinco datos' -ForegroundColor White

$buena = Llamar POST "/portal/api/$Empresa/buscar" $Factura
Esperar 'Datos correctos de la F001-96 la encuentran (control)' $buena 200 'F001-00000096'
$acceso = $null
if ($buena.Codigo -eq 200) { $acceso = ($buena.Texto | ConvertFrom-Json).acceso }

$x = Copia $Factura; $x.fechaEmision = '2026-10-09'
Esperar 'Fecha cambiada un día: no encuentra'      (Llamar POST "/portal/api/$Empresa/buscar" $x) 404 'No encontramos'

$x = Copia $Boleta; $x.importeTotal = '100.02'
Esperar 'Importe con un céntimo de más: no encuentra' (Llamar POST "/portal/api/$Empresa/buscar" $x) 404 'No encontramos'

$x = Copia $Factura; $x.numeroDocumento = '20601234565'
Esperar 'RUC del emisor en vez del cliente: no encuentra' (Llamar POST "/portal/api/$Empresa/buscar" $x) 404 'No encontramos'

$x = Copia $Factura; $x.tipoDocumento = '0'; $x.numeroDocumento = '-'
Esperar 'Sin documento (consumidor final): 400 con explicación' (Llamar POST "/portal/api/$Empresa/buscar" $x) 400 'enlace del correo'

$x = Copia $Factura; $x.serie = 'F0'
Esperar 'Serie con forma imposible: 400, no cuenta como intento' (Llamar POST "/portal/api/$Empresa/buscar" $x) 400 '4 caracteres'

# --- 4. Accesos ---------------------------------------------------------------
Write-Host ''
Write-Host 'Accesos' -ForegroundColor White

$bytes = New-Object byte[] 32
[System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
$inventado = [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')

Esperar 'Sin acceso: 404'          (Llamar GET "/portal/api/$Empresa/comprobante")                                         404 'disponible'
Esperar 'Acceso inventado: 404'    (Llamar GET "/portal/api/$Empresa/comprobante" -cabeceras @{ 'X-Portal-Acceso' = $inventado }) 404 'disponible'
Esperar 'Acceso con forma rara: 404' (Llamar GET "/portal/api/$Empresa/comprobante" -cabeceras @{ 'X-Portal-Acceso' = "../../$inventado" }) 404

if ($acceso) {
    $c = @{ 'X-Portal-Acceso' = $acceso }
    Esperar 'Acceso bueno en su empresa (control)'           (Llamar GET "/portal/api/$Empresa/comprobante" -cabeceras $c)        200 'F001-00000096'
    Esperar 'Acceso bueno en OTRA dirección: 404'            (Llamar GET '/portal/api/no-existe-zz9/comprobante' -cabeceras $c)  404
    Esperar 'Archivo que no existe (.exe): 404'              (Llamar GET "/portal/api/$Empresa/comprobante/exe" -cabeceras $c)   404
    Esperar 'XML de la factura (control)'                    (Llamar GET "/portal/api/$Empresa/comprobante/xml" -cabeceras $c)   200 'F001-00000096'
}
else { Anotar 'Pruebas con un acceso bueno' $false 'No hubo acceso: falló la búsqueda de control.' }

# --- 5. Boleta: solo PDF ---------------------------------------------------
Write-Host ''
Write-Host 'Boleta' -ForegroundColor White
$rb = Llamar POST "/portal/api/$Empresa/buscar" $Boleta
Esperar 'La B001-5 se encuentra con DNI (control)' $rb 200 'B001-00000005'
if ($rb.Codigo -eq 200) {
    $cb = @{ 'X-Portal-Acceso' = ($rb.Texto | ConvertFrom-Json).acceso }
    Esperar 'Boleta pidiendo XML: 404 con motivo' (Llamar GET "/portal/api/$Empresa/comprobante/xml" -cabeceras $cb) 404 'solo se descarga el PDF'
    Esperar 'Boleta pidiendo CDR: 404 con motivo' (Llamar GET "/portal/api/$Empresa/comprobante/cdr" -cabeceras $cb) 404 'solo se descarga el PDF'
    $pdf = Llamar GET "/portal/api/$Empresa/comprobante/pdf" -cabeceras $cb
    Anotar 'Boleta: el PDF sí (control)' ($pdf.Codigo -eq 200) "Llegó $($pdf.Codigo)"
}

# --- 6. Bloqueo por intentos ------------------------------------------------
# Con un RUC inventado distinto en cada vuelta: no bloquea a ningún cliente
# real, y una segunda ejecución no se encuentra el bloqueo de la primera.
Write-Host ''
Write-Host 'Bloqueo tras 5 fallos del mismo documento' -ForegroundColor White
$falso = '209' + (Get-Random -Minimum 10000000 -Maximum 99999999)
$x = Copia $Factura; $x.numeroDocumento = $falso
$fallos = 0
for ($i = 1; $i -le 5; $i++) {
    $r = Llamar POST "/portal/api/$Empresa/buscar" $x
    if ($r.Codigo -eq 404) { $fallos++ }
}
Anotar "Los 5 primeros intentos con el RUC $falso responden «no encontrado»" ($fallos -eq 5) "Solo $fallos de 5 respondieron 404"
Esperar 'El sexto queda bloqueado: 429'  (Llamar POST "/portal/api/$Empresa/buscar" $x) 429 'Demasiados intentos'
$y = Copia $x; $y.serie = 'B001'
Esperar 'Bloqueado aunque cambie la serie: 429' (Llamar POST "/portal/api/$Empresa/buscar" $y) 429 'Demasiados intentos'
Esperar 'Otro cliente no queda bloqueado (control)' (Llamar POST "/portal/api/$Empresa/buscar" $Boleta) 200 'B001-00000005'

# --- 7. Correo del receptor en la API ---------------------------------------
Write-Host ''
Write-Host 'Correo del receptor en POST /v1/comprobantes' -ForegroundColor White
Esperar 'Sin clave, /v1/emisor: 401' (Llamar GET '/v1/emisor') 401

$segura = Read-Host 'Clave fac_ del emisor para probar un correo inválido (Enter para saltar)' -AsSecureString
$clave = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($segura))
if ([string]::IsNullOrWhiteSpace($clave)) {
    Write-Host '  [SALTO] Sin clave: no se prueba el correo inválido.' -ForegroundColor DarkGray
}
else {
    # Se rechaza ANTES de guardar nada: no consume correlativo.
    $peticion = @{
        tipo = '01'; serie = 'F001'
        receptor = @{ tipoDocumento = '6'; numeroDocumento = '20512345671'; razonSocial = 'CLIENTE DE PRUEBA SAC'; correo = 'esto no es un correo' }
        lineas = @(@{ descripcion = 'Prueba negativa'; cantidad = 1; valorUnitario = 1 })
    }
    Esperar 'Correo del receptor inválido: 400, no crea nada' (Llamar POST '/v1/comprobantes' $peticion @{ 'X-Api-Key' = $clave }) 400 'correo'
}
$clave = $null

# --- Resumen ------------------------------------------------------------------
$malas = @($resultados | Where-Object { -not $_.Ok })
Write-Host ''
if ($malas.Count -eq 0) {
    Write-Host ("TODAS BIEN: {0} de {0}." -f $resultados.Count) -ForegroundColor Green
}
else {
    Write-Host ("{0} de {1} FALLARON:" -f $malas.Count, $resultados.Count) -ForegroundColor Red
    foreach ($m in $malas) { Write-Host "  - $($m.Prueba)" -ForegroundColor Red }
}
Write-Host ''
