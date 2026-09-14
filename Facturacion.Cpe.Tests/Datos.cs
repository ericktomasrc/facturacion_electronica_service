using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using Facturacion.Cpe;

namespace Facturacion.Tests;

/// <summary>
/// Datos y utilidades compartidas por las pruebas.
///
/// Todo aquí es determinista y local: ninguna prueba toca SUNAT ni la red.
/// El motor debe poder verificarse por completo sin salir de la máquina.
/// </summary>
internal static class Datos
{
    internal static Emisor Emisor() => new()
    {
        Ruc = "20601234567",
        RazonSocial = "MI EMPRESA SAC",
        NombreComercial = "MI EMPRESA",
        Ubigeo = "150101",
        Direccion = "AV. EJEMPLO 123",
        Distrito = "LIMA",
        Provincia = "LIMA",
        Departamento = "LIMA"
    };

    internal static Receptor Receptor() => new()
    {
        TipoDocumento = TipoDocIdentidad.Ruc,
        NumeroDocumento = "20512345678",
        RazonSocial = "CLIENTE DE PRUEBA SAC",
        Direccion = "JR. CLIENTE 456"
    };

    internal static LineaComprobante Linea(
        decimal cantidad = 2,
        decimal valorUnitario = 50.00m,
        string afectacion = AfectacionIgv.GravadoOperacionOnerosa,
        int numero = 1) => new()
        {
            Numero = numero,
            CodigoProducto = "P001",
            Descripcion = "PRODUCTO DE PRUEBA",
            UnidadMedida = "NIU",
            Cantidad = cantidad,
            ValorUnitario = valorUnitario,
            TipoAfectacionIgv = afectacion,
            PorcentajeIgv = 18m
        };

    internal static Factura Factura(params LineaComprobante[] lineas) => new()
    {
        Serie = "F001",
        Correlativo = 1,
        // Fecha fija: si dependiera de DateTime.Now, la prueba de regresión
        // del XML daría un resultado distinto cada día.
        FechaEmision = new DateTime(2026, 1, 15, 10, 30, 0),
        Emisor = Emisor(),
        Receptor = Receptor(),
        Lineas = lineas.Length > 0 ? [.. lineas] : [Linea()]
    };

    internal static NotaCredito NotaCredito() => new()
    {
        Serie = "FC01",
        Correlativo = 1,
        FechaEmision = new DateTime(2026, 1, 16, 9, 0, 0),
        Emisor = Emisor(),
        Receptor = Receptor(),
        CodigoMotivo = MotivoNotaCredito.AnulacionDeLaOperacion,
        Afectado = new DocumentoAfectado
        {
            Numero = "F001-00000001",
            TipoDocumento = TipoComprobante.Factura
        },
        Lineas = [Linea()]
    };

    /// <summary>
    /// Certificado autofirmado generado en memoria.
    ///
    /// Se crea al vuelo en vez de leer un .pfx del disco por dos razones:
    /// las pruebas no deben depender de archivos externos, y así nunca hay
    /// un certificado dentro del repositorio.
    /// </summary>
    internal static X509Certificate2 Certificado()
    {
        using var rsa = RSA.Create(2048);

        var peticion = new CertificateRequest(
            "CN=PRUEBAS FACTURACION",
            rsa,
            HashAlgorithmName.SHA256,
            RSASignaturePadding.Pkcs1);

        using var generado = peticion.CreateSelfSigned(
            DateTimeOffset.UtcNow.AddDays(-1),
            DateTimeOffset.UtcNow.AddYears(1));

        // Exportar y reimportar: sin este paso, en Windows la llave privada
        // no siempre queda accesible para firmar.
        var pfx = generado.Export(X509ContentType.Pfx, "temporal");

        return new X509Certificate2(pfx, "temporal", X509KeyStorageFlags.Exportable);
    }

    /// <summary>
    /// Busca la carpeta de esquemas subiendo desde el directorio de ejecución.
    ///
    /// Devuelve null si no la encuentra, y las pruebas que dependen del XSD
    /// se saltan solas. Eso permite que el proyecto compile y corra en una
    /// máquina donde nadie descargó los esquemas todavía.
    /// </summary>
    internal static string? RutaXsd(string nombreArchivo)
    {
        var directorio = new DirectoryInfo(AppContext.BaseDirectory);

        while (directorio is not null)
        {
            var candidato = Path.Combine(
                directorio.FullName, "Facturacion.Consola", "xsd", "maindoc", nombreArchivo);

            if (File.Exists(candidato)) return candidato;

            directorio = directorio.Parent;
        }

        return null;
    }
}
