using Facturacion.Cpe;
using Facturacion.Persistencia;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;

namespace Facturacion.Worker;

/// <summary>
/// Envía las comunicaciones de baja y los resúmenes de reversiones, y
/// consulta su desenlace.
///
/// LOS DOS POR EL MISMO SITIO porque son el mismo documento: RA para
/// facturas y notas, RR para retenciones y percepciones. Comparten esquema,
/// servicio y ciclo de ticket, y el único sitio donde se distinguen es el
/// campo `Tipo` que se copia desde la base al armar el XML.
///
/// DOS TIEMPOS, NO TRES. El resumen diario tiene un paso previo de agrupar,
/// porque nadie pide un resumen: lo arma el worker buscando boletas de un día
/// ya cerrado. Una baja sí la pide alguien, y llega a esta clase ya creada
/// por el endpoint. Aquí solo queda:
///
///   1. Enviar: generar el XML, firmarlo y mandarlo con sendSummary.
///      SUNAT devuelve un TICKET, no un CDR.
///
///   2. Consultar: más tarde se pregunta por ese ticket, y ahí SUNAT dice
///      si acepta la baja.
///
/// Es el mismo servicio de SUNAT que el resumen, con otro documento dentro.
///
///
/// LO QUE PASA AL FINAL NO ES LO MISMO, y es la razón de que esta clase no
/// sea ProcesadorResumenes:
///
///   Un resumen aceptado deja sus boletas ACEPTADAS: quedan comunicadas.
///   Una baja aceptada deja sus comprobantes ANULADOS: dejan de existir.
///
/// El repositorio se encarga de esa diferencia; aquí solo se le dice cómo
/// terminó.
/// </summary>
public sealed class ProcesadorBajas
{
    private readonly RepositorioBajas _bajas;
    private readonly ColaTrabajos _cola;
    private readonly AlmacenCertificados _certificados;
    private readonly ProveedorCredenciales _credenciales;
    private readonly IAlmacenArchivos _archivos;
    private readonly RepositorioXsd _xsd;
    private readonly ILogger<ProcesadorBajas> _log;

    public ProcesadorBajas(
        RepositorioBajas bajas,
        ColaTrabajos cola,
        AlmacenCertificados certificados,
        ProveedorCredenciales credenciales,
        IAlmacenArchivos archivos,
        RepositorioXsd xsd,
        ILogger<ProcesadorBajas> log)
    {
        _xsd = xsd;
        _bajas = bajas;
        _cola = cola;
        _certificados = certificados;
        _credenciales = credenciales;
        _archivos = archivos;
        _log = log;
    }

    // -------------------------------------------------------- 1. enviar

    public async Task EnviarPendientesAsync(CancellationToken ct)
    {
        foreach (var baja in await _bajas.BuscarPorEnviarAsync(ct: ct))
        {
            try { await EnviarAsync(baja, ct); }
            catch (Exception ex)
            {
                _log.LogError(ex, "Falló el envío de {Id}", baja.Identificador);

                await _bajas.ProgramarReintentoAsync(
                    baja.Id,
                    EsperaReintento.Calcular(baja.IntentosFallidos),
                    ex.Message, ct);
            }
        }
    }

