using System.IO.Compression;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Xml.Linq;
using Facturacion.Cpe;
using Facturacion.Persistencia;

namespace Facturacion.Api;

/// <summary>
/// La pestaña «Esquemas XSD» de Vigilancia SUNAT (migración 033): qué moldes
/// tiene cargados el Worker, subir los que faltan, y los XML que no
/// cumplieron el suyo. Quien ve el estado del servicio (diagnostico.ver).
///
/// SE SUBEN A MANO, como el catálogo: SUNAT no deja que un programa baje sus
/// archivos. Se acepta el .zip del paquete entero o .xsd sueltos.
///
/// LA API NO LOS USA: los guarda en la base y el Worker, que es el que firma y
/// envía, los copia a su carpeta en un par de minutos (SincronizadorXsd).
/// </summary>
public static class EndpointsEsquemasXsd
{
    /// <summary>Dónde se buscan en SUNAT. Su enlace directo al .zip cambia; la página no.</summary>
    // «11. Guías y manuales» de SUNAT (17 oct): ahí está «Otros archivos» →
    // «Archivos XSD – UBL 2.0 / 2.1» → «Clic aquí para acceder a los archivos».
    // La página anterior solo listaba las direcciones de los servicios web.
    public const string UrlPagina = "https://orientacion.sunat.gob.pe/11-guias-y-manuales";

    // Por debajo del tope de Kestrel (30 000 000 bytes), para que el mensaje
    // sea el nuestro. El paquete de SUNAT pesa mucho menos.
    private const int MaximoBytes = 25 * 1024 * 1024;
    private const int MaximoArchivos = 400;

    private static readonly Regex NombreValido = new(@"^[A-Za-z0-9._-]+\.xsd$", RegexOptions.CultureInvariant);

    public static void MapearEsquemasXsd(this WebApplication app)
    {
        var grupo = app.MapGroup("/admin/vigilancia/xsd")
            .AddEndpointFilter<AutenticacionPanel>()
            .WithTags("Vigilancia SUNAT");

        grupo.MapGet("", async (RepositorioXsd repo, int? pagina, CancellationToken ct) =>
        {
            try
            {
                var estado = await repo.EstadoAsync(ct);
                var subida = await repo.SubidaAsync(ct);
                var huella = await repo.HuellaAsync(ct);

                var p = Math.Max(1, pagina ?? 1);
                const int tamano = 20;
                var (filas, total) = await repo.AvisosAsync(p, tamano, 30, ct);

                return Results.Ok(new
                {
                    urlPagina = UrlPagina,
                    worker = estado is null ? null : new
                    {
                        estado.Maquina,
                        estado.InformadoEn,
                        estado.Bloquea,
                        moldes = JsonSerializer.Deserialize<JsonElement>(estado.MoldesJson),

                        // ¿Ya copió lo último que se subió?
                        alDia = huella.Length == 0 || estado.Huella == huella
                    },
                    subida = new { subida.Archivos, subida.UltimaEn, subida.UltimaPor },
                    avisos = new
                    {
                        items = filas,
                        total,
                        pagina = p,
                        tamano,
                        paginas = Math.Max(1, (total + tamano - 1) / tamano)
                    }
                });
            }
            catch (Npgsql.PostgresException ex) when (ex.SqlState == "42P01")
            {
                return Results.Json(new RespuestaError(
                    "Falta aplicar la migración 033.",
                    "Sin ella no se pueden subir esquemas ni ver los avisos."),
                    statusCode: StatusCodes.Status503ServiceUnavailable);
            }
        })
        .AddEndpointFilter(new ExigirPermiso(Permiso.DiagnosticoVer))
        .WithSummary("Los esquemas XSD que tiene el Worker y los XML que no cumplieron su molde");

        // El cuerpo ES el archivo (.zip o .xsd), sin formulario. El nombre de
        // un .xsd suelto llega en la cabecera X-Nombre-Archivo.
        grupo.MapPost("/subir", async (
            HttpRequest peticion, ContextoOperador operador, RepositorioXsd repo, CancellationToken ct) =>
        {
            if (peticion.ContentLength is > MaximoBytes)
                return Results.BadRequest(new RespuestaError("El archivo es demasiado grande (máximo 25 MB)."));

            using var memoria = new MemoryStream();
            var bufer = new byte[81920];
            int leidos;
            while ((leidos = await peticion.Body.ReadAsync(bufer, ct)) > 0)
            {
                memoria.Write(bufer, 0, leidos);
                if (memoria.Length > MaximoBytes)
                    return Results.BadRequest(new RespuestaError("El archivo es demasiado grande (máximo 25 MB)."));
            }

            var bytes = memoria.ToArray();
            if (bytes.Length == 0)
                return Results.BadRequest(new RespuestaError("No llegó ningún archivo."));

            var nombre = Path.GetFileName(peticion.Headers["X-Nombre-Archivo"].ToString());
            var raices = ValidacionPrevia.Moldes().Select(m => m.Raiz).ToHashSet(StringComparer.Ordinal);

            var (archivos, ignorados, error) = EsZip(bytes)
                ? LeerZip(bytes, raices)
                : LeerSuelto(bytes, nombre, raices);

            if (error is not null)
                return Results.BadRequest(new RespuestaError("No se guardó nada.", error));

            if (archivos.Count == 0)
                return Results.BadRequest(new RespuestaError(
                    "No había ningún esquema .xsd que guardar.",
                    ignorados.Count > 0 ? "Se ignoró: " + string.Join(", ", ignorados.Take(10)) : null));

            try
            {
                await repo.GuardarAsync(archivos, operador.Exigir().Correo, ct);
            }
            catch (Npgsql.PostgresException ex) when (ex.SqlState == "42P01")
            {
                return Results.Json(new RespuestaError("Falta aplicar la migración 033."),
                    statusCode: StatusCodes.Status503ServiceUnavailable);
            }

            var principales = archivos.Count(a => a.Ruta.StartsWith("maindoc/", StringComparison.Ordinal));

            return Results.Ok(new
            {
                guardados = archivos.Count,
                principales,
                ignorados,
                mensaje = $"Se guardaron {archivos.Count} esquema(s), {principales} principal(es). " +
                          "El Worker los copia y empieza a usarlos en unos 2 minutos."
            });
        })
        .AddEndpointFilter(new ExigirPermiso(Permiso.DiagnosticoVer))
        .WithSummary("Sube los esquemas XSD de SUNAT (el .zip del paquete o .xsd sueltos)");
    }

