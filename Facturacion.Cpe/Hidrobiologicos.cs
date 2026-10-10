namespace Facturacion.Cpe;

/// <summary>
/// Catálogo 55: conceptos tributarios que se declaran dentro del ítem.
///
/// QUÉ ES ESTO: un cajón genérico donde SUNAT mete datos que no caben en
/// ningún campo del estándar UBL. Cada concepto tiene un código, y el dato
/// viaja como una propiedad más del producto.
///
/// Hoy lo usan dos regímenes muy distintos: la detracción de recursos
/// hidrobiológicos —que es lo que se implementa aquí— y el transporte
/// terrestre de pasajeros, que necesita declarar el asiento y los datos de
/// cada pasajero.
/// </summary>
public static class ConceptoItem
{
    // --- Detracción de recursos hidrobiológicos ----------------------------

    public const string MatriculaEmbarcacion = "3001";
    public const string NombreEmbarcacion = "3002";
    public const string TipoEspecie = "3003";
    public const string LugarDescarga = "3004";
    public const string FechaDescarga = "3005";
    public const string CantidadEspecie = "3006";

    // --- Transporte terrestre de pasajeros ---------------------------------
    //
    // No está implementado, pero los códigos van aquí para que el día que
    // toque no haya que volver al catálogo.

    public const string NumeroAsiento = "3050";
    public const string ManifiestoPasajeros = "3051";
    public const string DocumentoPasajero = "3052";
    public const string TipoDocPasajero = "3053";
    public const string NombrePasajero = "3054";

    /// <summary>
    /// El nombre legible del concepto. SUNAT lo pide en cbc:Name junto al
    /// código, y aunque no lo valida, es lo que lee una persona.
    /// </summary>
    public static string Nombre(string codigo) => codigo switch
    {
        MatriculaEmbarcacion => "Matricula de la embarcacion",
        NombreEmbarcacion => "Nombre de la embarcacion",
        TipoEspecie => "Tipo de especie vendida",
        LugarDescarga => "Lugar de descarga",
        FechaDescarga => "Fecha de descarga",
        CantidadEspecie => "Cantidad de especie vendida",
        NumeroAsiento => "Numero de asiento",
        ManifiestoPasajeros => "Informacion de manifiesto de pasajeros",
        DocumentoPasajero => "Numero de documento de identidad del pasajero",
        TipoDocPasajero => "Tipo de documento de identidad del pasajero",
        NombrePasajero => "Nombres y apellidos del pasajero",
        _ => "Concepto " + codigo
    };
}

/// <summary>
/// Una propiedad del ítem: un dato del catálogo 55 con su valor.
/// </summary>
/// <param name="Codigo">El código del catálogo 55.</param>
/// <param name="Valor">El dato, como texto.</param>
/// <param name="Cantidad">
/// Para los conceptos que son una cantidad, como el 3006. Cuando tiene
/// valor, el dato viaja en cbc:ValueQuantity con su unidad en vez de en
/// cbc:Value.
/// </param>
/// <param name="UnidadMedida">La unidad de esa cantidad. "KGM" son kilos.</param>
/// <param name="Fecha">
/// Para los conceptos que son una fecha, como el 3005. Cuando tiene valor,
/// el dato viaja en cac:UsabilityPeriod/cbc:StartDate.
///
/// SUNAT NO ADMITE LA FECHA EN cbc:Value, aunque quepa: la busca en ese
/// nodo concreto y devuelve el error 3065 si no está. El estándar UBL
/// define ese periodo para decir cuándo es válida una propiedad, y SUNAT
/// lo reaprovecha como "el día en que pasó esto".
/// </param>
public record PropiedadItem(
    string Codigo,
    string Valor,
    decimal? Cantidad = null,
    string UnidadMedida = "KGM",
    DateTime? Fecha = null);

