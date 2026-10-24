namespace Facturacion.Cpe;

/// <summary>Catálogos propios de la guía de remisión.</summary>
public static class CatalogosGre
{
    /// <summary>Catálogo 20: por qué se trasladan los bienes.</summary>
    public static class MotivoTraslado
    {
        public const string Venta = "01";
        public const string Compra = "02";
        public const string VentaConEntregaATerceros = "03";
        public const string EntreEstablecimientos = "04";
        public const string Consignacion = "05";
        public const string Devolucion = "06";
        public const string RecojoTransformados = "07";
        public const string Importacion = "08";
        public const string Exportacion = "09";
        public const string Otros = "13";
        public const string VentaSujetaAConfirmacion = "14";
        public const string TrasladoParaTransformacion = "17";
        public const string EmisorItinerante = "18";

        public static readonly IReadOnlyDictionary<string, string> Descripciones =
            new Dictionary<string, string>
            {
                ["01"] = "VENTA",
                ["02"] = "COMPRA",
                ["03"] = "VENTA CON ENTREGA A TERCEROS",
                ["04"] = "TRASLADO ENTRE ESTABLECIMIENTOS DE LA MISMA EMPRESA",
                ["05"] = "CONSIGNACION",
                ["06"] = "DEVOLUCION",
                ["07"] = "RECOJO DE BIENES TRANSFORMADOS",
                ["08"] = "IMPORTACION",
                ["09"] = "EXPORTACION",
                ["13"] = "OTROS",
                ["14"] = "VENTA SUJETA A CONFIRMACION DEL COMPRADOR",
                ["17"] = "TRASLADO DE BIENES PARA TRANSFORMACION",
                ["18"] = "TRASLADO EMISOR ITINERANTE CP"
            };

        public static bool EsValido(string codigo) => Descripciones.ContainsKey(codigo);
    }

    /// <summary>Catálogo 18: quién pone el vehículo.</summary>
    public static class ModalidadTraslado
    {
        /// <summary>
        /// Lo lleva un transportista contratado.
        ///
        /// Obliga a declarar los datos del transportista, y ES ÉL quien debe
        /// emitir además su propia guía (tipo 31).
        /// </summary>
        public const string Publico = "01";

        /// <summary>
        /// Lo lleva la propia empresa con su vehículo.
        ///
        /// Obliga a declarar placa y conductor, porque no hay un tercero que
        /// responda por el traslado.
        /// </summary>
        public const string Privado = "02";

        public static bool EsValido(string codigo) => codigo is "01" or "02";
    }

    public const string TipoGuiaRemitente = "09";
    public const string TipoGuiaTransportista = "31";
}

/// <summary>
/// Los indicadores del envío.
///
/// SON CADENAS LITERALES, no códigos. SUNAT las compara carácter a carácter
/// y todas empiezan por "SUNAT_" (regla 3388), así que un espacio de más o
/// una tilde donde no toca rechaza la guía.
///
/// Por eso están aquí como constantes y no se escriben a mano en ningún
/// sitio: es la clase de dato que nadie recuerda bien.
/// </summary>
public static class IndicadorGre
{
    /// <summary>El emisor subcontrató el traslado a otro transportista.</summary>
    public const string TransporteSubcontratado =
        "SUNAT_Envio_IndicadorTrasporteSubcontratado";

    /// <summary>El flete lo paga el remitente.</summary>
    public const string PagaFleteRemitente =
        "SUNAT_Envio_IndicadorPagadorFlete_Remitente";

    /// <summary>El flete lo paga quien subcontrató.</summary>
    public const string PagaFleteSubcontratador =
        "SUNAT_Envio_IndicadorPagadorFlete_Subcontratador";

    /// <summary>El flete lo paga un tercero.</summary>
    public const string PagaFleteTercero =
        "SUNAT_Envio_IndicadorPagadorFlete_Tercero";

