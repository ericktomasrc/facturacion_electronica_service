using System.Text.RegularExpressions;
using Facturacion.Pdf;
using QuestPDF.Fluent;
using QuestPDF.Helpers;

namespace Facturacion.Api;

/// <summary>
/// Las comprobaciones de la marca de una empresa: identificador del portal,
/// color, correo de respuesta y logo.
///
/// LA BASE TIENE LAS MISMAS REGLAS (migración 020) y es la última barrera.
/// Estas existen para devolver un mensaje que se entienda en lugar de un
/// error de restricción. Si se cambia una regla aquí, hay que cambiarla allí.
///
/// Cada función devuelve null si el valor está bien, o el motivo si no.
/// </summary>
public static partial class Marca
{
    /// <summary>Lo que el logo puede pesar como máximo.</summary>
    public const int LogoMaximoBytes = 300 * 1024;

    // Palabras que ya usa o usará la dirección del portal. Una empresa
    // llamada "api" dejaría su página tapada por las rutas de la API.
    private static readonly HashSet<string> Reservados = new(StringComparer.Ordinal)
    {
        "api", "e", "portal", "admin", "www", "static", "assets", "health", "docs"
    };

    [GeneratedRegex("^[a-z0-9][a-z0-9-]{1,38}[a-z0-9]$")]
    private static partial Regex FormaIdentificador();

    [GeneratedRegex("^#[0-9a-fA-F]{6}$")]
    private static partial Regex FormaColor();

    /// <summary>Quita espacios y pasa a minúsculas. Vacío es null.</summary>
    public static string? LimpiarIdentificador(string? valor) =>
        string.IsNullOrWhiteSpace(valor) ? null : valor.Trim().ToLowerInvariant();

    public static string? ProblemaIdentificador(string? identificador)
    {
        if (identificador is null) return null;

        if (identificador.Length is < 3 or > 40)
            return "Debe tener entre 3 y 40 caracteres.";

        if (!FormaIdentificador().IsMatch(identificador))
            return "Solo letras minúsculas sin tilde, números y guiones, y no puede " +
                   "empezar ni terminar con guion. Ejemplo: ferreteria-lopez.";

        if (identificador.Contains("--"))
            return "No puede llevar dos guiones seguidos.";

        if (Reservados.Contains(identificador))
            return $"«{identificador}» está reservado para la dirección del portal. Elige otro.";

        return null;
    }

    /// <summary>#RRGGBB a #rrggbb. Vacío es null: sin color.</summary>
    public static string? LimpiarColor(string? valor) =>
        string.IsNullOrWhiteSpace(valor) ? null : valor.Trim().ToLowerInvariant();

    public static string? ProblemaColor(string? color) =>
        color is null || FormaColor().IsMatch(color)
            ? null
            : "El color tiene que ir como #rrggbb, por ejemplo #1f6feb.";

    public static string? LimpiarCorreo(string? valor) =>
        string.IsNullOrWhiteSpace(valor) ? null : valor.Trim();

    /// <summary>La misma regla que el correo del receptor (ReceptorDto).</summary>
    public static string? ProblemaCorreo(string? correo)
    {
        if (correo is null) return null;

        if (correo.Length > 254)
            return "El correo es demasiado largo (máximo 254 caracteres).";

        var arroba = correo.IndexOf('@');
        var dominio = arroba > 0 ? correo[(arroba + 1)..] : "";

        var tieneForma =
            arroba > 0 &&
            arroba == correo.LastIndexOf('@') &&
            dominio.Contains('.') &&
            !dominio.StartsWith('.') &&
            !dominio.EndsWith('.') &&
            !correo.Any(char.IsWhiteSpace);

        return tieneForma ? null : $"«{correo}» no tiene forma de correo.";
    }

    /// <summary>
    /// Qué clase de imagen es, mirando sus primeros bytes. Null si no es PNG
    /// ni JPG.
    ///
    /// NO SE FÍA DEL NOMBRE NI DEL TIPO QUE MANDA EL NAVEGADOR: los dos los
    /// pone quien sube el archivo. Los primeros bytes los pone el formato.
    /// SVG no se acepta: es texto con posibilidad de llevar código, y se
    /// serviría desde una página pública.
    /// </summary>
    public static (string Extension, string TipoMime)? TipoDeImagen(byte[] datos)
    {
        if (datos.Length >= 8 &&
            datos[0] == 0x89 && datos[1] == 0x50 && datos[2] == 0x4E && datos[3] == 0x47 &&
            datos[4] == 0x0D && datos[5] == 0x0A && datos[6] == 0x1A && datos[7] == 0x0A)
            return ("png", "image/png");

        if (datos.Length >= 3 && datos[0] == 0xFF && datos[1] == 0xD8 && datos[2] == 0xFF)
            return ("jpg", "image/jpeg");

        return null;
    }

    /// <summary>
    /// Prueba a dibujar el logo en un PDF de verdad, del mismo alto que en la
    /// factura. Null si sale; el motivo si no.
    ///
    /// POR QUÉ SE PRUEBA AL SUBIRLO Y NO AL USARLO: unos bytes que empiezan
    /// como PNG pueden estar cortados o dañados. Si eso se descubre al generar
    /// el PDF de una factura, el que se queda sin su comprobante es el cliente
    /// del emisor. Así se descubre aquí, con quien lo subió delante.
    /// </summary>
    public static string? ProblemaAlDibujar(byte[] datos)
    {
        try
        {
            GeneradorPdf.ConfigurarLicencia();

            Document.Create(contenedor => contenedor.Page(pagina =>
            {
                pagina.Size(PageSizes.A4);
                pagina.Content().Height(50).Image(datos).FitHeight();
            })).GeneratePdf();

            return null;
        }
        catch (Exception)
        {
            return "La imagen está dañada o no se puede dibujar en el PDF. " +
                   "Vuelve a exportarla como PNG o JPG.";
        }
    }
}