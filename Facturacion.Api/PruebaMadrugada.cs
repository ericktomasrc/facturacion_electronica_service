using System.Net.Http.Headers;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using System.Text.Json;
using Facturacion.Persistencia;

namespace Facturacion.Api;

/// <summary>Un caso de la prueba: qué se emite y por qué ruta.</summary>
/// <param name="Clave">Identificador estable: con él se compara noche contra noche.</param>
/// <param name="Cuerpo">Arma la petición. Recibe la fecha de Lima y lo ya emitido esa noche.</param>
public sealed record CasoPrueba(
    string Clave, string Nombre, string Ruta,
    Func<DateOnly, IReadOnlyDictionary<string, (Guid Id, string Numero)>, object?> Cuerpo,
    string? Depende = null, bool EsperaAceptado = false, string? SiFalta = null);

/// <summary>
/// LOS CASOS DE LA PRUEBA DE MADRUGADA. Para agregar uno, se agrega aquí.
///
/// Van en este orden porque algunos dependen de otros: las notas modifican la
/// «factura simple» de esa misma noche, y la baja se pide sobre otra factura.
/// Las tres ESPERAN (hasta 5 minutos) a que SUNAT acepte su factura: nuestra
/// API no deja emitir una nota ni una baja sobre algo que SUNAT no aceptó
/// todavía (corregido el 14 oct, tras la primera corrida).
///
/// LA BOLETA tarda un día: viaja en el resumen diario, que el servicio arma con
/// las boletas del día anterior. Su casilla sale «esperando» hasta entonces.
///
/// LA ANULACIÓN DE BOLETA también va un día atrás: cada noche se emite una
/// boleta «para anular», y la noche siguiente se anula (solo se puede anular lo
/// que SUNAT ya aceptó, y la boleta se acepta con el resumen del día después).
/// La primera noche sale «sin probar»: todavía no hay boleta de la víspera.
///
/// Las guías no están: SUNAT no tiene ambiente de pruebas para ellas.
/// </summary>
public static class CasosMadrugada
{
    // RUC del cliente de las facturas: la empresa de prueba de la plataforma.
    private const string RucCliente = "20610878564";

    private static object Cliente() => new
    {
        tipoDocumento = "6", numeroDocumento = RucCliente,
        razonSocial = "EMPRESA DE PRUEBA", direccion = "AV. PRUEBA 123, LIMA"
    };

    private static object Linea(string codigo, string descripcion, decimal cantidad, decimal valor,
                                string afectacion = "10", string? codigoSunat = null) => new
    {
        codigoProducto = codigo, codigoProductoSunat = codigoSunat, descripcion, unidadMedida = "NIU",
        cantidad, valorUnitario = valor, tipoAfectacionIgv = afectacion
    };

    private static string F(DateOnly d) => d.ToString("yyyy-MM-dd");

