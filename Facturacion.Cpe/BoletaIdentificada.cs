namespace Facturacion.Cpe;

/// <summary>
/// LA BOLETA DE MÁS DE S/ 700 IDENTIFICA AL COMPRADOR.
///
/// Reglamento de Comprobantes de Pago, artículo 8, numeral 3.10: cuando el
/// importe de la boleta supera S/ 700, tiene que llevar los apellidos y
/// nombres del comprador y su documento de identidad. Por debajo, la boleta
/// de mostrador sin identificar («clientes varios») es válida.
///
/// POR QUÉ HACE FALTA AQUÍ: SUNAT solo lo comprueba a medias. En el resumen
/// diario rechaza la línea que pasa de 700 y no trae el bloque del adquirente
/// (2514), pero este servicio siempre lo manda, así que una boleta de 900 a
/// «0 / - / CLIENTES VARIOS» pasaría sin error y quedaría mal emitida: el
/// comprador no podría sustentarla y el emisor queda expuesto a una multa.
///
/// QUÉ CUENTA COMO «SIN IDENTIFICAR»: el tipo 0 (sin documento), un número
/// hecho solo de ceros, nueves o guiones (el «00000000» de mostrador), o un
/// nombre genérico («VARIOS», «CLIENTES VARIOS», «PÚBLICO EN GENERAL»…).
///
/// EN DÓLARES: el tope es en soles, así que el importe se convierte con el
/// tipo de cambio declarado.
/// </summary>
public static class BoletaIdentificada
{
    /// <summary>El tope del reglamento: más de esto, identificada.</summary>
    public const decimal Tope = 700m;

    private static readonly string[] NombresGenericos =
    [
        "VARIOS", "CLIENTE VARIOS", "CLIENTES VARIOS", "CLIENTE VARIO",
        "PUBLICO EN GENERAL", "PUBLICO GENERAL", "CONSUMIDOR FINAL",
        "SIN NOMBRE", "SIN DOCUMENTO", "ANONIMO", "CLIENTE", "-", "--", "."
    ];

    /// <summary>
    /// ¿El receptor es el de mostrador, sin identificar? Lo usa también quien
    /// quiera avisar antes de emitir.
    /// </summary>
    public static bool SinIdentificar(Receptor r)
    {
        if (r.TipoDocumento == TipoDocIdentidad.SinDocumento) return true;

        var numero = (r.NumeroDocumento ?? "").Trim();

        if (numero.Length == 0) return true;
        // «00000000», «99999999», «11111111», «-»: el mismo carácter repetido
        // no es un documento de nadie.
        if (numero.All(c => c == numero[0]))
            return true;

        var nombre = Normalizar(r.RazonSocial);

        return nombre.Length == 0 || NombresGenericos.Contains(nombre);
    }

    /// <summary>El importe en soles, para compararlo con el tope.</summary>
    public static decimal EnSoles(decimal importe, string moneda, TipoCambio? tipoCambio) =>
        moneda == "PEN" || tipoCambio is null || tipoCambio.Tasa <= 0
            ? importe
            : Math.Round(importe * tipoCambio.Tasa, 2);

    /// <summary>
    /// Los problemas que impiden emitir. Lista vacía significa que pasa. Solo
    /// mira boletas; cualquier otro comprobante pasa.
    /// </summary>
    public static IReadOnlyList<string> Errores(ComprobanteBase c)
    {
        if (c is not Boleta) return [];
        if (!SinIdentificar(c.Receptor)) return [];

        var total = CalculadoraTotales.Calcular(c).ImporteTotal;

        // EN OTRA MONEDA SIN TIPO DE CAMBIO VÁLIDO no se puede saber si pasa
        // del tope. Comparar los dólares tal cual dejaría pasar una boleta de
        // USD 600 (más de S/ 2 000) sin identificar: se para.
        if (c.Moneda != "PEN" && (c.TipoCambio is null || c.TipoCambio.Tasa <= 0))
        {
            return
            [
                "La boleta va en " + c.Moneda + " sin un tipo de cambio válido, y el comprador " +
                "no está identificado: no se puede saber si pasa de S/ 700. Declara el tipo de " +
                "cambio, o emítela a nombre del comprador con su DNI."
            ];
        }

        var enSoles = EnSoles(total, c.Moneda, c.TipoCambio);

        if (enSoles <= Tope) return [];

        var inv = System.Globalization.CultureInfo.InvariantCulture;
        var importe = c.Moneda == "PEN"
            ? $"S/ {total.ToString("N2", inv)}"
            : $"{c.Moneda} {total.ToString("N2", inv)} (S/ {enSoles.ToString("N2", inv)} al tipo " +
              $"de cambio {(c.TipoCambio?.Tasa ?? 0m).ToString("0.000", inv)})";

        return
        [
            $"Esta boleta es de {importe} y va sin identificar al comprador. Desde " +
            $"S/ 700.01 el reglamento exige su nombre y su DNI (u otro documento de " +
            $"identidad): pídeselos y emítela a su nombre. Si tiene RUC y lo necesita " +
            $"para su contabilidad, lo que corresponde es una factura."
        ];
    }

    private static string Normalizar(string? texto)
    {
        var t = (texto ?? "").Trim().ToUpperInvariant();

        // Sin tildes: «PÚBLICO» y «PUBLICO» son lo mismo.
        var sinTildes = new System.Text.StringBuilder(t.Length);
        foreach (var ch in t.Normalize(System.Text.NormalizationForm.FormD))
            if (System.Globalization.CharUnicodeInfo.GetUnicodeCategory(ch) !=
                System.Globalization.UnicodeCategory.NonSpacingMark)
                sinTildes.Append(ch);

        return string.Join(' ', sinTildes.ToString()
            .Split(' ', StringSplitOptions.RemoveEmptyEntries));
    }
}