    private static bool EsZip(byte[] b) => b.Length > 4 && b[0] == 'P' && b[1] == 'K';

    private static (List<ArchivoXsd>, List<string>, string?) LeerZip(byte[] bytes, HashSet<string> raices)
    {
        var archivos = new List<ArchivoXsd>();
        var ignorados = new List<string>();
        long total = 0;

        try
        {
            using var zip = new ZipArchive(new MemoryStream(bytes), ZipArchiveMode.Read);

            if (zip.Entries.Count > MaximoArchivos)
                return (archivos, ignorados, $"El .zip trae {zip.Entries.Count} archivos; el máximo es {MaximoArchivos}.");

            foreach (var e in zip.Entries)
            {
                if (e.FullName.EndsWith('/') || e.Length == 0) continue;

                if (!e.Name.EndsWith(".xsd", StringComparison.OrdinalIgnoreCase))
                {
                    ignorados.Add(e.FullName);
                    continue;
                }

                total += e.Length;
                if (total > MaximoBytes)
                    return (archivos, ignorados, "Descomprimido pasa de 25 MB: no parece el paquete de esquemas.");

                using var s = e.Open();
                using var m = new MemoryStream();
                s.CopyTo(m);

                var carpeta = CarpetaDeRuta(e.FullName);
                var (archivo, problema) = Revisar(e.Name, m.ToArray(), carpeta, raices);

                if (problema is not null) ignorados.Add($"{e.FullName} ({problema})");
                else if (archivos.Any(a => a.Ruta == archivo!.Ruta))
                    ignorados.Add($"{e.FullName} (repetido: se usó el primero)");
                else archivos.Add(archivo!);
            }
        }
        catch (InvalidDataException)
        {
            return (archivos, ignorados, "El archivo no es un .zip válido.");
        }

        return (archivos, ignorados, null);
    }

    private static (List<ArchivoXsd>, List<string>, string?) LeerSuelto(
        byte[] bytes, string nombre, HashSet<string> raices)
    {
        if (string.IsNullOrWhiteSpace(nombre) || !nombre.EndsWith(".xsd", StringComparison.OrdinalIgnoreCase))
            return ([], [], "Sube el .zip del paquete de SUNAT o un archivo .xsd.");

        var (archivo, problema) = Revisar(nombre, bytes, null, raices);

        return problema is not null
            ? ([], [], $"{nombre}: {problema}")
            : ([archivo!], [], null);
    }

    private static readonly Regex Doctype = new(@"<!DOCTYPE[^\[>]*(\[(?<interno>.*?)\])?\s*>",
        RegexOptions.Singleline | RegexOptions.CultureInvariant);

    private static readonly Regex Ubicacion = new(@"schemaLocation\s*=\s*[""'](?<u>[^""']*)[""']",
        RegexOptions.CultureInvariant);

    private static readonly Regex UbicacionSegura = new(@"^(\.\./(maindoc|common)/|\./)?[A-Za-z0-9._-]+\.xsd$",
        RegexOptions.CultureInvariant | RegexOptions.IgnoreCase);

