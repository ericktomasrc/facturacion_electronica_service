namespace Facturacion.Cpe;

/// <summary>
/// Reglas de las facturas de exportación.
///
/// QUÉ CAMBIA UNA EXPORTACIÓN RESPECTO A UNA VENTA NORMAL:
///
/// 1. El tipo de operación deja de ser 0101 y pasa a 0200 (bienes) o a uno
///    de los 0201-0208 (servicios).
/// 2. TODAS las líneas llevan afectación 40. No se puede mezclar una línea
///    de exportación con una gravada en el mismo comprobante (error 2642).
/// 3. El tributo de esas líneas es el 9995 - EXP, no el 1000 - IGV, y el
///    impuesto es 0 (errores 3107 y 3110).
/// 4. El receptor es un no domiciliado, así que en 0200, 0201 y 0204 no
///    puede identificarse con RUC (error 2800).
/// 5. En 0201 y 0208 hay que declarar el país donde el servicio se usa, y
///    ese país no puede ser PE (errores 3098 y 3099).
///
/// LO QUE NO CAMBIA, Y SUELE SORPRENDER: la moneda. Se puede exportar
/// facturando en soles. USD es lo habitual, no lo obligatorio.
///
/// ESTA CLASE NO GENERA XML. Solo revisa que los datos aguanten las reglas
/// antes de gastar un correlativo, igual que hace Detraccion.Revisar.
/// </summary>
public static class Exportacion
{
    /// <summary>Texto de la leyenda 2010, para quien acoge el drawback.</summary>
    public const string TextoDrawback =
        "Restitucion Simplificada de Derechos Arancelarios";

    /// <summary>Texto de la leyenda 2011.</summary>
    public const string TextoExportacionServicios =
        "EXPORTACION DE SERVICIOS - DECRETO LEGISLATIVO N 919";