    /// <summary>Se traslada TODO lo que ampara la guía del remitente.</summary>
    public const string TrasladoTotal =
        "SUNAT_Envio_IndicadorTrasladoTotal";

    /// <summary>
    /// El traslado se hace en varios tramos con cambio de vehículo previsto.
    ///
    /// Es lo único que permite emitir una 31 SIN referenciar una guía del
    /// remitente (regla 2574): en un transbordo, el tramo puede empezar antes
    /// de que exista la 09.
    /// </summary>
    public const string TransbordoProgramado =
        "SUNAT_Envio_IndicadorTransbordoProgramado";

    /// <summary>El vehículo vuelve vacío.</summary>
    public const string RetornoVehiculoVacio =
        "SUNAT_Envio_IndicadorRetornoVehiculoVacio";

    /// <summary>El vehículo vuelve con envases vacíos.</summary>
    public const string RetornoVehiculoEnvaseVacio =
        "SUNAT_Envio_IndicadorRetornoVehiculoEnvaseVacio";

    /// <summary>
    /// Traslado en vehículo de categoría M1 o L.
    ///
    /// 24 oct: el literal es «…VehiculoM1L» (decía «…VehiculoM»). Sin él,
    /// SUNAT pide la placa y el conductor aunque el vehículo sea menor.
    /// </summary>
    public const string VehiculoMenor =
        "SUNAT_Envio_IndicadorTrasladoVehiculoM1L";

    /// <summary>
    /// El remitente declara el vehículo y los conductores del transportista.
    ///
    /// Solo aplica a la guía 09, cuando el remitente conoce esos datos y los
    /// pone él. Es lo que evita que el transportista tenga que emitir su 31
    /// antes de salir.
    /// </summary>
    public const string VehiculoYConductoresDelTransportista =
        "SUNAT_Envio_IndicadorVehiculoConductoresTransp";

    public static bool EsValido(string indicador) =>
        indicador.StartsWith("SUNAT_", StringComparison.Ordinal);

    /// <summary>24 oct: cómo se lee cada indicador en la hoja impresa.</summary>
    public static string Nombre(string indicador) => indicador switch
    {
        TransporteSubcontratado => "Transporte subcontratado",
        PagaFleteRemitente => "Flete pagado por el remitente",
        PagaFleteSubcontratador => "Flete pagado por el subcontratador",
        PagaFleteTercero => "Flete pagado por un tercero",
        TrasladoTotal => "Traslado total",
        TransbordoProgramado => "Transbordo programado",
        RetornoVehiculoVacio => "Retorno de vehículo vacío",
        RetornoVehiculoEnvaseVacio => "Retorno de vehículo con envases o embalajes vacíos",
        VehiculoMenor => "Traslado en vehículo M1 o L",
        VehiculoYConductoresDelTransportista => "Vehículo y conductores del transportista",
        _ => indicador
    };
}

/// <summary>Una dirección de partida o de llegada.</summary>
/// <param name="Ubigeo">
/// Código de seis dígitos del INEI. SUNAT lo valida contra su listado, así
/// que un ubigeo inventado rechaza la guía entera.
/// </param>
/// <param name="CodigoEstablecimiento">
/// Código de establecimiento anexo del RUC. Obligatorio cuando el traslado
/// es entre locales de la misma empresa.
/// </param>
public record DireccionTraslado(
    string Ubigeo,
    string Direccion,
    string? CodigoEstablecimiento = null);

/// <summary>El transportista, cuando el traslado es público.</summary>
public record Transportista(
    string TipoDocumento,
    string NumeroDocumento,
    string RazonSocial,

    /// <summary>Registro del MTC. Obligatorio para ciertos transportes.</summary>
    string? NumeroMtc = null);

