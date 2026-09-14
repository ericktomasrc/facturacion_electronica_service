using System.Text;
using System.Xml;
using System.Xml.Linq;
using System.Xml.Schema;

namespace Facturacion.Cpe;

public record ErrorValidacion(string Mensaje, int Linea, int Posicion, bool EsAdvertencia)
{
    public override string ToString() =>
        $"[{(EsAdvertencia ? "AVISO" : "ERROR")}] línea {Linea}, pos {Posicion}: {Mensaje}";
}

public record ResultadoValidacion(bool Valido, IReadOnlyList<ErrorValidacion> Errores);

/// <summary>
/// Valida el XML contra los esquemas XSD oficiales de UBL 2.1.
///
/// DOS PROBLEMAS CONOCIDOS AL USAR ESTOS ESQUEMAS DESDE .NET:
///
/// 1. Algunos esquemas de UBL referencian ds:Signature sin importar el namespace
///    de firma XML en ese mismo archivo. Herramientas como xmllint lo toleran; el
///    compilador de .NET no. Se resuelve cargando el esquema de firma primero.
///
/// 2. El esquema de firma del W3C trae una declaración DTD interna, y .NET la
///    bloquea por seguridad. Hay que habilitar DtdProcessing.Parse al leerlo.
///
/// Ambos se resuelven aquí. Los archivos XSD no se modifican.
/// </summary>
public class ValidadorXsd
{
    private const string NamespaceFirmaXml = "http://www.w3.org/2000/09/xmldsig#";

    private readonly XmlSchemaSet _esquemas;

    /// <summary>
    /// Configuración de lectura que permite DTD. Solo se usa para archivos XSD
    /// locales y de confianza, nunca para XML que venga de afuera.
    /// </summary>
    private static XmlReaderSettings ConfiguracionLectura() => new()
    {
        DtdProcessing = DtdProcessing.Parse,
        XmlResolver = new XmlUrlResolver()
    };

    public ValidadorXsd(string rutaXsdPrincipal)
    {
        if (!File.Exists(rutaXsdPrincipal))
            throw new FileNotFoundException(
                $"No se encontró el XSD principal en: {rutaXsdPrincipal}",
                rutaXsdPrincipal);

        _esquemas = new XmlSchemaSet
        {
            XmlResolver = new XmlUrlResolver()
        };

        CargarEsquemaDeFirma(rutaXsdPrincipal);
        AgregarEsquema(rutaXsdPrincipal, targetNamespace: null);

        _esquemas.Compile();
    }

    private void AgregarEsquema(string ruta, string? targetNamespace)
    {
        using var lector = XmlReader.Create(ruta, ConfiguracionLectura());
        _esquemas.Add(targetNamespace, lector);
    }

    /// <summary>
    /// Busca el esquema de firma XML en la carpeta 'common' hermana de 'maindoc'
    /// y lo registra antes que el principal.
    /// </summary>
    private void CargarEsquemaDeFirma(string rutaXsdPrincipal)
    {
        var carpetaMaindoc = Path.GetDirectoryName(rutaXsdPrincipal);
        if (carpetaMaindoc is null) return;

        var carpetaRaiz = Path.GetDirectoryName(carpetaMaindoc);
        if (carpetaRaiz is null) return;

        var carpetaCommon = Path.Combine(carpetaRaiz, "common");
        if (!Directory.Exists(carpetaCommon)) return;

        // El nombre exacto varía entre paquetes, así que se busca por patrón.
        var candidatos = Directory.GetFiles(carpetaCommon, "*xmldsig*.xsd");
        if (candidatos.Length == 0) return;

        AgregarEsquema(candidatos[0], NamespaceFirmaXml);
    }

    public ResultadoValidacion Validar(XDocument documento)
    {
        var errores = new List<ErrorValidacion>();

        documento.Validate(_esquemas, (_, e) =>
        {
            errores.Add(new ErrorValidacion(
                e.Message,
                e.Exception?.LineNumber ?? 0,
                e.Exception?.LinePosition ?? 0,
                e.Severity == XmlSeverityType.Warning));
        });

        var hayErroresReales = errores.Any(x => !x.EsAdvertencia);
        return new ResultadoValidacion(!hayErroresReales, errores);
    }

    /// <summary>
    /// Guarda el XML con la codificación y el formato que espera SUNAT.
    ///
    /// UTF-8 SIN BOM: obligatorio. El BOM hace que la firma no valide en el paso 2.
    /// Sin indentación: los espacios en blanco afectan la canonicalización.
    /// </summary>
    public static void Guardar(XDocument documento, string ruta)
    {
        var configuracion = new XmlWriterSettings
        {
            Encoding = new UTF8Encoding(encoderShouldEmitUTF8Identifier: false),
            Indent = false,
            OmitXmlDeclaration = false,
            NewLineHandling = NewLineHandling.None
        };

        var directorio = Path.GetDirectoryName(ruta);
        if (!string.IsNullOrEmpty(directorio))
            Directory.CreateDirectory(directorio);

        using var writer = XmlWriter.Create(ruta, configuracion);
        documento.Save(writer);
    }
}