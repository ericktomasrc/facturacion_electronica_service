using Facturacion.Cpe;
using Facturacion.Persistencia;

namespace Facturacion.Api;

/// <summary>
/// Emisión y consulta de guías de remisión.
///
/// Mismo patrón que los comprobantes: la API responde 202 y encola, el worker
/// hace el trabajo. Pero con una diferencia que conviene decirle al cliente
/// bien claro:
///
/// LA GUÍA NO SIRVE HASTA QUE SUNAT LA ACEPTA. Una factura se puede entregar
/// mientras se envía; una guía no, porque es lo que sustenta el traslado
/// ante una fiscalización en carretera. El vehículo no debe salir hasta que
/// el estado sea ACEPTADO.
/// </summary>
public static class EndpointsGuias
{
    public static void MapearGuias(this WebApplication app)
    {
        var grupo = app.MapGroup("/v1/guias")
            .WithTags("Guías de remisión");

        // ------------------------------------------------------------ alta

        grupo.MapPost("", async (
            PeticionGuia peticion,
            HttpContext http,
            ContextoEmisor emisor,
            RepositorioGuias guias,
            CancellationToken ct) =>
        {
            var tenant = emisor.Exigir();

            GuiaRemision guia;

            try
            {
                guia = ArmarGuia(peticion, tenant);
            }
            catch (Exception ex)
            {
                return Results.BadRequest(new RespuestaError(
                    "Los datos de la guía no son válidos.", ex.Message));
            }

            // Se revisa ANTES de guardar.
            //
            // Sin esto, una guía con un dato mal consumiría un correlativo
            // que no se puede recuperar, y el cliente tendría un hueco en su
            // numeración por un error suyo de tecleo.
            var problemas = guia.Revisar();

            if (problemas.Count > 0)
            {
                return Results.BadRequest(new RespuestaError(
                    "La guía tiene problemas que SUNAT rechazaría.",
                    string.Join(" ", problemas)));
            }

            var clave = http.Request.Headers["Idempotency-Key"].ToString();

            try
            {
                var guardada = await guias.CrearAsync(
                    tenant.Id, guia,
                    string.IsNullOrWhiteSpace(clave) ? null : clave,
                    peticion.Extra, ct);

                return Results.Accepted($"/v1/guias/{guardada.Id}", new
                {
                    id = guardada.Id,
                    numero = guardada.Numero,
                    estado = guardada.Estado,
                    duplicado = guardada.Duplicada,

                    aviso =
                        "La guía se está enviando a SUNAT. NO INICIES EL " +
                        "TRASLADO hasta que el estado sea ACEPTADO: la " +
                        "constancia aceptada es lo que sustenta el traslado " +
                        "ante una fiscalización."
                });
            }
            catch (InvalidOperationException ex)
            {
                return Results.BadRequest(new RespuestaError(
                    "No se pudo emitir la guía.", ex.Message));
            }
        })
        .WithSummary("Emite una guía de remisión del remitente")
        .WithDescription(
            "Responde 202 y encola. El estado se consulta en " +
            "/v1/guias/{id}.\n\n" +
            "**El vehículo no debe salir hasta que el estado sea ACEPTADO.** " +
            "A diferencia de una factura, la guía es lo que sustenta el " +
            "traslado ante una fiscalización en carretera.\n\n" +
            "Envía una cabecera `Idempotency-Key` para poder reintentar sin " +
            "riesgo de emitir dos guías para el mismo traslado.");

        // -------------------------------------------------------- consulta

        grupo.MapGet("/{id:guid}", async (
            Guid id, ContextoEmisor emisor,
            RepositorioGuias guias, CancellationToken ct) =>
        {
            var guardada = await guias.ObtenerAsync(emisor.Exigir().Id, id, ct);

            if (guardada is null)
                return Results.NotFound(new RespuestaError("No se encontró la guía."));

            return Results.Ok(new
            {
                id = guardada.Id,
                numero = guardada.Numero,
                estado = guardada.Estado,
                fechaEmision = guardada.FechaEmision,
                fechaTraslado = guardada.FechaTraslado,
                destinatario = guardada.DestinatarioNombre,
                codigoSunat = guardada.CodigoSunat,
                mensajeSunat = guardada.MensajeSunat,

                // Lo que de verdad quiere saber quien consulta.
                puedeIniciarTraslado = guardada.Estado is "ACEPTADO"
                    or "ACEPTADO_CON_OBSERVACIONES"
            });
        })
        .WithSummary("Estado de una guía")
        .WithDescription(
            "El campo `puedeIniciarTraslado` responde la única pregunta que " +
            "importa: si el vehículo puede salir.");

        grupo.MapGet("", async (
            ContextoEmisor emisor, RepositorioGuias guias,
            int? limite, CancellationToken ct) =>
            Results.Ok(await guias.ListarAsync(
                emisor.Exigir().Id, Math.Clamp(limite ?? 50, 1, 200), ct)))
            .WithSummary("Lista las guías emitidas");

        // -------------------------------------------------------- descargas

        grupo.MapGet("/{id:guid}/xml", (
            Guid id, ContextoEmisor emisor, RepositorioGuias guias,
            IAlmacenArchivos archivos, CancellationToken ct) =>
            DescargarAsync(id, "xml", emisor, guias, archivos, ct))
            .WithSummary("Descarga el XML firmado de la guía");

        grupo.MapGet("/{id:guid}/cdr", (
            Guid id, ContextoEmisor emisor, RepositorioGuias guias,
            IAlmacenArchivos archivos, CancellationToken ct) =>
            DescargarAsync(id, "cdr", emisor, guias, archivos, ct))
            .WithSummary("Descarga la constancia de recepción");
    }