/// <summary>El vehículo y su conductor, cuando el traslado es privado.</summary>
/// <param name="Placa">
/// Sin guiones ni espacios. SUNAT valida el formato.
/// </param>
public record Vehiculo(
    string Placa,

    /// <summary>
    /// Número del certificado de habilitación vehicular.
    ///
    /// En la guía del remitente casi nunca hace falta. En la del
    /// TRANSPORTISTA es obligatorio (error 3355): es lo que acredita que ese
    /// camión está habilitado para transporte de carga.
    /// </summary>
    string? Tuc = null,

    /// <summary>
    /// Número de la autorización especial, cuando el vehículo la necesita:
    /// mercancía peligrosa, carga sobredimensionada, residuos sólidos.
    /// </summary>
    string? NumeroAutorizacion = null,

    /// <summary>
    /// Qué entidad dio esa autorización. Catálogo 37 de SUNAT: "01" MTC,
    /// "02" Produce, "03" Digesa, "04" Senasa, "06" MINEM, "07" Sucamec.
    /// </summary>
    string? EntidadAutorizadora = null);

/// <summary>Quien conduce el vehículo.</summary>
public record Conductor(
    string TipoDocumento,
    string NumeroDocumento,
    string Nombres,
    string Apellidos,

    /// <summary>Número de licencia de conducir.</summary>
    string Licencia);

/// <summary>
/// Quien contrató el traslado, en una guía de transportista.
///
/// ES EL REMITENTE DE LA MERCANCÍA: la empresa que emitió su propia guía 09
/// y que puso la carga en el camión. El transportista tiene que declararlo
/// porque su guía sola no explica de dónde salieron los bienes.
///
/// Va en cac:OriginatorCustomerParty, que es un bloque que la guía del
/// remitente NO usa: allí el remitente es el emisor y no hace falta
/// nombrarlo dos veces.
/// </summary>
public record RemitenteContratante(
    string TipoDocumento,
    string NumeroDocumento,
    string RazonSocial);

/// <summary>Un bien trasladado.</summary>
public record BienTrasladado(
    string Descripcion,
    decimal Cantidad,
    string UnidadMedida,
    string? CodigoProducto = null,

    /// <summary>
    /// Código de producto SUNAT. Obligatorio para bienes normalizados.
    /// </summary>
    string? CodigoSunat = null);

/// <summary>
/// Un documento relacionado con el traslado: la factura que lo origina, la
/// declaración aduanera en una importación, etcétera.
/// </summary>
public record DocumentoRelacionadoGre(
    string TipoDocumento,
    string NumeroDocumento,

    /// <summary>RUC del emisor del documento, cuando no es el propio remitente.</summary>
    string? RucEmisor = null);

/// <summary>
/// Guía de remisión electrónica del remitente (tipo 09).
///
/// QUÉ ES Y EN QUÉ SE DIFERENCIA DE UNA FACTURA:
///
/// Una factura documenta una venta: tiene importes, IGV y condiciones de
/// pago. Una guía documenta un TRASLADO: tiene de dónde sale, a dónde va,
/// quién lo lleva, en qué vehículo y qué bienes van dentro. No lleva
/// importes.
///
/// Y hay una regla que no existe en las facturas: LA CONSTANCIA ACEPTADA
/// DEBE EXISTIR ANTES DE QUE EL VEHÍCULO SALGA. Una factura se puede enviar
/// después de la operación; una guía no, porque es lo que sustenta el
/// traslado ante una fiscalización en carretera.
/// </summary>
public sealed class GuiaRemision
{
    /// <summary>
    /// Catálogo 01: "09" del remitente, "31" del transportista.
    ///
    /// LAS DOS SON EL MISMO XML CON LAS PARTES CAMBIADAS DE SITIO, y por eso
    /// viven en la misma clase en vez de en dos:
    ///
    ///   09  la emite quien MANDA los bienes.  Serie T###.
    ///       Él es el DespatchSupplierParty, y si contrata transporte,
    ///       nombra al transportista en CarrierParty.
    ///
    ///   31  la emite quien los LLEVA.  Serie V###.
    ///       Él es el DespatchSupplierParty, y tiene que nombrar al
    ///       remitente en OriginatorCustomerParty y referenciar la guía 09
    ///       de ese remitente.
    ///
    /// En un traslado con transportista contratado existen LAS DOS, una por
    /// cada empresa, y las dos tienen que estar aceptadas antes de que el
    /// camión salga.
    /// </summary>
    public string TipoGuia { get; set; } = CatalogosGre.TipoGuiaRemitente;