/// <summary>
/// Los datos que SUNAT exige en una detracción de recursos hidrobiológicos,
/// que es el tipo de operación 1002.
///
/// POR QUÉ EXISTEN: el pescado se detrae al 4%, y SUNAT quiere cruzar cada
/// factura contra el desembarque real. Sin la matrícula de la embarcación y
/// la fecha de descarga no puede hacerlo, así que sin esos datos no acepta
/// el comprobante.
///
/// SON SEIS Y TODOS OBLIGATORIOS: errores 3063, 3130, 3131, 3132, 3133 y
/// 3134, uno por dato que falte.
/// </summary>
/// <param name="Matricula">Matrícula de la embarcación. Ej: "CE-12345-PM".</param>
/// <param name="NombreEmbarcacion">Cómo se llama el barco.</param>
/// <param name="TipoEspecie">Qué se pescó. Ej: "ANCHOVETA".</param>
/// <param name="LugarDescarga">Dónde se descargó. Ej: "PAITA".</param>
/// <param name="FechaDescarga">Cuándo se descargó.</param>
/// <param name="CantidadEspecie">
/// Cuánto se vendió, EN TONELADAS MÉTRICAS.
///
/// LA UNIDAD NO SE ELIGE: SUNAT exige "TNE" y rechaza cualquier otra con el
/// error 3115. Doce mil kilos son 12, no 12000.
/// </param>
public record RecursosHidrobiologicos(
    string Matricula,
    string NombreEmbarcacion,
    string TipoEspecie,
    string LugarDescarga,
    DateTime FechaDescarga,
    decimal CantidadEspecie)
{
    /// <summary>
    /// La única unidad que SUNAT admite para la cantidad de especie: TNE,
    /// toneladas métricas.
    ///
    /// ESTÁ FIJADA EN LA REGLA, no en un catálogo: el campo se declara como
    /// literal "TNE" y cualquier otro valor da el error 3115. Por eso es
    /// una constante y no un parámetro — dejar elegir solo serviría para
    /// elegir mal.
    /// </summary>
    public const string Unidad = "TNE";

    /// <summary>
    /// Los seis datos convertidos en propiedades del ítem.
    ///
    /// EL ORDEN NO IMPORTA para SUNAT —comprueba que cada código exista—
    /// pero se emiten en el orden del catálogo para que el XML se lea.
    /// </summary>
    public IEnumerable<PropiedadItem> ComoPropiedades()
    {
        yield return new(ConceptoItem.MatriculaEmbarcacion, Matricula);
        yield return new(ConceptoItem.NombreEmbarcacion, NombreEmbarcacion);
        yield return new(ConceptoItem.TipoEspecie, TipoEspecie);
        yield return new(ConceptoItem.LugarDescarga, LugarDescarga);

        // La fecha va en su propio nodo, no como texto: error 3065.
        yield return new(ConceptoItem.FechaDescarga, "", Fecha: FechaDescarga);

        yield return new(ConceptoItem.CantidadEspecie, "",
            CantidadEspecie, Unidad);
    }
}

/// <summary>
/// Reglas de la detracción de recursos hidrobiológicos.
///
///   3129  El código de bien o servicio tiene que ser "004".
///   3063  Falta la matrícula de la embarcación.
///   3130  Falta el nombre de la embarcación.
///   3131  Falta el tipo de especie vendida.
///   3132  Falta el lugar de descarga.
///   3133  Falta la cantidad de especie vendida.
///   3134  Falta la fecha de descarga.
/// </summary>
public static class ReglasHidrobiologicos
{
    /// <summary>El tipo de operación de esta detracción: catálogo 51.</summary>
    public const string TipoOperacion = "1002";

    /// <summary>El código del catálogo 54 que le corresponde, y no otro.</summary>
    public const string CodigoBienServicio = "004";

