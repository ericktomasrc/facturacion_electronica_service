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

    /// <summary>Tarjeta única de circulación. Opcional en muchos casos.</summary>
    string? Tuc = null);

/// <summary>Quien conduce el vehículo.</summary>
public record Conductor(
    string TipoDocumento,
    string NumeroDocumento,
    string Nombres,
    string Apellidos,

    /// <summary>Número de licencia de conducir.</summary>
    string Licencia);

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
    public string Serie { get; set; } = "";
    public int Correlativo { get; set; }

    public DateTime FechaEmision { get; set; } = DateTime.Today;

    /// <summary>
    /// Cuándo empieza el traslado.
    ///
    /// No puede ser anterior a la emisión: la guía se emite antes de mover
    /// los bienes, no después.
    /// </summary>
    public DateTime FechaTraslado { get; set; } = DateTime.Today;

    public Emisor Remitente { get; set; } = new();

    /// <summary>A quién se le entregan los bienes.</summary>
    public Receptor Destinatario { get; set; } = new();

    public string MotivoTraslado { get; set; } = CatalogosGre.MotivoTraslado.Venta;

    /// <summary>
    /// Descripción del motivo. Obligatoria cuando el motivo es "Otros".
    /// </summary>
    public string? DescripcionMotivo { get; set; }

    public string ModalidadTraslado { get; set; } = CatalogosGre.ModalidadTraslado.Privado;

    /// <summary>Peso total en kilogramos.</summary>
    public decimal PesoBruto { get; set; }

    /// <summary>Cuántos bultos. Obligatorio en importaciones.</summary>
    public int? NumeroBultos { get; set; }

    public DireccionTraslado PuntoPartida { get; set; } = new("", "");
    public DireccionTraslado PuntoLlegada { get; set; } = new("", "");

    /// <summary>Solo cuando la modalidad es pública.</summary>
    public Transportista? Transportista { get; set; }

    /// <summary>Solo cuando la modalidad es privada.</summary>
    public Vehiculo? Vehiculo { get; set; }

    /// <summary>Solo cuando la modalidad es privada.</summary>
    public Conductor? Conductor { get; set; }

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

    public string NombreArchivo =>
        $"{Remitente.Ruc}-{CatalogosGre.TipoGuiaRemitente}-{Numero}";

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

        if (string.IsNullOrWhiteSpace(Serie) || Serie.Length != 4 || Serie[0] != 'T')
            problemas.Add(
                "La serie de una guía de remitente debe empezar por T y tener " +
                "cuatro caracteres, como T001. Lo exige SUNAT.");

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

        // Cada modalidad exige datos distintos, y esta es la confusión más
        // habitual al empezar con guías.
        if (ModalidadTraslado == CatalogosGre.ModalidadTraslado.Publico)
        {
            if (Transportista is null)
                problemas.Add(
                    "En transporte público hay que declarar al transportista. " +
                    "Además, él debe emitir su propia guía (tipo 31).");
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
        var exigenRuc = new[] { "01", "03", "04", "09", "12", "48", "92" };

        foreach (var doc in DocumentosRelacionados)
        {
            if (exigenRuc.Contains(doc.TipoDocumento) &&
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

    private static bool EsUbigeo(string? valor) =>
        valor is { Length: 6 } && valor.All(char.IsDigit);
}