    public bool EsTransportista => TipoGuia == CatalogosGre.TipoGuiaTransportista;

    public string Serie { get; set; } = "";
    public int Correlativo { get; set; }

    public DateTime FechaEmision { get; set; } = RelojPeru.Hoy;

    /// <summary>
    /// Cuándo empieza el traslado.
    ///
    /// No puede ser anterior a la emisión: la guía se emite antes de mover
    /// los bienes, no después.
    /// </summary>
    public DateTime FechaTraslado { get; set; } = RelojPeru.Hoy;

    public Emisor Remitente { get; set; } = new();

    /// <summary>A quién se le entregan los bienes.</summary>
    public Receptor Destinatario { get; set; } = new();

    public string MotivoTraslado { get; set; } = CatalogosGre.MotivoTraslado.Venta;

    /// <summary>
    /// Descripción del motivo. Obligatoria cuando el motivo es "Otros".
    /// </summary>
    public string? DescripcionMotivo { get; set; }

    public string ModalidadTraslado { get; set; } = CatalogosGre.ModalidadTraslado.Privado;

    /// <summary>Peso total, en la unidad de UnidadPeso (kilos si no se dice).</summary>
    public decimal PesoBruto { get; set; }

    /// <summary>
    /// 24 oct: la unidad del peso bruto: "KGM" kilogramos (por defecto) o
    /// "TNE" toneladas, las dos que acepta SUNAT.
    /// </summary>
    public string UnidadPeso { get; set; } = "KGM";

    /// <summary>Cuántos bultos. Obligatorio en importaciones.</summary>
    public int? NumeroBultos { get; set; }

    public DireccionTraslado PuntoPartida { get; set; } = new("", "");
    public DireccionTraslado PuntoLlegada { get; set; } = new("", "");

    /// <summary>Solo cuando la modalidad es pública.</summary>
    public Transportista? Transportista { get; set; }

    /// <summary>
    /// Cuándo se le entregaron los bienes al transportista.
    ///
    /// OBLIGATORIO EN TRANSPORTE PÚBLICO (error 3617), y es un dato que no
    /// existe en el transporte privado porque allí no hay entrega: la misma
    /// empresa carga y lleva.
    ///
    /// SUNAT lo quiere para saber desde cuándo la mercancía está en manos del
    /// transportista, que es quien responde a partir de ese momento.
    ///
    /// Si no se indica, se usa la fecha de traslado: lo normal es entregar
    /// la carga el mismo día que sale.
    /// </summary>
    public DateTime? FechaEntregaAlTransportista { get; set; }

    /// <summary>
    /// La fecha que se declara, resolviendo el valor por defecto.
    /// </summary>
    public DateTime FechaEntregaEfectiva =>
        FechaEntregaAlTransportista ?? FechaTraslado;

    /// <summary>Solo cuando la modalidad es privada.</summary>
    public Vehiculo? Vehiculo { get; set; }

    /// <summary>Solo cuando la modalidad es privada.</summary>
    public Conductor? Conductor { get; set; }

    // ------------------------------------------- solo en la guía del transportista

    /// <summary>
    /// El remitente: de quién son los bienes. Obligatorio en la 31.
    ///
    /// VA DENTRO DEL PUNTO DE PARTIDA, en Delivery/Despatch/DespatchParty, y
    /// no en un bloque de partes propio. Es quien despacha desde ese punto.
    /// </summary>
    public RemitenteContratante? Contratante { get; set; }

