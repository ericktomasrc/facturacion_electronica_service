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
        .WithSummary("Emite una guía de remisión (remitente o transportista)")
        .WithDescription(
            "Con `tipoGuia` se elige cuál:\n\n" +
            "- **`09` remitente** (por defecto), serie `T###`. La emite quien " +
            "manda los bienes.\n" +
            "- **`31` transportista**, serie `V###`. La emite quien los lleva, " +
            "y necesita además: `contratante` (el remitente que lo contrató), " +
            "`numeroMtc`, `vehiculo` con su `tuc`, `conductor` con licencia, y " +
            "un documento relacionado de **tipo `09`** con la guía del " +
            "remitente que ampara.\n\n" +
            "En un traslado con transportista contratado existen **las dos**, " +
            "una por cada empresa, y las dos tienen que estar aceptadas antes " +
            "de que el camión salga.\n\n" +
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

        // ------------------------------------------------------- anulación

        grupo.MapPost("/{id:guid}/anulacion", async (
            Guid id,
            AnulacionPeticion peticion,
            ContextoEmisor emisor,
            RepositorioGuias guias,
            CancellationToken ct) =>
        {
            var tenant = emisor.Exigir();

            var guardada = await guias.ObtenerParaAnularAsync(tenant.Id, id, ct);

            if (guardada is null)
                return Results.NotFound(new RespuestaError("No se encontró la guía."));

            var anulacion = new AnulacionGuia(
                guardada.TipoGuia,
                guardada.Serie,
                guardada.Numero.Split('-').Last(),
                peticion.FechaAnulacion ?? RelojPeru.Hoy,
                peticion.Motivo ?? "",
                peticion.RegistradaPor ?? "");

            var problemas = ReglasAnulacionGuia.Revisar(
                anulacion, guardada.Estado, guardada.FechaEmision);

            if (problemas.Count > 0)
            {
                return Results.BadRequest(new RespuestaError(
                    "No se puede registrar la anulación.",
                    string.Join(" ", problemas)));
            }

            var registrada = await guias.RegistrarAnulacionAsync(
                tenant.Id, id,
                anulacion.FechaAnulacion, anulacion.Motivo, anulacion.RegistradaPor, ct);

            if (!registrada)
            {
                // El estado cambió entre la comprobación y la escritura.
                return Results.Conflict(new RespuestaError(
                    "La guía cambió de estado mientras se registraba.",
                    "Vuelve a consultarla y repite la operación si sigue " +
                    "haciendo falta."));
            }

            return Results.Ok(new
            {
                numero = guardada.Numero,
                estado = "ANULADO",
                anuladaEn = anulacion.FechaAnulacion,
                motivo = anulacion.Motivo,
                registradaPor = anulacion.RegistradaPor
            });
        })
        .WithSummary("Registra que una guía se anuló en SUNAT")
        .WithDescription(
            "**Esto NO anula nada.** SUNAT no publica ningún servicio para dar " +
            "de baja una guía: la anula una persona entrando a SUNAT " +
            "Operaciones en Línea con su Clave SOL.\n\n" +
            "Lo que hace este endpoint es **registrar que eso ya ocurrió**, " +
            "para que la guía deje de figurar activa aquí. Sin él, la guía " +
            "queda muerta en SUNAT y viva en el sistema, y una factura " +
            "posterior puede referenciarla como si existiera.\n\n" +
            "El orden es: **primero se anula en SUNAT, después se registra " +
            "aquí.** Solo se admite sobre guías que SUNAT aceptó.");

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

        // 24 oct: la hoja para el conductor.
        grupo.MapGet("/{id:guid}/pdf", async (
            Guid id, ContextoEmisor emisor, RepositorioGuias guias,
            IAlmacenArchivos archivos, CancellationToken ct) =>
        {
            var datos = await guias.ObtenerParaPdfAsync(emisor.Exigir().Id, id, ct);

            if (datos is null)
                return Results.NotFound(new RespuestaError("No se encontró la guía."));

            var guia = RepositorioGuias.Deserializar(datos.Gre);

            string? enlaceQr = null;
            if (!string.IsNullOrWhiteSpace(datos.RutaCdr))
            {
                try
                {
                    var cdr = await archivos.LeerAsync(datos.RutaCdr, ct);
                    if (cdr is not null) enlaceQr = EnlaceQrGuia.DesdeCdr(cdr);
                }
                catch (Exception) when (!ct.IsCancellationRequested)
                {
                    // Sin QR, pero con PDF.
                }
            }

            byte[]? logo = null;
            if (!string.IsNullOrWhiteSpace(datos.LogoRuta))
            {
                try { logo = await archivos.LeerAsync(datos.LogoRuta, ct); }
                catch (Exception) when (!ct.IsCancellationRequested) { }
            }

            // 24 oct: el mismo formato A4 que la empresa eligió para sus
            // facturas: «clásico» (como el de SOL) o «moderno».
            var opciones = new Facturacion.Pdf.OpcionesImpresion(
                EstadoSunat: datos.Estado, MensajeSunat: datos.MensajeSunat, Logo: logo,
                Estilo: FormatoPdf.Normalizar(datos.FormatoPdf));

            static byte[] Dibujar(GuiaRemision g, string? qr, Facturacion.Pdf.OpcionesImpresion o) =>
                o.Estilo == FormatoPdf.Clasico
                    ? Facturacion.Pdf.GeneradorGuiaPdfClasico.Generar(g, qr, o)
                    : Facturacion.Pdf.GeneradorGuiaPdf.Generar(g, qr, o);

            byte[] pdf;
            try
            {
                pdf = Dibujar(guia, enlaceQr, opciones);
            }
            catch (Exception) when (logo is not null)
            {
                pdf = Dibujar(guia, enlaceQr, opciones with { Logo = null });
            }

            return Results.File(pdf, "application/pdf", $"{datos.Numero}.pdf");
        })
        .WithSummary("PDF de la guía (la hoja que lleva el conductor)")
        .WithDescription(
            "Con QR de consulta en SUNAT cuando la guía ya fue aceptada. Si " +
            "todavía no lo está, la hoja lo dice en grande: el vehículo no sale.");
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
            // Por defecto, la del remitente: es la que emiten casi todos.
            TipoGuia = string.IsNullOrWhiteSpace(p.TipoGuia)
                ? CatalogosGre.TipoGuiaRemitente
                : p.TipoGuia,

            Serie = p.Serie,

            FechaEmision = p.FechaEmision ?? RelojPeru.Hoy,
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
            UnidadPeso = string.IsNullOrWhiteSpace(p.UnidadPeso) ? "KGM" : p.UnidadPeso.Trim().ToUpperInvariant(),   // 24 oct
            NumeroBultos = p.NumeroBultos,

            PuntoPartida = new DireccionTraslado(
                p.PuntoPartida.Ubigeo,
                p.PuntoPartida.Direccion,
                p.PuntoPartida.CodigoEstablecimiento),

            PuntoLlegada = new DireccionTraslado(
                p.PuntoLlegada.Ubigeo,
                p.PuntoLlegada.Direccion,
                p.PuntoLlegada.CodigoEstablecimiento),

            FechaEntregaAlTransportista = p.FechaEntregaAlTransportista,

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
        {
            guia.Vehiculo = new Vehiculo(
                p.Vehiculo.Placa,
                p.Vehiculo.Tuc,
                p.Vehiculo.NumeroAutorizacion,
                p.Vehiculo.EntidadAutorizadora);
        }

        // ----------------------------------- lo propio de la guía del transportista

        if (p.Contratante is not null)
        {
            guia.Contratante = new RemitenteContratante(
                p.Contratante.TipoDocumento,
                p.Contratante.NumeroDocumento,
                p.Contratante.RazonSocial);
        }

        if (p.PagadorFlete is not null)
        {
            guia.PagadorFlete = new RemitenteContratante(
                p.PagadorFlete.TipoDocumento,
                p.PagadorFlete.NumeroDocumento,
                p.PagadorFlete.RazonSocial);
        }

        guia.NumeroMtc = p.NumeroMtc;

        foreach (var c in p.ConductoresSecundarios ?? [])
        {
            guia.ConductoresSecundarios.Add(new Conductor(
                c.TipoDocumento, c.NumeroDocumento, c.Nombres, c.Apellidos, c.Licencia));
        }

        guia.Indicadores = p.Indicadores ?? [];

        // 24 oct: el vehículo menor (M1 o L) se declara con su indicador; sin
        // él SUNAT pide placa y conductor.
        if (guia.VehiculoMenor && !guia.EsTransportista && !guia.Indicadores.Contains(IndicadorGre.VehiculoMenor))
            guia.Indicadores.Add(IndicadorGre.VehiculoMenor);

        if (p.OperadorSubcontratado is not null)
        {
            guia.OperadorSubcontratado = new Transportista(
                p.OperadorSubcontratado.TipoDocumento,
                p.OperadorSubcontratado.NumeroDocumento,
                p.OperadorSubcontratado.RazonSocial,
                p.OperadorSubcontratado.NumeroMtc);
        }

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
                // 24 oct: solo en los que llevan RUC (no en una constancia
                // de detracción ni en una DAM).
                string.IsNullOrWhiteSpace(doc.RucEmisor)
                    ? (GuiaRemision.DocumentosQueExigenRuc.Contains(doc.TipoDocumento) ? tenant.Ruc : null)
                    : doc.RucEmisor.Trim()));
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

    /// <summary>
    /// Cuándo se le entregaron los bienes al transportista. Obligatorio en
    /// transporte público. Si no se envía, se usa la fecha de traslado.
    /// </summary>
    DateTime? FechaEntregaAlTransportista = null,
    VehiculoPeticion? Vehiculo = null,
    ConductorPeticion? Conductor = null,
    List<DocumentoRelacionadoPeticion>? DocumentosRelacionados = null,
    string? Observaciones = null,
    bool? VehiculoMenor = null,
    object? Extra = null,

    // ------------------------------------ guía del transportista (tipo 31)

    /// <summary>"09" remitente (por defecto) o "31" transportista.</summary>
    string? TipoGuia = null,

    /// <summary>El remitente: de quién son los bienes. Obligatorio en la 31.</summary>
    ContratantePeticion? Contratante = null,

    /// <summary>
    /// Quien paga el flete, si es un tercero. Va junto al indicador
    /// "SUNAT_Envio_IndicadorPagadorFlete_Tercero".
    /// </summary>
    ContratantePeticion? PagadorFlete = null,

    /// <summary>Registro del MTC del transportista. Obligatorio en la 31.</summary>
    string? NumeroMtc = null,

    /// <summary>Conductores de relevo.</summary>
    List<ConductorPeticion>? ConductoresSecundarios = null,

    /// <summary>
    /// Indicadores del envío, tal cual los define SUNAT. El más frecuente es
    /// "SUNAT_Envio_IndicadorTrasporteSubcontratado".
    /// </summary>
    List<string>? Indicadores = null,

    /// <summary>El transportista subcontratado, si lo hay.</summary>
    TransportistaPeticion? OperadorSubcontratado = null,

    /// <summary>24 oct: unidad del peso bruto: "KGM" (por defecto) o "TNE".</summary>
    string? UnidadPeso = null);