    private static readonly HashSet<string> DtdPermitidas = new(StringComparer.OrdinalIgnoreCase)
    {
        "-//W3C//DTD XMLSCHEMA 200102//EN",
        "http://www.w3.org/2001/XMLSchema.dtd"
    };

    /// <summary>Null si el esquema no apunta fuera; si no, el motivo.</summary>
    private static string? ProblemaDeReferencias(byte[] contenido)
    {
        string texto;
        try { texto = System.Text.Encoding.UTF8.GetString(contenido); }
        catch (Exception) { return "no se puede leer como texto"; }

        foreach (Match d in Doctype.Matches(texto))
        {
            var corchete = d.Value.IndexOf('[');
            var cabecera = corchete >= 0 ? d.Value[..corchete] : d.Value;

            // La única referencia externa que se admite es la DTD de XML
            // Schema del W3C: la trae el esquema oficial de la firma
            // (xmldsig-core-schema.xsd) y es pública y conocida.
            var referencias = Regex.Matches(cabecera, @"[""']([^""']*)[""']").Select(m => m.Groups[1].Value);

            if (Regex.IsMatch(cabecera, @"\b(SYSTEM|PUBLIC)\b") &&
                referencias.Any(r => !DtdPermitidas.Contains(r)))
                return "su DOCTYPE apunta a un archivo externo";

            var interno = d.Groups["interno"].Value;
            if (Regex.IsMatch(interno, @"<!ENTITY[^>]*\b(SYSTEM|PUBLIC)\b"))
                return "su DOCTYPE declara entidades externas";
        }

        foreach (Match u in Ubicacion.Matches(texto))
        {
            if (!UbicacionSegura.IsMatch(u.Groups["u"].Value))
                return $"importa «{u.Groups["u"].Value}», que no es un archivo de la carpeta de esquemas";
        }

        return null;
    }

    /// <summary>maindoc o common si la ruta del .zip lo dice; si no, null.</summary>
    private static string? CarpetaDeRuta(string rutaEnZip)
    {
        var partes = rutaEnZip.Replace('\\', '/').Split('/', StringSplitOptions.RemoveEmptyEntries);

        for (var i = partes.Length - 2; i >= 0; i--)
        {
            if (partes[i].Equals("maindoc", StringComparison.OrdinalIgnoreCase)) return "maindoc";
            if (partes[i].Equals("common", StringComparison.OrdinalIgnoreCase)) return "common";
        }

        return null;
    }

    /// <summary>
    /// Que sea un esquema XSD de verdad, con un nombre simple, y a qué carpeta
    /// va: la que diga su ruta; si no dice, maindoc cuando declara la raíz de
    /// un documento (Invoice, SummaryDocuments…) y common si no.
    /// </summary>
    private static (ArchivoXsd?, string?) Revisar(
        string nombre, byte[] contenido, string? carpeta, HashSet<string> raices)
    {
        // «.XSD» vale igual que «.xsd»: se guarda con la extensión en minúsculas.
        nombre = Path.GetFileNameWithoutExtension(nombre) + ".xsd";

        if (!NombreValido.IsMatch(nombre))
            return (null, "nombre con caracteres raros");

        // NADA QUE SALGA DE LA CARPETA. El Worker compila estos moldes con un
        // lector que sigue referencias, así que aquí se rechaza cualquier
        // DOCTYPE con referencias externas o entidades, y cualquier
        // import/include que no sea un archivo hermano (../common/X.xsd).
        // Solo el de la firma (xmldsig) trae un DOCTYPE, y es interno.
        if (ProblemaDeReferencias(contenido) is { } peligro)
            return (null, peligro);

        XElement? raiz;

        try
        {
            using var lector = System.Xml.XmlReader.Create(new MemoryStream(contenido), new System.Xml.XmlReaderSettings
            {
                // El de la firma (xmldsig) trae una DTD interna. Se lee, pero
                // sin resolver nada de afuera.
                DtdProcessing = System.Xml.DtdProcessing.Parse,
                XmlResolver = null,
                MaxCharactersFromEntities = 1024
            });

            raiz = XDocument.Load(lector).Root;
        }
        catch (Exception)
        {
            return (null, "no es un XML válido");
        }

        XNamespace xs = "http://www.w3.org/2001/XMLSchema";

        if (raiz is null || raiz.Name != xs + "schema")
            return (null, "no es un esquema XSD");

        if (carpeta is null)
        {
            var declara = raiz.Elements(xs + "element")
                .Select(e => (string?)e.Attribute("name"))
                .Any(n => n is not null && raices.Contains(n));

            carpeta = declara ? "maindoc" : "common";
        }

        return (new ArchivoXsd($"{carpeta}/{nombre}", contenido), null);
    }
}