    /// <summary>
    /// Revisa una factura de pesca. Lista vacía significa que pasa.
    /// Los textos que empiezan por "Aviso:" no impiden emitir.
    /// </summary>
    public static IReadOnlyList<string> Revisar(Factura f)
    {
        var problemas = new List<string>();

        var esHidrobiologica = f.Detraccion?.TipoOperacion == TipoOperacion;

        // --- Los datos sin la detracción que los pide --------------------------

        if (!esHidrobiologica)
        {
            if (f.Hidrobiologicos is not null)
            {
                problemas.Add(
                    "Llegan datos de embarcacion y descarga, pero la factura no " +
                    "es una detraccion de recursos hidrobiologicos. Para que lo " +
                    "sea, la detraccion tiene que llevar el tipo de operacion " +
                    "'1002' y el codigo de bien '004'.");
            }

            return problemas;
        }

        // --- La detracción sin los datos que exige ---------------------------

        if (f.Hidrobiologicos is null)
        {
            problemas.Add(
                "Una detraccion de recursos hidrobiologicos (tipo 1002) necesita " +
                "los datos del desembarque: matricula y nombre de la embarcacion, " +
                "especie, lugar y fecha de descarga, y cantidad. Son seis datos y " +
                "SUNAT rechaza la factura por cada uno que falte (errores 3063, " +
                "3130, 3131, 3132, 3133 y 3134).");

            return problemas;
        }

        // --- El código de bien tiene que ser el de pesca ----------------------

        if (f.Detraccion!.CodigoBienServicio != CodigoBienServicio)
        {
            problemas.Add(
                $"La detraccion es de tipo 1002 (recursos hidrobiologicos) pero " +
                $"el codigo de bien es '{f.Detraccion.CodigoBienServicio}'. Tiene " +
                $"que ser '{CodigoBienServicio}' (error 3129).");
        }

        // --- Los datos, uno por uno -------------------------------------------

        var h = f.Hidrobiologicos;

        if (string.IsNullOrWhiteSpace(h.Matricula))
            problemas.Add("Falta la matricula de la embarcacion (error 3063).");

        if (string.IsNullOrWhiteSpace(h.NombreEmbarcacion))
            problemas.Add("Falta el nombre de la embarcacion (error 3130).");

        if (string.IsNullOrWhiteSpace(h.TipoEspecie))
            problemas.Add("Falta el tipo de especie vendida (error 3131).");

        if (string.IsNullOrWhiteSpace(h.LugarDescarga))
            problemas.Add("Falta el lugar de descarga (error 3132).");

        if (h.CantidadEspecie <= 0)
        {
            problemas.Add(
                "La cantidad de especie vendida debe ser mayor que cero " +
                "(error 3133).");
        }
        else if (h.CantidadEspecie > 5000)
        {
            // UN AVISO QUE ATRAPA EL ERROR MÁS PROBABLE: la cantidad va en
            // TONELADAS, y quien la teclea suele tener el dato en kilos.
            // Cinco mil toneladas en una sola descarga no existen; cinco mil
            // kilos, todos los días.
            problemas.Add(
                $"Aviso: la cantidad de especie declarada son " +
                $"{h.CantidadEspecie:0.##} toneladas. SUNAT exige la unidad " +
                $"TNE, asi que si el dato que tenias estaba en kilos hay que " +
                $"dividirlo entre mil.");
        }

        // --- La fecha de descarga ---------------------------------------------
        //
        // Se pesca, se descarga y después se factura. Una descarga posterior a
        // la emisión significa casi siempre que alguien tecleó el año mal.

        if (h.FechaDescarga.Date > f.FechaEmision.Date)
        {
            problemas.Add(
                $"La fecha de descarga ({h.FechaDescarga:yyyy-MM-dd}) es " +
                $"posterior a la de emision ({f.FechaEmision:yyyy-MM-dd}). " +
                $"Primero se descarga y despues se factura.");
        }

        return problemas;
    }

    /// <summary>Los problemas que impiden emitir. Los avisos quedan fuera.</summary>
    public static IReadOnlyList<string> Errores(Factura f) =>
        Revisar(f).Where(p => !p.StartsWith("Aviso:")).ToList();
}