    /// <summary>
    /// Quien paga el flete, cuando no es ni el remitente ni el emisor.
    ///
    /// Va en OriginatorCustomerParty —que a pesar del nombre NO es el
    /// remitente— y solo tiene sentido junto al indicador
    /// SUNAT_Envio_IndicadorPagadorFlete_Tercero.
    /// </summary>
    public RemitenteContratante? PagadorFlete { get; set; }

    /// <summary>
    /// Número de registro del transportista en el MTC.
    ///
    /// Obligatorio en la 31 (error 3353): es lo que acredita que la empresa
    /// puede prestar servicio de transporte de carga. El remitente no lo
    /// tiene porque no es transportista.
    /// </summary>
    public string? NumeroMtc { get; set; }

    /// <summary>
    /// Conductores de relevo, si el viaje los lleva.
    ///
    /// El principal va en Conductor. Estos salen con JobTitle "Secundario",
    /// y SUNAT exige la licencia de cada uno igual que la del principal.
    /// </summary>
    public List<Conductor> ConductoresSecundarios { get; set; } = [];

    /// <summary>
    /// Indicadores del catálogo de SUNAT que modifican el traslado.
    ///
    /// Son cadenas literales que se declaran tal cual, y están en
    /// IndicadorGre. El más frecuente es el de subcontratación.
    /// </summary>
    public List<string> Indicadores { get; set; } = [];

    /// <summary>
    /// El transportista al que se subcontrató, cuando el emisor no lleva la
    /// carga él mismo.
    ///
    /// Va acompañado del indicador de transporte subcontratado: sin él SUNAT
    /// no entiende qué pinta ese tercero en el documento (error 4424).
    /// </summary>
    public Transportista? OperadorSubcontratado { get; set; }

    public List<BienTrasladado> Bienes { get; set; } = [];

    public List<DocumentoRelacionadoGre> DocumentosRelacionados { get; set; } = [];

    /// <summary>Observaciones libres.</summary>
    public string? Observaciones { get; set; }

    /// <summary>
    /// El traslado se hace en vehículo de categoría M1 o L.
    ///
    /// Cuando es así, SUNAT exime de declarar placa y licencia del conductor.
    /// Son motos y vehículos menores, típicos del reparto urbano.
    /// </summary>
    public bool VehiculoMenor { get; set; }

    public string Numero => $"{Serie}-{Correlativo:D8}";

    /// <summary>
    /// El nombre del archivo que se le manda a SUNAT.
    ///
    /// LLEVA EL TIPO DENTRO, y por eso esto es lo único que el worker
    /// necesitaba para empezar a mandar guías de transportista: el resto del
    /// canal —el ZIP, el envío REST, la consulta del ticket— es idéntico.
    /// </summary>
    public string NombreArchivo => $"{Remitente.Ruc}-{TipoGuia}-{Numero}";

