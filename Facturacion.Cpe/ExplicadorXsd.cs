using System.Text.RegularExpressions;

namespace Facturacion.Cpe;

/// <summary>
/// Pone en castellano los errores del validador XSD de .NET (pestaña
/// «Esquemas XSD» de Vigilancia SUNAT, migración 033).
///
/// El validador habla en inglés y con los espacios de nombres completos:
///
///     The element 'Invoice' in namespace 'urn:oasis:…:Invoice-2' has invalid
///     child element 'IssueDate' in namespace 'urn:oasis:…:CommonBasicComponents-2'.
///     List of possible elements expected: 'ID' in namespace '…'.
///
/// Aquí queda:
///
///     Dentro de «Invoice», «cbc:IssueDate» sobra o está fuera de orden.
///     En ese lugar el molde espera: cbc:ID.
///
/// SOLO LOS CASOS QUE DE VERDAD PASAN: un elemento fuera de orden, uno que
/// falta, un valor que no es del tipo, un atributo de más o de menos. Lo que
/// no reconoce lo deja como venía, con los espacios de nombres abreviados: es
/// mejor un mensaje en inglés que uno inventado.
/// </summary>
public static class ExplicadorXsd
{
    // Del espacio de nombres al prefijo que se usa en los XML de SUNAT.
    private static string Prefijo(string ns) =>
        ns.EndsWith("CommonBasicComponents-2", StringComparison.Ordinal) ? "cbc:"
        : ns.EndsWith("CommonAggregateComponents-2", StringComparison.Ordinal) ? "cac:"
        : ns.EndsWith("CommonExtensionComponents-2", StringComparison.Ordinal) ? "ext:"
        : ns.EndsWith("SunatAggregateComponents-1", StringComparison.Ordinal) ? "sac:"
        : ns.Contains("xmldsig", StringComparison.Ordinal) ? "ds:"
        : ns.EndsWith("XMLSchema", StringComparison.Ordinal) ? "xs:"
        : "";   // el del documento (Invoice-2, CreditNote-2…): sin prefijo

    // 'A, B' in namespace 'urn:…'  →  'cbc:A, cbc:B'
    private static readonly Regex EnEspacio = new(
        @"'(?<n>[^']+)' in namespace '(?<ns>[^']+)'", RegexOptions.CultureInvariant);

    // 'urn:…:CommonBasicComponents-2:IssueDate'  →  'cbc:IssueDate'
    private static readonly Regex Calificado = new(
        @"'(?<ns>(?:urn:|https?://)[^']*):(?<n>[^:'\s]+)'", RegexOptions.CultureInvariant);

    private static readonly (Regex Patron, Func<Match, string> Texto)[] Casos =
    [
        (new(@"^The element '(?<p>[^']+)' has invalid child element '(?<h>[^']+)'\. List of possible elements expected: (?<e>.+?)\.?$"),
            m => $"Dentro de «{m.Groups["p"].Value}», «{m.Groups["h"].Value}» sobra o está fuera de orden. " +
                 $"En ese lugar el molde espera: {Lista(m.Groups["e"].Value)}."),

        (new(@"^The element '(?<p>[^']+)' has invalid child element '(?<h>[^']+)'\.$"),
            m => $"Dentro de «{m.Groups["p"].Value}», el elemento «{m.Groups["h"].Value}» no está permitido."),

        (new(@"^The element '(?<p>[^']+)' has incomplete content\. List of possible elements expected: (?<e>.+?)\.?$"),
            m => $"A «{m.Groups["p"].Value}» le falta un elemento obligatorio. Se esperaba: {Lista(m.Groups["e"].Value)}."),

        (new(@"^The '(?<x>[^']+)' element is invalid - The value '(?<v>[^']*)' is invalid according to its datatype '(?<t>[^']+)'"),
            m => $"El valor «{m.Groups["v"].Value}» de «{m.Groups["x"].Value}» no es válido para el tipo {m.Groups["t"].Value}."),

        (new(@"^The '(?<x>[^']+)' attribute is invalid - The value '(?<v>[^']*)' is invalid according to its datatype '(?<t>[^']+)'"),
            m => $"El valor «{m.Groups["v"].Value}» del atributo «{m.Groups["x"].Value}» no es válido para el tipo {m.Groups["t"].Value}."),

        (new(@"^The '(?<x>[^']+)' attribute is not declared\.$"),
            m => $"El atributo «{m.Groups["x"].Value}» no existe en el molde."),

        (new(@"^The required attribute '(?<x>[^']+)' is missing\.$"),
            m => $"Falta el atributo obligatorio «{m.Groups["x"].Value}»."),

        (new(@"^The '(?<x>[^']+)' element is not declared\.$"),
            m => $"El elemento «{m.Groups["x"].Value}» no existe en el molde."),

        (new(@"^The '(?<x>[^']+)' element is invalid - (?<r>.+)$"),
            m => $"«{m.Groups["x"].Value}» no es válido: {m.Groups["r"].Value}")
    ];

    /// <summary>El mensaje en castellano; si no se reconoce, el original abreviado.</summary>
    public static string Explicar(string mensaje)
    {
        if (string.IsNullOrWhiteSpace(mensaje)) return "";

        var corto = Abreviar(mensaje.Trim());

        foreach (var (patron, texto) in Casos)
        {
            var m = patron.Match(corto);
            if (m.Success) return texto(m);
        }

        return corto;
    }

    /// <summary>Quita los espacios de nombres largos y pone el prefijo de siempre.</summary>
    public static string Abreviar(string mensaje)
    {
        var s = EnEspacio.Replace(mensaje, m =>
        {
            var prefijo = Prefijo(m.Groups["ns"].Value);
            var nombres = m.Groups["n"].Value.Split(", ", StringSplitOptions.RemoveEmptyEntries)
                .Select(n => prefijo + n.Trim());
            return "'" + string.Join(", ", nombres) + "'";
        });

        return Calificado.Replace(s, m => "'" + Prefijo(m.Groups["ns"].Value) + m.Groups["n"].Value + "'");
    }

    // 'cbc:A, cbc:B' as well as 'cac:C'  →  cbc:A, cbc:B, cac:C
    private static string Lista(string esperados) =>
        string.Join(", ", Regex.Matches(esperados, "'([^']+)'").Select(m => m.Groups[1].Value));
}

/// <summary>
/// Cómo salió la comprobación de un XML contra su molde. Esquema null = no se
/// comprobó (falta el molde de esa raíz, o no hay carpeta de esquemas).
/// </summary>
public sealed record RevisionXsd(string? Raiz, string? Esquema, IReadOnlyList<ErrorValidacion> Errores)
{
    public bool Comprobado => Esquema is not null;
    public bool Cumple => Errores.Count == 0;
}

/// <summary>Un molde de los que se usan: la raíz del XML, su archivo y si está en disco.</summary>
public sealed record MoldeXsd(string Raiz, string Archivo, bool Cargado);