    public static readonly IReadOnlyList<CasoPrueba> Todos =
    [
        new("factura-simple", "Factura simple", "/v1/comprobantes", (hoy, _) => new
        {
            tipo = "01", serie = "F900", fechaEmision = F(hoy), moneda = "PEN",
            receptor = Cliente(),
            lineas = new[] { Linea("PM-001", "SERVICIO DE PRUEBA DE MADRUGADA", 1, 100m) }
        }),

        new("factura-dolares", "Factura en dólares con descuento", "/v1/comprobantes", (hoy, _) => new
        {
            tipo = "01", serie = "F900", fechaEmision = F(hoy), moneda = "USD",
            tipoCambio = new { monedaOrigen = "USD", monedaDestino = "PEN", tasa = 3.750m, fecha = F(hoy) },
            descuentoGlobalPorcentaje = 5m,
            receptor = Cliente(),
            lineas = new[] { Linea("PM-002", "PRODUCTO DE PRUEBA EN DOLARES", 2, 50m) }
        }),

        new("factura-bonificacion", "Factura con bonificación", "/v1/comprobantes", (hoy, _) => new
        {
            tipo = "01", serie = "F900", fechaEmision = F(hoy), moneda = "PEN",
            receptor = Cliente(),
            lineas = new[]
            {
                Linea("PM-003", "PRODUCTO DE PRUEBA", 3, 20m),
                Linea("PM-004", "PRODUCTO DE REGALO (BONIFICACION)", 1, 20m, afectacion: "15")
            }
        }),

        new("boleta", "Boleta (va en el resumen del día siguiente)", "/v1/comprobantes", (hoy, _) => new
        {
            tipo = "03", serie = "B900", fechaEmision = F(hoy), moneda = "PEN",
            receptor = new { tipoDocumento = "1", numeroDocumento = "12345678",
                             razonSocial = "CLIENTE DE PRUEBA", direccion = "LIMA" },
            lineas = new[] { Linea("PM-005", "VENTA DE PRUEBA", 1, 50m) }
        }),

        // Las gratuitas de una boleta viajan en el resumen diario, y su forma
        // cambia con las reglas de 2027 (06–09 en vez del 05). Este caso es el
        // que avisa si SUNAT beta lo activa antes, o si nuestro cambio falla.
        new("boleta-bonificacion", "Boleta con bonificación (gratuitas en el resumen)", "/v1/comprobantes", (hoy, _) => new
        {
            tipo = "03", serie = "B900", fechaEmision = F(hoy), moneda = "PEN",
            receptor = new { tipoDocumento = "1", numeroDocumento = "12345678",
                             razonSocial = "CLIENTE DE PRUEBA", direccion = "LIMA" },
            lineas = new[]
            {
                Linea("PM-008", "VENTA DE PRUEBA", 1, 50m),
                Linea("PM-009", "PRODUCTO DE REGALO (BONIFICACION)", 1, 10m, afectacion: "15")
            }
        }),

        // El código de producto SUNAT (catálogo 25) en el XML: uno de nivel
        // producto y uno de nivel clase. Si SUNAT cambia cómo lo valida —desde
        // 2027 uno inválido es rechazo, no observación—, este caso avisa.
        new("factura-codigo-sunat", "Factura con código de producto SUNAT", "/v1/comprobantes", (hoy, _) => new
        {
            tipo = "01", serie = "F900", fechaEmision = F(hoy), moneda = "PEN",
            receptor = Cliente(),
            lineas = new[]
            {
                Linea("PM-010", "AZUCAR RUBIA 1 KG (PRUEBA)", 2, 4m, codigoSunat: "50161509"),
                Linea("PM-011", "SERVICIO CONTABLE (PRUEBA)", 1, 100m, codigoSunat: "84111500")
            }
        }),

        // EL ICBPER (bolsas de plástico): la línea de las bolsas lleva su
        // cantidad y el impuesto por bolsa, que sube el total. Avisa si SUNAT
        // cambia la tasa o cómo comprueba la suma (3236, 3306).
        new("factura-icbper", "Factura con bolsas (ICBPER)", "/v1/comprobantes", (hoy, _) => new
        {
            tipo = "01", serie = "F900", fechaEmision = F(hoy), moneda = "PEN",
            receptor = Cliente(),
            lineas = new object[]
            {
                Linea("PM-012", "PRODUCTO DE PRUEBA", 2, 10m),
                new
                {
                    codigoProducto = "PM-013", descripcion = "BOLSA PLASTICA (PRUEBA)", unidadMedida = "NIU",
                    cantidad = 3m, valorUnitario = 0.10m, tipoAfectacionIgv = "10", afectoIcbper = true
                }
            }
        }),

        // LA EXPORTACIÓN: tipo de operación 0200, en dólares, a un cliente del
        // exterior sin RUC, todas las líneas con afectación 40.
        new("factura-exportacion", "Factura de exportación", "/v1/comprobantes", (hoy, _) => new
        {
            tipo = "01", serie = "F900", fechaEmision = F(hoy), moneda = "USD",
            tipoOperacion = "0200",
            tipoCambio = new { monedaOrigen = "USD", monedaDestino = "PEN", tasa = 3.750m, fecha = F(hoy) },
            receptor = new { tipoDocumento = "0", numeroDocumento = "EXT900001",
                             razonSocial = "CLIENTE DEL EXTERIOR (PRUEBA)", direccion = "MIAMI, ESTADOS UNIDOS" },
            lineas = new[] { Linea("PM-014", "MERCADERIA DE EXPORTACION (PRUEBA)", 10, 25m, afectacion: "40") }
        }),

        // LA DETRACCIÓN: más de S/ 700, código 037 (demás servicios gravados,
        // 12 %). La cuenta del Banco de la Nación es de mentira: SUNAT solo
        // exige que exista (3034). Avisa si cambia el cálculo o la leyenda.
        new("factura-detraccion", "Factura con detracción", "/v1/comprobantes", (hoy, _) => new
        {
            tipo = "01", serie = "F900", fechaEmision = F(hoy), moneda = "PEN",
            receptor = Cliente(),
            detraccion = new { codigoBienServicio = "037", porcentaje = 12m, cuentaBancoNacion = "00000000000" },
            lineas = new[] { Linea("PM-015", "SERVICIO DE CONSULTORIA (PRUEBA)", 1, 1000m) }
        }),

        new("nota-credito", "Nota de crédito", "/v1/notas-credito", (hoy, hechos) =>
            !hechos.TryGetValue("factura-simple", out var f) ? null : new
            {
                serie = "FC90", fechaEmision = F(hoy), moneda = "PEN",
                codigoMotivo = "01", descripcionMotivo = "ANULACION DE LA OPERACION (PRUEBA)",
                afectado = Afectado(f.Numero),
                receptor = Cliente(),
                lineas = new[] { Linea("PM-001", "SERVICIO DE PRUEBA DE MADRUGADA", 1, 100m) }
            }, Depende: "factura-simple", EsperaAceptado: true),

        new("nota-debito", "Nota de débito", "/v1/notas-debito", (hoy, hechos) =>
            !hechos.TryGetValue("factura-simple", out var f) ? null : new
            {
                serie = "FD90", fechaEmision = F(hoy), moneda = "PEN",
                codigoMotivo = "01", descripcionMotivo = "INTERESES POR MORA (PRUEBA)",
                afectado = Afectado(f.Numero),
                receptor = Cliente(),
                lineas = new[] { Linea("PM-006", "INTERESES POR MORA", 1, 10m) }
            }, Depende: "factura-simple", EsperaAceptado: true),

        new("factura-para-baja", "Factura que luego se da de baja", "/v1/comprobantes", (hoy, _) => new
        {
            tipo = "01", serie = "F900", fechaEmision = F(hoy), moneda = "PEN",
            receptor = Cliente(),
            lineas = new[] { Linea("PM-007", "SERVICIO QUE SE ANULA", 1, 30m) }
        }),

        new("baja", "Baja de una factura", "/v1/bajas", (_, hechos) =>
            !hechos.TryGetValue("factura-para-baja", out var f) ? null : new
            {
                motivo = "PRUEBA DE MADRUGADA",
                comprobantes = new[] { new { tipoDocumento = "01", serie = f.Numero[..4],
                                             correlativo = int.Parse(f.Numero[5..]),
                                             motivo = "PRUEBA DE MADRUGADA" } }
            }, Depende: "factura-para-baja", EsperaAceptado: true),

        // LA LIQUIDACIÓN DE COMPRA (serie L900): se le compra a una persona
        // sin RUC (vendedor con DNI), con su domicilio y el lugar de la compra.
        // Desde 2027 el código de producto SUNAT es obligatorio en ella.
        new("liquidacion", "Liquidación de compra (vendedor con DNI)", "/v1/liquidaciones", (hoy, _) => new
        {
            serie = "L900", fechaEmision = F(hoy), moneda = "PEN", tipoOperacion = "0501",
            vendedor = new
            {
                tipoDocumento = "1", numeroDocumento = "45678912", nombres = "VENDEDOR DE PRUEBA",
                direccion = "CASERIO LA PRUEBA S/N", ubigeo = "150101",
                distrito = "LIMA", provincia = "LIMA", departamento = "LIMA", condicionDomicilio = "05"
            },
            lugar = new
            {
                direccion = "CHACRA DE PRUEBA KM 10", ubigeo = "150101",
                distrito = "LIMA", provincia = "LIMA", departamento = "LIMA", condicion = "02"
            },
            lineas = new[] { Linea("PM-016", "AZUCAR RUBIA (PRUEBA)", 50, 3m, codigoSunat: "50161509") }
        }),

        // LA RETENCIÓN (serie R900, 3 %): la empresa interna hace de agente de
        // retención y le retiene al cliente de prueba sobre una factura suya.
        // Beta no comprueba que esa factura exista.
        new("retencion", "Comprobante de retención", "/v1/retenciones", (hoy, _) => new
        {
            serie = "R900", fechaEmision = F(hoy), regimen = "01",
            proveedor = Contraparte(),
            documentos = new[] { Cobrado("F001-00000001", hoy, 1180m) }
        }),

        // LA PERCEPCIÓN (serie P900, 2 % venta interna): igual, del otro lado.
        new("percepcion", "Comprobante de percepción", "/v1/percepciones", (hoy, _) => new
        {
            serie = "P900", fechaEmision = F(hoy), regimen = "01",
            cliente = Contraparte(),
            documentos = new[] { Cobrado("F001-00000002", hoy, 1180m) }
        }),

        // La boleta que se anulará la noche siguiente (ver arriba).
        new("boleta-para-anular", "Boleta que se anula la noche siguiente", "/v1/comprobantes", (hoy, _) => new
        {
            tipo = "03", serie = "B900", fechaEmision = F(hoy), moneda = "PEN",
            receptor = new { tipoDocumento = "1", numeroDocumento = "45678912",
                             razonSocial = "CLIENTE DE PRUEBA", direccion = "LIMA" },
            lineas = new[] { Linea("PM-017", "VENTA QUE SE ANULA", 1, 20m) }
        }),

        // LA ANULACIÓN DE BOLETA: no es una baja (SUNAT no admite boletas en
        // la RA, error 2308): viaja en un resumen diario con estado 3. Se
        // anula la «boleta para anular» de una noche anterior que SUNAT ya
        // aceptó. Sale verde cuando la boleta pasa a ANULADO.
        new("anular-boleta", "Anulación de boleta (resumen con estado 3)", "/v1/comprobantes/{id}/anular", (_, hechos) =>
            !hechos.ContainsKey(BoletaAnterior) ? null : new { motivo = "PRUEBA DE MADRUGADA" },
            Depende: BoletaAnterior,
            SiFalta: "No se pudo probar: todavía no hay una «boleta para anular» de una noche anterior " +
                     "que SUNAT haya aceptado. Sale sola desde la próxima noche."),
    ];