    // ------------------------------------------------------------- apoyo

    private static async Task<IResult> DescargarAsync(
        Guid id, string tipo, ContextoEmisor emisor,
        RepositorioGuias guias, IAlmacenArchivos archivos, CancellationToken ct)
    {
        var rutas = await guias.RutasAsync(emisor.Exigir().Id, id, ct);

        if (rutas is null)
            return Results.NotFound(new RespuestaError("No se encontró la guía."));

        var (numero, estado, xml, cdr) = rutas.Value;

        var ruta = tipo == "xml" ? xml : cdr;

        if (string.IsNullOrWhiteSpace(ruta))
        {
            return Results.NotFound(new RespuestaError(
                "Archivo no disponible.",
                tipo == "xml"
                    ? $"La guía está en estado {estado} y todavía no se firmó."
                    : $"La guía está en estado {estado}. La constancia solo " +
                      "existe cuando SUNAT ya respondió."));
        }

        var contenido = await archivos.LeerAsync(ruta, ct);

        if (contenido is null)
        {
            return Results.Problem(
                detail: $"La base registra el archivo en '{ruta}' pero el " +
                        "almacén no lo tiene.",
                statusCode: StatusCodes.Status500InternalServerError,
                title: "Archivo registrado pero ausente");
        }

        var (mime, extension) = tipo == "xml"
            ? ("application/xml", "xml")
            : ("application/zip", "zip");

        return Results.File(contenido, mime, $"{numero}.{extension}");
    }

