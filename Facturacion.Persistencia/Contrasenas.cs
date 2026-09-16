using System.Security.Cryptography;
using System.Text;

namespace Facturacion.Persistencia;

/// <summary>
/// Cifra y verifica contraseñas de personas.
///
/// POR QUÉ NO SE USA SHA-256, QUE SÍ SIRVE PARA LAS CLAVES DE API:
///
/// Una clave de API es un valor aleatorio de 32 bytes generado por el sistema.
/// Nadie la va a adivinar probando: el espacio de búsqueda es inabordable.
///
/// Una contraseña la eligió una persona, y las personas eligen mal. Contra un
/// hash rápido como SHA-256, una tarjeta gráfica prueba miles de millones de
/// contraseñas por segundo, y los diccionarios de las más usadas tienen unos
/// pocos millones de entradas. Cuestión de segundos.
///
/// PBKDF2 con muchas iteraciones hace que cada intento cueste tiempo. Lo que
/// para el usuario legítimo son unos milisegundos, para quien prueba un
/// diccionario entero son años.
///
/// FORMATO GUARDADO:
///
///     pbkdf2-sha256$210000$sal_base64$hash_base64
///
/// El algoritmo y las iteraciones viajan junto al hash a propósito: el día
/// que haya que endurecerlo, los usuarios existentes siguen pudiendo entrar
/// con su hash viejo y se les re-cifra la contraseña al ingresar. Sin eso,
/// cambiar el algoritmo obligaría a restablecer la contraseña de todos.
/// </summary>
public static class Contrasenas
{
    private const string Algoritmo = "pbkdf2-sha256";

    /// <summary>
    /// Iteraciones actuales.
    ///
    /// Este número debe subir con los años: el hardware mejora y lo que hoy
    /// cuesta un segundo mañana costará una décima. Cuando se suba, los hashes
    /// viejos siguen funcionando y se actualizan solos al ingresar.
    /// </summary>
    private const int Iteraciones = 210_000;

    private const int TamanoSal = 16;
    private const int TamanoHash = 32;

    /// <summary>Longitud mínima aceptada.</summary>
    public const int LongitudMinima = 10;

    public static string Cifrar(string contrasena)
    {
        if (string.IsNullOrWhiteSpace(contrasena))
            throw new ArgumentException("La contraseña no puede estar vacía.");

        // La sal hace que dos usuarios con la misma contraseña tengan hashes
        // distintos. Sin ella, una tabla precalculada rompería todas a la vez.
        var sal = RandomNumberGenerator.GetBytes(TamanoSal);

        var hash = Rfc2898DeriveBytes.Pbkdf2(
            Encoding.UTF8.GetBytes(contrasena),
            sal,
            Iteraciones,
            HashAlgorithmName.SHA256,
            TamanoHash);

        return string.Join('$',
            Algoritmo,
            Iteraciones,
            Convert.ToBase64String(sal),
            Convert.ToBase64String(hash));
    }

    /// <summary>
    /// Comprueba una contraseña contra su hash guardado.
    /// </summary>
    /// <param name="convieneRecifrar">
    /// true si el hash se hizo con menos iteraciones de las actuales. Quien
    /// llama debería volver a cifrar la contraseña y guardarla: es el momento
    /// en que la tiene en claro.
    /// </param>
    public static bool Verificar(
        string contrasena, string guardado, out bool convieneRecifrar)
    {
        convieneRecifrar = false;

        if (string.IsNullOrWhiteSpace(contrasena) ||
            string.IsNullOrWhiteSpace(guardado))
            return false;

        var partes = guardado.Split('$');

        if (partes.Length != 4 || partes[0] != Algoritmo) return false;

        if (!int.TryParse(partes[1], out var iteraciones)) return false;

        byte[] sal, esperado;

        try
        {
            sal = Convert.FromBase64String(partes[2]);
            esperado = Convert.FromBase64String(partes[3]);
        }
        catch (FormatException)
        {
            return false;
        }

        var calculado = Rfc2898DeriveBytes.Pbkdf2(
            Encoding.UTF8.GetBytes(contrasena),
            sal,
            iteraciones,
            HashAlgorithmName.SHA256,
            esperado.Length);

        // COMPARACIÓN EN TIEMPO CONSTANTE.
        //
        // Comparar byte a byte con un bucle que se detiene en la primera
        // diferencia hace que el tiempo de respuesta revele cuántos bytes se
        // acertaron. Midiendo esas diferencias se puede deducir el hash.
        var coincide = CryptographicOperations.FixedTimeEquals(calculado, esperado);

        if (coincide && iteraciones < Iteraciones)
            convieneRecifrar = true;

        return coincide;
    }

    /// <summary>
    /// Comprueba que una contraseña sea aceptable.
    ///
    /// SE EXIGE LONGITUD, NO COMPLEJIDAD. Obligar a mayúsculas, números y
    /// símbolos produce contraseñas como "Password1!", que son fáciles de
    /// adivinar y difíciles de recordar, así que terminan en un papel pegado
    /// a la pantalla. Una frase larga es mejor por ambos lados.
    /// </summary>
    public static string? Revisar(string contrasena)
    {
        if (string.IsNullOrWhiteSpace(contrasena))
            return "Escribe una contraseña.";

        if (contrasena.Length < LongitudMinima)
            return $"Debe tener al menos {LongitudMinima} caracteres. " +
                   "Una frase que recuerdes es mejor que algo corto y complicado.";

        if (contrasena.Length > 200)
            return "Es demasiado larga.";

        // Las más usadas del mundo, que están en el primer intento de
        // cualquier diccionario.
        var obvias = new[]
        {
            "contrasena", "contraseña", "password", "12345678", "1234567890",
            "qwertyuiop", "administrador", "facturacion"
        };

        var minuscula = contrasena.ToLowerInvariant();

        if (obvias.Any(o => minuscula == o || minuscula.StartsWith(o + "1")))
            return "Esa contraseña es de las primeras que se prueban. Elige otra.";

        return null;
    }

    /// <summary>Genera una contraseña provisional legible.</summary>
    public static string GenerarProvisional()
    {
        // Sin caracteres que se confundan al dictarla por teléfono:
        // ni 0/O, ni 1/l/I.
        const string alfabeto = "abcdefghijkmnpqrstuvwxyz23456789";

        var partes = Enumerable.Range(0, 3).Select(_ =>
            new string(Enumerable.Range(0, 4)
                .Select(_ => alfabeto[RandomNumberGenerator.GetInt32(alfabeto.Length)])
                .ToArray()));

        return string.Join('-', partes);
    }
}
