using System.Collections.Concurrent;
using System.Text;
using System.Xml.Linq;

namespace Facturacion.Cpe;

/// <summary>
/// Comprueba un XML contra el esquema de SUNAT antes de firmarlo y enviarlo.
///
/// POR QUÉ EXISTE, con un caso real:
///
/// El comprobante de retención R001-00000005 se rechazó tres veces con el
/// error 0306. El XML era correcto en todo salvo en una cosa: `cac:Signature`
/// iba en cuarta posición y tenía que ir en tercera. Tres viajes a SUNAT,
/// tres correlativos quemados, y el mensaje de error no mencionaba ni la
/// firma ni el orden.
///
/// Un XSD comprueba el orden de los elementos. Esto lo habría dicho antes del
/// primer viaje, señalando la línea.
///
/// QUÉ NO ATAJA, para que nadie confíe de más: solo la forma. Que el
/// TaxableAmount global no cuadre con la suma de las líneas (3277), que el
/// remitente esté en el elemento equivocado (3383) o que un código no exista
/// en un catálogo (2256) son cosas que el esquema considera perfectamente
/// válidas. Esta es una red, no un colador fino.
///
///
/// AVISA, NO BLOQUEA. Y es deliberado.
///
/// Un validador recién estrenado no debería poder impedir que se emita. Si
/// el mapeo de esquemas falla en un caso que no previmos, bloquear dejaría a
/// una empresa sin facturar por un error nuestro, que es peor que el problema
/// que esto resuelve. Escribe el fallo en el log —se ve antes que SUNAT lo
/// diga— y deja pasar el comprobante.
///
/// Cuando lleve semanas sin dar un falso positivo, se le da el veto con
/// FACTURACION_XSD_BLOQUEA=true.
/// </summary>
public static class ValidacionPrevia
{
    /// <summary>
    /// Carpeta que contiene `maindoc` y `common`. Vacía significa que no hay
    /// esquemas y que esto no hace nada.
    /// </summary>
    public static string Ruta { get; set; } = "";

    /// <summary>¿Un XML que no cumple el esquema impide emitir?</summary>
    public static bool Bloquea { get; set; }

    /// <summary>
    /// De la raíz del documento al archivo XSD que lo describe.
    ///
    /// LOS CUATRO ÚLTIMOS SON ESQUEMAS PROPIOS DE SUNAT y no vienen en el
    /// paquete de OASIS. Si no están en disco, esos documentos sencillamente
    /// no se comprueban: es justo lo que hace la última línea de
    /// BuscarValidador.
    /// </summary>
    private static readonly Dictionary<string, string> EsquemaDe = new()
    {
        ["Invoice"] = "UBL-Invoice-2.1.xsd",
        ["CreditNote"] = "UBL-CreditNote-2.1.xsd",
        ["DebitNote"] = "UBL-DebitNote-2.1.xsd",
        ["DespatchAdvice"] = "UBL-DespatchAdvice-2.1.xsd",
        ["SelfBilledInvoice"] = "UBL-SelfBilledInvoice-2.1.xsd",

        ["SummaryDocuments"] = "UBL-SummaryDocuments-1.0.xsd",
        ["VoidedDocuments"] = "UBL-VoidedDocuments-1.0.xsd",
        ["Retention"] = "UBL-Retention-1.0.xsd",
        ["Perception"] = "UBL-Perception-1.0.xsd"
    };

    /// <summary>
    /// Los validadores ya construidos, por nombre de archivo.
    ///
    /// COMPILAR UN XmlSchemaSet DE UBL TARDA CASI UN SEGUNDO. Hacerlo en cada
    /// comprobante convertiría una red de seguridad en el cuello de botella
    /// del worker. Se compila una vez y se reutiliza.
    ///
    /// El valor puede ser null a propósito: significa "ya se intentó y no se
    /// pudo", y evita reintentar la carga —y volver a fallar— cien veces por
    /// minuto.
    /// </summary>
    private static ConcurrentDictionary<string, ValidadorXsd?> _cache = new();

    // 033: Recargar() pone un diccionario NUEVO en vez de vaciar este. Un
    // validador que se estaba compilando con los moldes viejos termina en el
    // diccionario viejo, que ya nadie mira, y no se cuela en el nuevo.
    private static ConcurrentDictionary<string, ValidadorXsd?> Cache => Volatile.Read(ref _cache);