    /// <summary>
    /// Revisa una factura de exportación y devuelve los problemas encontrados.
    ///
    /// Lista vacía significa que pasa. Los textos que empiezan por "Aviso:"
    /// no impiden emitir; el resto sí, igual que en la detracción.
    ///
    /// POR QUÉ VALIDAR AQUÍ Y NO DEJAR QUE SUNAT RECHACE: cada rechazo consume
    /// un correlativo que después hay que dar de baja, y el mensaje que
    /// devuelve SUNAT habla de tags y códigos, no de lo que el usuario hizo
    /// mal. Un error propio y en castellano cuesta una línea de código y
    /// ahorra media hora de teléfono.
    /// </summary>
    public static IReadOnlyList<string> Revisar(Factura f)
    {
        var problemas = new List<string>();
        var tipo = f.TipoOperacion;

        var hayLineasDeExportacion =
            f.Lineas.Any(l => AfectacionIgv.EsExportacion(l.TipoAfectacionIgv));

        // --- Coherencia entre el tipo de operación y las líneas -------------
        //
        // Las dos direcciones del mismo error. SUNAT solo valida una (2642),
        // pero la otra produce un comprobante que declara una exportación sin
        // decirlo, y eso no lo detecta nadie hasta la fiscalización.

        if (!TipoOperacion.EsExportacion(tipo))
        {
            if (hayLineasDeExportacion)
            {
                problemas.Add(
                    $"Hay lineas con afectacion 40 (exportacion) pero el tipo de " +
                    $"operacion llego como '{tipo}'. Usa 0200 para bienes o " +
                    $"0201-0208 para servicios.");
            }

            return problemas;
        }

        // A partir de aquí, la factura se declara como exportación.

        if (f.Detraccion is not null)
        {
            problemas.Add(
                "Una factura no puede ser de exportacion y estar sujeta a " +
                "detraccion a la vez: el tipo de operacion es uno solo y ambas " +
                "lo ocupan.");
        }

        if (TipoOperacion.NecesitaDatosDeHuesped(tipo))
        {
            problemas.Add(
                $"El tipo de operacion {tipo} ({TipoOperacion.Descripcion(tipo)}) " +
                $"obliga a declarar los datos del huesped o turista en cada linea " +
                $"(documento, nombre, pais, fechas y dias de permanencia). Este " +
                $"motor todavia no genera esos campos.");
        }

        // EL MENSAJE MUESTRA EL VALOR QUE LLEGÓ, no solo el número de línea.
        //
        // Un error que dice "la linea 1 esta mal" obliga a adivinar. Diciendo
        // "la linea 1 llego con '10'" se distingue de un golpe entre dos
        // causas muy distintas: que el usuario puso el código equivocado, o
        // que el dato se perdió en el camino y llegó el valor por defecto.
        var lineasNoExportacion = f.Lineas
            .Where(l => !AfectacionIgv.EsExportacion(l.TipoAfectacionIgv))
            .Select(l => $"la linea {l.Numero} llego con " +
                         $"'{l.TipoAfectacionIgv}'")
            .ToList();

        if (lineasNoExportacion.Count > 0)
        {
            problemas.Add(
                $"En una factura de exportacion todas las lineas deben tener " +
                $"afectacion 40, y {string.Join("; ", lineasNoExportacion)}.");
        }

        if (f.Lineas.Count == 0)
        {
            problemas.Add("La factura de exportacion no tiene lineas.");
        }

        // --- Receptor -------------------------------------------------------

        var receptor = f.Receptor;

        if (!TipoDocIdentidad.Existe(receptor.TipoDocumento))
        {
            problemas.Add(
                $"El tipo de documento del receptor '{receptor.TipoDocumento}' no " +
                $"existe en el catalogo 06.");
        }
        else if (TipoOperacion.ProhibeReceptorConRuc(tipo) &&
                 receptor.TipoDocumento == TipoDocIdentidad.Ruc)
        {
            problemas.Add(
                $"En el tipo de operacion {tipo} el receptor no puede identificarse " +
                $"con RUC: es un no domiciliado. Usa '0' (documento tributario sin " +
                $"RUC), '7' (pasaporte), 'C' (TIN) o 'D' (IN).");
        }

        if (receptor.TipoDocumento != TipoDocIdentidad.Ruc &&
            receptor.TipoDocumento != TipoDocIdentidad.Dni)
        {
            // Regla 2802: alfanumérico de hasta 15 caracteres, sin espacios
            // ni saltos de línea. Un pasaporte copiado de un PDF llega con
            // espacios más veces de las que uno esperaría.
            var numero = receptor.NumeroDocumento ?? "";

            if (numero.Length == 0 || numero.Length > 15)
            {
                problemas.Add(
                    "El numero de documento del receptor debe tener entre 1 y 15 " +
                    "caracteres.");
            }
            else if (numero.Any(char.IsWhiteSpace))
            {
                problemas.Add(
                    "El numero de documento del receptor no admite espacios ni " +
                    "saltos de linea.");
            }
        }

        // --- País de uso del servicio ---------------------------------------

        var pais = (f.PaisDeUso ?? "").Trim().ToUpperInvariant();

        if (TipoOperacion.ExigePaisDeUso(tipo))
        {
            if (pais.Length == 0)
            {
                problemas.Add(
                    $"El tipo de operacion {tipo} obliga a declarar el pais donde " +
                    $"el servicio se usa o aprovecha (codigo ISO de 2 letras).");
            }
            else if (pais.Length != 2 || !pais.All(char.IsAsciiLetterUpper))
            {
                problemas.Add(
                    $"El pais de uso '{f.PaisDeUso}' no es un codigo ISO 3166-1 de " +
                    $"dos letras.");
            }
            else if (pais == "PE")
            {
                problemas.Add(
                    "El pais de uso no puede ser PE: si el servicio se aprovecha " +
                    "en el Peru, la operacion no es exportacion.");
            }
        }
        else if (pais.Length > 0)
        {
            problemas.Add(
                $"El pais de uso solo se declara en los tipos 0201 y 0208. " +
                $"En {tipo} sobra.");
        }

        // --- Avisos ----------------------------------------------------------

        if (f.Moneda == "PEN")
        {
            problemas.Add(
                "Aviso: la exportacion se esta facturando en soles. Es valido, " +
                "pero lo habitual es USD. Revisa que sea intencional.");
        }

        if (f.Moneda != "PEN" && f.TipoCambio is null)
        {
            problemas.Add(
                $"La factura esta en {f.Moneda} y no trae tipo de cambio.");
        }

        return problemas;
    }

    /// <summary>
    /// Los problemas que impiden emitir. Los avisos quedan fuera.
    /// </summary>
    public static IReadOnlyList<string> Errores(Factura f) =>
        Revisar(f).Where(p => !p.StartsWith("Aviso:")).ToList();
}