    /// <summary>
    /// Comprueba lo que se puede comprobar antes de enviar.
    ///
    /// POR QUÉ VALE LA PENA: cada envío rechazado es un viaje de ida y vuelta
    /// a SUNAT, y en el caso de las guías es peor que en las facturas, porque
    /// el camión está esperando. Atrapar aquí lo evidente ahorra minutos en
    /// el momento en que más molestan.
    /// </summary>
    public IReadOnlyList<string> Revisar()
    {
        var problemas = new List<string>();

        // LA SERIE DICE QUÉ GUÍA ES, y no son intercambiables: una T en una
        // guía de transportista es un rechazo inmediato.
        var inicial = EsTransportista ? 'V' : 'T';

        if (string.IsNullOrWhiteSpace(Serie) || Serie.Length != 4 ||
            char.ToUpperInvariant(Serie[0]) != inicial)
        {
            problemas.Add(
                $"La serie de una guía de {(EsTransportista ? "transportista" : "remitente")} " +
                $"debe empezar por {inicial} y tener cuatro caracteres, como " +
                $"{inicial}001. Lo exige SUNAT.");
        }

        if (TipoGuia != CatalogosGre.TipoGuiaRemitente &&
            TipoGuia != CatalogosGre.TipoGuiaTransportista)
        {
            problemas.Add(
                $"El tipo de guía '{TipoGuia}' no existe. Solo hay dos: '09' " +
                $"del remitente y '31' del transportista.");
        }

        foreach (var indicador in Indicadores.Where(i => !IndicadorGre.EsValido(i)))
        {
            problemas.Add(
                $"El indicador '{indicador}' no es válido: todos empiezan por " +
                $"'SUNAT_' y SUNAT los compara carácter a carácter (regla 3388).");
        }

        if (Correlativo < 0)
            problemas.Add("El correlativo debe ser mayor que cero.");

        if (FechaTraslado.Date < FechaEmision.Date)
            problemas.Add(
                "La fecha de traslado no puede ser anterior a la de emisión: " +
                "la guía se emite antes de mover los bienes.");

        if (!CatalogosGre.MotivoTraslado.EsValido(MotivoTraslado))
            problemas.Add($"El motivo de traslado '{MotivoTraslado}' no existe en el catálogo.");

        if (MotivoTraslado == CatalogosGre.MotivoTraslado.Otros &&
            string.IsNullOrWhiteSpace(DescripcionMotivo))
        {
            problemas.Add(
                "Con motivo 'Otros' hay que describir el motivo real.");
        }

        if (!CatalogosGre.ModalidadTraslado.EsValido(ModalidadTraslado))
            problemas.Add($"La modalidad '{ModalidadTraslado}' no existe. Usa 01 o 02.");

        // LA GUÍA DEL TRANSPORTISTA TIENE OTRAS EXIGENCIAS, y ninguna de las
        // de abajo: él SIEMPRE lleva la carga, así que la modalidad no le
        // aplica y el vehículo y el conductor nunca son opcionales.
        if (EsTransportista)
        {
            RevisarTransportista(problemas);

            return problemas;
        }

        // Cada modalidad exige datos distintos, y esta es la confusión más
        // habitual al empezar con guías.
        if (ModalidadTraslado == CatalogosGre.ModalidadTraslado.Publico)
        {
            if (Transportista is null)
                problemas.Add(
                    "En transporte público hay que declarar al transportista. " +
                    "Además, él debe emitir su propia guía (tipo 31).");

            // La entrega no puede ser posterior al inicio del traslado: no se
            // puede mover lo que todavía no se ha entregado.
            if (FechaEntregaEfectiva.Date > FechaTraslado.Date)
            {
                problemas.Add(
                    $"La fecha de entrega al transportista " +
                    $"({FechaEntregaEfectiva:yyyy-MM-dd}) es posterior al inicio " +
                    $"del traslado ({FechaTraslado:yyyy-MM-dd}).");
            }
        }
        else
        {
            if (!VehiculoMenor)
            {
                if (Vehiculo is null || string.IsNullOrWhiteSpace(Vehiculo.Placa))
                    problemas.Add(
                        "En transporte privado hay que declarar la placa del vehículo.");

                if (Conductor is null)
                    problemas.Add(
                        "En transporte privado hay que declarar al conductor con su licencia.");
            }
        }

        if (PesoBruto <= 0)
            problemas.Add("El peso bruto debe ser mayor que cero.");

        if (UnidadPeso is not ("KGM" or "TNE"))
            problemas.Add($"La unidad del peso '{UnidadPeso}' no vale: KGM (kilos) o TNE (toneladas).");

        if (Bienes.Count == 0)
            problemas.Add("La guía no tiene bienes.");

        foreach (var (bien, i) in Bienes.Select((b, i) => (b, i + 1)))
        {
            if (bien.Cantidad <= 0)
                problemas.Add($"El bien {i} tiene cantidad cero o negativa.");

            if (string.IsNullOrWhiteSpace(bien.Descripcion))
                problemas.Add($"El bien {i} no tiene descripción.");
        }

        if (!EsUbigeo(PuntoPartida.Ubigeo))
            problemas.Add(
                "El ubigeo de partida debe tener seis dígitos y existir en el " +
                "listado del INEI.");

        if (!EsUbigeo(PuntoLlegada.Ubigeo))
            problemas.Add("El ubigeo de llegada debe tener seis dígitos.");

        if (MotivoTraslado == CatalogosGre.MotivoTraslado.EntreEstablecimientos)
        {
            if (string.IsNullOrWhiteSpace(PuntoPartida.CodigoEstablecimiento) ||
                string.IsNullOrWhiteSpace(PuntoLlegada.CodigoEstablecimiento))
            {
                problemas.Add(
                    "En traslados entre establecimientos hay que declarar el " +
                    "código de establecimiento de partida y de llegada, los que " +
                    "figuran en la ficha RUC.");
            }
        }

        if (MotivoTraslado == CatalogosGre.MotivoTraslado.Importacion &&
            NumeroBultos is null or <= 0)
        {
            problemas.Add("En importaciones hay que declarar el número de bultos.");
        }

        // El RUC del emisor es obligatorio para casi todos los tipos de
        // documento relacionado.
        //
        // Lo exige la regla 3380, y el mensaje de rechazo no lo dice claro:
        // devuelve un código 99 genérico con el detalle escondido dentro de
        // la respuesta.
        foreach (var doc in DocumentosRelacionados)
        {
            if (DocumentosQueExigenRuc.Contains(doc.TipoDocumento) &&
                string.IsNullOrWhiteSpace(doc.RucEmisor))
            {
                problemas.Add(
                    $"El documento relacionado {doc.TipoDocumento}-{doc.NumeroDocumento} " +
                    "necesita el RUC de quien lo emitió. Si lo emitiste tú, " +
                    "pon tu propio RUC.");
            }
        }

        return problemas;
    }

