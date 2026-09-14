using System.Globalization;
using System.Text;

namespace Facturacion.Cpe;

/// <summary>
/// Convierte un importe a su expresión en letras.
///
/// SUNAT exige la leyenda con código 1000 ("monto en letras") en todo comprobante.
/// El formato esperado es del tipo: SON CIENTO DIECIOCHO CON 00/100 SOLES
/// </summary>
public static class NumeroALetras
{
    private static readonly string[] Unidades =
    [
        "", "UNO", "DOS", "TRES", "CUATRO", "CINCO", "SEIS", "SIETE", "OCHO", "NUEVE",
        "DIEZ", "ONCE", "DOCE", "TRECE", "CATORCE", "QUINCE", "DIECISEIS",
        "DIECISIETE", "DIECIOCHO", "DIECINUEVE", "VEINTE"
    ];

    private static readonly string[] Decenas =
    [
        "", "", "VEINTE", "TREINTA", "CUARENTA", "CINCUENTA",
        "SESENTA", "SETENTA", "OCHENTA", "NOVENTA"
    ];

    private static readonly string[] Centenas =
    [
        "", "CIENTO", "DOSCIENTOS", "TRESCIENTOS", "CUATROCIENTOS", "QUINIENTOS",
        "SEISCIENTOS", "SETECIENTOS", "OCHOCIENTOS", "NOVECIENTOS"
    ];

    /// <summary>
    /// Genera la leyenda completa. Ejemplo: "SON CIENTO DIECIOCHO CON 00/100 SOLES".
    /// </summary>
    public static string Leyenda(decimal importe, string moneda = "PEN")
    {
        var entero = (long)decimal.Truncate(Math.Abs(importe));
        var centimos = (int)Math.Round(
            (Math.Abs(importe) - entero) * 100m, 0, MidpointRounding.AwayFromZero);

        // El redondeo de los céntimos puede llevar a 100.
        if (centimos == 100)
        {
            entero += 1;
            centimos = 0;
        }

        var nombreMoneda = moneda switch
        {
            "PEN" => "SOLES",
            "USD" => "DOLARES AMERICANOS",
            "EUR" => "EUROS",
            _     => moneda
        };

        var letras = entero == 0 ? "CERO" : Convertir(entero);

        return $"SON {letras} CON {centimos:D2}/100 {nombreMoneda}";
    }

    private static string Convertir(long numero)
    {
        if (numero == 0) return "";

        var sb = new StringBuilder();

        var millones = numero / 1_000_000;
        var resto = numero % 1_000_000;

        if (millones > 0)
        {
            sb.Append(millones == 1 ? "UN MILLON" : $"{Convertir(millones)} MILLONES");
            if (resto > 0) sb.Append(' ');
        }

        if (resto > 0)
            sb.Append(ConvertirMenorAMillon(resto));

        return sb.ToString().Trim();
    }

    private static string ConvertirMenorAMillon(long numero)
    {
        var sb = new StringBuilder();

        var miles = numero / 1000;
        var resto = numero % 1000;

        if (miles > 0)
        {
            sb.Append(miles == 1 ? "MIL" : $"{ConvertirCentenas((int)miles)} MIL");
            if (resto > 0) sb.Append(' ');
        }

        if (resto > 0)
            sb.Append(ConvertirCentenas((int)resto));

        return sb.ToString().Trim();
    }

    private static string ConvertirCentenas(int numero)
    {
        if (numero == 0) return "";
        if (numero == 100) return "CIEN";

        var sb = new StringBuilder();

        var centena = numero / 100;
        var resto = numero % 100;

        if (centena > 0)
        {
            sb.Append(Centenas[centena]);
            if (resto > 0) sb.Append(' ');
        }

        if (resto > 0)
            sb.Append(ConvertirDecenas(resto));

        return sb.ToString().Trim();
    }

    private static string ConvertirDecenas(int numero)
    {
        if (numero <= 20) return Unidades[numero];

        var decena = numero / 10;
        var unidad = numero % 10;

        if (unidad == 0) return Decenas[decena];

        // Los del 21 al 29 se escriben en una sola palabra.
        if (decena == 2) return $"VEINTI{Unidades[unidad]}";

        return $"{Decenas[decena]} Y {Unidades[unidad]}";
    }

    /// <summary>Formatea un decimal con 2 decimales y punto, como espera SUNAT.</summary>
    public static string F2(decimal valor) =>
        valor.ToString("F2", CultureInfo.InvariantCulture);
}
