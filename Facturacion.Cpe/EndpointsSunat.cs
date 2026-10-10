namespace Facturacion.Cpe;

/// <summary>
/// Resuelve a qué servicio de SUNAT va cada comprobante.
///
/// EL DESCUBRIMIENTO QUE COSTÓ UN RECHAZO 0151: SUNAT no tiene un billService,
/// tiene varios, y cada uno solo acepta ciertos tipos de documento.
///
///   ol-ti-itcpfegem            factura, boleta, notas, liquidación, resúmenes
///   ol-ti-itemision-otroscpe   comprobante de retención y de percepción
///   ol-ti-itemision-guia       guías (ya sustituido por la API REST de GRE)
///
/// Mandar un tipo 20 al primero devuelve:
///
///   0151 - El nombre del archivo ZIP es incorrecto
///          "...codigo cpe: 20 no es un cpe valido"
///
/// El mensaje habla del nombre del archivo y el nombre está perfecto. Lo que
/// pasa es que ese servicio no sabe qué es un 20, así que lo primero que no le
/// cuadra es el nombre.
///
/// POR QUÉ SE DERIVA Y NO SE CONFIGURA APARTE:
///
/// Las tres URLs se diferencian en un tramo de la ruta y nada más. Tenerlas
/// como tres variables de entorno significa que el día del paso a producción
/// hay que acertar con las tres, y que si alguien cambia una y olvida otra, el
/// sistema envía la mitad de los comprobantes a producción y la otra mitad a
/// beta sin que nadie se entere.
///
/// Derivándolas, en producción solo se cambia la de siempre.
/// </summary>
public static class EndpointsSunat
{
    // Los tramos de ruta que distinguen un servicio de otro.

    private const string FacturasBeta = "ol-ti-itcpfegem-beta";
    private const string FacturasProduccion = "ol-ti-itcpfegem";

    private const string OtrosCpeBeta = "ol-ti-itemision-otroscpe-gem-beta";
    private const string OtrosCpeProduccion = "ol-ti-itemision-otroscpe-gem";

    /// <summary>
    /// Los tipos que NO van por el servicio de facturas.
    ///
    /// Son dos: el comprobante de retención (20) y el de percepción (40). Todo
    /// lo demás —facturas, boletas, notas, liquidaciones de compra, resúmenes
    /// y comunicaciones de baja— va por el de siempre.
    /// </summary>
    public static bool VaPorOtrosCpe(string tipoComprobante) =>
        tipoComprobante == ComprobanteRetencion.Tipo ||
        tipoComprobante == ComprobantePercepcion.Tipo;

    /// <summary>
    /// La URL del servicio de otros CPE, a partir de la de facturas.
    ///
    /// SI NO RECONOCE LA URL LA DEVUELVE TAL CUAL. Pasa si alguien configuró
    /// un OSE o un simulador: en ese caso no hay nada que derivar y el envío
    /// irá donde diga la configuración, que es lo que quien la puso pretendía.
    /// </summary>
    public static string OtrosCpe(string endpointDeFacturas)
    {
        if (string.IsNullOrWhiteSpace(endpointDeFacturas))
            return endpointDeFacturas;

        // EL ORDEN DE LOS DOS REEMPLAZOS IMPORTA.
        //
        // "ol-ti-itcpfegem-beta" contiene "ol-ti-itcpfegem". Si se hiciera al
        // revés, una URL de beta quedaría como
        // "ol-ti-itemision-otroscpe-gem-beta-beta" y el envío se iría a un 404.
        if (endpointDeFacturas.Contains(FacturasBeta))
            return endpointDeFacturas.Replace(FacturasBeta, OtrosCpeBeta);

        if (endpointDeFacturas.Contains(FacturasProduccion))
            return endpointDeFacturas.Replace(FacturasProduccion, OtrosCpeProduccion);

        return endpointDeFacturas;
    }

    /// <summary>
    /// La configuración que le toca a un comprobante según su tipo.
    ///
    /// Devuelve la misma instancia cuando no hay nada que cambiar, así el
    /// caso normal —que son casi todos los comprobantes— no copia nada.
    /// </summary>
    public static ConfiguracionSunat ParaTipo(
        this ConfiguracionSunat config, string tipoComprobante)
    {
        ArgumentNullException.ThrowIfNull(config);

        if (!VaPorOtrosCpe(tipoComprobante))
            return config;

        var destino = OtrosCpe(config.Endpoint);

        if (destino == config.Endpoint)
            return config;

        // Se copia todo lo demás: las credenciales son las mismas y los
        // endpoints de consulta no cambian entre servicios.
        return new ConfiguracionSunat
        {
            Endpoint = destino,
            EndpointConsulta = config.EndpointConsulta,
            EndpointValidez = config.EndpointValidez,
            Usuario = config.Usuario,
            Clave = config.Clave,
            Timeout = config.Timeout
        };
    }
}
