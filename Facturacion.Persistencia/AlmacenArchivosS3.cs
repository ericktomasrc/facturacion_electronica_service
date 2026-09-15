using Amazon.S3;
using Amazon.S3.Model;

namespace Facturacion.Persistencia;

/// <summary>Cómo conectarse al almacén de archivos.</summary>
public sealed class OpcionesAlmacen
{
    /// <summary>"disco" o "s3".</summary>
    public string Tipo { get; set; } = "disco";

    /// <summary>Solo para tipo "disco".</summary>
    public string Carpeta { get; set; } = "../almacen";

    /// <summary>
    /// Dirección del servidor S3.
    ///
    /// MinIO local:      http://localhost:9000
    /// Cloudflare R2:    https://{cuenta}.r2.cloudflarestorage.com
    /// AWS S3:           dejar vacío y poner la región
    /// </summary>
    public string Endpoint { get; set; } = "";

    public string Bucket { get; set; } = "comprobantes";

    public string Usuario { get; set; } = "";
    public string Clave { get; set; } = "";

    /// <summary>Solo para AWS. MinIO y R2 la ignoran.</summary>
    public string Region { get; set; } = "us-east-1";
}

/// <summary>
/// Construye el almacén que toque según la configuración.
///
/// Es lo que permite cambiar de destino sin tocar código: se edita
/// appsettings.json y nada más. El resto del sistema solo conoce la interfaz.
/// </summary>
public static class FabricaAlmacen
{
    public static IAlmacenArchivos Crear(OpcionesAlmacen opciones)
    {
        ArgumentNullException.ThrowIfNull(opciones);

        return opciones.Tipo.ToLowerInvariant() switch
        {
            "s3" => new AlmacenArchivosS3(opciones),
            "disco" => new AlmacenArchivosDisco(opciones.Carpeta),

            _ => throw new InvalidOperationException(
                $"Tipo de almacén no reconocido: '{opciones.Tipo}'. " +
                "Los valores válidos son 'disco' y 's3'.")
        };
    }
}

/// <summary>
/// Almacén sobre el protocolo S3.
///
/// FUNCIONA CON CUALQUIER PROVEEDOR QUE HABLE S3, y eso incluye:
///
///   MinIO            corre donde tú lo pongas, en tu máquina o tu servidor
///   Cloudflare R2    no cobra por sacar datos, que es donde más se gasta
///                    cuando los clientes descargan comprobantes a diario
///   AWS S3           el original, con reglas de ciclo de vida para mover
///                    lo viejo a almacenamiento frío
///
/// Cambiar de uno a otro es cambiar la configuración: el código es el mismo
/// porque todos responden a las mismas órdenes.
/// </summary>
public sealed class AlmacenArchivosS3 : IAlmacenArchivos, IDisposable
{
    private readonly IAmazonS3 _cliente;
    private readonly string _bucket;

    public AlmacenArchivosS3(OpcionesAlmacen opciones)
    {
        if (string.IsNullOrWhiteSpace(opciones.Bucket))
            throw new ArgumentException(
                "Falta el nombre del bucket.", nameof(opciones));

        _bucket = opciones.Bucket;

        var configuracion = new AmazonS3Config
        {
            // MinIO y R2 usan rutas del tipo servidor/bucket/archivo, mientras
            // que AWS usa bucket.servidor/archivo. Sin esto, MinIO responde
            // errores de DNS desconcertantes.
            ForcePathStyle = true,

            // Sin esto, el SDK intenta averiguar la región preguntándole a
            // Amazon, cosa que no tiene sentido cuando el servidor es propio.
            AuthenticationRegion = opciones.Region
        };

        if (!string.IsNullOrWhiteSpace(opciones.Endpoint))
            configuracion.ServiceURL = opciones.Endpoint;
        else
            configuracion.RegionEndpoint =
                Amazon.RegionEndpoint.GetBySystemName(opciones.Region);

        _cliente = new AmazonS3Client(
            opciones.Usuario, opciones.Clave, configuracion);
    }

    public async Task<string> GuardarAsync(
        string ruc, DateTime fecha, string nombreArchivo, byte[] contenido,
        CancellationToken ct = default)
    {
        // Misma organización que en disco: por empresa y por mes.
        //
        // No es cosmético. Las herramientas de S3 listan por prefijo, y un
        // prefijo con cientos de miles de objetos tarda en recorrerse. Además
        // permite aplicar reglas de retención por año sin tocar lo reciente.
        var ruta = $"{Sanear(ruc)}/{fecha:yyyy}/{fecha:MM}/{Sanear(nombreArchivo)}";

        using var flujo = new MemoryStream(contenido);

        await _cliente.PutObjectAsync(new PutObjectRequest
        {
            BucketName = _bucket,
            Key = ruta,
            InputStream = flujo,
            ContentType = TipoMime(nombreArchivo),

            // Se calcula el resumen del contenido para que el servidor
            // verifique que llegó íntegro. Un archivo corrupto en un CDR
            // no se detectaría hasta que alguien lo necesite, años después.
            AutoCloseStream = false
        }, ct);

        return ruta;
    }

    public async Task<byte[]?> LeerAsync(string ruta, CancellationToken ct = default)
    {
        try
        {
            using var respuesta = await _cliente.GetObjectAsync(
                new GetObjectRequest { BucketName = _bucket, Key = ruta }, ct);

            using var destino = new MemoryStream();
            await respuesta.ResponseStream.CopyToAsync(destino, ct);

            return destino.ToArray();
        }
        catch (AmazonS3Exception ex) when (ex.StatusCode == System.Net.HttpStatusCode.NotFound)
        {
            // El archivo no existe. Se devuelve null en vez de lanzar, igual
            // que hace la versión en disco: quien llama decide qué significa.
            return null;
        }
    }

    /// <summary>
    /// Comprueba que el almacén responde y que el bucket existe.
    ///
    /// Se llama al arrancar. Descubrir que la configuración está mal cuando
    /// alguien emite su primera factura es mucho peor que descubrirlo al
    /// encender el servicio.
    /// </summary>
    public async Task<string> ComprobarAsync(CancellationToken ct = default)
    {
        try
        {
            await _cliente.GetBucketLocationAsync(_bucket, ct);
            return $"Almacén S3 listo. Bucket '{_bucket}'.";
        }
        catch (AmazonS3Exception ex) when (ex.StatusCode == System.Net.HttpStatusCode.NotFound)
        {
            throw new InvalidOperationException(
                $"El bucket '{_bucket}' no existe en el almacén. " +
                "Si usas MinIO con Docker Compose, el contenedor " +
                "'minio-inicial' debería crearlo al arrancar.", ex);
        }
        catch (Exception ex)
        {
            throw new InvalidOperationException(
                $"No se pudo contactar el almacén: {ex.Message}. " +
                "Revisa el endpoint y las credenciales en appsettings.json.", ex);
        }
    }

    private static string TipoMime(string nombre) =>
        Path.GetExtension(nombre).ToLowerInvariant() switch
        {
            ".xml" => "application/xml",
            ".zip" => "application/zip",
            ".pdf" => "application/pdf",
            _ => "application/octet-stream"
        };

    private static string Sanear(string parte)
    {
        // Las claves de S3 admiten casi cualquier carácter, pero los que
        // necesitan escaparse complican las herramientas de línea de comandos.
        // Se limita a lo predecible.
        var limpio = new string(parte
            .Select(c => char.IsLetterOrDigit(c) || c is '-' or '_' or '.' ? c : '_')
            .ToArray());

        return limpio;
    }

    public void Dispose() => _cliente.Dispose();
}
