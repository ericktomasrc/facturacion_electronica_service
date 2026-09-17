using System.Text.Json;
using Facturacion.Cpe;
using Facturacion.Pdf;
using Facturacion.Persistencia;

namespace Facturacion.Api;

/// <summary>
/// Búsqueda de comprobantes desde el panel de operación.
///
/// POR QUÉ NO BASTA CON LA API DE LOS EMISORES:
///
/// Los endpoints de /v1 trabajan siempre dentro de un tenant, así que para
/// consultar un comprobante hay que tener la clave de ese cliente. Cuando
/// alguien llama a soporte preguntando por una factura, no siempre se sabe
/// de qué empresa es, y desde luego no se le va a pedir su clave.
///
/// Estos endpoints ven todas las empresas y se protegen con la clave del
/// operador, que es distinta y da acceso a todo.
/// </summary>
public static class EndpointsConsulta
{
    private static readonly JsonSerializerOptions OpcionesJson = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        PropertyNameCaseInsensitive = true
    };

    public static void MapearConsultas(this WebApplication app)
    {
        var grupo = app.MapGroup("/admin/comprobantes")
            .AddEndpointFilter<AutenticacionPanel>()
            .AddEndpointFilter(new ExigirPermiso(Permiso.ComprobantesVer))
            .WithTags("Consulta de comprobantes");

        grupo.MapGet("", async (
            RepositorioConsultas consultas,
            string? texto, Guid? tenantId, string? tipo, string? estado,
            DateTime? desde, DateTime? hasta,
            int? pagina, int? porPagina,
            CancellationToken ct) =>
        {
            var filtro = new FiltroComprobantes
            {
                Texto = texto,
                TenantId = tenantId,
                TipoComprobante = tipo,
                Estado = estado,
                Desde = desde,
                Hasta = hasta,
                Pagina = pagina ?? 1,
                PorPagina = porPagina ?? 25
            };

            return Results.Ok(await consultas.BuscarAsync(filtro, ct));
        })
        .WithSummary("Busca comprobantes de todas las empresas")
        .WithDescription(
            "El parámetro 'texto' busca a la vez en RUC, razón social del " +
            "emisor, número de comprobante y datos del receptor.\\n\\n" +
            "Quien da soporte tiene en la cabeza un dato, no un campo: puede " +
            "ser el RUC, el nombre de la empresa o el número de la factura.");

        // ------------------------------------------------------------ guías

        grupo.MapGet("/guias", async (
            RepositorioConsultas consultas,
            string? texto, Guid? tenantId, string? estado,
            DateTime? desde, DateTime? hasta,
            int? pagina, int? porPagina,
            CancellationToken ct) =>
        {
            var filtro = new FiltroComprobantes
            {
                Texto = texto,
                TenantId = tenantId,
                Estado = estado,
                Desde = desde,
                Hasta = hasta,
                Pagina = pagina ?? 1,
                PorPagina = porPagina ?? 25
            };

            return Results.Ok(await consultas.BuscarGuiasAsync(filtro, ct));
        })
        .WithSummary("Busca guías de remisión de todas las empresas")
        .WithDescription(
            "El parámetro 'texto' busca a la vez en RUC, razón social, número " +
            "de guía, destinatario y PLACA del vehículo.\n\n" +
            "La placa importa: cuando llaman desde una fiscalización en " +
            "carretera, es el único dato que tiene quien pregunta.");

        grupo.MapGet("/guias/{id:guid}/xml", (
            Guid id, RepositorioConsultas consultas, IAlmacenArchivos archivos,
            CancellationToken ct) =>
            DescargarGuiaAsync(id, "xml", consultas, archivos, ct))
            .WithSummary("Descarga el XML de una guía");

        grupo.MapGet("/guias/{id:guid}/cdr", (
            Guid id, RepositorioConsultas consultas, IAlmacenArchivos archivos,
            CancellationToken ct) =>
            DescargarGuiaAsync(id, "cdr", consultas, archivos, ct))
            .WithSummary("Descarga la constancia de una guía");

        grupo.MapGet("/{id:guid}/historial", async (
            Guid id, RepositorioConsultas consultas, CancellationToken ct) =>
        {
            var historial = await consultas.HistorialAsync(id, ct);

            return historial.Count == 0
                ? Results.NotFound(new RespuestaError(
                    "No se encontró el comprobante, o no tiene historial."))
                : Results.Ok(historial.Select(i => new
                {
                    intento = i.IntentoNro,
                    desde = i.EstadoAnterior,
                    hasta = i.EstadoNuevo,
                    codigoSunat = i.CodigoSunat,
                    mensaje = i.Mensaje,
                    duracionMs = i.DuracionMs,
                    worker = i.Worker,
                    fecha = i.CreadoEn
                }));
        })
        .WithSummary("Bitácora completa de un comprobante")
        .WithDescription(
            "Cada cambio de estado, con el código de SUNAT, el mensaje exacto " +
            "y cuánto tardó. Es lo que permite explicar qué pasó con una " +
            "factura de hace tres meses.");

        grupo.MapGet("/{id:guid}/xml", (
            Guid id, RepositorioConsultas consultas, IAlmacenArchivos archivos,
            CancellationToken ct) =>
            DescargarAsync(id, "xml", consultas, archivos, ct))
            .WithSummary("Descarga el XML firmado");

        grupo.MapGet("/{id:guid}/cdr", (
            Guid id, RepositorioConsultas consultas, IAlmacenArchivos archivos,
            CancellationToken ct) =>
            DescargarAsync(id, "cdr", consultas, archivos, ct))
            .WithSummary("Descarga el CDR");

        grupo.MapGet("/{id:guid}/pdf", async (
            Guid id,
            RepositorioConsultas consultas,
            RepositorioComprobantes comprobantes,
            IAlmacenArchivos archivos,
            CancellationToken ct) =>
        {
            // Primero se averigua de qué empresa es, porque el repositorio de
            // comprobantes necesita el tenant para abrir la sesión.
            var ubicacion = await consultas.RutaArchivoAsync(id, "xml", ct);

            if (ubicacion is null)
                return Results.NotFound(new RespuestaError("No se encontró el comprobante."));

            var datos = await comprobantes.ObtenerParaPdfAsync(
                ubicacion.Value.TenantId, id, ct);

            if (datos is null)
                return Results.NotFound(new RespuestaError("No se encontró el comprobante."));

            if (datos.Estado == "BORRADOR")
                return Results.NotFound(new RespuestaError(
                    "Todavía no se puede generar el PDF.",
                    "El comprobante está en BORRADOR: aún no se firmó ni se envió."));

            ComprobanteBase comprobante;

            try
            {
                comprobante = Deserializar(datos);
            }
            catch (Exception ex)
            {
                return Results.Problem(
                    detail: $"No se pudo reconstruir el comprobante: {ex.Message}",
                    statusCode: StatusCodes.Status500InternalServerError,
                    title: "Comprobante ilegible");
            }

            string? digest = null;

            if (!string.IsNullOrWhiteSpace(datos.RutaXml))
            {
                var xml = await archivos.LeerAsync(datos.RutaXml, ct);

                if (xml is not null)
                {
                    try
                    {
                        digest = CodigoQr.LeerDigest(System.Xml.Linq.XDocument.Parse(
                            System.Text.Encoding.UTF8.GetString(xml)));
                    }
                    catch (Exception) { /* sin digest el PDF se genera igual */ }
                }
            }

            var pdf = GeneradorPdf.Generar(comprobante, digest,
                new OpcionesImpresion(
                    EstadoSunat: TextoEstado(datos.Estado),
                    MensajeSunat: datos.MensajeSunat));

            return Results.File(pdf, "application/pdf", $"{datos.Numero}.pdf");
        })
        .WithSummary("Genera la representación impresa");
    }

    private static async Task<IResult> DescargarGuiaAsync(
        Guid id, string tipo,
        RepositorioConsultas consultas, IAlmacenArchivos archivos,
        CancellationToken ct)
    {
        var ubicacion = await consultas.RutaArchivoGuiaAsync(id, tipo, ct);

        if (ubicacion is null)
            return Results.NotFound(new RespuestaError("No se encontró la guía."));

        if (string.IsNullOrWhiteSpace(ubicacion.Value.Ruta))
        {
            return Results.NotFound(new RespuestaError(
                "Archivo no disponible.",
                tipo == "xml"
                    ? "La guía todavía no se firmó."
                    : "La constancia solo existe cuando SUNAT ya respondió."));
        }

        var contenido = await archivos.LeerAsync(ubicacion.Value.Ruta!, ct);

        if (contenido is null)
        {
            return Results.Problem(
                detail: $"La base registra el archivo en " +
                        $"'{ubicacion.Value.Ruta}' pero el almacén no lo tiene.",
                statusCode: StatusCodes.Status500InternalServerError,
                title: "Archivo registrado pero ausente");
        }

        var (mime, extension) = tipo == "xml"
            ? ("application/xml", "xml")
            : ("application/zip", "zip");

        return Results.File(contenido, mime,
            $"{ubicacion.Value.Numero}.{extension}");
    }

    private static async Task<IResult> DescargarAsync(
        Guid id, string tipo,
        RepositorioConsultas consultas, IAlmacenArchivos archivos,
        CancellationToken ct)
    {
        var ubicacion = await consultas.RutaArchivoAsync(id, tipo, ct);

        if (ubicacion is null)
            return Results.NotFound(new RespuestaError("No se encontró el comprobante."));

        if (string.IsNullOrWhiteSpace(ubicacion.Value.Ruta))
        {
            return Results.NotFound(new RespuestaError(
                "Archivo no disponible.",
                tipo == "xml"
                    ? "El comprobante todavía no se firmó."
                    : "El CDR solo existe cuando SUNAT ya respondió."));
        }

        var contenido = await archivos.LeerAsync(ubicacion.Value.Ruta!, ct);

        if (contenido is null)
        {
            return Results.Problem(
                detail:
                    $"La base registra el archivo en '{ubicacion.Value.Ruta}' " +
                    "pero el almacén no lo tiene.",
                statusCode: StatusCodes.Status500InternalServerError,
                title: "Archivo registrado pero ausente");
        }

        var (mime, extension) = tipo == "xml"
            ? ("application/xml", "xml")
            : ("application/zip", "zip");

        return Results.File(contenido, mime,
            $"{ubicacion.Value.Numero}.{extension}");
    }

    private static string TextoEstado(string estado) => estado switch
    {
        "ACEPTADO" => "Aceptado por SUNAT",
        "ACEPTADO_CON_OBSERVACIONES" => "Aceptado con observaciones",
        "RECHAZADO" => "Rechazado por SUNAT",
        "ANULADO" => "Dado de baja",
        _ => "Pendiente de envío"
    };

    private static ComprobanteBase Deserializar(DatosParaPdf datos) =>
        datos.TipoComprobante switch
        {
            TipoComprobante.Factura =>
                JsonSerializer.Deserialize<Factura>(datos.CpeJson, OpcionesJson)!,
            TipoComprobante.Boleta =>
                JsonSerializer.Deserialize<Boleta>(datos.CpeJson, OpcionesJson)!,
            TipoComprobante.NotaCredito =>
                JsonSerializer.Deserialize<NotaCredito>(datos.CpeJson, OpcionesJson)!,
            TipoComprobante.NotaDebito =>
                JsonSerializer.Deserialize<NotaDebito>(datos.CpeJson, OpcionesJson)!,
            _ => throw new InvalidOperationException(
                $"Tipo de comprobante no soportado: {datos.TipoComprobante}")
        };
}