    /// <summary>
    /// Convierte la petición en el modelo canónico.
    ///
    /// EL RUC DEL REMITENTE NO SE ENVÍA EN EL CUERPO: sale de la clave de
    /// acceso, igual que en las facturas. Si viniera del cliente, cualquiera
    /// con una clave podría emitir guías en nombre de otra empresa.
    /// </summary>
    private static GuiaRemision ArmarGuia(PeticionGuia p, TenantResuelto tenant)
    {
        var guia = new GuiaRemision
        {
            Serie = p.Serie,

            FechaEmision = p.FechaEmision ?? DateTime.Today,
            FechaTraslado = p.FechaTraslado,

            Remitente = new Emisor
            {
                Ruc = tenant.Ruc,
                RazonSocial = tenant.RazonSocial,
                NombreComercial = tenant.NombreComercial,
                Direccion = tenant.Direccion,
                Ubigeo = tenant.Ubigeo
            },

            Destinatario = new Receptor
            {
                TipoDocumento = p.Destinatario.TipoDocumento,
                NumeroDocumento = p.Destinatario.NumeroDocumento,
                RazonSocial = p.Destinatario.RazonSocial
            },

            MotivoTraslado = p.MotivoTraslado,
            DescripcionMotivo = p.DescripcionMotivo,
            ModalidadTraslado = p.ModalidadTraslado,

            PesoBruto = p.PesoBruto,
            NumeroBultos = p.NumeroBultos,

            PuntoPartida = new DireccionTraslado(
                p.PuntoPartida.Ubigeo,
                p.PuntoPartida.Direccion,
                p.PuntoPartida.CodigoEstablecimiento),

            PuntoLlegada = new DireccionTraslado(
                p.PuntoLlegada.Ubigeo,
                p.PuntoLlegada.Direccion,
                p.PuntoLlegada.CodigoEstablecimiento),

            VehiculoMenor = p.VehiculoMenor ?? false,

            Observaciones = p.Observaciones
        };

        if (p.Transportista is not null)
        {
            guia.Transportista = new Transportista(
                p.Transportista.TipoDocumento,
                p.Transportista.NumeroDocumento,
                p.Transportista.RazonSocial,
                p.Transportista.NumeroMtc);
        }

        if (p.Vehiculo is not null)
            guia.Vehiculo = new Vehiculo(p.Vehiculo.Placa, p.Vehiculo.Tuc);

        if (p.Conductor is not null)
        {
            guia.Conductor = new Conductor(
                p.Conductor.TipoDocumento,
                p.Conductor.NumeroDocumento,
                p.Conductor.Nombres,
                p.Conductor.Apellidos,
                p.Conductor.Licencia);
        }

        foreach (var bien in p.Bienes)
        {
            guia.Bienes.Add(new BienTrasladado(
                bien.Descripcion, bien.Cantidad, bien.UnidadMedida,
                bien.CodigoProducto, bien.CodigoSunat));
        }

        foreach (var doc in p.DocumentosRelacionados ?? [])
        {
            guia.DocumentosRelacionados.Add(new DocumentoRelacionadoGre(
                doc.TipoDocumento, doc.NumeroDocumento,

                // Si no se indica el RUC del emisor, se asume que el
                // documento lo emitió el propio remitente. Es el caso más
                // común: la factura de la venta que origina el traslado.
                doc.RucEmisor ?? tenant.Ruc));
        }

        return guia;
    }
}

// ------------------------------------------------------------- contratos

public record PeticionGuia(
    string Serie,
    DateTime FechaTraslado,
    ReceptorDto Destinatario,
    string MotivoTraslado,
    string ModalidadTraslado,
    decimal PesoBruto,
    DireccionPeticion PuntoPartida,
    DireccionPeticion PuntoLlegada,
    List<BienPeticion> Bienes,
    DateTime? FechaEmision = null,
    string? DescripcionMotivo = null,
    int? NumeroBultos = null,
    TransportistaPeticion? Transportista = null,
    VehiculoPeticion? Vehiculo = null,
    ConductorPeticion? Conductor = null,
    List<DocumentoRelacionadoPeticion>? DocumentosRelacionados = null,
    string? Observaciones = null,
    bool? VehiculoMenor = null,
    object? Extra = null);

public record DireccionPeticion(
    string Ubigeo,
    string Direccion,
    string? CodigoEstablecimiento = null);

public record TransportistaPeticion(
    string TipoDocumento,
    string NumeroDocumento,
    string RazonSocial,
    string? NumeroMtc = null);

public record VehiculoPeticion(string Placa, string? Tuc = null);

public record ConductorPeticion(
    string TipoDocumento,
    string NumeroDocumento,
    string Nombres,
    string Apellidos,
    string Licencia);

public record BienPeticion(
    string Descripcion,
    decimal Cantidad,
    string UnidadMedida,
    string? CodigoProducto = null,
    string? CodigoSunat = null);

public record DocumentoRelacionadoPeticion(
    string TipoDocumento,
    string NumeroDocumento,
    string? RucEmisor = null);
