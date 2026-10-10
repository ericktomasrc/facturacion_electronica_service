namespace Facturacion.Cpe;

/// <summary>
/// La baja de una guía de remisión electrónica.
///
/// LA CONCLUSIÓN, POR DELANTE: no se puede automatizar. No existe endpoint.
///
/// Se revisaron las tres fuentes:
///
///   1. El "Manual URL GRE" que tienes, que documenta la API entera de guías.
///      Tiene exactamente dos servicios: enviar el comprobante y consultar el
///      ticket. Y el envío solo admite codCpe "09" y "31" — es decir, guías
///      nuevas. No hay un tercer servicio.
///
///   2. Las reglas de la comunicación de baja (el RA-, que sí tienes montado).
///      La regla 2308 dice que el tipo de documento solo puede ser "01", "07",
///      "08", "25", "28", "30", "34", "42" y "56". Ni "09" ni "31" están en esa
///      lista, así que una guía metida en un RA- se rechaza.
///
///   3. La propia SUNAT, en cpe.sunat.gob.pe: la baja de una GRE "se debe
///      realizar a través de la opción que contemple el SEE - SOL".
///
/// O sea: la guía se da de baja UNA PERSONA, entrando a SUNAT con su Clave SOL.
/// No hay forma de que lo haga el sistema, ni la tienen los PSE grandes.
///
/// QUÉ HACE ENTONCES ESTE ARCHIVO: que el sistema no se quede mintiendo. Si la
/// guía se anuló en SUNAT y en tu base sigue como aceptada, el panel miente y
/// la próxima factura se va a referenciar contra una guía muerta. Aquí está la
/// anulación que registra ese hecho, y las comprobaciones de que lo que te
/// están registrando tiene sentido.
///
/// Registrar la anulación NO anula nada en SUNAT. Es al revés: primero se anula
/// en SUNAT y después se registra aquí.
/// </summary>
public static class BajaGuias
{
    /// <summary>Los dos tipos del catálogo 01 que son guías.</summary>
    public static bool EsGuia(string tipoDocumento) =>
        tipoDocumento == CatalogosGre.TipoGuiaRemitente ||
        tipoDocumento == CatalogosGre.TipoGuiaTransportista;

    /// <summary>Cómo se llama cada una, para los mensajes.</summary>
    public static string NombreTipo(string tipo) => tipo switch
    {
        CatalogosGre.TipoGuiaRemitente => "Guia de remision remitente",
        CatalogosGre.TipoGuiaTransportista => "Guia de remision transportista",
        _ => "Documento " + tipo
    };

    /// <summary>
    /// Dónde tiene que entrar la persona. No es un enlace directo: SUNAT no
    /// publica uno estable para esta opción, y los que circulan caducan.
    /// </summary>
    public const string MenuSol =
        "SUNAT Operaciones en Linea (e-menu.sunat.gob.pe) > Empresas > " +
        "Comprobantes de pago > Guia de remision electronica > " +
        "Consultar/Dar de baja guias";

    /// <summary>
    /// El texto que conviene enseñar en el panel cuando alguien le da al botón
    /// de anular una guía, en vez de un error seco.
    /// </summary>
    public const string Explicacion =
        "Las guias de remision no se dan de baja desde el sistema: SUNAT no " +
        "publica ningun servicio para eso. Hay que anularla con la Clave SOL " +
        "en " + MenuSol + ", y despues registrar aqui que se anulo, para que " +
        "el panel y las facturas que la referencian queden al dia.";
}

/// <summary>
/// El registro de que una guía se anuló en SUNAT.
/// </summary>
/// <param name="TipoDocumento">"09" o "31".</param>
/// <param name="Serie">T### para la remitente, V### para la transportista.</param>
/// <param name="Numero">Correlativo.</param>
/// <param name="FechaAnulacion">Cuándo se anuló en SUNAT, no cuándo se teclea.</param>
/// <param name="Motivo">Por qué. Queda para cuando pregunten dentro de un año.</param>
/// <param name="RegistradaPor">Quién lo registra. Es el rastro de quién dice qué.</param>
public record AnulacionGuia(
    string TipoDocumento,
    string Serie,
    string Numero,
    DateTime FechaAnulacion,
    string Motivo,
    string RegistradaPor)
{
    public string Identificador => $"{Serie}-{Numero}";
}