    /// <summary>
    /// Los problemas de forma del XML tal y como va a viajar a SUNAT.
    ///
    /// SE COMPRUEBA EL DOCUMENTO YA FIRMADO, Y NO EL DE ANTES. Se intentó al
    /// revés primero y no funciona: hasta que la firma entra, el elemento
    /// `ExtensionContent` está vacío, y el esquema de UBL exige que lleve
    /// algo dentro. Toda factura sin firmar da este error:
    ///
    ///     The element 'ExtensionContent' ... has incomplete content.
    ///     List of possible elements expected: any element in namespace '##other'
    ///
    /// Es un falso positivo del cien por cien de los documentos. Si esta
    /// clase hubiera nacido bloqueando, habría parado la facturación entera
    /// el primer día.
    ///
    /// Validar no modifica nada, así que hacerlo después de firmar no rompe
    /// la firma: al contrario, comprueba exactamente los bytes que se envían.
    /// </summary>
    public static IReadOnlyList<string> Comprobar(byte[] xmlUtf8)
    {
        if (string.IsNullOrWhiteSpace(Ruta)) return [];

        try
        {
            // SetLineInfo para que los errores digan en qué línea están.
            // Sin esto el mensaje sale con "línea 0, pos 0", que es justo el
            // dato que uno necesita y no tiene.
            var documento = XDocument.Parse(
                Encoding.UTF8.GetString(xmlUtf8), LoadOptions.SetLineInfo);

            return Comprobar(documento);
        }
        catch (Exception ex)
        {
            return [$"No se pudo leer el XML para validarlo: {ex.Message}"];
        }
    }

    /// <summary>
    /// Los problemas de forma del documento. Lista vacía significa que pasa,
    /// y también que no se pudo comprobar.
    ///
    /// LAS DOS COSAS DEVUELVEN LO MISMO A PROPÓSITO: quien llama solo tiene
    /// que decidir qué hace con los problemas, no gestionar además el caso de
    /// que no haya esquema. Que falte un esquema se dice una vez, en
    /// Diagnostico(), no en cada comprobante.
    /// </summary>
    public static IReadOnlyList<string> Comprobar(XDocument documento)
    {
        var raiz = documento.Root?.Name.LocalName;

        if (raiz is null) return [];

        var validador = BuscarValidador(raiz);

        if (validador is null) return [];

        try
        {
            var resultado = validador.Validar(documento);

            if (resultado.Valido) return [];

            return resultado.Errores
                .Where(e => !e.EsAdvertencia)
                .Select(e => e.ToString())
                .ToList();
        }
        catch (Exception ex)
        {
            // Un fallo del propio validador no puede parar una emisión. Se
            // informa como un problema más y quien llama decidirá, que por
            // defecto es dejar pasar.
            return [$"No se pudo validar contra el esquema: {ex.Message}"];
        }
    }

    /// <summary>
    /// Lo mismo que <see cref="Comprobar(byte[])"/>, pero con el detalle que
    /// enseña la pestaña «Esquemas XSD» (migración 033): qué molde se usó y
    /// cada error con su línea y su posición. Esquema null = no se comprobó
    /// (no hay ruta, no hay molde para esa raíz, o el molde no carga).
    /// </summary>
    public static RevisionXsd ComprobarDetallado(byte[] xmlUtf8)
    {
        if (string.IsNullOrWhiteSpace(Ruta)) return new RevisionXsd(null, null, []);

        XDocument documento;

        try
        {
            documento = XDocument.Parse(Encoding.UTF8.GetString(xmlUtf8), LoadOptions.SetLineInfo);
        }
        catch (Exception ex)
        {
            return new RevisionXsd(null, null,
                [new ErrorValidacion($"No se pudo leer el XML para validarlo: {ex.Message}", 0, 0, false)]);
        }

        var raiz = documento.Root?.Name.LocalName;
        var archivo = raiz is null ? null : ArchivoDe(raiz);

        if (raiz is null || archivo is null)
            return new RevisionXsd(raiz, null, []);

        var validador = BuscarValidador(raiz);

        if (validador is null) return new RevisionXsd(raiz, null, []);

        try
        {
            var resultado = validador.Validar(documento);
            return new RevisionXsd(raiz, archivo, resultado.Errores.Where(e => !e.EsAdvertencia).ToList());
        }
        catch (Exception ex)
        {
            return new RevisionXsd(raiz, archivo,
                [new ErrorValidacion($"No se pudo validar contra el esquema: {ex.Message}", 0, 0, false)]);
        }
    }

    /// <summary>
    /// Olvida los validadores ya compilados: los moldes cambiaron en disco
    /// (se subieron desde el panel) y el siguiente comprobante usa los nuevos.
    /// </summary>
    public static void Recargar()
    {
        Interlocked.Increment(ref _generacion);
        Volatile.Write(ref _cache, new ConcurrentDictionary<string, ValidadorXsd?>());
        _indice = null;
    }

    private static int _generacion;

    /// <summary>Los moldes que se usan, de la raíz al archivo, y si están en disco.</summary>
    public static IReadOnlyList<MoldeXsd> Moldes() =>
        EsquemaDe
            .Select(p => ArchivoDe(p.Key) is { } enDisco
                ? new MoldeXsd(p.Key, enDisco, true)
                : new MoldeXsd(p.Key, p.Value, false))
            .ToList();

