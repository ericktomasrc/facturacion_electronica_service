using System.Security.Cryptography;
using System.Text;

namespace Facturacion.Persistencia;

/// <summary>
/// Códigos temporales de seis dígitos, los de Google Authenticator y
/// similares.
///
/// CÓMO FUNCIONA, QUE ES MÁS SIMPLE DE LO QUE PARECE:
///
/// El servidor y el teléfono comparten un secreto. Cada 30 segundos, ambos
/// calculan el mismo número a partir de ese secreto y de la hora actual. Si
/// el número que escribe el usuario coincide con el que calcula el servidor,
/// es que tiene el teléfono.
///
/// No hay comunicación entre el teléfono y el servidor: el código sale de una
/// cuenta que los dos pueden hacer por separado. Por eso funciona en avión.
///
/// POR QUÉ ESTO Y NO SMS:
///
/// El SMS parece más cómodo y es bastante peor. Una tarjeta SIM se puede
/// clonar convenciendo a un empleado de la operadora, y el mensaje viaja por
/// una red que no controla nadie. El secreto de una aplicación autenticadora
/// no sale del teléfono.
///
/// Implementa el RFC 6238, que es lo que hace que cualquier aplicación sirva.
/// </summary>
public static class Totp
{
    /// <summary>Duración de cada código, en segundos.</summary>
    private const int Periodo = 30;

    private const int Digitos = 6;

    /// <summary>
    /// Cuántos periodos de margen se aceptan hacia atrás y hacia adelante.
    ///
    /// POR QUÉ HACE FALTA MARGEN: el reloj del teléfono y el del servidor
    /// nunca están perfectamente sincronizados, y el usuario tarda unos
    /// segundos en teclear. Sin margen, un código válido se rechazaría solo
    /// por haberlo escrito despacio.
    ///
    /// Un periodo a cada lado da 90 segundos de ventana. Más sería cómodo y
    /// menos seguro: cada periodo extra amplía el tiempo que sirve un código
    /// interceptado.
    /// </summary>
    private const int Margen = 1;

    /// <summary>
    /// Genera un secreto nuevo, en el formato que esperan las aplicaciones.
    ///
    /// Base32 y no base64 porque es lo que usa el estándar: solo letras
    /// mayúsculas y dígitos del 2 al 7, sin caracteres que se confundan al
    /// teclearlos a mano cuando no se puede escanear el código.
    /// </summary>
    public static string GenerarSecreto()
    {
        var bytes = RandomNumberGenerator.GetBytes(20);
        return Base32.Codificar(bytes);
    }

    /// <summary>
    /// Arma la dirección que se convierte en código QR.
    ///
    /// El nombre del emisor y la cuenta son lo que el usuario verá en su
    /// aplicación. Importa que sean reconocibles: alguien con diez cuentas
    /// configuradas necesita saber cuál es cuál.
    /// </summary>
    public static string ArmarUri(string secreto, string cuenta, string emisor)
    {
        var e = Uri.EscapeDataString(emisor);
        var c = Uri.EscapeDataString(cuenta);

        return $"otpauth://totp/{e}:{c}" +
               $"?secret={secreto}" +
               $"&issuer={e}" +
               $"&algorithm=SHA1" +
               $"&digits={Digitos}" +
               $"&period={Periodo}";
    }

    /// <summary>
    /// Comprueba un código contra el secreto.
    /// </summary>
    /// <param name="periodoUsado">
    /// El periodo concreto que validó el código. Hay que guardarlo para
    /// rechazar ese mismo código si se vuelve a usar: sin eso, quien
    /// interceptara un código podría emplearlo dentro de su ventana de
    /// validez.
    /// </param>
    public static bool Verificar(
        string secreto, string codigo, out long periodoUsado)
    {
        periodoUsado = 0;

        if (string.IsNullOrWhiteSpace(secreto) ||
            string.IsNullOrWhiteSpace(codigo))
            return false;

        // La gente escribe el código con espacios, tal como lo muestra la
        // aplicación: "123 456".
        var limpio = new string(codigo.Where(char.IsDigit).ToArray());

        if (limpio.Length != Digitos) return false;

        byte[] llave;

        try { llave = Base32.Decodificar(secreto); }
        catch (FormatException) { return false; }

        var ahora = DateTimeOffset.UtcNow.ToUnixTimeSeconds() / Periodo;

        for (var desfase = -Margen; desfase <= Margen; desfase++)
        {
            var periodo = ahora + desfase;

            if (Calcular(llave, periodo) == limpio)
            {
                periodoUsado = periodo;
                return true;
            }
        }

        return false;
    }

    /// <summary>Calcula el código de un periodo concreto.</summary>
    private static string Calcular(byte[] llave, long periodo)
    {
        var contador = BitConverter.GetBytes(periodo);

        // El estándar exige orden de byte más significativo primero, y las
        // máquinas de Intel usan el contrario.
        if (BitConverter.IsLittleEndian) Array.Reverse(contador);

        using var hmac = new HMACSHA1(llave);
        var hash = hmac.ComputeHash(contador);

        // Truncamiento dinámico: los últimos cuatro bits del hash indican
        // desde dónde leer los cuatro bytes que forman el número. Es lo que
        // evita que siempre se use la misma parte del hash.
        var inicio = hash[^1] & 0x0F;

        var binario =
            ((hash[inicio] & 0x7F) << 24) |
            ((hash[inicio + 1] & 0xFF) << 16) |
            ((hash[inicio + 2] & 0xFF) << 8) |
            (hash[inicio + 3] & 0xFF);

        return (binario % (int)Math.Pow(10, Digitos))
            .ToString().PadLeft(Digitos, '0');
    }
}

/// <summary>
/// Base32 según el RFC 4648.
///
/// Es el formato que usan las aplicaciones autenticadoras. Solo letras
/// mayúsculas y dígitos del 2 al 7: se excluyen el 0, el 1 y el 8 porque se
/// confunden con la O, la I y la B al teclearlos a mano.
/// </summary>
public static class Base32
{
    private const string Alfabeto = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";

    public static string Codificar(byte[] datos)
    {
        var resultado = new StringBuilder();

        var bits = 0;
        var valor = 0;

        foreach (var b in datos)
        {
            valor = (valor << 8) | b;
            bits += 8;

            while (bits >= 5)
            {
                resultado.Append(Alfabeto[(valor >> (bits - 5)) & 31]);
                bits -= 5;
            }
        }

        if (bits > 0)
            resultado.Append(Alfabeto[(valor << (5 - bits)) & 31]);

        return resultado.ToString();
    }

    public static byte[] Decodificar(string texto)
    {
        var limpio = texto.Trim().Replace(" ", "").Replace("=", "").ToUpperInvariant();

        var bytes = new List<byte>();

        var bits = 0;
        var valor = 0;

        foreach (var c in limpio)
        {
            var indice = Alfabeto.IndexOf(c);

            if (indice < 0)
                throw new FormatException($"Carácter no válido en base32: '{c}'.");

            valor = (valor << 5) | indice;
            bits += 5;

            if (bits >= 8)
            {
                bytes.Add((byte)((valor >> (bits - 8)) & 255));
                bits -= 8;
            }
        }

        return bytes.ToArray();
    }
}
