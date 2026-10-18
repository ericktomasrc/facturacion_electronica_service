# =============================================================================
# Entrega 2026-10-14 — VIGILANCIA SUNAT, PARTE 3: EL CATÁLOGO DE PRODUCTOS
# (SERVICIO de facturación). Va DESPUÉS de entrega-2026-10-14-codigo-producto-sunat.ps1.
#
# Se ejecuta desde la carpeta de la plataforma, igual que la anterior:
#   cd "D:\Reyban Consulting\reyban_plataforma"
#   .\entrega-2026-10-14-vigilancia-catalogo.ps1
#
# QUÉ HACE: una vez al día el servicio descarga el Excel oficial del catálogo
# de códigos de producto de SUNAT (CCNU_MOD_2.xlsm), lo compara código por
# código con el que usa la plataforma y, si SUNAT agregó o quitó códigos,
# manda el correo de alerta diciendo cuáles. Si no puede revisarlo (SUNAT lo
# movió o cambió su forma, o una semana sin internet), también avisa.
#
# NUEVOS (facturacion_electronica_service)
#   migraciones\031_vigilancia_catalogo_productos.sql   NO se aplica sola
#   Facturacion.Cpe\CatalogoProductosSunat.cs       La lista que usa la plataforma
#   Facturacion.Cpe\LectorCatalogoXlsx.cs           Lee el Excel de SUNAT
#   Facturacion.Cpe.Tests\CatalogoProductosSunatTests.cs   (5 pruebas)
#   Facturacion.Persistencia\RepositorioCatalogoSunat.cs
#   Facturacion.Api\VigilanciaCatalogo.cs           La revisión diaria
#   Facturacion.Api\EndpointsCatalogoSunat.cs       /admin/vigilancia/catalogo
# CAMBIOS PUNTUALES
#   Facturacion.Api\Program.cs                      La registra
#   Facturacion.Api\VigilanciaSunat.cs              El correo de un código de
#                                                   SUNAT del código de producto
#                                                   (3496, 4332…) dice qué mirar
#   Facturacion.Api\wwwroot\vigilancia.html         Sección «Catálogo de
#                                                   productos SUNAT»
#
# No toca .env, claves ni certificados.
#
# Cómo trabaja: comprueba TODO antes de escribir. Si un texto a cambiar no
# está tal cual, o un archivo nuevo ya existe distinto, NO TOCA NADA. Copia
# .bak de lo que cambia. Respeta los saltos de línea. No pregunta nada. Si se
# corre dos veces, la segunda no cambia nada.
# =============================================================================

$ErrorActionPreference = 'Stop'
$aqui = (Get-Location).Path
$raiz = Split-Path $aqui

$necesarias = @(
    'facturacion electronica\facturacion_electronica_service\Facturacion.Api',
    'facturacion electronica\facturacion_electronica_service\migraciones',
    'facturacion electronica\facturacion_electronica_service\Facturacion.Cpe\CodigoProductoSunat.cs'
)
foreach ($n in $necesarias) {
    if (-not (Test-Path (Join-Path $raiz $n))) {
        Write-Host "No encuentro $(Join-Path $raiz $n)." -ForegroundColor Red
        Write-Host 'Ejecuta el script desde D:\Reyban Consulting\reyban_plataforma, y después de' -ForegroundColor Red
        Write-Host 'entrega-2026-10-14-codigo-producto-sunat.ps1. No se tocó nada.' -ForegroundColor Red
        exit 1
    }
}

$utf8SinBom = New-Object System.Text.UTF8Encoding $false

