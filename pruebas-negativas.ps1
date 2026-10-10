# ===========================================================================
# BATERÍA DE CASOS QUE DEBEN FALLAR
#
# QUÉ ES ESTO Y POR QUÉ IMPORTA:
#
# Todo lo que se probó hasta ahora fueron datos CORRECTOS. El sistema los
# aceptó y SUNAT también. Eso demuestra que el camino feliz funciona, y no
# dice nada de lo que pasa cuando llegan datos malos.
#
# Aquí van treinta y tantas peticiones MAL HECHAS a propósito. Cada una
# debería devolver 400 con un mensaje que explique qué está mal.
#
#   Si devuelve 400  → la validación protege. No se quema correlativo.
#   Si devuelve 202  → la validación NO protege: el comprobante se creó,
#                      se quemó un correlativo y SUNAT lo va a rechazar.
#
# NINGUNA DE ESTAS PETICIONES DEBERÍA CREAR NADA, porque todas se validan
# antes de reservar el número. Si alguna sale 202, ese es el hallazgo.
#
# USO:
#
#     .\pruebas-negativas.ps1
#
# O con otra clave o servidor:
#
#     .\pruebas-negativas.ps1 -Url https://localhost:7295 -Clave fac_dev_...
# ===========================================================================

param(
    [string]$Url   = "https://localhost:7295",
    [string]$Clave = "fac_dev_UkV5QkFOX0RFU0FSUk9MTE9fMjAyNg"
)

$ErrorActionPreference = "Stop"

# El certificado de desarrollo es autofirmado. En Windows PowerShell 5.1 hay
# que desactivar la comprobación a mano; en PowerShell 7 basta un parámetro.
$esPS7 = $PSVersionTable.PSVersion.Major -ge 6

if (-not $esPS7) {
    Add-Type @"
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class SinValidarCert : ICertificatePolicy {
    public bool CheckValidationResult(ServicePoint s, X509Certificate c,
        WebRequest r, int p) { return true; }
}
"@
    [System.Net.ServicePointManager]::CertificatePolicy = New-Object SinValidarCert
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
}

$cabeceras = @{
    "Authorization" = "Bearer $Clave"
    "Content-Type"  = "application/json"
}

$casos      = @()
$resultados = @()

function Caso($grupo, $nombre, $ruta, $debeDecir, $cuerpo) {
    $script:casos += [pscustomobject]@{
        Grupo     = $grupo
        Nombre    = $nombre
        Ruta      = $ruta
        DebeDecir = $debeDecir
        Cuerpo    = $cuerpo
    }
}

# ---------------------------------------------------------------------------
# Piezas que se repiten. Se clonan en cada caso para no arrastrar cambios.
# ---------------------------------------------------------------------------

$receptorOk = '{ "tipoDocumento": "6", "numeroDocumento": "20512345671", "razonSocial": "CLIENTE DE PRUEBA SAC" }'
$lineaOk    = '{ "descripcion": "PRODUCTO DE PRUEBA", "unidadMedida": "NIU", "cantidad": 1, "valorUnitario": 100.00 }'

function Factura($extra) {
    return "{ ""tipo"": ""01"", ""serie"": ""F001"", ""formaPago"": ""Contado"", ""receptor"": $receptorOk, ""lineas"": [ $lineaOk ] $extra }"
}


# ===========================================================================
# RECEPTOR Y DATOS BÁSICOS
# ===========================================================================

Caso "Receptor" "RUC con dígito verificador incorrecto" "/v1/comprobantes" `
    "que el RUC no existe, y sugerir el correcto (20512345671)" `
    '{ "tipo":"01","serie":"F001","formaPago":"Contado","receptor":{"tipoDocumento":"6","numeroDocumento":"20512345678","razonSocial":"CLIENTE SAC"},"lineas":[{"descripcion":"X","unidadMedida":"NIU","cantidad":1,"valorUnitario":100}] }'

Caso "Receptor" "RUC de 10 dígitos" "/v1/comprobantes" `
    "que un RUC tiene once dígitos" `
    '{ "tipo":"01","serie":"F001","formaPago":"Contado","receptor":{"tipoDocumento":"6","numeroDocumento":"2051234567","razonSocial":"CLIENTE SAC"},"lineas":[{"descripcion":"X","unidadMedida":"NIU","cantidad":1,"valorUnitario":100}] }'

Caso "Receptor" "Factura a un DNI" "/v1/comprobantes" `
    "que una factura necesita RUC" `
    '{ "tipo":"01","serie":"F001","formaPago":"Contado","receptor":{"tipoDocumento":"1","numeroDocumento":"45678912","razonSocial":"JUAN PEREZ"},"lineas":[{"descripcion":"X","unidadMedida":"NIU","cantidad":1,"valorUnitario":100}] }'

