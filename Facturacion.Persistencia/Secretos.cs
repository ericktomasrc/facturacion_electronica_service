using System.Security.Cryptography;

namespace Facturacion.Persistencia;

/// <summary>
/// Cifra y descifra secretos: certificados digitales y claves SOL.
///
/// POR QUÉ ES UNA INTERFAZ Y NO UNA CLASE SUELTA: hoy la llave maestra vive en
/// una variable de entorno, que es suficiente para desarrollo. El día que haga
/// falta un gestor de secretos, o cifrado con una llave que nunca sale de un
/// módulo de hardware, se cambia esta implementación y nada más del sistema
/// se entera.
/// </summary>
public interface IProtectorDeSecretos
{
    byte[] Proteger(ReadOnlySpan<byte> datos);
    byte[] Desproteger(ReadOnlySpan<byte> protegido);

    byte[] ProtegerTexto(string texto);
    string DesprotegerTexto(ReadOnlySpan<byte> protegido);
}

/// <summary>
/// Cifrado autenticado con AES-GCM.
///
/// POR QUÉ AES-GCM Y NO AES-CBC: GCM además de cifrar AUTENTICA. Si alguien
/// altera un solo byte del certificado guardado, el descifrado falla en vez
/// de devolver basura. Con CBC a secas, un certificado manipulado se
/// descifraría en silencio y el error aparecería mucho después, al firmar.
///
/// FORMATO DEL BLOB GUARDADO:
///
///     [ nonce: 12 bytes ][ tag: 16 bytes ][ texto cifrado: n bytes ]
///
/// El nonce va en claro a propósito: no es secreto, pero DEBE ser distinto
/// en cada cifrado. Reutilizar un nonce con la misma llave rompe la garantía
/// de AES-GCM por completo. Por eso se genera aleatorio cada vez.
/// </summary>
public sealed class ProtectorAesGcm : IProtectorDeSecretos
{
    private const int TamanoNonce = 12;
    private const int TamanoTag = 16;
    private const int TamanoLlave = 32;   // AES-256

    /// <summary>Nombre de la variable de entorno con la llave maestra.</summary>
    public const string VariableLlaveMaestra = "FACTURACION_LLAVE_MAESTRA";

    private readonly byte[] _llave;

    public ProtectorAesGcm(byte[] llaveMaestra)
    {
        ArgumentNullException.ThrowIfNull(llaveMaestra);

        if (llaveMaestra.Length != TamanoLlave)
            throw new ArgumentException(
                $"La llave maestra debe tener exactamente {TamanoLlave} bytes " +
                $"y tiene {llaveMaestra.Length}.", nameof(llaveMaestra));

        _llave = (byte[])llaveMaestra.Clone();
    }

    /// <summary>
    /// Construye el protector leyendo la llave de la variable de entorno.
    ///
    /// Falla ruidosamente si no está definida. La alternativa —usar una llave
    /// por defecto— produciría un sistema que parece cifrar y no cifra.
    /// </summary>
    public static ProtectorAesGcm DesdeEntorno()
    {
        var valor = Environment.GetEnvironmentVariable(VariableLlaveMaestra);

        if (string.IsNullOrWhiteSpace(valor))
            throw new InvalidOperationException(
                $"Falta la variable de entorno {VariableLlaveMaestra}. " +
                $"Genera una llave con ProtectorAesGcm.GenerarLlaveBase64() " +
                $"y guárdala fuera del repositorio.");

        byte[] llave;

        try
        {
            llave = Convert.FromBase64String(valor);
        }
        catch (FormatException)
        {
            throw new InvalidOperationException(
                $"{VariableLlaveMaestra} no contiene base64 válido.");
        }

        return new ProtectorAesGcm(llave);
    }

    /// <summary>Genera una llave nueva, lista para pegar en la variable de entorno.</summary>
    public static string GenerarLlaveBase64() =>
        Convert.ToBase64String(RandomNumberGenerator.GetBytes(TamanoLlave));

    public byte[] Proteger(ReadOnlySpan<byte> datos)
    {
        var resultado = new byte[TamanoNonce + TamanoTag + datos.Length];

        var nonce = resultado.AsSpan(0, TamanoNonce);
        var tag = resultado.AsSpan(TamanoNonce, TamanoTag);
        var cifrado = resultado.AsSpan(TamanoNonce + TamanoTag);

        // Nonce nuevo en cada cifrado. Repetirlo con la misma llave rompe AES-GCM.
        RandomNumberGenerator.Fill(nonce);

        using var aes = new AesGcm(_llave, TamanoTag);
        aes.Encrypt(nonce, datos, cifrado, tag);

        return resultado;
    }

    public byte[] Desproteger(ReadOnlySpan<byte> protegido)
    {
        if (protegido.Length < TamanoNonce + TamanoTag)
            throw new CryptographicException(
                "El dato protegido es más corto de lo posible. Está corrupto.");

        var nonce = protegido[..TamanoNonce];
        var tag = protegido.Slice(TamanoNonce, TamanoTag);
        var cifrado = protegido[(TamanoNonce + TamanoTag)..];

        var resultado = new byte[cifrado.Length];

        using var aes = new AesGcm(_llave, TamanoTag);

        try
        {
            aes.Decrypt(nonce, cifrado, tag, resultado);
        }
        catch (CryptographicException)
        {
            // Llega aquí si la llave es otra o si alguien alteró el dato.
            // Distinguir ambos casos daría información a un atacante.
            throw new CryptographicException(
                "No se pudo descifrar: la llave maestra no corresponde o el " +
                "dato fue alterado.");
        }

        return resultado;
    }

    public byte[] ProtegerTexto(string texto) =>
        Proteger(System.Text.Encoding.UTF8.GetBytes(texto));

    public string DesprotegerTexto(ReadOnlySpan<byte> protegido) =>
        System.Text.Encoding.UTF8.GetString(Desproteger(protegido));
}