    /// <summary>
    /// El archivo de maindoc que describe esa raíz: el de siempre si está; si
    /// no, el que declare ese elemento. LOS NOMBRES CAMBIAN DE UN PAQUETE A
    /// OTRO (UBL-SummaryDocuments-1.0.xsd, -2.0, UBLPE-…), así que no se exige
    /// un nombre: se mira qué elemento raíz declara cada archivo.
    /// </summary>
    public static string? ArchivoDe(string raiz)
    {
        if (string.IsNullOrWhiteSpace(Ruta)) return null;

        if (EsquemaDe.TryGetValue(raiz, out var fijo) && File.Exists(Path.Combine(Ruta, "maindoc", fijo)))
            return fijo;

        return Indice().GetValueOrDefault(raiz);
    }

    private static volatile Dictionary<string, string>? _indice;

    private static Dictionary<string, string> Indice()
    {
        var indice = _indice;
        if (indice is not null) return indice;

        // Si mientras se arma llega un Recargar(), este índice ya es viejo:
        // se usa para esta consulta, pero no se guarda.
        var generacion = Volatile.Read(ref _generacion);
        indice = new Dictionary<string, string>(StringComparer.Ordinal);
        var maindoc = Path.Combine(Ruta, "maindoc");

        if (Directory.Exists(maindoc))
        {
            foreach (var ruta in Directory.GetFiles(maindoc, "*.xsd").OrderBy(r => r, StringComparer.Ordinal))
            {
                foreach (var elemento in ElementosRaiz(ruta))
                    indice.TryAdd(elemento, Path.GetFileName(ruta));
            }
        }

        if (generacion == Volatile.Read(ref _generacion)) _indice = indice;
        return indice;
    }

    /// <summary>Los elementos que el esquema declara en su primer nivel.</summary>
    public static IReadOnlyList<string> ElementosRaiz(string rutaXsd)
    {
        try
        {
            using var lector = System.Xml.XmlReader.Create(rutaXsd, new System.Xml.XmlReaderSettings
            {
                DtdProcessing = System.Xml.DtdProcessing.Ignore,
                XmlResolver = null
            });

            var raiz = XDocument.Load(lector).Root;
            if (raiz is null) return [];

            XNamespace xs = "http://www.w3.org/2001/XMLSchema";
            return raiz.Elements(xs + "element")
                .Select(e => (string?)e.Attribute("name"))
                .Where(n => !string.IsNullOrEmpty(n))
                .Select(n => n!)
                .ToList();
        }
        catch (Exception)
        {
            return [];
        }
    }

    private static ValidadorXsd? BuscarValidador(string raiz)
    {
        if (string.IsNullOrWhiteSpace(Ruta)) return null;

        // 033: el archivo se busca por la raíz que declara, no solo por el nombre.
        var archivo = ArchivoDe(raiz);
        if (archivo is null) return null;

        return Cache.GetOrAdd(archivo, nombre =>
        {
            var ruta = Path.Combine(Ruta, "maindoc", nombre);

            if (!File.Exists(ruta)) return null;

            try { return new ValidadorXsd(ruta); }
            catch (Exception) { return null; }
        });
    }

    /// <summary>
    /// Qué se va a comprobar y qué no, para escribirlo en el log al arrancar.
    ///
    /// SE DICE UNA VEZ Y EN VOZ ALTA porque el modo de fallo de esto es el
    /// silencio: si la carpeta está mal puesta, no valida nada y nadie se
    /// entera nunca. Un aviso al arrancar convierte ese silencio en una línea
    /// que alguien puede leer.
    /// </summary>
    public static string Diagnostico()
    {
        if (string.IsNullOrWhiteSpace(Ruta))
        {
            return "Validación XSD DESACTIVADA: no se configuró " +
                   "FACTURACION_XSD_RUTA. Los XML no se comprobarán contra el " +
                   "esquema antes de enviarlos.";
        }

        var maindoc = Path.Combine(Ruta, "maindoc");

        if (!Directory.Exists(maindoc))
        {
            return $"Validación XSD DESACTIVADA: no existe {maindoc}. " +
                   $"FACTURACION_XSD_RUTA debe apuntar a la carpeta que " +
                   $"contiene 'maindoc' y 'common'.";
        }

        var hay = new List<string>();
        var faltan = new List<string>();

        foreach (var raiz in EsquemaDe.Keys.OrderBy(k => k, StringComparer.Ordinal))
        {
            if (ArchivoDe(raiz) is not null) hay.Add(raiz);
            else faltan.Add(raiz);
        }

        var modo = Bloquea
            ? "BLOQUEA la emisión si el XML no cumple"
            : "solo AVISA en el log, no bloquea";

        var mensaje = $"Validación XSD activa ({modo}). " +
                      $"Se comprobarán: {string.Join(", ", hay)}.";

        if (faltan.Count > 0)
        {
            mensaje += $" NO se comprobarán, porque falta su esquema: " +
                       $"{string.Join(", ", faltan)}. Esos son los esquemas " +
                       $"propios de SUNAT y se descargan de su portal.";
        }

        return mensaje;
    }
}