    /// <summary>La clave con que se pasa a la anulación la boleta de la víspera.</summary>
    public const string BoletaAnterior = "boleta-para-anular (noche anterior)";

    /// <summary>Las series que la prueba necesita además de F900, B900, FC90 y FD90.</summary>
    public static readonly (string Tipo, string Serie)[] SeriesExtra =
        [("04", "L900"), ("20", "R900"), ("40", "P900")];

    private static object Contraparte() => new
    {
        ruc = RucCliente, razonSocial = "EMPRESA DE PRUEBA", direccion = "AV. PRUEBA 123, LIMA",
        ubigeo = "150101", distrito = "LIMA", provincia = "LIMA", departamento = "LIMA"
    };

    private static object Cobrado(string numero, DateOnly hoy, decimal importe) => new
    {
        tipoDocumento = "01", numero, fechaEmision = F(hoy), importeTotal = importe, moneda = "PEN",
        numeroPago = 1, fechaPago = F(hoy), importePago = importe
    };

    private static object Afectado(string numero) =>
        new { tipoDocumento = "01", serie = numero[..4], correlativo = int.Parse(numero[5..]) };
}

/// <summary>
/// LA PRUEBA DE MADRUGADA (migración 030).
///
/// Prepara la empresa interna si hace falta, emite los casos POR LA API —igual
/// que un cliente, con su clave fac_— y anota qué se emitió. El desenlace lo
/// pone el worker como a cualquier comprobante; la comparación con la noche
/// anterior la hace <see cref="EvaluarAsync"/>, que corre con la vigilancia
/// cada 5 minutos.
///
/// LA EMPRESA INTERNA: RUC 20999999990, siempre en beta (la base no la deja
/// pasar a producción), certificado autofirmado (SUNAT beta lo acepta),
/// series F900, B900, FC90 y FD90. Ningún correlativo real se toca.
/// </summary>
public sealed class PruebaMadrugada
{
    public const string RucInterno = "20999999990";
    private const string ClaveCertificado = "prueba-de-madrugada";