/// <summary>
/// Comprobaciones antes de aceptar el registro de una anulación.
///
/// Ninguna de estas reglas es de SUNAT —SUNAT no se entera de este registro—,
/// son las que impiden que la base termine diciendo cosas imposibles.
/// </summary>
public static class ReglasAnulacionGuia
{
    /// <summary>
    /// Revisa una anulación. Lista vacía significa que pasa.
    /// </summary>
    /// <param name="a">Lo que llega.</param>
    /// <param name="estadoActual">
    /// El estado en que está la guía en tu base. Null si no aparece.
    /// </param>
    /// <param name="fechaEmision">La fecha en que se emitió la guía, si se sabe.</param>
    public static IReadOnlyList<string> Revisar(
        AnulacionGuia a,
        string? estadoActual,
        DateTime? fechaEmision)
    {
        var problemas = new List<string>();

        // --- Que sea una guía -------------------------------------------------

        if (!BajaGuias.EsGuia(a.TipoDocumento))
        {
            problemas.Add(
                $"El tipo de documento '{a.TipoDocumento}' no es una guia de " +
                $"remision. Las guias son '09' (remitente) y '31' " +
                $"(transportista). Un comprobante normal se da de baja con una " +
                $"comunicacion de baja, que es otro camino.");

            return problemas;
        }

        // --- Que la serie corresponda al tipo ---------------------------------
        //
        // SUNAT lo fija en el manual de la API: si codCpe es 09, la serie es
        // T###; si es 31, V###. Una serie cruzada significa casi siempre que
        // alguien copió el número de otra guía.

        var inicial = a.TipoDocumento == CatalogosGre.TipoGuiaRemitente ? 'T' : 'V';

        if (string.IsNullOrWhiteSpace(a.Serie) ||
            a.Serie.Length != 4 ||
            char.ToUpperInvariant(a.Serie[0]) != inicial)
        {
            problemas.Add(
                $"La serie '{a.Serie}' no corresponde a una " +
                $"{BajaGuias.NombreTipo(a.TipoDocumento).ToLowerInvariant()}. " +
                $"Tiene que empezar por '{inicial}' y tener cuatro caracteres.");
        }

        // --- Que exista ------------------------------------------------------

        if (estadoActual is null)
        {
            problemas.Add(
                $"La guia {a.Identificador} no esta en el sistema. Solo se " +
                $"registra la anulacion de guias que se emitieron desde aqui.");

            return problemas;
        }

        // --- Que no esté ya anulada ------------------------------------------

        if (estadoActual == EstadoGuia.Anulada)
        {
            problemas.Add(
                $"La guia {a.Identificador} ya figura como anulada. Si se " +
                $"anulo dos veces en SUNAT, algo mas raro esta pasando.");
        }

        // --- Que SUNAT la hubiera aceptado -----------------------------------
        //
        // No se puede anular en SUNAT lo que SUNAT nunca aceptó. Si figura como
        // rechazada o en proceso, lo que hay que arreglar es otra cosa.

        else if (estadoActual != EstadoGuia.Aceptada)
        {
            problemas.Add(
                $"La guia {a.Identificador} esta en estado '{estadoActual}'. " +
                $"Solo se anulan las guias que SUNAT acepto: si esta rechazada " +
                $"o todavia en proceso, no hay nada que anular alli.");
        }

        // --- Que las fechas vayan en el orden que va el tiempo ----------------

        if (fechaEmision is not null && a.FechaAnulacion.Date < fechaEmision.Value.Date)
        {
            problemas.Add(
                $"La fecha de anulacion ({a.FechaAnulacion:yyyy-MM-dd}) es " +
                $"anterior a la de emision ({fechaEmision:yyyy-MM-dd}).");
        }

        if (a.FechaAnulacion.Date > RelojPeru.Hoy)
        {
            problemas.Add(
                $"La fecha de anulacion ({a.FechaAnulacion:yyyy-MM-dd}) es " +
                $"futura. Se registra lo que ya paso.");
        }

        // --- El motivo --------------------------------------------------------
        //
        // Obligarlo cuesta poco y dentro de un año vale mucho.

        if (string.IsNullOrWhiteSpace(a.Motivo) || a.Motivo.Trim().Length < 5)
        {
            problemas.Add(
                "Hace falta el motivo de la anulacion. No es un requisito de " +
                "SUNAT, es para que dentro de un año se sepa que paso.");
        }

        if (string.IsNullOrWhiteSpace(a.RegistradaPor))
        {
            problemas.Add(
                "Hace falta quien registra la anulacion.");
        }

        return problemas;
    }
}

/// <summary>
/// Los estados por los que pasa una guía. Son los que ya usa el procesador,
/// más el de anulada.
/// </summary>
public static class EstadoGuia
{
    public const string Pendiente = "PENDIENTE";
    public const string Enviado = "ENVIADO";
    public const string Aceptada = "ACEPTADO";
    public const string Rechazada = "RECHAZADO";

    /// <summary>
    /// Anulada por una persona en SUNAT y registrado aquí después. Este estado
    /// no lo pone nunca el procesador: lo pone el registro manual.
    /// </summary>
    public const string Anulada = "ANULADO";
}