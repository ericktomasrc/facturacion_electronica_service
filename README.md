# Paso 1 — Generar el XML UBL 2.1 de una factura

Meta de este paso: **que el XSD acepte tu XML.** Nada más. Sin firma, sin ZIP, sin SUNAT.

## Cómo ejecutarlo

```bash
cd Facturacion.Consola
dotnet run
```

Verás los totales calculados y el XML se guardará en `bin/Debug/net9.0/salida/`.

## Para que valide contra el XSD

1. Descarga los esquemas desde el portal de SUNAT (sección "XSD de los documentos electrónicos").
2. Descomprímelos en `Facturacion.Consola/xsd/`.
3. Verifica que exista `xsd/maindoc/UBLPE-Invoice-2.1.xsd`. Si el archivo tiene otro nombre en el paquete que descargaste, ajusta la ruta en `Program.cs`.
4. Vuelve a ejecutar.

Si la estructura de carpetas del ZIP es distinta, lo importante es que el XSD principal pueda resolver sus imports relativos: no muevas los archivos de sitio dentro del paquete.

## Qué hace cada archivo

| Archivo | Responsabilidad |
|---|---|
| `Catalogos.cs` | Namespaces UBL y códigos de los catálogos de SUNAT |
| `Modelo.cs` | El dominio: factura, emisor, receptor, líneas. No sabe de XML |
| `CalculadoraTotales.cs` | IGV, totales y reglas de redondeo |
| `NumeroALetras.cs` | La leyenda obligatoria del importe en letras |
| `GeneradorFacturaXml.cs` | Construye el XML UBL 2.1 |
| `ValidadorXsd.cs` | Valida contra el esquema y guarda el archivo |

## Los tres detalles que más rechazos causan

**1. El orden de los nodos no es libre.** UBL define una secuencia estricta en el XSD. Si mueves un elemento "para que se lea mejor", el documento entero se invalida. El orden en `GeneradorFacturaXml.cs` está tomado del esquema.

**2. UTF-8 sin BOM.** Está resuelto en `ValidadorXsd.Guardar`. Si guardas el archivo con las opciones por defecto de Windows, se agregan tres bytes invisibles al inicio y la firma del paso 2 no valida. Este error cuesta días de depuración porque el XML se ve perfecto en el editor.

**3. Redondeo `AwayFromZero`.** .NET usa redondeo bancario por defecto, que trata los casos `.5` distinto. SUNAT recalcula tus totales y compara con una tolerancia mínima, así que un céntimo de diferencia es un rechazo.

## Sobre el nodo de la firma

`ext:ExtensionContent` se genera **vacío** a propósito. Ahí entra la firma XAdES-BES en el paso 2, insertándola en ese nodo sin tocar nada más del documento. No lo rellenes desde el generador.

## Verificación antes de pasar al paso 2

- [ ] El XSD valida el XML sin errores.
- [ ] Los totales cuadran: valor de venta + IGV = importe total.
- [ ] La leyenda dice el importe correcto en letras.
- [ ] El nombre del archivo sigue el patrón `RUC-TIPO-SERIE-CORRELATIVO.xml`.
- [ ] El archivo abierto en un editor hexadecimal empieza con `<?xml`, no con `EF BB BF`.

## Advertencia sobre las reglas vigentes

Este generador cubre el caso base: factura de venta interna, gravada con IGV, en soles. SUNAT agrega y modifica validaciones por resolución, y algunas afectan a campos que aquí no están (códigos de producto estandarizados, detracciones, percepciones, datos adicionales).

Antes de dar por cerrado el motor, contrasta contra la guía de validaciones y códigos de error vigente en el portal de SUNAT. Lo que hay aquí es una base correcta, no una lista completa.
