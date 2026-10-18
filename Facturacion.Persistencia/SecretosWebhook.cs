namespace Facturacion.Persistencia;

/// <summary>
/// EL SECRETO DE FIRMA DE LOS WEBHOOKS, CIFRADO (migración 032).
///
/// Antes se guardaba en claro en `webhooks.secreto`, y un `pg_dump` se lo
/// llevaba: con él cualquiera firma un aviso falso («SUNAT aceptó tu
/// factura»). Ahora va en `webhooks.secreto_cifrado`, con la misma llave
/// maestra y el mismo AES-GCM que los certificados y las claves SOL.
///
/// POR QUÉ ESTÁTICO Y NO INYECTADO: lo usan cuatro repositorios de dos
/// procesos (la API y el Worker) que se construyen con `new`. Los dos ya leen
/// la llave de FACTURACION_LLAVE_MAESTRA para los certificados; aquí se lee la
/// misma, una vez, la primera vez que hace falta.
///
/// LA LECTURA ACEPTA LAS DOS FORMAS mientras quede alguna fila de antes: la
/// consulta devuelve el secreto con el prefijo <see cref="Prefijo"/> y el blob
/// en hexadecimal si está cifrado, o el texto tal cual si es uno viejo.
/// </summary>
public static class SecretosWebhook
{
    /// <summary>Marca, en la consulta, que lo que sigue es el blob cifrado en hexadecimal.</summary>
    public const string Prefijo = "cifrado:";

    private static Lazy<IProtectorDeSecretos> _protector =
        new(ProtectorAesGcm.DesdeEntorno, LazyThreadSafetyMode.ExecutionAndPublication);

    /// <summary>Para las pruebas: otro protector en vez del de la variable de entorno.</summary>
    public static void UsarProtector(IProtectorDeSecretos protector) =>
        _protector = new Lazy<IProtectorDeSecretos>(() => protector);

    /// <summary>El blob que se guarda en `secreto_cifrado`.</summary>
    public static byte[] Cifrar(string secreto) => _protector.Value.ProtegerTexto(secreto);

    /// <summary>El secreto en claro, venga como venga de la consulta.</summary>
    public static string Leer(string? deLaConsulta)
    {
        if (string.IsNullOrEmpty(deLaConsulta))
            throw new InvalidOperationException("El webhook no tiene secreto de firma.");

        if (!deLaConsulta.StartsWith(Prefijo, StringComparison.Ordinal))
            return deLaConsulta;

        var blob = Convert.FromHexString(deLaConsulta.AsSpan(Prefijo.Length));
        return _protector.Value.DesprotegerTexto(blob);
    }
}