    private async Task EnviarAsync(ResumenGuardado baja, CancellationToken ct)
    {
        var tenant = await _cola.ObtenerTenantAsync(baja.TenantId, ct)
            ?? throw new InvalidOperationException("El emisor ya no existe.");

        var comprobantes = await _bajas.ComprobantesDeAsync(baja.Id, ct);

        if (comprobantes.Count == 0)
            throw new InvalidOperationException(
                "La comunicacion no tiene comprobantes asignados.");

        using var certificado = await _certificados.ObtenerActivoAsync(
                baja.TenantId, ct)
            ?? throw new InvalidOperationException(
                "El emisor no tiene certificado activo.");

        // --- Reconstruir el documento ---
        //
        // Se arma desde la base, no desde lo que trajo el POST: entre que se
        // pidió la baja y este momento pudo pasar un día entero, y lo que
        // vale es lo que está guardado.

        var documento = new ComunicacionBaja
        {
            Emisor = ArmarEmisor(tenant),

            // EL TIPO SALE DE LA BASE, no se asume. Es lo único que
            // distingue una comunicación de baja de un resumen de
            // reversiones, y ponerlo a mano aquí haría que una reversión
            // viajara con identificador RA y SUNAT la rechazara sin decir
            // por qué.
            Tipo = baja.Tipo,

            FechaReferencia = baja.FechaReferencia,
            FechaGeneracion = baja.FechaGeneracion,
            Correlativo = baja.Correlativo,
            Lineas = comprobantes.Select((c, indice) => new LineaBaja
            {
                Orden = indice + 1,
                TipoComprobante = c.TipoComprobante,
                Serie = c.Serie,
                Numero = c.Correlativo,
                Motivo = c.Motivo
            }).ToList()
        };

        // EL PLAZO SE VUELVE A MIRAR AQUÍ, y no es redundante.
        //
        // El endpoint lo comprobó cuando se pidió la baja. Si el envío falló
        // varias veces y los reintentos se estiraron, la comunicación puede
        // haber cruzado los siete días mientras esperaba. Enviarla entonces
        // solo sirve para gastar un viaje y volver con el 2957.
        var avisos = ReglasBaja.Avisos(documento);

        foreach (var aviso in avisos)
            _log.LogWarning("{Id}: {Aviso}", baja.Identificador, aviso);

        // --- Firmar y guardar ---

        var xml = GeneradorBajaXml.Generar(documento);
        var firmado = FirmadorXml.Firmar(xml, certificado);
        var bytes = SerializarSinBom(firmado);

        // 033: se compara con su molde (UBL-VoidedDocuments). SOLO AVISA: la
        // baja tiene siete días contados y no se para por esto.
        await RevisionXsdWorker.RevisarYAnotarAsync(
            _xsd, _log, baja.TenantId, tenant.Ruc, baja.Identificador, bytes, ct);

        var rutaXml = await _archivos.GuardarAsync(
            tenant.Ruc, documento.FechaGeneracion,
            $"{documento.NombreArchivo}.xml", bytes, ct);

        // --- Enviar ---
        //
        // EnviarResumenAsync es sendSummary, que es el mismo servicio que
        // recibe las comunicaciones de baja. El nombre del método habla del
        // primer uso que tuvo, no de lo único que hace.

        var zip = EmpaquetadorZip.Comprimir(documento.NombreArchivo, bytes);

        // EL RR NO VA POR EL SERVICIO DE FACTURAS, y esto costó un rechazo.
        //
        // SUNAT no tiene un billService: tiene varios, y cada uno solo acepta
        // ciertos documentos. Las retenciones y percepciones viajan por el de
        // "otros CPE", y el resumen que las revierte, también.
        //
        // Mandarlo al de facturas devuelve un 0151 que habla del nombre del
        // archivo ZIP:
        //
        //     Error de nombre archivo "20601234565-RR-20260921-1.zip
        //     codigo cpe: RR" no es un cpe valido
        //
        // El nombre está perfecto. Lo que pasa es que ese servicio no sabe
        // qué es un RR. Es el mismo 0151 que dio la retención en su día, y
        // por el mismo motivo.
        //
        // La comunicación de baja (RA) sí va por el de facturas, porque los
        // documentos que anula son facturas.
        var configuracion = (await _credenciales.ObtenerAsync(baja.TenantId, ct))
            .ParaTipo(baja.Tipo == TipoComunicacionBaja.Reversion
                ? ComprobanteRetencion.Tipo
                : TipoComprobante.Factura);

        using var enviador = new EnviadorSunatSoap(configuracion);

        var envio = await enviador.EnviarResumenAsync(
            $"{documento.NombreArchivo}.zip", zip, ct);

        if (!envio.Exitoso)
        {
            await _bajas.ProgramarReintentoAsync(
                baja.Id,
                EsperaReintento.Calcular(baja.IntentosFallidos),
                envio.Mensaje, ct);

            _log.LogWarning("{Id} no se pudo enviar: {Mensaje}",
                baja.Identificador, envio.Mensaje);

            return;
        }

        await _bajas.RegistrarTicketAsync(baja.Id, envio.Ticket, rutaXml, ct);

        _log.LogInformation(
            "{Id} ({Que}) enviada con {Cantidad} comprobante(s). Ticket {Ticket}.",
            baja.Identificador, TipoComunicacionBaja.Nombre(baja.Tipo),
            comprobantes.Count, envio.Ticket);
    }

    // ----------------------------------------------------- 2. consultar

    public async Task ConsultarTicketsAsync(CancellationToken ct)
    {
        foreach (var baja in await _bajas.BuscarTicketsPendientesAsync(ct: ct))
        {
            try { await ConsultarAsync(baja, ct); }
            catch (Exception ex)
            {
                _log.LogError(ex, "Falló la consulta de {Id}", baja.Identificador);

                await _bajas.ProgramarReintentoAsync(
                    baja.Id,
                    EsperaReintento.Calcular(baja.IntentosFallidos),
                    ex.Message, ct);
            }
        }
    }