Caso "Líneas" "Sin ninguna línea" "/v1/comprobantes" `
    "que hace falta al menos una línea" `
    '{ "tipo":"01","serie":"F001","formaPago":"Contado","receptor":{"tipoDocumento":"6","numeroDocumento":"20512345671","razonSocial":"CLIENTE SAC"},"lineas":[] }'

Caso "Líneas" "Afectación IGV inventada (1O con letra O)" "/v1/comprobantes" `
    "que esa afectación no existe en el catálogo 07, y nombrar la línea" `
    (Factura ', "lineas":[{"descripcion":"X","unidadMedida":"NIU","cantidad":1,"valorUnitario":100,"tipoAfectacionIgv":"1O"}]')

Caso "Moneda" "Dólares sin tipo de cambio" "/v1/comprobantes" `
    "que falta el tipo de cambio" `
    (Factura ', "moneda":"USD"')


# ===========================================================================
# ISC
# ===========================================================================

Caso "ISC" "Sistema 04, que no existe" "/v1/comprobantes" `
    "que el sistema de cálculo no está en el catálogo 08" `
    (Factura ', "lineas":[{"descripcion":"GASEOSA","unidadMedida":"NIU","cantidad":1,"valorUnitario":100,"sistemaIsc":"04","tasaIsc":12}]')

Caso "ISC" "Sistema declarado con tasa cero" "/v1/comprobantes" `
    "que la tasa no puede ser cero" `
    (Factura ', "lineas":[{"descripcion":"GASEOSA","unidadMedida":"NIU","cantidad":1,"valorUnitario":100,"sistemaIsc":"01","tasaIsc":0}]')

# EL RECEPTOR VA CON PASAPORTE Y NO CON RUC, Y NO ES UN DETALLE.
#
# Con el receptor de siempre —que tiene RUC— esta prueba SALIA BIEN POR EL
# MOTIVO EQUIVOCADO: la atajaba la regla de que una exportacion no puede
# identificar al comprador con RUC, que corre antes. La del ISC no llegaba a
# ejecutarse nunca, y una regla que nunca se ejecuta es una regla que no
# sabemos si funciona.
Caso "ISC" "ISC en una exportación" "/v1/comprobantes" `
    "que una exportación no lleva ISC" `
    '{ "tipo":"01","serie":"F001","formaPago":"Contado","tipoOperacion":"0200","receptor":{"tipoDocumento":"7","numeroDocumento":"X1234567","razonSocial":"FOREIGN BUYER INC"},"lineas":[{"descripcion":"X","unidadMedida":"NIU","cantidad":1,"valorUnitario":100,"tipoAfectacionIgv":"40","sistemaIsc":"01","tasaIsc":12}] }'

Caso "ISC" "ISC con arroz pilado (IVAP)" "/v1/comprobantes" `
    "que el arroz pilado no lleva ISC" `
    (Factura ', "lineas":[{"descripcion":"ARROZ","unidadMedida":"NIU","cantidad":1,"valorUnitario":100,"tipoAfectacionIgv":"17","sistemaIsc":"01","tasaIsc":12}]')


# ===========================================================================
# IVAP
# ===========================================================================

Caso "IVAP" "Una línea con IVAP y otra sin él" "/v1/comprobantes" `
    "que el IVAP es excluyente: si una línea lo lleva, todas" `
    (Factura ', "lineas":[{"descripcion":"ARROZ","unidadMedida":"NIU","cantidad":1,"valorUnitario":100,"tipoAfectacionIgv":"17"},{"descripcion":"OTRO","unidadMedida":"NIU","cantidad":1,"valorUnitario":50,"tipoAfectacionIgv":"10"}]')


# ===========================================================================
# CARGOS Y DESCUENTOS GLOBALES
# ===========================================================================

Caso "Cargos" "Retención 62 sin base ni porcentaje" "/v1/comprobantes" `
    "que SUNAT recalcula el importe y necesita base y porcentaje" `
    (Factura ', "cargosGlobales":[{"codigo":"62","monto":35.40,"descripcion":"RETENCION"}]')

Caso "Cargos" "Código de cargo inventado (77)" "/v1/comprobantes" `
    "que ese código no está en el catálogo 53" `
    (Factura ', "cargosGlobales":[{"codigo":"77","monto":10,"descripcion":"LO QUE SEA"}]')


# ===========================================================================
# DETRACCIÓN
# ===========================================================================

Caso "Detracción" "Detracción en una boleta" "/v1/comprobantes" `
    "que la detracción solo aplica a facturas" `
    '{ "tipo":"03","serie":"B001","formaPago":"Contado","receptor":{"tipoDocumento":"1","numeroDocumento":"45678912","razonSocial":"JUAN PEREZ"},"lineas":[{"descripcion":"X","unidadMedida":"NIU","cantidad":1,"valorUnitario":1000}],"detraccion":{"tipoOperacion":"1001","codigoBienServicio":"022","porcentaje":12,"cuentaBancoNacion":"00-068-123456","medioDePago":"001"} }'