    /// <summary>
    /// Lo que solo exige la guía del transportista.
    ///
    /// SE LLAMA DESPUÉS de las comprobaciones comunes —fechas, motivo, peso,
    /// bienes, ubigeos— y sustituye a las de modalidad, que aquí no pintan
    /// nada: el transportista siempre lleva la carga.
    /// </summary>
    private void RevisarTransportista(List<string> problemas)
    {
        // --- Quién contrató el traslado ---------------------------------------

        if (Contratante is null)
        {
            problemas.Add(
                "Falta el remitente que contrató el traslado. La guía del " +
                "transportista sola no explica de dónde salieron los bienes, " +
                "y SUNAT lo exige en OriginatorCustomerParty.");
        }
        else if (string.IsNullOrWhiteSpace(Contratante.NumeroDocumento))
        {
            problemas.Add("Falta el documento del remitente que contrató.");
        }

        // --- El registro del MTC ----------------------------------------------

        if (string.IsNullOrWhiteSpace(NumeroMtc))
        {
            problemas.Add(
                "Falta el número de registro del MTC del transportista " +
                "(error 3353). Es lo que acredita que la empresa puede " +
                "prestar servicio de transporte de carga.");
        }

        // --- El vehículo -------------------------------------------------------
        //
        // Aquí NO hay exención por vehículo menor: eso es del remitente. Un
        // transportista declara siempre placa y habilitación.

        if (Vehiculo is null || string.IsNullOrWhiteSpace(Vehiculo.Placa))
        {
            problemas.Add(
                "Falta la placa del vehículo (error 2567).");
        }
        else if (string.IsNullOrWhiteSpace(Vehiculo.Tuc))
        {
            problemas.Add(
                "Falta el número de certificado de habilitación vehicular " +
                "(error 3355). No es la tarjeta de propiedad: es el documento " +
                "que habilita ese camión para transporte de carga.");
        }

        if (Vehiculo is not null &&
            !string.IsNullOrWhiteSpace(Vehiculo.NumeroAutorizacion) &&
            string.IsNullOrWhiteSpace(Vehiculo.EntidadAutorizadora))
        {
            problemas.Add(
                "Se declara una autorización especial sin decir qué entidad " +
                "la dio (error 4407). Catálogo 37: '01' MTC, '02' Produce, " +
                "'03' Digesa, '04' Senasa, '06' MINEM, '07' Sucamec.");
        }

        // --- Los conductores ---------------------------------------------------

        if (Conductor is null || string.IsNullOrWhiteSpace(Conductor.Licencia))
        {
            problemas.Add(
                "Falta el conductor principal con su licencia (error 2573).");
        }

        foreach (var (c, i) in ConductoresSecundarios.Select((c, i) => (c, i + 1)))
        {
            if (string.IsNullOrWhiteSpace(c.Licencia))
                problemas.Add($"Al conductor secundario {i} le falta la licencia.");

            if (string.IsNullOrWhiteSpace(c.NumeroDocumento))
                problemas.Add($"Al conductor secundario {i} le falta el documento.");
        }

        // --- La guía del remitente ---------------------------------------------
        //
        // REGLA 2574, y es la que más sorprende: la 31 no vive sola. Tiene que
        // decir qué guía 09 está amparando, porque es esa la que declara de
        // quién son los bienes.
        //
        // La única excepción es el transbordo programado, donde el tramo puede
        // empezar antes de que exista la 09.

        var amparaUnaGuia = DocumentosRelacionados
            .Any(d => d.TipoDocumento == CatalogosGre.TipoGuiaRemitente);

        var esTransbordo = Indicadores.Contains(IndicadorGre.TransbordoProgramado);

        if (!amparaUnaGuia && !esTransbordo)
        {
            problemas.Add(
                "La guía del transportista tiene que referenciar la guía del " +
                "remitente que ampara: un documento relacionado de tipo '09' " +
                "con su número y el RUC de quien la emitió (error 2574). " +
                "Solo se puede omitir en un transbordo programado.");
        }

        // --- Quién paga el flete ------------------------------------------------

        var pagaUnTercero = Indicadores.Contains(IndicadorGre.PagaFleteTercero);

        if (pagaUnTercero && PagadorFlete is null)
        {
            problemas.Add(
                "Se declara que el flete lo paga un tercero pero no se dice " +
                "quién (error 4401).");
        }

        if (!pagaUnTercero && PagadorFlete is not null)
        {
            problemas.Add(
                "Se declara un pagador del flete sin el indicador " +
                $"'{IndicadorGre.PagaFleteTercero}'.");
        }

        // --- La subcontratación -------------------------------------------------

        var declaraSubcontrata =
            Indicadores.Contains(IndicadorGre.TransporteSubcontratado);

        if (declaraSubcontrata && OperadorSubcontratado is null)
        {
            problemas.Add(
                "Se declara transporte subcontratado pero no se dice a quién " +
                "(error 3390).");
        }

        if (!declaraSubcontrata && OperadorSubcontratado is not null)
        {
            problemas.Add(
                "Se declara un transportista subcontratado sin el indicador " +
                $"'{IndicadorGre.TransporteSubcontratado}'. Sin él SUNAT no " +
                "entiende qué pinta ese tercero en el documento (error 4424).");
        }
    }

    /// <summary>
    /// Los documentos relacionados que llevan el RUC de quien los emitió
    /// (regla 3380): comprobantes y guías. Una constancia de detracción o una
    /// DAM no lo llevan.
    /// </summary>
    public static readonly string[] DocumentosQueExigenRuc = ["01", "03", "04", "09", "12", "31", "48", "92"];

    private static bool EsUbigeo(string? valor) =>
        valor is { Length: 6 } && valor.All(char.IsDigit);
}