    private readonly RepositorioMadrugada _repo;
    private readonly RepositorioAdmin _admin;
    private readonly AlmacenCertificados _certificados;
    private readonly IProtectorDeSecretos _protector;
    private readonly IHttpClientFactory _http;
    private readonly ILogger<PruebaMadrugada> _log;

    // Una sola corrida a la vez dentro de este proceso.
    private readonly SemaphoreSlim _uno = new(1, 1);

    public PruebaMadrugada(
        RepositorioMadrugada repo, RepositorioAdmin admin, AlmacenCertificados certificados,
        IProtectorDeSecretos protector, IHttpClientFactory http, ILogger<PruebaMadrugada> log)
    {
        _repo = repo;
        _admin = admin;
        _certificados = certificados;
        _protector = protector;
        _http = http;
        _log = log;
    }

    public bool Corriendo => _uno.CurrentCount == 0;

    public static DateTime AhoraLima()
    {
        TimeZoneInfo zona;
        try { zona = TimeZoneInfo.FindSystemTimeZoneById("America/Lima"); }
        catch (TimeZoneNotFoundException)
        {
            try { zona = TimeZoneInfo.FindSystemTimeZoneById("SA Pacific Standard Time"); }
            catch (TimeZoneNotFoundException) { return DateTime.UtcNow.AddHours(-5); }
        }
        return TimeZoneInfo.ConvertTimeFromUtc(DateTime.UtcNow, zona);
    }

