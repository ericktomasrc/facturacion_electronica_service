namespace Facturacion.Cpe;

/// <summary>
/// Validación de los documentos de identidad del receptor.
///
/// QUÉ ATAJA Y QUÉ NO:
///
/// Un RUC lleva un dígito verificador calculado con módulo 11. Eso permite
/// saber, SIN CONSULTAR NADA, que un número no puede existir: si el último
/// dígito no cuadra con los diez anteriores, alguien se equivocó al teclear.
///
/// No dice que el RUC exista —para eso hace falta el padrón de SUNAT— pero
/// ataja el error que de verdad ocurre: el dedazo. Un dígito cambiado, dos
/// dígitos trocados. Y lo ataja gratis, sin red y sin latencia.
///
/// POR QUÉ IMPORTA MÁS DE LO QUE PARECE: una factura emitida al RUC
/// equivocado no es un error de formato. Es una factura que el cliente no
/// puede usar como crédito fiscal, que hay que anular con una nota de
/// crédito, y que ya consumió un correlativo. Detectarlo antes de emitir
/// vale más que detectarlo después.
/// </summary>
public static class DocumentoIdentidad
{
    /// <summary>
    /// Los dos primeros dígitos de un RUC dicen qué clase de contribuyente
    /// es. Solo estos cuatro están en uso:
    ///
    ///   10  persona natural con negocio
    ///   15  persona jurídica (asignación antigua)
    ///   16  persona jurídica (asignación antigua)
    ///   17  persona jurídica (asignación antigua)
    ///   20  persona jurídica
    ///
    /// Un RUC que empieza por 11, 30 o 99 no existe, por mucho que el
    /// dígito verificador cuadre.
    /// </summary>
    private static readonly string[] PrefijosRuc = ["10", "15", "16", "17", "20"];

    /// <summary>
    /// Los pesos del módulo 11, en el orden en que se aplican a los diez
    /// primeros dígitos. No son arbitrarios ni se pueden reordenar: los fija
    /// el algoritmo.
    /// </summary>
    private static readonly int[] Pesos = [5, 4, 3, 2, 7, 6, 5, 4, 3, 2];

    /// <summary>
    /// El dígito verificador que le correspondería a estos diez dígitos.
    ///
    /// El resto 10 se convierte en 0 y el 11 en 1: es la convención del
    /// módulo 11, que necesita un solo dígito y tiene once restos posibles.
    /// </summary>
    public static int DigitoVerificador(string primerosDiez)
    {
        var suma = 0;

        for (var i = 0; i < 10; i++)
            suma += (primerosDiez[i] - '0') * Pesos[i];

        var resto = 11 - (suma % 11);

        return resto switch { 10 => 0, 11 => 1, _ => resto };
    }

    /// <summary>¿Es un RUC que podría existir?</summary>
    public static bool RucValido(string ruc)
    {
        if (string.IsNullOrWhiteSpace(ruc)) return false;

        ruc = ruc.Trim();

        if (ruc.Length != 11 || !ruc.All(char.IsAsciiDigit)) return false;

        if (Array.IndexOf(PrefijosRuc, ruc[..2]) < 0) return false;

        return DigitoVerificador(ruc) == ruc[10] - '0';
    }

    /// <summary>
    /// El RUC que el usuario probablemente quiso escribir: los mismos diez
    /// dígitos con el verificador correcto.
    ///
    /// SE OFRECE COMO PISTA, NO COMO CORRECCIÓN AUTOMÁTICA. Cambiar el
    /// número por nuestra cuenta emitiría una factura a un tercero, y el
    /// error original pudo estar en cualquiera de los once dígitos.
    /// </summary>
    public static string? RucSugerido(string ruc)
    {
        if (string.IsNullOrWhiteSpace(ruc)) return null;

        ruc = ruc.Trim();

        if (ruc.Length != 11 || !ruc.All(char.IsAsciiDigit)) return null;

        return ruc[..10] + DigitoVerificador(ruc);
    }
}

/// <summary>
/// Reglas del receptor de un comprobante.
///
/// Se aplican según el TIPO de documento, porque cada uno tiene su forma:
/// un DNI son ocho dígitos, un carné de extranjería es alfanumérico, y un
/// pasaporte puede ser casi cualquier cosa.
/// </summary>
public static class ReglasReceptor
{
    /// <summary>
    /// Revisa el documento del receptor. Lista vacía significa que pasa.
    /// Los textos que empiezan por "Aviso:" no impiden emitir.
    /// </summary>
    public static IReadOnlyList<string> Revisar(Receptor r)
    {
        var problemas = new List<string>();

        var numero = (r.NumeroDocumento ?? "").Trim();

        if (!TipoDocIdentidad.Existe(r.TipoDocumento))
        {
            problemas.Add(
                $"El tipo de documento '{r.TipoDocumento}' no existe en el " +
                $"catalogo 06.");

            return problemas;
        }

        if (numero.Length == 0)
        {
            problemas.Add("El receptor necesita un numero de documento.");
            return problemas;
        }

        switch (r.TipoDocumento)
        {
            case TipoDocIdentidad.Ruc:
                RevisarRuc(problemas, numero);
                break;

            case TipoDocIdentidad.Dni:
                if (numero.Length != 8 || !numero.All(char.IsAsciiDigit))
                {
                    problemas.Add(
                        $"Un DNI son 8 digitos, y llego '{numero}' " +
                        $"({numero.Length} caracteres).");
                }
                break;

            default:
                // Pasaporte, carné de extranjería, TIN, IN y los demás del
                // catálogo 06 admiten letras y no tienen dígito verificador.
                // Lo único comprobable es que quepan en el campo.
                if (numero.Length > 15)
                {
                    problemas.Add(
                        $"El numero de documento no puede pasar de 15 " +
                        $"caracteres, y llego uno de {numero.Length}.");
                }
                break;
        }

        if (string.IsNullOrWhiteSpace(r.RazonSocial))
            problemas.Add("El receptor necesita una razon social o un nombre.");

        return problemas;
    }

    private static void RevisarRuc(List<string> problemas, string numero)
    {
        if (numero.Length != 11 || !numero.All(char.IsAsciiDigit))
        {
            problemas.Add(
                $"Un RUC son 11 digitos, y llego '{numero}' " +
                $"({numero.Length} caracteres).");

            return;
        }

        if (!DocumentoIdentidad.RucValido(numero))
        {
            var sugerido = DocumentoIdentidad.RucSugerido(numero);

            // SE DICE CUÁL SERÍA EL CORRECTO, PERO NO SE CORRIGE SOLO.
            //
            // Cambiar el número por nuestra cuenta emitiría la factura a un
            // tercero, y el dedazo pudo estar en cualquiera de los once
            // digitos: el verificador solo sabe que el conjunto no cuadra.
            problemas.Add(
                $"El RUC {numero} no es valido: su digito verificador no " +
                $"corresponde. Casi siempre es un digito mal tecleado. Si los " +
                $"primeros diez son correctos, el RUC seria {sugerido}. " +
                $"Comprueba el numero antes de emitir: una factura al RUC " +
                $"equivocado hay que anularla con nota de credito, y ya habria " +
                $"gastado un correlativo.");
        }
    }

    /// <summary>Los problemas que impiden emitir. Los avisos quedan fuera.</summary>
    public static IReadOnlyList<string> Errores(Receptor r) =>
        Revisar(r).Where(p => !p.StartsWith("Aviso:")).ToList();
}