$nuevos = @(
    @{ Ruta = 'facturacion electronica\facturacion_electronica_service\migraciones\031_vigilancia_catalogo_productos.sql'; Texto = @'
-- =============================================================================
-- 031 - VIGILANCIA SUNAT, PARTE 3: EL CATALOGO DE CODIGOS DE PRODUCTO
--
-- Una vez al dia el servicio descarga el Excel oficial del catalogo 25 de
-- SUNAT (CCNU_MOD_2.xlsm) y compara sus codigos con los que usa la
-- plataforma. Si SUNAT agrega o quita codigos, avisa por correo
-- (vigilancia_alertas, tipo 'catalogo_cambio').
--
--   vigilancia_catalogo            el estado: ultimo intento, ultimo exito,
--                                  ultimo error (una sola fila)
--   vigilancia_catalogo_versiones  cada lista distinta que SUNAT publico,
--                                  con lo que cambio respecto a la nuestra
--
-- Tablas de la plataforma entera: sin RLS y solo para el operador (el panel).
-- NADA SE BORRA: nadie tiene DELETE. Idempotente. Sin tildes a proposito:
-- PowerShell 5.1 la manda a psql en ASCII.
-- =============================================================================

BEGIN;

CREATE TABLE IF NOT EXISTS vigilancia_catalogo (
    id                 smallint    PRIMARY KEY DEFAULT 1,
    creado_en          timestamptz NOT NULL DEFAULT now(),
    ultimo_intento_en  timestamptz,
    ultimo_exito_en    timestamptz,
    -- Por que fallo el ultimo intento. NULL si salio bien.
    ultimo_error       text,
    -- Ya se aviso de que no se puede revisar. Vuelve a false al primer exito,
    -- para que una falla larga avise UNA vez y no cada dia.
    falla_avisada      boolean     NOT NULL DEFAULT false,
    CONSTRAINT ck_vigilancia_catalogo_una CHECK (id = 1)
);

CREATE TABLE IF NOT EXISTS vigilancia_catalogo_versiones (
    -- SHA-256 de los codigos ordenados: dos archivos con los mismos codigos
    -- son la misma version aunque el Excel cambie por dentro.
    huella             text        PRIMARY KEY,
    codigos            integer     NOT NULL,
    agregados          integer     NOT NULL,
    quitados           integer     NOT NULL,
    -- Los primeros codigos agregados y quitados, para el correo y el panel.
    agregados_muestra  text,
    quitados_muestra   text,
    sha256_archivo     text        NOT NULL,
    tamano             bigint      NOT NULL,
    -- La fecha que da el servidor de SUNAT (Last-Modified), si la da.
    publicado          text,
    visto_primera      timestamptz NOT NULL DEFAULT now(),
    visto_ultima       timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE vigilancia_catalogo_versiones IS
    'Cada lista de codigos de producto que SUNAT publico (catalogo 25), comparada con la de la plataforma.';

-- --------------------------------------------------------------- permisos
REVOKE ALL ON vigilancia_catalogo, vigilancia_catalogo_versiones FROM PUBLIC;

GRANT SELECT, INSERT, UPDATE ON vigilancia_catalogo, vigilancia_catalogo_versiones
    TO facturacion_operador;

DO $$
DECLARE
    t text;
BEGIN
    FOREACH t IN ARRAY ARRAY['vigilancia_catalogo', 'vigilancia_catalogo_versiones'] LOOP
        IF has_table_privilege('facturacion_operador', t, 'DELETE') THEN
            RAISE EXCEPTION '031: el operador no deberia poder borrar en %.', t;
        END IF;
        IF has_table_privilege('facturacion_app', t, 'SELECT') THEN
            RAISE EXCEPTION '031: la aplicacion no deberia ver %.', t;
        END IF;
    END LOOP;

    IF NOT has_table_privilege('facturacion_operador', 'vigilancia_alertas', 'INSERT') THEN
        RAISE EXCEPTION '031: falta la 029 (el operador tiene que poder crear alertas).';
    END IF;

    RAISE NOTICE '031: vigilancia del catalogo de productos lista.';
END $$;

COMMIT;
'@ },
    @{ Ruta = 'facturacion electronica\facturacion_electronica_service\Facturacion.Cpe\CatalogoProductosSunat.cs'; Texto = @'
using System.IO.Compression;
using System.Security.Cryptography;
using System.Text;

namespace Facturacion.Cpe;

/// <summary>
/// EL CATÁLOGO DE CÓDIGOS DE PRODUCTO DE SUNAT QUE USA LA PLATAFORMA, y con qué
/// compararlo (14 de octubre de 2026).
///
/// ══════════════════════════════════════════════════════════════════════════
/// POR QUÉ ESTÁ AQUÍ. La plataforma lleva su propia copia del catálogo 25
/// (CatalogoSunatDatos.cs, con descripciones, para el buscador). Si SUNAT
/// quita un código de su lista y la copia sigue teniéndolo, un producto puede
/// guardarse con él y, desde 2027, sus comprobantes se rechazan (ERR-3496).
///
/// La Vigilancia SUNAT descarga una vez al día el Excel oficial y lo compara
/// con ESTA lista: solo los códigos, sin descripciones (una descripción
/// cambiada no rechaza nada; un código quitado, sí). Si no coinciden, avisa
/// por correo con los códigos agregados y quitados.
///
/// AL REGENERAR EL CATÁLOGO DE LA PLATAFORMA HAY QUE REGENERAR ESTA LISTA
/// TAMBIÉN, del mismo Excel. Si no, la vigilancia seguiría avisando.
///
/// La lista va comprimida: los 52 840 códigos ordenados, cada uno como la
/// diferencia con el anterior, en gzip y base64.
/// ══════════════════════════════════════════════════════════════════════════
/// </summary>
public static class CatalogoProductosSunat
{
    /// <summary>Dónde publica SUNAT el Excel (página «Código de producto»).</summary>
    public const string UrlArchivo =
        "https://cpe.sunat.gob.pe/sites/default/files/inline-files/CCNU_MOD_2.xlsm";

    public const string UrlPagina =
        "https://cpe.sunat.gob.pe/informacion_general/codigoproducto";

    /// <summary>Qué versión lleva la plataforma. Cambia al regenerar.</summary>
    public const string VersionEnUso = "UNSPSC v14 (CCNU_MOD_2.xlsm), cargado el 14/10/2026";

    /// <summary>Cuántos códigos tiene (clases y productos). Para comprobar la lista.</summary>
    public const int CantidadEnUso = 52840;

    /// <summary>La huella de la lista: SHA-256 de los códigos ordenados, uno por línea.</summary>
    public const string HuellaEnUso = "c3ed2acd0ebbf63b5f1130eb253117ee6eb2984091f7cce1301f739c9e3040ee";

    private static readonly Lazy<IReadOnlySet<string>> Lista = new(Descomprimir);

    /// <summary>Los códigos que usa la plataforma.</summary>
    public static IReadOnlySet<string> EnUso => Lista.Value;

    /// <summary>La huella de cualquier lista de códigos, calculada igual que <see cref="HuellaEnUso"/>.</summary>
    public static string Huella(IEnumerable<string> codigos) =>
        Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(
            string.Join("\n", codigos.Distinct().Order(StringComparer.Ordinal))))).ToLowerInvariant();

    /// <summary>Qué tiene SUNAT que no tenemos, y qué tenemos que SUNAT ya no tiene.</summary>
    public static DiferenciaCatalogo Comparar(IReadOnlySet<string> deSunat) => new(
        deSunat.Where(c => !EnUso.Contains(c)).Order(StringComparer.Ordinal).ToList(),
        EnUso.Where(c => !deSunat.Contains(c)).Order(StringComparer.Ordinal).ToList());

    private const string CodigosGzipBase64 = """
        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
        """;

    private static IReadOnlySet<string> Descomprimir()
    {
        using var entrada = new MemoryStream(Convert.FromBase64String(CodigosGzipBase64));
        using var gzip = new GZipStream(entrada, CompressionMode.Decompress);
        using var lector = new StreamReader(gzip, Encoding.UTF8);

        var codigos = new HashSet<string>(StringComparer.Ordinal);
        long anterior = 0;
        string? linea;

        while ((linea = lector.ReadLine()) is not null)
        {
            if (linea.Length == 0) continue;
            anterior += long.Parse(linea, System.Globalization.CultureInfo.InvariantCulture);
            codigos.Add(anterior.ToString("D8", System.Globalization.CultureInfo.InvariantCulture));
        }

        return codigos;
    }
}

/// <summary>Lo que cambió entre la lista de SUNAT y la de la plataforma.</summary>
public sealed record DiferenciaCatalogo(IReadOnlyList<string> Agregados, IReadOnlyList<string> Quitados)
{
    public bool Igual => Agregados.Count == 0 && Quitados.Count == 0;
}
'@ },
    @{ Ruta = 'facturacion electronica\facturacion_electronica_service\Facturacion.Cpe\LectorCatalogoXlsx.cs'; Texto = @'
using System.IO.Compression;
using System.Xml;
using System.Xml.Linq;

namespace Facturacion.Cpe;

/// <summary>
/// Lee los códigos del Excel oficial del catálogo 25 de SUNAT (CCNU_MOD_2.xlsm).
///
/// SIN LIBRERÍAS: un .xlsm es un .zip con XML dentro. Se busca la hoja
/// «Bienes y Servicios», se ubica la fila de títulos por su texto («ID CLASE»
/// e «ID PRODUCTO») y se leen esas dos columnas. Así, si SUNAT agrega una
/// columna o mueve la tabla, se sigue leyendo bien.
///
/// SI EL ARCHIVO CAMBIA DE FORMA —otra hoja, otros títulos, casi ningún
/// código—, lanza <see cref="FormatException"/> con un mensaje que lo dice.
/// La vigilancia lo convierte en un aviso: mejor saber que ya no se puede
/// leer que creer que todo sigue igual.
/// </summary>
public static class LectorCatalogoXlsx
{
    private static readonly XNamespace Main = "http://schemas.openxmlformats.org/spreadsheetml/2006/main";
    private static readonly XNamespace Rel = "http://schemas.openxmlformats.org/officeDocument/2006/relationships";
    private static readonly XNamespace Pkg = "http://schemas.openxmlformats.org/package/2006/relationships";

    /// <summary>Por debajo de esto no es el catálogo: hoy tiene más de 52 000.</summary>
    public const int MinimoRazonable = 10_000;

    public static IReadOnlySet<string> Leer(byte[] archivo)
    {
        ZipArchive zip;
        try { zip = new ZipArchive(new MemoryStream(archivo), ZipArchiveMode.Read); }
        catch (InvalidDataException)
        {
            throw new FormatException(
                "Lo que se descargo no es un Excel (.xlsm). SUNAT pudo haber cambiado la pagina " +
                "o el archivo.");
        }

        using (zip)
        {
            var hoja = RutaDeLaHoja(zip);
            var compartidos = TextosCompartidos(zip);

            var entrada = zip.GetEntry(hoja)
                ?? throw new FormatException($"El Excel no tiene la hoja que dice tener ({hoja}).");

            using var flujo = entrada.Open();
            using var lector = XmlReader.Create(flujo, new XmlReaderSettings { IgnoreWhitespace = true });

            var codigos = new HashSet<string>(StringComparer.Ordinal);
            string? colClase = null, colProducto = null;

            lector.MoveToContent();
            while (!lector.EOF)
            {
                if (lector.NodeType != XmlNodeType.Element || lector.LocalName != "row")
                {
                    lector.Read();
                    continue;
                }

                var fila = (XElement)XNode.ReadFrom(lector);
                var celdas = Celdas(fila, compartidos);

                if (colProducto is null)
                {
                    foreach (var (col, valor) in celdas)
                    {
                        var t = valor.Trim().ToUpperInvariant();
                        if (t == "ID PRODUCTO") colProducto = col;
                        else if (t == "ID CLASE") colClase = col;
                    }
                    continue;
                }

                foreach (var col in new[] { colClase, colProducto })
                {
                    if (col is not null && celdas.TryGetValue(col, out var v))
                    {
                        var c = v.Trim();
                        if (c.Length == 8 && c.All(char.IsAsciiDigit)) codigos.Add(c);
                    }
                }
            }

            if (colProducto is null)
                throw new FormatException(
                    "La hoja de bienes y servicios ya no tiene la columna «ID PRODUCTO». SUNAT " +
                    "cambio la forma del Excel.");

            if (codigos.Count < MinimoRazonable)
                throw new FormatException(
                    $"El Excel solo trae {codigos.Count} codigos; el catalogo tiene mas de 50 000. " +
                    "SUNAT cambio la forma del archivo.");

            return codigos;
        }
    }

    /// <summary>La hoja cuyo nombre dice «Bienes» (hoy, «Bienes y Servicios»).</summary>
    private static string RutaDeLaHoja(ZipArchive zip)
    {
        var libro = Xml(zip, "xl/workbook.xml")
            ?? throw new FormatException("El Excel no tiene xl/workbook.xml.");
        var relaciones = Xml(zip, "xl/_rels/workbook.xml.rels")
            ?? throw new FormatException("El Excel no tiene la lista de sus hojas.");

        var hoja = libro.Descendants(Main + "sheet")
            .FirstOrDefault(h => ((string?)h.Attribute("name") ?? "")
                .Contains("bienes", StringComparison.OrdinalIgnoreCase))
            ?? throw new FormatException(
                "El Excel ya no tiene la hoja «Bienes y Servicios». SUNAT cambio la forma del archivo.");

        var id = (string?)hoja.Attribute(Rel + "id");
        var destino = relaciones.Descendants(Pkg + "Relationship")
            .FirstOrDefault(r => (string?)r.Attribute("Id") == id)?.Attribute("Target")?.Value
            ?? throw new FormatException("No se encuentra el archivo de la hoja «Bienes y Servicios».");

        return destino.StartsWith('/') ? destino.TrimStart('/') : "xl/" + destino;
    }

    private static List<string> TextosCompartidos(ZipArchive zip)
    {
        var textos = new List<string>();
        var entrada = zip.GetEntry("xl/sharedStrings.xml");
        if (entrada is null) return textos;

        using var flujo = entrada.Open();
        using var lector = XmlReader.Create(flujo, new XmlReaderSettings { IgnoreWhitespace = true });

        lector.MoveToContent();
        while (!lector.EOF)
        {
            if (lector.NodeType == XmlNodeType.Element && lector.LocalName == "si")
            {
                var si = (XElement)XNode.ReadFrom(lector);
                // Un texto puede venir en trozos con formato (<r><t>…</t></r>);
                // los fonéticos (<rPh>) no son parte del texto.
                textos.Add(string.Concat(si.Descendants(Main + "t")
                    .Where(t => t.Parent?.Name != Main + "rPh")
                    .Select(t => t.Value)));
            }
            else lector.Read();
        }

        return textos;
    }

    private static Dictionary<string, string> Celdas(XElement fila, List<string> compartidos)
    {
        var celdas = new Dictionary<string, string>(StringComparer.Ordinal);

        foreach (var c in fila.Elements(Main + "c"))
        {
            var referencia = (string?)c.Attribute("r");
            if (referencia is null) continue;

            var columna = new string(referencia.TakeWhile(char.IsAsciiLetter).ToArray());
            var tipo = (string?)c.Attribute("t");
            var v = c.Element(Main + "v")?.Value;

            var valor = tipo switch
            {
                "s" when int.TryParse(v, out var i) && i >= 0 && i < compartidos.Count => compartidos[i],
                "inlineStr" => string.Concat(c.Descendants(Main + "t").Select(t => t.Value)),
                _ => v
            };

            if (valor is not null) celdas[columna] = valor;
        }

        return celdas;
    }

    private static XDocument? Xml(ZipArchive zip, string ruta)
    {
        var e = zip.GetEntry(ruta);
        if (e is null) return null;
        using var flujo = e.Open();
        return XDocument.Load(flujo);
    }
}
'@ },
    @{ Ruta = 'facturacion electronica\facturacion_electronica_service\Facturacion.Cpe.Tests\CatalogoProductosSunatTests.cs'; Texto = @'
using Facturacion.Cpe;

namespace Facturacion.Tests;

/// <summary>
/// La lista de códigos de producto que usa la plataforma, y la comparación con
/// la de SUNAT (Vigilancia SUNAT, migración 031) — 14 de octubre de 2026.
/// </summary>
public class CatalogoProductosSunatTests
{
    [Fact]
    public void La_lista_en_uso_esta_completa_y_coincide_con_su_huella()
    {
        Assert.Equal(CatalogoProductosSunat.CantidadEnUso, CatalogoProductosSunat.EnUso.Count);
        Assert.Equal(CatalogoProductosSunat.HuellaEnUso,
            CatalogoProductosSunat.Huella(CatalogoProductosSunat.EnUso));
        Assert.Contains("50161509", CatalogoProductosSunat.EnUso);   // azúcares naturales
        Assert.Contains("50161500", CatalogoProductosSunat.EnUso);   // su clase
    }

    [Fact]
    public void Misma_lista_es_igual()
    {
        var d = CatalogoProductosSunat.Comparar(new HashSet<string>(CatalogoProductosSunat.EnUso));
        Assert.True(d.Igual);
    }

    [Fact]
    public void Dice_que_se_agrego_y_que_se_quito()
    {
        var deSunat = new HashSet<string>(CatalogoProductosSunat.EnUso);
        deSunat.Remove("50161509");
        deSunat.Add("50161599");

        var d = CatalogoProductosSunat.Comparar(deSunat);

        Assert.False(d.Igual);
        Assert.Equal(["50161599"], d.Agregados);
        Assert.Equal(["50161509"], d.Quitados);
    }

    [Fact]
    public void La_huella_no_depende_del_orden()
    {
        Assert.Equal(
            CatalogoProductosSunat.Huella(["10101501", "50161509"]),
            CatalogoProductosSunat.Huella(["50161509", "10101501", "50161509"]));
    }

    [Fact]
    public void Un_archivo_que_no_es_Excel_se_dice_claro()
    {
        var ex = Assert.Throws<FormatException>(() => LectorCatalogoXlsx.Leer([1, 2, 3]));
        Assert.Contains("no es un Excel", ex.Message);
    }
}
'@ },
    @{ Ruta = 'facturacion electronica\facturacion_electronica_service\Facturacion.Persistencia\RepositorioCatalogoSunat.cs'; Texto = @'
using Dapper;
using Npgsql;

namespace Facturacion.Persistencia;

/// <summary>El estado de la vigilancia del catálogo (una sola fila).</summary>
public record EstadoCatalogo(
    DateTime CreadoEn, DateTime? UltimoIntentoEn, DateTime? UltimoExitoEn,
    string? UltimoError, bool FallaAvisada);

/// <summary>Una lista de códigos que SUNAT publicó, comparada con la nuestra.</summary>
public record VersionCatalogo(
    string Huella, int Codigos, int Agregados, int Quitados,
    string? AgregadosMuestra, string? QuitadosMuestra,
    string Sha256Archivo, long Tamano, string? Publicado,
    DateTime VistoPrimera, DateTime VistoUltima);

/// <summary>
/// La vigilancia del catálogo de códigos de producto de SUNAT (migración 031).
/// Usa la conexión del operador, como el resto de Vigilancia SUNAT.
/// </summary>
public sealed class RepositorioCatalogoSunat
{
    private readonly string _cadenaOperador;

    public RepositorioCatalogoSunat(string cadenaConexionOperador)
    {
        _cadenaOperador = cadenaConexionOperador
            ?? throw new ArgumentNullException(nameof(cadenaConexionOperador));
    }

    private async Task<NpgsqlConnection> AbrirAsync(CancellationToken ct)
    {
        var conexion = new NpgsqlConnection(_cadenaOperador);
        await conexion.OpenAsync(ct);
        return conexion;
    }

    private const string ColumnasEstado = """
        creado_en AS "CreadoEn", ultimo_intento_en AS "UltimoIntentoEn",
        ultimo_exito_en AS "UltimoExitoEn", ultimo_error AS "UltimoError",
        falla_avisada AS "FallaAvisada"
        """;

    /// <summary>El estado, o null si nunca se intentó.</summary>
    public async Task<EstadoCatalogo?> EstadoAsync(CancellationToken ct)
    {
        await using var c = await AbrirAsync(ct);
        return await c.QuerySingleOrDefaultAsync<EstadoCatalogo>(new CommandDefinition(
            $"SELECT {ColumnasEstado} FROM vigilancia_catalogo WHERE id = 1",
            cancellationToken: ct));
    }

    /// <summary>Las versiones vistas, la más reciente primero.</summary>
    public async Task<IReadOnlyList<VersionCatalogo>> VersionesAsync(int cuantas, CancellationToken ct)
    {
        await using var c = await AbrirAsync(ct);
        var filas = await c.QueryAsync<VersionCatalogo>(new CommandDefinition(
            """
            SELECT huella AS "Huella", codigos AS "Codigos", agregados AS "Agregados",
                   quitados AS "Quitados", agregados_muestra AS "AgregadosMuestra",
                   quitados_muestra AS "QuitadosMuestra", sha256_archivo AS "Sha256Archivo",
                   tamano AS "Tamano", publicado AS "Publicado",
                   visto_primera AS "VistoPrimera", visto_ultima AS "VistoUltima"
            FROM vigilancia_catalogo_versiones
            ORDER BY visto_ultima DESC
            LIMIT @cuantas
            """,
            new { cuantas }, cancellationToken: ct));
        return filas.ToList();
    }

    /// <summary>
    /// Anota una revisión que salió bien. Devuelve true si esa lista de
    /// códigos es NUEVA (nunca vista): es la que puede merecer un aviso.
    /// </summary>
    public async Task<bool> RegistrarExitoAsync(
        string huella, int codigos, int agregados, int quitados,
        string? agregadosMuestra, string? quitadosMuestra,
        string sha256Archivo, long tamano, string? publicado, CancellationToken ct)
    {
        await using var c = await AbrirAsync(ct);
        await using var tx = await c.BeginTransactionAsync(ct);

        // (xmax = 0) es cierto solo si la fila se acaba de insertar.
        var nueva = await c.ExecuteScalarAsync<bool>(new CommandDefinition(
            """
            INSERT INTO vigilancia_catalogo_versiones
                (huella, codigos, agregados, quitados, agregados_muestra, quitados_muestra,
                 sha256_archivo, tamano, publicado)
            VALUES (@huella, @codigos, @agregados, @quitados, @agregadosMuestra, @quitadosMuestra,
                    @sha256Archivo, @tamano, @publicado)
            ON CONFLICT (huella) DO UPDATE
               SET visto_ultima = now(),
                   sha256_archivo = EXCLUDED.sha256_archivo,
                   tamano = EXCLUDED.tamano,
                   publicado = EXCLUDED.publicado
            RETURNING (xmax = 0)
            """,
            new { huella, codigos, agregados, quitados, agregadosMuestra, quitadosMuestra,
                  sha256Archivo, tamano, publicado },
            tx, cancellationToken: ct));

        await c.ExecuteAsync(new CommandDefinition(
            """
            INSERT INTO vigilancia_catalogo (id, ultimo_intento_en, ultimo_exito_en, ultimo_error, falla_avisada)
            VALUES (1, now(), now(), NULL, false)
            ON CONFLICT (id) DO UPDATE
               SET ultimo_intento_en = now(), ultimo_exito_en = now(),
                   ultimo_error = NULL, falla_avisada = false
            """,
            transaction: tx, cancellationToken: ct));

        await tx.CommitAsync(ct);
        return nueva;
    }

    /// <summary>Anota una revisión que falló y devuelve el estado que queda.</summary>
    public async Task<EstadoCatalogo> RegistrarFallaAsync(string error, CancellationToken ct)
    {
        await using var c = await AbrirAsync(ct);
        return await c.QuerySingleAsync<EstadoCatalogo>(new CommandDefinition(
            $"""
            INSERT INTO vigilancia_catalogo (id, ultimo_intento_en, ultimo_error)
            VALUES (1, now(), @error)
            ON CONFLICT (id) DO UPDATE
               SET ultimo_intento_en = now(), ultimo_error = EXCLUDED.ultimo_error
            RETURNING {ColumnasEstado}
            """,
            new { error = error.Length > 1000 ? error[..1000] : error },
            cancellationToken: ct));
    }

    /// <summary>Crea la alerta (la manda por correo la vuelta de 5 minutos) y, si es de falla, la marca avisada.</summary>
    public async Task CrearAlertaAsync(
        string tipo, string gravedad, string titulo, string detalle, bool esFalla, CancellationToken ct)
    {
        await using var c = await AbrirAsync(ct);
        await using var tx = await c.BeginTransactionAsync(ct);

        await c.ExecuteAsync(new CommandDefinition(
            """
            INSERT INTO vigilancia_alertas (tipo, gravedad, titulo, detalle)
            VALUES (@tipo, @gravedad, @titulo, @detalle)
            """,
            new { tipo, gravedad, titulo, detalle = detalle.Length > 3000 ? detalle[..3000] : detalle },
            tx, cancellationToken: ct));

        if (esFalla)
            await c.ExecuteAsync(new CommandDefinition(
                "UPDATE vigilancia_catalogo SET falla_avisada = true WHERE id = 1",
                transaction: tx, cancellationToken: ct));

        await tx.CommitAsync(ct);
    }
}
'@ },
    @{ Ruta = 'facturacion electronica\facturacion_electronica_service\Facturacion.Api\VigilanciaCatalogo.cs'; Texto = @'
using System.Security.Cryptography;
using Facturacion.Cpe;
using Facturacion.Persistencia;
using Npgsql;

namespace Facturacion.Api;

/// <summary>Cómo fue una revisión del catálogo.</summary>
public sealed record ResultadoCatalogo(bool Exito, bool Igual, int Agregados, int Quitados, string Mensaje);

/// <summary>
/// VIGILANCIA SUNAT, PARTE 3: EL CATÁLOGO DE CÓDIGOS DE PRODUCTO (migración 031).
///
/// ══════════════════════════════════════════════════════════════════════════
/// EL HUECO QUE CIERRA. La plataforma lleva una copia del catálogo 25 de
/// SUNAT para su buscador. Si SUNAT quita un código y la copia sigue
/// teniéndolo, alguien puede guardar un producto con él, y desde 2027 sus
/// comprobantes se rechazan (ERR-3496).
///
/// QUÉ HACE. Una vez al día descarga el Excel oficial
/// (<see cref="CatalogoProductosSunat.UrlArchivo"/>), lee sus códigos y los
/// compara con los que usa la plataforma. Si no coinciden, crea UNA alerta
/// por cada lista distinta, con los códigos agregados y quitados; la vuelta
/// de 5 minutos de Vigilancia SUNAT la manda por correo, como las demás.
///
/// Y SI NO PUEDE REVISAR —SUNAT movió el archivo, cambió su forma, o no hay
/// internet desde hace una semana— también avisa, una sola vez hasta que
/// vuelva a salir bien. Callarse sería lo peor: parecería que todo está al
/// día.
///
/// QUÉ NO HACE: no cambia el catálogo de la plataforma solo. Eso se regenera
/// a mano desde el Excel, revisando qué cambió.
/// ══════════════════════════════════════════════════════════════════════════
/// </summary>
public sealed class VigilanciaCatalogo
{
    /// <summary>Sin internet más de esto, se avisa.</summary>
    public static readonly TimeSpan AvisarSinExitoTras = TimeSpan.FromDays(7);

    private readonly IHttpClientFactory _http;
    private readonly RepositorioCatalogoSunat _repo;
    private readonly ILogger<VigilanciaCatalogo> _log;
    private readonly SemaphoreSlim _uno = new(1, 1);

    public VigilanciaCatalogo(
        IHttpClientFactory http, RepositorioCatalogoSunat repo, ILogger<VigilanciaCatalogo> log)
    {
        _http = http;
        _repo = repo;
        _log = log;
    }

    public async Task<ResultadoCatalogo> RevisarAsync(CancellationToken ct)
    {
        if (!await _uno.WaitAsync(0, ct))
            return new ResultadoCatalogo(false, false, 0, 0, "Ya se está revisando. Espera unos segundos.");

        try
        {
            // --- 1. Descargar ------------------------------------------------
            byte[] archivo;
            string? publicado;

            try
            {
                var cliente = _http.CreateClient("catalogo-sunat");
                using var respuesta = await cliente.GetAsync(CatalogoProductosSunat.UrlArchivo, ct);

                if (!respuesta.IsSuccessStatusCode)
                    return await FallaAsync(
                        $"SUNAT respondió {(int)respuesta.StatusCode} al pedir el Excel. Puede que lo haya " +
                        "movido o cambiado de nombre.", porRed: false, ct);

                archivo = await respuesta.Content.ReadAsByteArrayAsync(ct);
                publicado = respuesta.Content.Headers.LastModified?.ToString("yyyy-MM-dd");
            }
            catch (Exception ex) when ((ex is HttpRequestException or TaskCanceledException) && !ct.IsCancellationRequested)
            {
                return await FallaAsync($"No se pudo descargar el Excel de SUNAT: {ex.Message}", porRed: true, ct);
            }

            // --- 2. Leer -----------------------------------------------------
            IReadOnlySet<string> deSunat;
            try { deSunat = LectorCatalogoXlsx.Leer(archivo); }
            catch (FormatException ex)
            {
                return await FallaAsync(ex.Message, porRed: false, ct);
            }

            // --- 3. Comparar y anotar ----------------------------------------
            var dif = CatalogoProductosSunat.Comparar(deSunat);
            var huella = CatalogoProductosSunat.Huella(deSunat);

            var nueva = await _repo.RegistrarExitoAsync(
                huella, deSunat.Count, dif.Agregados.Count, dif.Quitados.Count,
                Muestra(dif.Agregados), Muestra(dif.Quitados),
                Convert.ToHexString(SHA256.HashData(archivo)).ToLowerInvariant(),
                archivo.LongLength, publicado, ct);

            if (dif.Igual)
                return new ResultadoCatalogo(true, true, 0, 0,
                    $"Al día: SUNAT publica los mismos {deSunat.Count:N0} códigos que usa la plataforma.");

            if (nueva)
            {
                _log.LogWarning(
                    "Catálogo de productos SUNAT: la lista de SUNAT cambió ({Agregados} agregados, {Quitados} quitados).",
                    dif.Agregados.Count, dif.Quitados.Count);

                await _repo.CrearAlertaAsync(
                    "catalogo_cambio",
                    "problema",
                    "SUNAT cambió el catálogo de códigos de producto",
                    DetalleCambio(deSunat.Count, dif, publicado),
                    esFalla: false, ct);
            }

            return new ResultadoCatalogo(true, false, dif.Agregados.Count, dif.Quitados.Count,
                $"SUNAT cambió la lista: {dif.Agregados.Count} código(s) agregado(s) y " +
                $"{dif.Quitados.Count} quitado(s). Hay que regenerar el catálogo de la plataforma." +
                (nueva ? " Se avisó por correo." : ""));
        }
        finally
        {
            _uno.Release();
        }
    }

    private async Task<ResultadoCatalogo> FallaAsync(string error, bool porRed, CancellationToken ct)
    {
        _log.LogWarning("Catálogo de productos SUNAT: {Error}", error);

        var estado = await _repo.RegistrarFallaAsync(error, ct);

        // Sin internet un rato no es noticia; una semana, sí. Lo demás (SUNAT
        // movió o cambió el archivo) se avisa a la primera.
        var desde = estado.UltimoExitoEn ?? estado.CreadoEn;
        var avisar = !estado.FallaAvisada &&
                     (!porRed || DateTime.UtcNow - desde.ToUniversalTime() > AvisarSinExitoTras);

        if (avisar)
            await _repo.CrearAlertaAsync(
                "catalogo_falla",
                "atencion",
                "No se puede revisar el catálogo de códigos de producto de SUNAT",
                $"{error}\n" +
                $"Último éxito: {(estado.UltimoExitoEn is { } u ? u.ToString("yyyy-MM-dd HH:mm") : "nunca")}.\n" +
                $"Página de SUNAT: {CatalogoProductosSunat.UrlPagina}\n" +
                "Qué hacer: abrir la página y ver si el Excel sigue ahí. Si cambió de dirección o de " +
                "forma, hay que ajustar la vigilancia. Mientras tanto no se sabe si la lista cambió.",
                esFalla: true, ct);

        return new ResultadoCatalogo(false, false, 0, 0, error);
    }

    private static string DetalleCambio(int deSunat, DiferenciaCatalogo dif, string? publicado) =>
        $"SUNAT publica {deSunat:N0} códigos (archivo del {publicado ?? "—"}); la plataforma usa " +
        $"{CatalogoProductosSunat.CantidadEnUso:N0} ({CatalogoProductosSunat.VersionEnUso}).\n" +
        $"Agregados: {dif.Agregados.Count}{(dif.Agregados.Count > 0 ? " · " + Muestra(dif.Agregados) : "")}\n" +
        $"Quitados: {dif.Quitados.Count}{(dif.Quitados.Count > 0 ? " · " + Muestra(dif.Quitados) : "")}\n" +
        (dif.Quitados.Count > 0
            ? "Un producto con un código quitado hace rechazar sus comprobantes desde 2027 (ERR-3496).\n"
            : "") +
        $"Qué hacer: descargar el Excel de {CatalogoProductosSunat.UrlPagina} y regenerar el catálogo " +
        "de la plataforma (CatalogoSunatDatos.cs) y la lista del servicio (CatalogoProductosSunat.cs). " +
        "Después, revisar los productos que tengan un código quitado.";

    /// <summary>Los primeros 30, separados por coma. Null si no hay.</summary>
    private static string? Muestra(IReadOnlyList<string> codigos) =>
        codigos.Count == 0 ? null
        : string.Join(", ", codigos.Take(30)) + (codigos.Count > 30 ? $" y {codigos.Count - 30} más" : "");
}


/// <summary>
/// El reloj de la vigilancia del catálogo: una revisión al día. Mira en la
/// base cuándo fue la última, así que reiniciar la API no la repite.
/// </summary>
public sealed class ServicioVigilanciaCatalogo : BackgroundService
{
    private static readonly TimeSpan TrasExito = TimeSpan.FromHours(24);
    private static readonly TimeSpan TrasFalla = TimeSpan.FromHours(6);

    private readonly VigilanciaCatalogo _vigilancia;
    private readonly RepositorioCatalogoSunat _repo;
    private readonly ILogger<ServicioVigilanciaCatalogo> _log;

    public ServicioVigilanciaCatalogo(
        VigilanciaCatalogo vigilancia, RepositorioCatalogoSunat repo, ILogger<ServicioVigilanciaCatalogo> log)
    {
        _vigilancia = vigilancia;
        _repo = repo;
        _log = log;
    }

    protected override async Task ExecuteAsync(CancellationToken ct)
    {
        // Que la API termine de arrancar antes de salir a internet.
        try { await Task.Delay(TimeSpan.FromMinutes(3), ct); }
        catch (OperationCanceledException) { return; }

        var avisoMigracion = false;

        while (!ct.IsCancellationRequested)
        {
            try
            {
                var e = await _repo.EstadoAsync(ct);
                var toca = e?.UltimoIntentoEn is not { } ultimo ||
                           DateTime.UtcNow - ultimo.ToUniversalTime() >
                               (e.UltimoError is null ? TrasExito : TrasFalla);

                if (toca)
                {
                    var r = await _vigilancia.RevisarAsync(ct);
                    _log.LogInformation("Catálogo de productos SUNAT: {Mensaje}", r.Mensaje);
                }
            }
            catch (PostgresException ex) when (ex.SqlState == "42P01")
            {
                if (!avisoMigracion)
                    _log.LogWarning("Catálogo de productos SUNAT: falta aplicar la migración 031; no se vigila.");
                avisoMigracion = true;
            }
            catch (OperationCanceledException) when (ct.IsCancellationRequested) { return; }
            catch (Exception ex)
            {
                _log.LogError(ex, "Falló la vigilancia del catálogo de productos SUNAT. Se reintenta en una hora.");
            }

            try { await Task.Delay(TimeSpan.FromHours(1), ct); }
            catch (OperationCanceledException) { return; }
        }
    }
}
'@ },
    @{ Ruta = 'facturacion electronica\facturacion_electronica_service\Facturacion.Api\EndpointsCatalogoSunat.cs'; Texto = @'
using Facturacion.Cpe;
using Facturacion.Persistencia;

namespace Facturacion.Api;

/// <summary>
/// La sección «Catálogo de productos SUNAT» de Vigilancia SUNAT (migración 031).
/// Ver y «Revisar ahora»: quien ve el estado del servicio (diagnostico.ver).
/// </summary>
public static class EndpointsCatalogoSunat
{
    public static void MapearVigilanciaCatalogo(this WebApplication app)
    {
        var grupo = app.MapGroup("/admin/vigilancia/catalogo")
            .AddEndpointFilter<AutenticacionPanel>()
            .WithTags("Vigilancia SUNAT");

        grupo.MapGet("", async (RepositorioCatalogoSunat repo, CancellationToken ct) =>
        {
            EstadoCatalogo? estado;
            IReadOnlyList<VersionCatalogo> versiones;

            try
            {
                estado = await repo.EstadoAsync(ct);
                versiones = await repo.VersionesAsync(5, ct);
            }
            catch (Npgsql.PostgresException ex) when (ex.SqlState == "42P01")
            {
                return Results.Json(new RespuestaError(
                    "Falta aplicar la migración 031.",
                    "Sin ella no se vigila el catálogo de códigos de producto."),
                    statusCode: StatusCodes.Status503ServiceUnavailable);
            }

            var actual = versiones.FirstOrDefault();

            return Results.Ok(new
            {
                urlPagina = CatalogoProductosSunat.UrlPagina,
                enUso = new
                {
                    codigos = CatalogoProductosSunat.CantidadEnUso,
                    version = CatalogoProductosSunat.VersionEnUso
                },
                ultimoIntentoEn = estado?.UltimoIntentoEn,
                ultimoExitoEn = estado?.UltimoExitoEn,
                ultimoError = estado?.UltimoError,
                actual = actual is null ? null : new
                {
                    actual.Codigos, actual.Agregados, actual.Quitados,
                    actual.AgregadosMuestra, actual.QuitadosMuestra,
                    actual.Publicado, actual.VistoPrimera, actual.VistoUltima,
                    igual = actual.Huella == CatalogoProductosSunat.HuellaEnUso
                }
            });
        })
        .AddEndpointFilter(new ExigirPermiso(Permiso.DiagnosticoVer))
        .WithSummary("El catálogo de códigos de producto de SUNAT: si cambió respecto al de la plataforma");

        grupo.MapPost("/revisar", async (VigilanciaCatalogo vigilancia, CancellationToken ct) =>
        {
            try
            {
                var r = await vigilancia.RevisarAsync(ct);
                return Results.Ok(new { r.Exito, r.Igual, r.Agregados, r.Quitados, mensaje = r.Mensaje });
            }
            catch (Npgsql.PostgresException ex) when (ex.SqlState == "42P01")
            {
                return Results.Json(new RespuestaError(
                    "Falta aplicar la migración 031.", "Sin ella no se vigila el catálogo."),
                    statusCode: StatusCodes.Status503ServiceUnavailable);
            }
        })
        .AddEndpointFilter(new ExigirPermiso(Permiso.DiagnosticoVer))
        .WithSummary("Descarga ahora el catálogo de SUNAT y lo compara, sin esperar al día siguiente");
    }
}
'@ }
)

$reemplazos = @(
    @{ Ruta = 'facturacion electronica\facturacion_electronica_service\Facturacion.Api\Program.cs'
       Antes = @'
builder.Services.AddHostedService<ServicioVigilancia>();
'@
       Despues = @'
builder.Services.AddHostedService<ServicioVigilancia>();

// VIGILANCIA DEL CATÁLOGO DE PRODUCTOS (migración 031): una vez al día
// descarga el Excel oficial del catálogo 25 de SUNAT y lo compara con el que
// usa la plataforma. Si SUNAT agrega o quita códigos, crea una alerta que la
// vuelta de 5 minutos manda por correo.
builder.Services.AddSingleton(new RepositorioCatalogoSunat(cadenaOperador));
builder.Services.AddSingleton<VigilanciaCatalogo>();
builder.Services.AddHostedService<ServicioVigilanciaCatalogo>();
builder.Services.AddHttpClient("catalogo-sunat", cliente =>
{
    cliente.Timeout = TimeSpan.FromMinutes(2);
    cliente.DefaultRequestHeaders.UserAgent.ParseAdd("ReybanFacturacion/1.0 (vigilancia del catalogo 25)");
});
'@ },
    @{ Ruta = 'facturacion electronica\facturacion_electronica_service\Facturacion.Api\Program.cs'
       Antes = @'
app.MapearPruebaMadrugada();
'@
       Despues = @'
app.MapearPruebaMadrugada();
app.MapearVigilanciaCatalogo();
'@ },
    @{ Ruta = 'facturacion electronica\facturacion_electronica_service\Facturacion.Api\VigilanciaSunat.cs'
       Antes = @'
                $"<b>{E(a.Titulo)}</b><br>" +
                E(a.Detalle).Replace("\n", "<br>") +
                "</div>");
'@
       Despues = @'
                $"<b>{E(a.Titulo)}</b><br>" +
                E(a.Detalle).Replace("\n", "<br>") +
                PistaCodigoProducto(a.Titulo) +
                "</div>");
'@ },
    @{ Ruta = 'facturacion electronica\facturacion_electronica_service\Facturacion.Api\VigilanciaSunat.cs'
       Antes = @'
    private static string Marco(string cuerpo) =>
'@
       Despues = @'
    // LOS CÓDIGOS DE SUNAT QUE SON DEL CÓDIGO DE PRODUCTO (catálogo 25). Si
    // aparece uno nuevo, lo primero es mirar si el catálogo de la plataforma
    // quedó viejo (migración 031, «Catálogo de productos SUNAT»).
    private static readonly System.Text.RegularExpressions.Regex CodigosDeProducto =
        new(@"\b(3496|3506|3181|4331|4332|4337)\b");

    private static string PistaCodigoProducto(string titulo) =>
        CodigosDeProducto.IsMatch(titulo)
            ? "<br><i>Es del código de producto SUNAT (catálogo 25). Mira en Vigilancia SUNAT la " +
              "sección «Catálogo de productos SUNAT»: si SUNAT cambió su lista, hay que regenerar " +
              "la de la plataforma.</i>"
            : "";

    private static string Marco(string cuerpo) =>
'@ },
    @{ Ruta = 'facturacion electronica\facturacion_electronica_service\Facturacion.Api\wwwroot\vigilancia.html'
       Antes = @'
let madrugada = null;      // la prueba de madrugada (migración 030)
'@
       Despues = @'
let madrugada = null;      // la prueba de madrugada (migración 030)
let catalogo = null;       // el catálogo de productos de SUNAT (migración 031)
'@ },
    @{ Ruta = 'facturacion electronica\facturacion_electronica_service\Facturacion.Api\wwwroot\vigilancia.html'
       Antes = @'
    madrugada = await pedir("/admin/vigilancia/madrugada")
      .catch(e => ({ error: e.message, detalle: e.detalle }));
'@
       Despues = @'
    madrugada = await pedir("/admin/vigilancia/madrugada")
      .catch(e => ({ error: e.message, detalle: e.detalle }));
    catalogo = await pedir("/admin/vigilancia/catalogo")
      .catch(e => ({ error: e.message, detalle: e.detalle }));
'@ },
    @{ Ruta = 'facturacion electronica\facturacion_electronica_service\Facturacion.Api\wwwroot\vigilancia.html'
       Antes = @'
  const partes = [seccionMadrugada()];
'@
       Despues = @'
  const partes = [seccionMadrugada(), seccionCatalogo()];
'@ },
    @{ Ruta = 'facturacion electronica\facturacion_electronica_service\Facturacion.Api\wwwroot\vigilancia.html'
       Antes = @'
  enlazarMadrugada();
'@
       Despues = @'
  enlazarMadrugada();
  enlazarCatalogo();
'@ },
    @{ Ruta = 'facturacion electronica\facturacion_electronica_service\Facturacion.Api\wwwroot\vigilancia.html'
       Antes = @'
<div class="sub">${t.texto}</div></td>
'@
       Despues = @'
<div class="sub">${t.texto}${esDeProducto(c.codigo) ? " · código de producto SUNAT" : ""}</div></td>
'@ },
    @{ Ruta = 'facturacion electronica\facturacion_electronica_service\Facturacion.Api\wwwroot\vigilancia.html'
       Antes = @'
// ------------------------------------------------------ prueba de madrugada
'@
       Despues = @'
// ------------------------------------------- catálogo de productos (031)
// Una vez al día el servicio descarga la lista oficial de códigos de
// producto de SUNAT (catálogo 25) y la compara con la que usa la plataforma.

// Los códigos de SUNAT que hablan del código de producto.
const esDeProducto = codigo => /\b(3496|3506|3181|4331|4332|4337)$/.test(String(codigo));

function seccionCatalogo() {
  const k = catalogo;
  const cabecera = `
      <div class="cabecera-seccion">
        <h2>Catálogo de productos SUNAT</h2>
        <button class="mini" id="revisar-catalogo">Revisar ahora</button>
      </div>
      <p class="bajada">Una vez al día se descarga de SUNAT la lista oficial de códigos de producto
        y se compara con la que usa la plataforma en su buscador. Si SUNAT agrega o quita códigos,
        llega un correo: hay que regenerar la lista de la plataforma, porque un código quitado
        hace rechazar el comprobante desde 2027.</p>`;

  if (!k || k.error)
    return `<section>${cabecera}<p class="mal">${esc(k?.error || "Sin datos.")} ${esc(k?.detalle || "")}</p></section>`;

  const a = k.actual;
  let pildora, resumen;

  if (!k.ultimoIntentoEn) {
    pildora = `<span class="pildora">Todavía no se revisó</span>`;
    resumen = "La primera revisión se hace sola a los pocos minutos de arrancar la API, o con «Revisar ahora».";
  } else if (k.ultimoError) {
    pildora = `<span class="pildora atencion">No se pudo revisar</span>`;
    resumen = k.ultimoError;
  } else if (a && a.igual) {
    pildora = `<span class="pildora sano">Al día</span>`;
    resumen = "SUNAT publica exactamente los mismos códigos que usa la plataforma.";
  } else {
    pildora = `<span class="pildora problema">SUNAT cambió la lista</span>`;
    resumen = "Hay que regenerar la lista de la plataforma con el Excel nuevo de SUNAT.";
  }

  const n = v => Number(v ?? 0).toLocaleString("es-PE");

  const filas = [
    ["La plataforma usa", `${n(k.enUso.codigos)} códigos · ${esc(k.enUso.version)}`],
    ["SUNAT publica", a
      ? `${n(a.codigos)} códigos${a.publicado ? ` · archivo del ${esc(a.publicado)}` : ""}`
      : "—"],
    ...(a && !a.igual ? [
      ["Agregados", `${n(a.agregados)}${a.agregadosMuestra ? `<div class="sub">${esc(a.agregadosMuestra)}</div>` : ""}`],
      ["Quitados", `<span class="${a.quitados > 0 ? "mal" : ""}">${n(a.quitados)}</span>${a.quitadosMuestra ? `<div class="sub">${esc(a.quitadosMuestra)}</div>` : ""}`]
    ] : []),
    ["Última revisión", `${fecha(k.ultimoIntentoEn)}${k.ultimoExitoEn && k.ultimoError ? ` · último éxito: ${fecha(k.ultimoExitoEn)}` : ""}`],
    ["Fuente", `<a href="${esc(k.urlPagina)}" target="_blank" rel="noopener">Página de SUNAT «Código de producto»</a>`]
  ];

  return `
    <section>${cabecera}
      <div class="ficha">
        <p style="margin:0 0 10px">${pildora} <span class="sub">${esc(resumen)}</span></p>
        <dl>${filas.map(([t, d]) => `<dt>${t}</dt><dd>${d}</dd>`).join("")}</dl>
      </div>
    </section>`;
}

function enlazarCatalogo() {
  const boton = elem("revisar-catalogo");
  if (!boton) return;
  boton.onclick = async () => {
    boton.disabled = true;
    boton.textContent = "Revisando…";
    try {
      const r = await pedir("/admin/vigilancia/catalogo/revisar", { method: "POST" });
      avisar(r.mensaje, "", r.exito && r.igual ? "ok" : "mal");
      await cargar();
    } catch (e) {
      avisar(e.message, e.detalle, "mal");
    } finally {
      boton.disabled = false;
      boton.textContent = "Revisar ahora";
    }
  };
}

// ------------------------------------------------------ prueba de madrugada
'@ }
)

$lineas = @()

# --- 1. Comprobar todo, sin escribir nada ----------------------------------
$problemas = New-Object System.Collections.Generic.List[string]
$archivos = @{}   # ruta -> @{ Texto (con \n); Crlf; Original }

function Cargar([string]$ruta) {
    if ($archivos.ContainsKey($ruta)) { return $archivos[$ruta] }
    $completa = Join-Path $raiz $ruta
    if (-not (Test-Path $completa)) { return $null }
    $original = [System.IO.File]::ReadAllText($completa)
    $a = @{ Completa = $completa; Original = $original; Crlf = $original.Contains("`r`n"); Texto = $original.Replace("`r`n", "`n") }
    $archivos[$ruta] = $a
    return $a
}

foreach ($n in $nuevos) {
    $completa = Join-Path $raiz $n.Ruta
    if (Test-Path $completa) {
        $actual = [System.IO.File]::ReadAllText($completa).Replace("`r", '').TrimEnd()
        if ($actual -ne $n.Texto.Replace("`r", '').TrimEnd()) {
            $problemas.Add("$($n.Ruta) ya existe y es distinto. ¿Ya se aplicó otra versión?")
        }
    }
}

foreach ($r in $reemplazos) {
    $a = Cargar $r.Ruta
    if ($null -eq $a) { $problemas.Add("No existe $($r.Ruta)."); continue }
    $antes = $r.Antes.Replace("`r", '')
    $despues = $r.Despues.Replace("`r", '')
    if ($a.Texto.Contains($despues)) { continue }   # ya estaba aplicado
    $n = ([regex]::Matches($a.Texto, [regex]::Escape($antes))).Count
    if ($n -ne 1) {
        $problemas.Add("En $($r.Ruta) esperaba UNA vez:`n      $(($antes -split "`n")[0].Trim())`n    y aparece $n veces.")
        continue
    }
    $a.Texto = $a.Texto.Replace($antes, $despues)
}

foreach ($l in $lineas) {
    $a = Cargar $l.Ruta
    if ($null -eq $a) { $problemas.Add("No existe $($l.Ruta)."); continue }
    $ancla = $l.Ancla.Replace("`r", '')
    $nueva = $l.Nueva.Replace("`r", '')
    if ($a.Texto.Contains($nueva)) { continue }   # ya estaba
    $patron = '(?m)^([ \t]*)' + [regex]::Escape($ancla) + '[ \t]*$'
    $m = [regex]::Matches($a.Texto, $patron)
    if ($m.Count -ne 1) {
        $problemas.Add("En $($l.Ruta) esperaba UNA vez la línea del menú:`n      $ancla`n    y aparece $($m.Count) veces.")
        continue
    }
    $sangria = $m[0].Groups[1].Value
    $fin = $m[0].Index + $m[0].Length
    $a.Texto = $a.Texto.Substring(0, $fin) + "`n" + $sangria + $nueva + $a.Texto.Substring($fin)
}

if ($problemas.Count -gt 0) {
    Write-Host ''
    Write-Host 'NO SE TOCÓ NINGÚN ARCHIVO. Esto no cuadra:' -ForegroundColor Red
    foreach ($p in $problemas) { Write-Host "  - $p" -ForegroundColor Red }
    Write-Host ''
    exit 2
}

# --- 2. Escribir ------------------------------------------------------------
Write-Host ''
foreach ($n in $nuevos) {
    $completa = Join-Path $raiz $n.Ruta
    if (Test-Path $completa) { Write-Host "  IGUAL        $($n.Ruta)" -ForegroundColor DarkGray; continue }
    New-Item -ItemType Directory -Path (Split-Path $completa) -Force | Out-Null
    [System.IO.File]::WriteAllText($completa, $n.Texto.Replace("`r", '').Replace("`n", "`r`n"), $utf8SinBom)
    Write-Host "  NUEVO        $($n.Ruta)" -ForegroundColor Green
}

foreach ($ruta in $archivos.Keys) {
    $a = $archivos[$ruta]
    $salida = if ($a.Crlf) { $a.Texto.Replace("`n", "`r`n") } else { $a.Texto }
    if ($salida -eq $a.Original) { Write-Host "  IGUAL        $ruta" -ForegroundColor DarkGray; continue }
    $bak = "$($a.Completa).bak"
    if (Test-Path $bak) { $bak = "$($a.Completa).$(Get-Date -Format 'yyyyMMdd-HHmmss').bak" }
    Copy-Item $a.Completa $bak -Force
    [System.IO.File]::WriteAllText($a.Completa, $salida, $utf8SinBom)
    Write-Host "  CAMBIADO     $ruta  (copia: $(Split-Path $bak -Leaf))" -ForegroundColor Green
}

Write-Host ''
Write-Host 'FALTA APLICAR LA MIGRACIÓN 031 (este script NO la aplica). Así:' -ForegroundColor Cyan
Write-Host ''
Write-Host '  cd "D:\Reyban Consulting\facturacion electronica\facturacion_electronica_service"' -ForegroundColor White
Write-Host '  Get-Content migraciones\031_vigilancia_catalogo_productos.sql -Raw | docker compose exec -T postgres psql -U facturacion_owner -d facturacion -v ON_ERROR_STOP=1' -ForegroundColor White
Write-Host ''
Write-Host 'Tiene que terminar en COMMIT. Después:' -ForegroundColor Cyan
Write-Host '  1. dotnet test (deben pasar 106), y reinicia la API del servicio.' -ForegroundColor White
Write-Host '  2. Panel > Vigilancia SUNAT > «Catálogo de productos SUNAT» > Revisar ahora.' -ForegroundColor White
Write-Host '     Debe decir «Al día». (Sola, la primera revisión sale a los 3 minutos.)' -ForegroundColor White
Write-Host ''