    // =============================================================== preparar

    /// <summary>
    /// Deja lista la empresa interna. Si ya está, no hace nada. Si la empresa
    /// existe pero sin configuración (una preparación que se cortó), la reusa.
    /// </summary>
    public async Task<ConfigMadrugada> PrepararAsync(string quien, CancellationToken ct)
    {
        var cfg = await _repo.ConfigAsync(ct);
        if (cfg is not null) return cfg;

        var tenantId = await _repo.TenantPorRucAsync(RucInterno, ct)
            ?? await _admin.CrearTenantAsync(new NuevoTenant
            {
                Ruc = RucInterno,
                RazonSocial = "PRUEBA DE MADRUGADA (INTERNA)",
                NombreComercial = "PRUEBA DE MADRUGADA",
                Ubigeo = "150101",
                Direccion = "EMPRESA INTERNA DE PRUEBAS - NO FACTURA",
                Distrito = "LIMA", Provincia = "LIMA", Departamento = "LIMA",
                Ambiente = "beta", UsuarioSol = "MODDATOS", MaxConcurrencia = 1
            }, ct);

        foreach (var (tipo, serie) in new[] { ("01", "F900"), ("03", "B900"), ("07", "FC90"), ("08", "FD90") })
            await _admin.CrearSerieAsync(tenantId, tipo, serie, 0, null, quien, ct);

        // Certificado autofirmado, 10 años. Solo vale en beta, que es donde vive.
        using (var rsa = RSA.Create(2048))
        {
            var pedido = new CertificateRequest(
                $"CN=PRUEBA DE MADRUGADA, SERIALNUMBER={RucInterno}", rsa,
                HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
            using var cert = pedido.CreateSelfSigned(
                DateTimeOffset.UtcNow.AddDays(-1), DateTimeOffset.UtcNow.AddYears(10));
            await _certificados.GuardarAsync(
                tenantId, cert.Export(X509ContentType.Pfx, ClaveCertificado), ClaveCertificado, ct);
        }

        var (_, clave) = await _admin.CrearClaveAsync(tenantId, "Prueba de madrugada", ct: ct);
        await _repo.GuardarConfigAsync(tenantId, _protector.ProtegerTexto(clave), quien, ct);

        _log.LogInformation("Prueba de madrugada: empresa interna {Ruc} preparada por {Quien}.", RucInterno, quien);

        return (await _repo.ConfigAsync(ct))!;
    }

    // ================================================================= correr

    /// <summary>
    /// Una corrida completa. Devuelve null si no corrió (otra en curso, o el
    /// reloj ya corrió hoy), o el id de la corrida.
    /// </summary>
    public async Task<long?> CorrerAsync(string origen, string quien, CancellationToken ct)
    {
        if (!await _uno.WaitAsync(0, ct)) return null;

        try
        {
            if (await _repo.HayUnaEnCursoAsync(ct)) return null;

            var cfg = await PrepararAsync(quien, ct);
            var hoy = DateOnly.FromDateTime(AhoraLima());

            // Las series L900, R900 y P900 llegaron después (16 oct): a una
            // empresa interna ya preparada se le agregan aquí. Si ya existen,
            // no hace nada.
            foreach (var (tipo, serie) in CasosMadrugada.SeriesExtra)
                await _admin.CrearSerieAsync(cfg.TenantId, tipo, serie, 0, null, quien, ct);

            var pruebaId = await _repo.IniciarAsync(origen, quien, hoy, ct);
            if (pruebaId is null) return null;

            string? errorGeneral = null;

            try
            {
                await EmitirCasosAsync(pruebaId.Value, cfg, hoy, ct);
            }
            catch (Exception ex) when (ex is not OperationCanceledException)
            {
                errorGeneral = ex.Message;
                _log.LogError(ex, "Prueba de madrugada {Id}: falló.", pruebaId);
            }

            await _repo.TerminarAsync(pruebaId.Value, errorGeneral, CancellationToken.None);

            _log.LogInformation("Prueba de madrugada {Id} terminada ({Origen}, {Quien}).", pruebaId, origen, quien);

            return pruebaId;
        }
        finally
        {
            _uno.Release();
        }
    }

    private async Task EmitirCasosAsync(long pruebaId, ConfigMadrugada cfg, DateOnly hoy, CancellationToken ct)
    {
        var clave = _protector.DesprotegerTexto(cfg.ClaveCifrada);
        var cliente = _http.CreateClient("madrugada");
        var hechos = new Dictionary<string, (Guid Id, string Numero)>();
        short orden = 0;

        // La boleta de una noche anterior que se puede anular (siete días de plazo).
        if (await _repo.BoletaParaAnularAsync(pruebaId, hoy.AddDays(-6), ct) is { } anterior)
            hechos[CasosMadrugada.BoletaAnterior] = anterior;

        foreach (var caso in CasosMadrugada.Todos)
        {
            orden++;

            if (caso.EsperaAceptado && caso.Depende is not null && hechos.TryGetValue(caso.Depende, out var previo))
            {
                var estado = await EsperarDesenlaceAsync(previo.Id, TimeSpan.FromMinutes(5), ct);
                if (estado is not ("ACEPTADO" or "ACEPTADO_CON_OBSERVACIONES"))
                {
                    await _repo.RegistrarCasoAsync(pruebaId, caso.Clave, orden, null, null, null, null,
                        $"No se pudo probar: {previo.Numero} no fue aceptada a tiempo (estado {estado ?? "desconocido"}).", ct);
                    continue;
                }
            }

            var cuerpo = caso.Cuerpo(hoy, hechos);

            if (cuerpo is null)
            {
                await _repo.RegistrarCasoAsync(pruebaId, caso.Clave, orden, null, null, null, null,
                    caso.SiFalta ?? $"No se pudo probar: depende de «{caso.Depende}», que no se emitió.", ct);
                continue;
            }

            // Una ruta con {id} lleva el del documento del que depende.
            var ruta = caso.Ruta.Contains("{id}") && caso.Depende is not null
                       && hechos.TryGetValue(caso.Depende, out var base_)
                ? caso.Ruta.Replace("{id}", base_.Id.ToString())
                : caso.Ruta;

            using var pedido = new HttpRequestMessage(HttpMethod.Post, ruta)
            {
                Content = new StringContent(JsonSerializer.Serialize(cuerpo), Encoding.UTF8, "application/json")
            };
            pedido.Headers.Authorization = new AuthenticationHeaderValue("Bearer", clave);
            pedido.Headers.Add("Idempotency-Key", $"madrugada-{pruebaId}-{caso.Clave}");

            HttpResponseMessage respuesta;
            string texto;

            try
            {
                respuesta = await cliente.SendAsync(pedido, ct);
                texto = await respuesta.Content.ReadAsStringAsync(ct);
            }
            catch (HttpRequestException ex)
            {
                // No llegamos a nuestra propia API: no es SUNAT. Se anota y se sigue.
                await _repo.RegistrarCasoAsync(pruebaId, caso.Clave, orden, null, null, null,
                    $"No se pudo llamar a la API: {ex.Message}", null, ct);
                continue;
            }

            if (!respuesta.IsSuccessStatusCode)
            {
                await _repo.RegistrarCasoAsync(pruebaId, caso.Clave, orden, null, null, null,
                    $"La API respondió {(int)respuesta.StatusCode}: {Recortar(texto, 600)}", null, ct);
                continue;
            }

            using var json = JsonDocument.Parse(texto);
            var raiz = json.RootElement;
            var id = raiz.GetProperty("id").GetGuid();
            var numero = raiz.TryGetProperty("numero", out var n) ? n.GetString()
                       : raiz.TryGetProperty("identificador", out var i) ? i.GetString() : null;

            var esBaja = caso.Ruta.StartsWith("/v1/bajas", StringComparison.Ordinal);

            await _repo.RegistrarCasoAsync(pruebaId, caso.Clave, orden,
                esBaja ? null : id, esBaja ? id : null, numero, null, null, ct);

            if (!esBaja && numero is not null) hechos[caso.Clave] = (id, numero);
        }
    }

    private async Task<string?> EsperarDesenlaceAsync(Guid comprobanteId, TimeSpan tope, CancellationToken ct)
    {
        var hasta = DateTime.UtcNow + tope;
        string? estado = null;

        while (DateTime.UtcNow < hasta)
        {
            estado = await _repo.EstadoComprobanteAsync(comprobanteId, ct);
            if (estado is "ACEPTADO" or "ACEPTADO_CON_OBSERVACIONES" or "RECHAZADO" or "ANULADO") return estado;
            await Task.Delay(TimeSpan.FromSeconds(10), ct);
        }

        return estado;
    }

    // =============================================================== comparar

    /// <summary>
    /// Compara cada caso que ya tiene desenlace con el de la noche anterior y
    /// crea una alerta solo si cambió. Lo llama la vigilancia cada 5 minutos.
    /// </summary>
    public async Task<int> EvaluarAsync(CancellationToken ct)
    {
        var alertas = 0;

        foreach (var caso in await _repo.SinCompararAsync(ct))
        {
            var estado = caso.Estado;
            if (estado == "pend") continue;

            var nombre = CasosMadrugada.Todos.FirstOrDefault(c => c.Clave == caso.Caso)?.Nombre ?? caso.Caso;
            var mensaje = caso.ErrorApi ?? caso.MensajeDoc ?? caso.MensajeCaso;

            if (estado == "caida")
            {
                await _repo.MarcarComparadoAsync(caso.Id, "caida", null, mensaje, "sin respuesta", ct);
                continue;
            }

            var anterior = await _repo.AnteriorAsync(caso.Caso, caso.PruebaId, ct);
            var codigo = caso.Codigo;
            var (cambio, gravedad, titulo) = Comparar(nombre, estado, codigo, anterior?.Estado, anterior?.Codigo);

            if (titulo is not null)
            {
                var detalle =
                    $"Caso: {nombre}\n" +
                    $"Antes ({anterior?.Cuando:yyyy-MM-dd}): {Texto(anterior?.Estado)}{(anterior?.Codigo is { } ca ? $", código {ca}" : "")}" +
                    $"{(anterior?.Numero is { } na ? $" · {na}" : "")}\n" +
                    $"Ahora: {Texto(estado)}{(codigo is not null ? $", código {codigo}" : "")}" +
                    $"{(caso.Numero is { } nn ? $" · {nn}" : "")}\n" +
                    $"Qué dijo: {mensaje ?? "—"}";

                await _repo.CrearAlertaAsync("prueba_cambio", gravedad!, titulo, detalle, ct);
                alertas++;
            }

            await _repo.MarcarComparadoAsync(caso.Id, estado, codigo, mensaje, cambio, ct);
        }

        if (await _repo.BetaCaidaSinAvisarAsync(ct))
        {
            await _repo.CrearAlertaAsync("beta_caida", "atencion",
                "SUNAT beta no responde desde hace tres pruebas",
                "Las tres últimas pruebas de madrugada no recibieron respuesta de SUNAT beta. " +
                "Así la prueba no puede detectar cambios de reglas. Suele ser una caída de SUNAT; " +
                "si sigue varios días, revisa la conexión del servicio.", ct);
            alertas++;
        }

        return alertas;
    }

    /// <summary>Qué cambió, y si amerita alerta (título) o no (null).</summary>
    public static (string Cambio, string? Gravedad, string? Titulo) Comparar(
        string nombre, string ahora, string? codigo, string? antes, string? codigoAntes)
    {
        static bool Pasa(string? e) => e is "ok" or "obs";
        static bool Falla(string? e) => e is "mal" or "error_api";

        if (antes is null) return ("primera vez", null, null);

        if (Pasa(antes) && ahora == "mal")
            return ("ahora rechaza", "problema", $"Prueba de madrugada: SUNAT ahora rechaza «{nombre}»");

        if (Pasa(antes) && ahora == "error_api")
            return ("nuestra API falla", "problema", $"Prueba de madrugada: nuestra API ya no acepta «{nombre}»");

        if (Falla(antes) && Pasa(ahora))
            return ("ya funciona", "atencion", $"Prueba de madrugada: «{nombre}» ya funciona (antes fallaba)");

        if (ahora == "mal" && antes == "mal" && codigo != codigoAntes)
            return ("otro rechazo", "problema", $"Prueba de madrugada: «{nombre}» se rechaza por otro motivo");

        if (ahora == "obs" && (antes == "ok" || codigo != codigoAntes))
            return ("nueva observación", "atencion", $"Prueba de madrugada: «{nombre}» trae una observación nueva");

        return ("igual", null, null);
    }

    private static string Texto(string? e) => e switch
    {
        "ok" => "aceptado", "obs" => "aceptado con observaciones", "mal" => "rechazado",
        "error_api" => "nuestra API no lo aceptó", null => "—", _ => e
    };

    private static string Recortar(string t, int n) => t.Length <= n ? t : t[..n] + "…";
}

/// <summary>
/// El reloj de la prueba: una vez al día, a partir de la hora de Lima que diga
/// PRUEBA_MADRUGADA_HORA (por defecto 03:00). Si la API estaba apagada a esa
/// hora, corre en cuanto arranque ese mismo día. PRUEBA_MADRUGADA_ACTIVA=false
/// la apaga.
/// </summary>
public sealed class ServicioMadrugada : BackgroundService
{
    private readonly PruebaMadrugada _prueba;
    private readonly RepositorioMadrugada _repo;
    private readonly ILogger<ServicioMadrugada> _log;
    private readonly TimeSpan _hora;
    private readonly bool _activa;