Caso "Detracción pesca" "Tipo 1002 sin los datos del desembarque" "/v1/comprobantes" `
    "que la 1002 necesita los seis datos, y nombrarlos" `
    (Factura ', "detraccion":{"tipoOperacion":"1002","codigoBienServicio":"004","porcentaje":4,"cuentaBancoNacion":"00-068-123456","medioDePago":"001"}')

Caso "Detracción pesca" "Código de bien 011 en vez de 004" "/v1/comprobantes" `
    "que con la 1002 el código tiene que ser 004" `
    (Factura ', "detraccion":{"tipoOperacion":"1002","codigoBienServicio":"011","porcentaje":4,"cuentaBancoNacion":"00-068-123456","medioDePago":"001"}, "hidrobiologicos":{"matricula":"CE-12345-PM","nombreEmbarcacion":"DON GILBERTO I","tipoEspecie":"ANCHOVETA","lugarDescarga":"PAITA","fechaDescarga":"2026-09-19","cantidadEspecie":12}')

Caso "Detracción pesca" "Descarga posterior a la emisión" "/v1/comprobantes" `
    "que primero se descarga y después se factura" `
    (Factura ', "detraccion":{"tipoOperacion":"1002","codigoBienServicio":"004","porcentaje":4,"cuentaBancoNacion":"00-068-123456","medioDePago":"001"}, "hidrobiologicos":{"matricula":"CE-12345-PM","nombreEmbarcacion":"DON GILBERTO I","tipoEspecie":"ANCHOVETA","lugarDescarga":"PAITA","fechaDescarga":"2026-12-31","cantidadEspecie":12}')

Caso "Detracción pesca" "Datos de pesca sin detracción" "/v1/comprobantes" `
    "que esos datos solo tienen sentido con la 1002" `
    (Factura ', "hidrobiologicos":{"matricula":"CE-12345-PM","nombreEmbarcacion":"DON GILBERTO I","tipoEspecie":"ANCHOVETA","lugarDescarga":"PAITA","fechaDescarga":"2026-09-19","cantidadEspecie":12}')


# ===========================================================================
# CRÉDITO
# ===========================================================================

Caso "Crédito" "Factura a crédito sin cuotas" "/v1/comprobantes" `
    "que desde 2022 hay que declarar al menos una cuota" `
    (Factura ', "formaPago":"Credito"')


# ===========================================================================
# ANTICIPOS
# ===========================================================================

Caso "Anticipos" "Anticipo de un comprobante que no existe" "/v1/comprobantes" `
    "que no se encontró ese comprobante entre los del emisor" `
    (Factura ', "anticipos":[{"identificadorPago":"1","tipoComprobante":"02","numero":"F001-99999999","rucEmisor":"20601234565","montoTotal":100,"fechaPago":"2026-09-01"}]')


# ===========================================================================
# PLAZO
# ===========================================================================

Caso "Plazo" "Factura con fecha de hace un mes" "/v1/comprobantes" `
    "que el plazo venció y SUNAT la rechazaría con el 2108" `
    (Factura ', "fechaEmision":"2026-08-01"')

Caso "Plazo" "Factura con fecha futura" "/v1/comprobantes" `
    "que un comprobante no puede nacer mañana" `
    (Factura ', "fechaEmision":"2027-01-01"')


# ===========================================================================
# LIQUIDACIÓN DE COMPRA
# ===========================================================================

$vendedorOk = '{ "tipoDocumento":"1","numeroDocumento":"45678912","nombres":"QUISPE MAMANI JUAN","direccion":"CASERIO SANTA ROSA","ubigeo":"040101","distrito":"AREQUIPA","provincia":"AREQUIPA","departamento":"AREQUIPA","condicionDomicilio":"05" }'
$lugarOk    = '{ "direccion":"FUNDO LA ESPERANZA","ubigeo":"040129","distrito":"YURA","provincia":"AREQUIPA","departamento":"AREQUIPA","condicion":"02" }'
$lineaLc    = '{ "descripcion":"CAFE PERGAMINO","unidadMedida":"KGM","cantidad":100,"valorUnitario":12.00 }'

Caso "Liquidación" "Vendedor con RUC" "/v1/liquidaciones" `
    "que si tuviera RUC emitiría su propia factura" `
    "{ ""serie"":""L001"",""vendedor"":{""tipoDocumento"":""6"",""numeroDocumento"":""20512345671"",""nombres"":""EMPRESA SAC"",""direccion"":""AV X"",""ubigeo"":""040101"",""condicionDomicilio"":""05""},""lugar"":$lugarOk,""lineas"":[$lineaLc] }"

