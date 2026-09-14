namespace Facturacion.Persistencia;

/// <summary>
/// Guarda los archivos de cada comprobante: XML firmado, CDR y PDF.
///
/// POR QUÉ ES UNA INTERFAZ: hoy escribe en disco, que es suficiente en una
/// máquina. Mañana será S3 o MinIO, y ese cambio no debe tocar nada más.
///
/// Y POR QUÉ NO VAN EN LA BASE DE DATOS: son megabytes por comprobante que
/// nunca se consultan con SQL. Guardarlos ahí hincha los backups hasta que
/// restaurar deja de ser viable, y ese problema aparece a los seis meses,
/// justo cuando más falta hace poder restaurar.
/// </summary>
public interface IAlmacenArchivos
{
    /// <summary>Guarda un archivo y devuelve la ruta con la que recuperarlo.</summary>
    Task<string> GuardarAsync(
        string ruc, DateTime fecha, string nombreArchivo, byte[] contenido,
        CancellationToken ct = default);

    Task<byte[]?> LeerAsync(string ruta, CancellationToken ct = default);
}

/// <summary>
/// Almacén en disco local. Para desarrollo y para despliegues de una sola
/// máquina.
///
/// Organiza por RUC y por mes:
///
///     almacen/20601234567/2026/09/20601234567-01-F001-00000052.xml
///
/// No es cosmético: con miles de archivos por empresa, un solo directorio
/// plano hace que listar la carpeta tarde segundos.
/// </summary>
public sealed class AlmacenArchivosDisco : IAlmacenArchivos
{
    private readonly string _raiz;

    public AlmacenArchivosDisco(string carpetaRaiz)
    {
        if (string.IsNullOrWhiteSpace(carpetaRaiz))
            throw new ArgumentException(
                "Falta la carpeta del almacén.", nameof(carpetaRaiz));

        _raiz = Path.GetFullPath(carpetaRaiz);
        Directory.CreateDirectory(_raiz);
    }

    public async Task<string> GuardarAsync(
        string ruc, DateTime fecha, string nombreArchivo, byte[] contenido,
        CancellationToken ct = default)
    {
        var relativa = Path.Combine(
            Sanear(ruc), fecha.ToString("yyyy"), fecha.ToString("MM"),
            Sanear(nombreArchivo));

        var completa = Path.Combine(_raiz, relativa);

        Directory.CreateDirectory(Path.GetDirectoryName(completa)!);

        await File.WriteAllBytesAsync(completa, contenido, ct);

        // Se devuelve la ruta RELATIVA, no la absoluta. Guardar rutas
        // absolutas en la base ata los datos a la máquina que los escribió,
        // y al mudar de servidor todas dejan de servir.
        return relativa.Replace('\\', '/');
    }

    public async Task<byte[]?> LeerAsync(string ruta, CancellationToken ct = default)
    {
        var completa = Path.Combine(_raiz, ruta.Replace('/', Path.DirectorySeparatorChar));

        // Comprobar que la ruta no escapa del almacén. Sin esto, una ruta
        // manipulada con ".." podría leer cualquier archivo del servidor.
        if (!Path.GetFullPath(completa).StartsWith(_raiz, StringComparison.Ordinal))
            throw new UnauthorizedAccessException("La ruta sale del almacén.");

        return File.Exists(completa)
            ? await File.ReadAllBytesAsync(completa, ct)
            : null;
    }

    private static string Sanear(string parte)
    {
        foreach (var caracter in Path.GetInvalidFileNameChars())
            parte = parte.Replace(caracter, '_');

        return parte;
    }
}