    private async Task ConsultarAsync(ResumenGuardado baja, CancellationToken ct)
    {
        var tenant = await _cola.ObtenerTenantAsync(baja.TenantId, ct)
            ?? throw new InvalidOperationException("El emisor ya no existe.");

        // EL MISMO SERVICIO QUE SE USO PARA ENVIAR, y no es un detalle: el
        // ticket lo emitió uno de los dos y el otro no sabe nada de él.
        var configuracion = (await _credenciales.ObtenerAsync(baja.TenantId, ct))
            .ParaTipo(baja.Tipo == TipoComunicacionBaja.Reversion
                ? ComprobanteRetencion.Tipo
                : TipoComprobante.Factura);

        using var enviador = new EnviadorSunatSoap(configuracion);

        var resultado = await enviador.ConsultarTicketAsync(baja.Ticket!, ct);

        // 98 significa que SUNAT sigue procesando. No es un fallo: se vuelve
        // a preguntar más tarde, sin gastar un intento.
        if (resultado.CodigoRespuesta == "98")
        {
            await _bajas.ProgramarReintentoAsync(
                baja.Id, TimeSpan.FromMinutes(2),
                "SUNAT sigue procesando la comunicacion.", ct);

            return;
        }

        if (resultado.EsReintentable)
        {
            await _bajas.ProgramarReintentoAsync(
                baja.Id,
                EsperaReintento.Calcular(baja.IntentosFallidos),
                resultado.Descripcion, ct);

            return;
        }

        // --- Desenlace ---

        string? rutaCdr = null;

        if (resultado.CdrZip is not null)
        {
            rutaCdr = await _archivos.GuardarAsync(
                tenant.Ruc,
                baja.FechaGeneracion,
                $"R-{tenant.Ruc}-{baja.Identificador}.zip",
                resultado.CdrZip, ct);
        }

        var estado = resultado.Aceptado
            ? (resultado.Observaciones.Count > 0
                ? EstadoResumenCpe.ConObservaciones
                : EstadoResumenCpe.Aceptado)
            : EstadoResumenCpe.Rechazado;

        var observaciones = resultado.Observaciones.Count == 0
            ? ""
            : " Observaciones: " + string.Join(" | ", resultado.Observaciones);

        await _bajas.CerrarAsync(
            baja.Id, estado, resultado.CodigoRespuesta,
            resultado.Descripcion + observaciones, rutaCdr, ct);

        if (resultado.Aceptado)
        {
            _log.LogInformation(
                "{Id} aceptada. {Cantidad} comprobante(s) ANULADOS.",
                baja.Identificador, baja.Comprobantes);
        }
        else
        {
            // SE DICE EXPLÍCITAMENTE QUE SIGUEN VÁLIDOS.
            //
            // Quien lee este log a las tres de la mañana necesita saber que
            // no tiene un agujero contable: la baja falló, las facturas
            // siguen ahí, y se puede volver a intentar dentro del plazo.
            _log.LogWarning(
                "{Id} RECHAZADA. Código {Codigo}: {Mensaje}. " +
                "Sus {Cantidad} comprobante(s) SIGUEN VÁLIDOS y se puede " +
                "reintentar mientras no pasen los siete días.",
                baja.Identificador, resultado.CodigoRespuesta,
                resultado.Descripcion, baja.Comprobantes);
        }
    }

    // ------------------------------------------------------------ apoyo

    private static Emisor ArmarEmisor(TenantResuelto t) => new()
    {
        Ruc = t.Ruc,
        RazonSocial = t.RazonSocial,
        NombreComercial = t.NombreComercial,
        Ubigeo = t.Ubigeo,
        Direccion = t.Direccion,
        Distrito = t.Distrito,
        Provincia = t.Provincia,
        Departamento = t.Departamento
    };

    private static byte[] SerializarSinBom(System.Xml.XmlDocument doc)
    {
        using var memoria = new MemoryStream();

        var configuracion = new System.Xml.XmlWriterSettings
        {
            Encoding = new System.Text.UTF8Encoding(false),
            Indent = false,
            OmitXmlDeclaration = false,
            NewLineHandling = System.Xml.NewLineHandling.None
        };

        using (var writer = System.Xml.XmlWriter.Create(memoria, configuracion))
            doc.Save(writer);

        return memoria.ToArray();
    }
}

/// <summary>
/// Ejecuta el ciclo de bajas en segundo plano.
///
/// CORRE MÁS RÁPIDO QUE EL DE RESÚMENES, y con motivo: un resumen se arma
/// una vez al día y no corre prisa, mientras que quien pide una baja está
/// esperando a que su factura desaparezca, y encima tiene siete días
/// contados. Medio minuto es un buen término entre no hacer esperar y no
/// martillear un servicio que limita la tasa.
/// </summary>
public sealed class ServicioBajas : BackgroundService
{
    private readonly ProcesadorBajas _procesador;
    private readonly ILogger<ServicioBajas> _log;
    private readonly TimeSpan _intervalo;

    public ServicioBajas(
        ProcesadorBajas procesador,
        ILogger<ServicioBajas> log,
        TimeSpan? intervalo = null)
    {
        _procesador = procesador;
        _log = log;
        _intervalo = intervalo ?? TimeSpan.FromSeconds(30);
    }

    protected override async Task ExecuteAsync(CancellationToken ct)
    {
        _log.LogInformation(
            "Servicio de bajas iniciado. Ciclo cada {Intervalo}.", _intervalo);

        while (!ct.IsCancellationRequested)
        {
            try
            {
                await _procesador.EnviarPendientesAsync(ct);
                await _procesador.ConsultarTicketsAsync(ct);
            }
            catch (OperationCanceledException) when (ct.IsCancellationRequested)
            {
                break;
            }
            catch (Exception ex)
            {
                // El ciclo nunca muere por un error. Si muriera, las bajas
                // dejarían de enviarse en silencio y nadie se enteraría
                // hasta que venciera el plazo de siete días.
                _log.LogError(ex, "Error en el ciclo de bajas. Se reintenta.");
            }

            await Task.Delay(_intervalo, ct);
        }

        _log.LogInformation("Servicio de bajas detenido.");
    }
}