Caso "Liquidación" "Vendedor sin ubigeo" "/v1/liquidaciones" `
    "que en una liquidación el domicilio no es opcional" `
    "{ ""serie"":""L001"",""vendedor"":{""tipoDocumento"":""1"",""numeroDocumento"":""45678912"",""nombres"":""QUISPE JUAN"",""direccion"":""CASERIO"",""ubigeo"":"""",""condicionDomicilio"":""05""},""lugar"":$lugarOk,""lineas"":[$lineaLc] }"

Caso "Liquidación" "Sin lugar de la operación" "/v1/liquidaciones" `
    "que hace falta dónde se hizo la compra" `
    "{ ""serie"":""L001"",""vendedor"":$vendedorOk,""lugar"":{""direccion"":"""",""ubigeo"":""""},""lineas"":[$lineaLc] }"

Caso "Liquidación" "Serie F001 en vez de L001" "/v1/liquidaciones" `
    "que la serie empieza por L" `
    "{ ""serie"":""F001"",""vendedor"":$vendedorOk,""lugar"":$lugarOk,""lineas"":[$lineaLc] }"

Caso "Liquidación" "Línea de exportación" "/v1/liquidaciones" `
    "que no se exporta comprando" `
    "{ ""serie"":""L001"",""vendedor"":$vendedorOk,""lugar"":$lugarOk,""lineas"":[{""descripcion"":""CAFE"",""unidadMedida"":""KGM"",""cantidad"":100,""valorUnitario"":12,""tipoAfectacionIgv"":""40""}] }"

Caso "Liquidación" "Condición de lugar 09, que no existe" "/v1/liquidaciones" `
    "que no está en el catálogo 60" `
    "{ ""serie"":""L001"",""vendedor"":$vendedorOk,""lugar"":{""direccion"":""FUNDO"",""ubigeo"":""040129"",""condicion"":""09""},""lineas"":[$lineaLc] }"


# ===========================================================================
# RETENCIÓN Y PERCEPCIÓN
# ===========================================================================

$docOk = '{ "tipoDocumento":"01","numero":"F001-00000123","fechaEmision":"2026-09-05","importeTotal":1180.00,"moneda":"PEN","numeroPago":1,"fechaPago":"2026-09-18","importePago":1180.00 }'

Caso "Retención" "El proveedor es el propio emisor" "/v1/retenciones" `
    "que nadie se retiene a sí mismo" `
    "{ ""serie"":""R001"",""regimen"":""01"",""proveedor"":{""ruc"":""20601234565"",""razonSocial"":""MI EMPRESA SAC""},""documentos"":[$docOk] }"

Caso "Retención" "Dos documentos con el mismo número de pago" "/v1/retenciones" `
    "que cada pago lleva su número" `
    "{ ""serie"":""R001"",""regimen"":""01"",""proveedor"":{""ruc"":""20512345671"",""razonSocial"":""PROVEEDOR SAC""},""documentos"":[$docOk,$docOk] }"

Caso "Retención" "Pagos de meses distintos" "/v1/retenciones" `
    "que un comprobante agrupa un solo mes" `
    "{ ""serie"":""R001"",""regimen"":""01"",""proveedor"":{""ruc"":""20512345671"",""razonSocial"":""PROVEEDOR SAC""},""documentos"":[$docOk,{""tipoDocumento"":""01"",""numero"":""F001-00000124"",""fechaEmision"":""2026-08-05"",""importeTotal"":500,""moneda"":""PEN"",""numeroPago"":2,""fechaPago"":""2026-08-18"",""importePago"":500}] }"

Caso "Retención" "Pago anterior a la emisión de la factura" "/v1/retenciones" `
    "que primero se factura y después se paga" `
    "{ ""serie"":""R001"",""regimen"":""01"",""proveedor"":{""ruc"":""20512345671"",""razonSocial"":""PROVEEDOR SAC""},""documentos"":[{""tipoDocumento"":""01"",""numero"":""F001-00000125"",""fechaEmision"":""2026-09-18"",""importeTotal"":1180,""moneda"":""PEN"",""numeroPago"":1,""fechaPago"":""2026-09-05"",""importePago"":1180}] }"

Caso "Retención" "Régimen 05, que no existe" "/v1/retenciones" `
    "que no está en el catálogo 23" `
    "{ ""serie"":""R001"",""regimen"":""05"",""proveedor"":{""ruc"":""20512345671"",""razonSocial"":""PROVEEDOR SAC""},""documentos"":[$docOk] }"

Caso "Retención" "Serie F001 en vez de R001" "/v1/retenciones" `
    "que la serie empieza por R" `
    "{ ""serie"":""F001"",""regimen"":""01"",""proveedor"":{""ruc"":""20512345671"",""razonSocial"":""PROVEEDOR SAC""},""documentos"":[$docOk] }"

Caso "Retención" "Factura en dólares sin tipo de cambio" "/v1/retenciones" `
    "que se declara en soles y falta el tipo de cambio" `
    "{ ""serie"":""R001"",""regimen"":""01"",""proveedor"":{""ruc"":""20512345671"",""razonSocial"":""PROVEEDOR SAC""},""documentos"":[{""tipoDocumento"":""01"",""numero"":""F001-00000126"",""fechaEmision"":""2026-09-05"",""importeTotal"":300,""moneda"":""USD"",""numeroPago"":1,""fechaPago"":""2026-09-18"",""importePago"":300}] }"

Caso "Percepción" "Régimen 09, que no existe" "/v1/percepciones" `
    "que no está en el catálogo 22" `
    "{ ""serie"":""P001"",""regimen"":""09"",""cliente"":{""ruc"":""20512345671"",""razonSocial"":""CLIENTE SAC""},""documentos"":[$docOk] }"

Caso "Percepción" "Sin ningún documento" "/v1/percepciones" `
    "que hace falta al menos un documento" `
    '{ "serie":"P001","regimen":"01","cliente":{"ruc":"20512345671","razonSocial":"CLIENTE SAC"},"documentos":[] }'


# ===========================================================================
# GUÍAS
# ===========================================================================

$destinatarioOk = '{ "tipoDocumento":"6","numeroDocumento":"20512345671","razonSocial":"DESTINO SAC" }'
$partidaOk      = '{ "ubigeo":"150101","direccion":"AV EJEMPLO 123" }'
$llegadaOk      = '{ "ubigeo":"150135","direccion":"AV LOS OLIVOS 900" }'
$bienOk         = '{ "descripcion":"LADRILLO","cantidad":1000,"unidadMedida":"NIU" }'
$conductorOk    = '{ "tipoDocumento":"1","numeroDocumento":"45678912","nombres":"PEDRO","apellidos":"RAMOS","licencia":"Q45678912" }'

Caso "Guía 09" "Traslado anterior a la emisión" "/v1/guias" `
    "que la guía se emite antes de mover los bienes" `
    "{ ""serie"":""T001"",""fechaTraslado"":""2026-01-01"",""motivoTraslado"":""01"",""modalidadTraslado"":""02"",""pesoBruto"":500,""destinatario"":$destinatarioOk,""puntoPartida"":$partidaOk,""puntoLlegada"":$llegadaOk,""vehiculo"":{""placa"":""XYZ789""},""conductor"":$conductorOk,""bienes"":[$bienOk] }"

Caso "Guía 09" "Privado sin placa ni conductor" "/v1/guias" `
    "que en transporte privado hacen falta placa y conductor" `
    "{ ""serie"":""T001"",""fechaTraslado"":""2026-09-22"",""motivoTraslado"":""01"",""modalidadTraslado"":""02"",""pesoBruto"":500,""destinatario"":$destinatarioOk,""puntoPartida"":$partidaOk,""puntoLlegada"":$llegadaOk,""bienes"":[$bienOk] }"

Caso "Guía 09" "Público sin transportista" "/v1/guias" `
    "que en transporte público hay que declarar al transportista" `
    "{ ""serie"":""T001"",""fechaTraslado"":""2026-09-22"",""motivoTraslado"":""01"",""modalidadTraslado"":""01"",""pesoBruto"":500,""destinatario"":$destinatarioOk,""puntoPartida"":$partidaOk,""puntoLlegada"":$llegadaOk,""bienes"":[$bienOk] }"

Caso "Guía 09" "Peso bruto cero" "/v1/guias" `
    "que el peso debe ser mayor que cero" `
    "{ ""serie"":""T001"",""fechaTraslado"":""2026-09-22"",""motivoTraslado"":""01"",""modalidadTraslado"":""02"",""pesoBruto"":0,""destinatario"":$destinatarioOk,""puntoPartida"":$partidaOk,""puntoLlegada"":$llegadaOk,""vehiculo"":{""placa"":""XYZ789""},""conductor"":$conductorOk,""bienes"":[$bienOk] }"

Caso "Guía 09" "Ubigeo de cuatro dígitos" "/v1/guias" `
    "que el ubigeo tiene seis dígitos" `
    "{ ""serie"":""T001"",""fechaTraslado"":""2026-09-22"",""motivoTraslado"":""01"",""modalidadTraslado"":""02"",""pesoBruto"":500,""destinatario"":$destinatarioOk,""puntoPartida"":{""ubigeo"":""1501"",""direccion"":""AV X""},""puntoLlegada"":$llegadaOk,""vehiculo"":{""placa"":""XYZ789""},""conductor"":$conductorOk,""bienes"":[$bienOk] }"

Caso "Guía 09" "Motivo 'Otros' sin describirlo" "/v1/guias" `
    "que con motivo Otros hay que describir el motivo real" `
    "{ ""serie"":""T001"",""fechaTraslado"":""2026-09-22"",""motivoTraslado"":""13"",""modalidadTraslado"":""02"",""pesoBruto"":500,""destinatario"":$destinatarioOk,""puntoPartida"":$partidaOk,""puntoLlegada"":$llegadaOk,""vehiculo"":{""placa"":""XYZ789""},""conductor"":$conductorOk,""bienes"":[$bienOk] }"

Caso "Guía 31" "Sin la guía 09 que ampara" "/v1/guias" `
    "que la 31 tiene que referenciar una guía de tipo 09" `
    "{ ""tipoGuia"":""31"",""serie"":""V001"",""fechaTraslado"":""2026-09-22"",""motivoTraslado"":""01"",""modalidadTraslado"":""01"",""pesoBruto"":500,""numeroMtc"":""0123456789"",""contratante"":{""tipoDocumento"":""6"",""numeroDocumento"":""20512345671"",""razonSocial"":""REMITENTE SAC""},""destinatario"":$destinatarioOk,""puntoPartida"":$partidaOk,""puntoLlegada"":$llegadaOk,""vehiculo"":{""placa"":""ABC123"",""tuc"":""1234567890""},""conductor"":$conductorOk,""bienes"":[$bienOk] }"

Caso "Guía 31" "Sin número de MTC" "/v1/guias" `
    "que falta el registro del MTC del transportista" `
    "{ ""tipoGuia"":""31"",""serie"":""V001"",""fechaTraslado"":""2026-09-22"",""motivoTraslado"":""01"",""modalidadTraslado"":""01"",""pesoBruto"":500,""contratante"":{""tipoDocumento"":""6"",""numeroDocumento"":""20512345671"",""razonSocial"":""REMITENTE SAC""},""destinatario"":$destinatarioOk,""puntoPartida"":$partidaOk,""puntoLlegada"":$llegadaOk,""vehiculo"":{""placa"":""ABC123"",""tuc"":""1234567890""},""conductor"":$conductorOk,""bienes"":[$bienOk],""documentosRelacionados"":[{""tipoDocumento"":""09"",""numeroDocumento"":""T001-00000001"",""rucEmisor"":""20512345671""}] }"

Caso "Guía 31" "Sin certificado de habilitación (tuc)" "/v1/guias" `
    "que falta el certificado de habilitación vehicular" `
    "{ ""tipoGuia"":""31"",""serie"":""V001"",""fechaTraslado"":""2026-09-22"",""motivoTraslado"":""01"",""modalidadTraslado"":""01"",""pesoBruto"":500,""numeroMtc"":""0123456789"",""contratante"":{""tipoDocumento"":""6"",""numeroDocumento"":""20512345671"",""razonSocial"":""REMITENTE SAC""},""destinatario"":$destinatarioOk,""puntoPartida"":$partidaOk,""puntoLlegada"":$llegadaOk,""vehiculo"":{""placa"":""ABC123""},""conductor"":$conductorOk,""bienes"":[$bienOk],""documentosRelacionados"":[{""tipoDocumento"":""09"",""numeroDocumento"":""T001-00000001"",""rucEmisor"":""20512345671""}] }"

Caso "Guía 31" "Sin el remitente que contrató" "/v1/guias" `
    "que falta el remitente que contrató el traslado" `
    "{ ""tipoGuia"":""31"",""serie"":""V001"",""fechaTraslado"":""2026-09-22"",""motivoTraslado"":""01"",""modalidadTraslado"":""01"",""pesoBruto"":500,""numeroMtc"":""0123456789"",""destinatario"":$destinatarioOk,""puntoPartida"":$partidaOk,""puntoLlegada"":$llegadaOk,""vehiculo"":{""placa"":""ABC123"",""tuc"":""1234567890""},""conductor"":$conductorOk,""bienes"":[$bienOk],""documentosRelacionados"":[{""tipoDocumento"":""09"",""numeroDocumento"":""T001-00000001"",""rucEmisor"":""20512345671""}] }"

Caso "Guía 31" "Serie T001 en vez de V001" "/v1/guias" `
    "que la del transportista empieza por V" `
    "{ ""tipoGuia"":""31"",""serie"":""T001"",""fechaTraslado"":""2026-09-22"",""motivoTraslado"":""01"",""modalidadTraslado"":""01"",""pesoBruto"":500,""numeroMtc"":""0123456789"",""contratante"":{""tipoDocumento"":""6"",""numeroDocumento"":""20512345671"",""razonSocial"":""REMITENTE SAC""},""destinatario"":$destinatarioOk,""puntoPartida"":$partidaOk,""puntoLlegada"":$llegadaOk,""vehiculo"":{""placa"":""ABC123"",""tuc"":""1234567890""},""conductor"":$conductorOk,""bienes"":[$bienOk],""documentosRelacionados"":[{""tipoDocumento"":""09"",""numeroDocumento"":""T001-00000001"",""rucEmisor"":""20512345671""}] }"

Caso "Guía 31" "Subcontrata declarada sin decir a quién" "/v1/guias" `
    "que se declara subcontrata sin nombrar al transportista" `
    "{ ""tipoGuia"":""31"",""serie"":""V001"",""fechaTraslado"":""2026-09-22"",""motivoTraslado"":""01"",""modalidadTraslado"":""01"",""pesoBruto"":500,""numeroMtc"":""0123456789"",""indicadores"":[""SUNAT_Envio_IndicadorTrasporteSubcontratado""],""contratante"":{""tipoDocumento"":""6"",""numeroDocumento"":""20512345671"",""razonSocial"":""REMITENTE SAC""},""destinatario"":$destinatarioOk,""puntoPartida"":$partidaOk,""puntoLlegada"":$llegadaOk,""vehiculo"":{""placa"":""ABC123"",""tuc"":""1234567890""},""conductor"":$conductorOk,""bienes"":[$bienOk],""documentosRelacionados"":[{""tipoDocumento"":""09"",""numeroDocumento"":""T001-00000001"",""rucEmisor"":""20512345671""}] }"


# ===========================================================================
# COMUNICACIÓN DE BAJA
#
# ESTOS CASOS USAN COMPROBANTES REALES DE LA BASE, y no datos inventados
# como los de arriba. No hay forma de evitarlo: una baja se pide SOBRE algo
# que existe, y las reglas que queremos probar solo se alcanzan cuando el
# comprobante se encontro y estaba aceptado.
#
# Eso significa que estos cuatro casos dependen del estado de TU base. Si
# alguno empieza a decir "no existe" cuando esperabas otra cosa, es que el
# comprobante que nombra ya no esta donde estaba, no que la regla se rompio.
#
#
# FALTA UN QUINTO CASO Y NO SE PUEDE ESCRIBIR: el del plazo vencido (error
# 2957, siete dias desde la emision). Haria falta una factura aceptada de
# hace mas de una semana, y ahora mismo no hay ninguna: todo lo emitido es
# reciente. Tampoco sirve crear una con fecha antigua, porque la regla de
# los 3 dias de plazo de la factura la rechaza antes de nacer.
#
# El dia que tengas facturas de mas de siete dias, el caso se escribe solo:
# una peticion de baja sobre una de ellas debe decir que el plazo vencio.
#
#
# YA PASO UNA VEZ, Y ASI SE VE: el caso de la boleta apuntaba a
# B001-00000004 y esa boleta se anulo en una prueba posterior. A partir de
# ahi el caso seguia saliendo en verde, pero por la regla equivocada —"ya
# esta anulado"— y la que queria probar no se ejecutaba nunca.
#
# Un caso que pasa por el motivo equivocado es peor que uno que falla: el
# que falla se arregla, y este se queda tranquilizando a nadie.
#
# Ahora apunta a B001-00000001. Si algun dia lees "ya esta anulado" en ese
# caso, es que le paso lo mismo: cambia el correlativo por una boleta viva.
# ===========================================================================

Caso "Baja" "Dar de baja una boleta" "/v1/bajas" `
    "que las boletas se anulan por el resumen diario, no por aqui" `
    '{ "motivo":"PRUEBA","comprobantes":[{"tipoDocumento":"03","serie":"B001","correlativo":1}] }'

Caso "Baja" "Dar de baja algo que no existe" "/v1/bajas" `
    "que ese comprobante no esta entre los del emisor" `
    '{ "motivo":"PRUEBA","comprobantes":[{"tipoDocumento":"01","serie":"F001","correlativo":99999999}] }'

Caso "Baja" "Dos comprobantes de dias distintos" "/v1/bajas" `
    "que una comunicacion informa una sola fecha de emision" `
    '{ "motivo":"PRUEBA","comprobantes":[{"tipoDocumento":"01","serie":"F001","correlativo":82},{"tipoDocumento":"08","serie":"FD01","correlativo":1}] }'

Caso "Baja" "Dar de baja algo ya anulado" "/v1/bajas" `
    "que ese comprobante ya esta anulado" `
    '{ "motivo":"PRUEBA","comprobantes":[{"tipoDocumento":"01","serie":"F001","correlativo":72}] }'

Caso "Baja" "Baja sin motivo" "/v1/bajas" `
    "que el motivo lo lee una persona en SUNAT y no puede ir vacio" `
    '{ "motivo":"","comprobantes":[{"tipoDocumento":"01","serie":"F001","correlativo":82}] }'


# ===========================================================================
# RESUMEN DE REVERSIONES
#
# El RR es a las retenciones y percepciones lo que la RA a las facturas:
# el documento que las mata. Son el mismo XML y el mismo servicio de SUNAT,
# y justo por eso hay que probar que NO se confunden — meter una factura en
# un RR, o una retencion en una RA, se rechaza con el error 2308.
#
# Igual que los casos de baja, estos usan comprobantes reales de la base.
# ===========================================================================

Caso "Reversion" "Revertir una factura" "/v1/reversiones" `
    "que un RR solo admite retenciones y percepciones" `
    '{ "motivo":"PRUEBA","comprobantes":[{"tipoDocumento":"01","serie":"F001","correlativo":82}] }'

Caso "Reversion" "Revertir algo ya anulado" "/v1/reversiones" `
    "que ese comprobante ya esta anulado" `
    '{ "motivo":"PRUEBA","comprobantes":[{"tipoDocumento":"20","serie":"R001","correlativo":6}] }'

Caso "Reversion" "Reversion sin motivo" "/v1/reversiones" `
    "que el motivo lo lee una persona en SUNAT y no puede ir vacio" `
    '{ "motivo":"","comprobantes":[{"tipoDocumento":"40","serie":"P001","correlativo":4}] }'

# APUNTA A UNA PERCEPCION VIVA, Y NO A LA RETENCION R001-00000006.
#
# Se escribio primero con esa retencion y salia en verde POR EL MOTIVO
# EQUIVOCADO: se habia revertido minutos antes, asi que lo atajaba la regla
# de "ya esta anulado" y la que se queria probar no llegaba a ejecutarse.
#
# Si algun dia este caso dice "ya esta anulado", le paso lo mismo: cambialo
# por una retencion o percepcion que siga aceptada.
Caso "Baja" "Dar de baja una percepcion" "/v1/bajas" `
    "que las percepciones se anulan con un resumen de reversiones" `
    '{ "motivo":"PRUEBA","comprobantes":[{"tipoDocumento":"40","serie":"P001","correlativo":4}] }'


# ===========================================================================
# EJECUCIÓN
# ===========================================================================

Write-Host ""
Write-Host "  Casos que DEBEN fallar: $($casos.Count)" -ForegroundColor White
Write-Host "  Servidor: $Url"
Write-Host ""

$protegidos = 0
$colados    = 0
$raros      = 0

foreach ($c in $casos) {
    $codigo  = 0
    $mensaje = ""

    try {
        $parametros = @{
            Uri     = "$Url$($c.Ruta)"
            Method  = "Post"
            Headers = $cabeceras
            Body    = [System.Text.Encoding]::UTF8.GetBytes($c.Cuerpo)
        }

        if ($esPS7) { $parametros["SkipCertificateCheck"] = $true }

        $respuesta = Invoke-WebRequest @parametros -UseBasicParsing
        $codigo    = [int]$respuesta.StatusCode
        $mensaje   = "SE CREÓ: $($respuesta.Content)"
    }
    catch {
        $r = $_.Exception.Response

        if ($r) {
            $codigo = [int]$r.StatusCode

            try {
                $lector  = New-Object System.IO.StreamReader($r.GetResponseStream())
                $cuerpo  = $lector.ReadToEnd()
                $json    = $cuerpo | ConvertFrom-Json
                $mensaje = ($json.error, $json.detalle -join " ").Trim()
                if (-not $mensaje) { $mensaje = $cuerpo }
            }
            catch { $mensaje = $_.Exception.Message }
        }
        else {
            $mensaje = $_.Exception.Message
        }
    }

    if ($codigo -eq 400) {
        $estado = "PROTEGE"; $color = "Green";  $protegidos++
    }
    elseif ($codigo -in 200, 201, 202) {
        $estado = "SE COLÓ"; $color = "Red";    $colados++
    }
    else {
        $estado = "RARO $codigo"; $color = "Yellow"; $raros++
    }

    Write-Host ("  [{0,-8}] {1,-12} {2}" -f $estado, $c.Grupo, $c.Nombre) -ForegroundColor $color

    if ($codigo -ne 400) {
        Write-Host ("             esperaba: {0}" -f $c.DebeDecir) -ForegroundColor DarkGray
    }

    Write-Host ("             dijo: {0}" -f $mensaje) -ForegroundColor DarkGray

    $resultados += [pscustomobject]@{
        Grupo   = $c.Grupo
        Caso    = $c.Nombre
        Codigo  = $codigo
        Estado  = $estado
        Esperaba = $c.DebeDecir
        Dijo    = $mensaje
    }
}

Write-Host ""
Write-Host "  ---------------------------------------------------------------"
Write-Host ("  Protegidos: {0}" -f $protegidos) -ForegroundColor Green
Write-Host ("  Se colaron: {0}" -f $colados)    -ForegroundColor $(if ($colados -gt 0) { "Red" } else { "Green" })
Write-Host ("  Raros:      {0}" -f $raros)      -ForegroundColor $(if ($raros -gt 0) { "Yellow" } else { "Green" })
Write-Host "  ---------------------------------------------------------------"
Write-Host ""

if ($colados -gt 0) {
    Write-Host "  LOS QUE SE COLARON crearon un comprobante y quemaron un" -ForegroundColor Red
    Write-Host "  correlativo. Son los que hay que arreglar." -ForegroundColor Red
    Write-Host ""
}

$archivo = "resultado-pruebas-negativas.csv"
$resultados | Export-Csv -Path $archivo -NoTypeInformation -Encoding UTF8

Write-Host "  Detalle completo en: $archivo"
Write-Host ""