public record DireccionPeticion(
    string Ubigeo,
    string Direccion,
    string? CodigoEstablecimiento = null);

public record TransportistaPeticion(
    string TipoDocumento,
    string NumeroDocumento,
    string RazonSocial,
    string? NumeroMtc = null);

public record VehiculoPeticion(
    string Placa,

    /// <summary>
    /// Número del certificado de habilitación vehicular. Obligatorio en la
    /// guía del transportista.
    /// </summary>
    string? Tuc = null,

    /// <summary>Número de autorización especial, si el vehículo la necesita.</summary>
    string? NumeroAutorizacion = null,

    /// <summary>
    /// Entidad que dio la autorización. Catálogo 37: "01" MTC, "02" Produce,
    /// "03" Digesa, "04" Senasa, "06" MINEM, "07" Sucamec.
    /// </summary>
    string? EntidadAutorizadora = null);

/// <summary>Quien contrató el traslado. Solo en la guía del transportista.</summary>
public record ContratantePeticion(
    string TipoDocumento,
    string NumeroDocumento,
    string RazonSocial);

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

/// <summary>
/// Lo que se registra al anular una guía.
///
/// LA FECHA ES LA DE SUNAT, no la de hoy: puede haberse anulado ayer y
/// registrarse ahora, y lo que vale para cualquier revisión posterior es
/// cuándo dejó de existir el documento.
/// </summary>
public record AnulacionPeticion(
    string Motivo,
    string RegistradaPor,
    DateTime? FechaAnulacion = null);

public record DocumentoRelacionadoPeticion(
    string TipoDocumento,
    string NumeroDocumento,
    string? RucEmisor = null);