    public ServicioMadrugada(PruebaMadrugada prueba, RepositorioMadrugada repo, ILogger<ServicioMadrugada> log)
    {
        _prueba = prueba;
        _repo = repo;
        _log = log;
        _hora = TimeSpan.TryParse(ConfiguracionSecretos.Opcional("PRUEBA_MADRUGADA_HORA", "03:00"), out var h)
            ? h : new TimeSpan(3, 0, 0);
        _activa = !ConfiguracionSecretos.Opcional("PRUEBA_MADRUGADA_ACTIVA", "true")
            .Equals("false", StringComparison.OrdinalIgnoreCase);
    }

    public TimeSpan Hora => _hora;

    protected override async Task ExecuteAsync(CancellationToken ct)
    {
        if (!_activa)
        {
            _log.LogInformation("Prueba de madrugada apagada (PRUEBA_MADRUGADA_ACTIVA=false).");
            return;
        }

        try { await Task.Delay(TimeSpan.FromMinutes(2), ct); }
        catch (OperationCanceledException) { return; }

        _log.LogInformation("Prueba de madrugada: todos los días desde las {Hora} (hora de Lima).", _hora);

        while (!ct.IsCancellationRequested)
        {
            try
            {
                var ahora = PruebaMadrugada.AhoraLima();
                if (ahora.TimeOfDay >= _hora && !await _repo.RelojYaCorrioAsync(DateOnly.FromDateTime(ahora), ct))
                    await _prueba.CorrerAsync("reloj", "reloj de las " + _hora.ToString(@"hh\:mm"), ct);
            }
            catch (OperationCanceledException) when (ct.IsCancellationRequested) { break; }
            catch (Npgsql.PostgresException ex) when (ex.SqlState == "42P01")
            {
                _log.LogWarning("Prueba de madrugada apagada: falta aplicar la migración 030 ({Mensaje}).", ex.MessageText);
                return;
            }
            catch (Exception ex)
            {
                _log.LogError(ex, "Falló el reloj de la prueba de madrugada. Se reintenta en un minuto.");
            }

            try { await Task.Delay(TimeSpan.FromMinutes(1), ct); }
            catch (OperationCanceledException) { break; }
        }
    }
}