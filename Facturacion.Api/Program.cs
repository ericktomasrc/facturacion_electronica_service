using System.ComponentModel.DataAnnotations;
using System.Text.Json;
using Facturacion.Api;
using Facturacion.Cpe;
using Facturacion.Persistencia;
using Microsoft.OpenApi.Models;

var builder = WebApplication.CreateBuilder(args);

// --- Servicios -------------------------------------------------------------

var cadenaConexion = builder.Configuration.GetConnectionString("Facturacion")
    ?? throw new InvalidOperationException(
        "Falta la cadena de conexión 'Facturacion' en appsettings.json.");

// El diagnóstico mira TODAS las empresas, así que usa el rol de operador.
// Es una vista de infraestructura, no de cliente, y por eso su endpoint
// está protegido con una clave distinta.
var cadenaOperador = builder.Configuration.GetConnectionString("FacturacionOperador")
    ?? throw new InvalidOperationException(
        "Falta la cadena 'FacturacionOperador' en appsettings.json.");

builder.Services.AddSingleton(new FabricaSesiones(cadenaConexion));
builder.Services.AddSingleton(new RepositorioDiagnostico(cadenaOperador));
builder.Services.AddSingleton<RepositorioTenants>();
builder.Services.AddSingleton<RepositorioComprobantes>();

// ALMACÉN COMPARTIDO CON EL WORKER.
//
// La API y el worker son procesos distintos, pero tienen que leer y escribir
// en la MISMA carpeta. Si cada uno apunta a la suya, el worker genera los
// archivos y la API responde que no existen, con un error desconcertante.
//
// En desarrollo se resuelve con una ruta relativa que ambos resuelven al
// mismo sitio. En producción esto será un volumen montado o S3, y entonces
// el problema desaparece solo.
var carpetaAlmacen = builder.Configuration["Almacen:Carpeta"] ?? "../almacen";

builder.Services.AddSingleton<IAlmacenArchivos>(
    _ => new AlmacenArchivosDisco(carpetaAlmacen));

// Administración de empresas, series y claves.
builder.Services.AddSingleton(new RepositorioAdmin(cadenaOperador));
builder.Services.AddSingleton(new RepositorioWebhooks(cadenaOperador));

// La API necesita la llave maestra porque cifra los certificados al cargarlos.
// Si falta la variable de entorno, el proceso no arranca: es preferible a
// descubrirlo cuando alguien intente subir un certificado.
builder.Services.AddSingleton<IProtectorDeSecretos>(_ => ProtectorAesGcm.DesdeEntorno());
builder.Services.AddSingleton<AlmacenCertificados>();

// Con ámbito de petición: cada llamada tiene su propio emisor.
builder.Services.AddScoped<ContextoEmisor>();

builder.Services.ConfigureHttpJsonOptions(opciones =>
{
    opciones.SerializerOptions.PropertyNamingPolicy = JsonNamingPolicy.CamelCase;
    opciones.SerializerOptions.DefaultIgnoreCondition =
        System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull;
});

// --- Documentación interactiva ---------------------------------------------
//
// Swagger sirve para dos cosas distintas, y la segunda importa más:
//
//   1. Probar la API sin escribir un cliente.
//   2. Ser el contrato que le entregas a quien integra. Cuando un cliente
//      pregunte "¿qué campos acepta?", la respuesta es una URL, no un correo
//      con un ejemplo que quedará desactualizado.
//
// En producción conviene protegerlo o desactivarlo: expone la forma completa
// de la API a cualquiera que la alcance.

builder.Services.AddEndpointsApiExplorer();

builder.Services.AddSwaggerGen(opciones =>
{
    opciones.SwaggerDoc("v1", new OpenApiInfo
    {
        Title = "Servicio de facturación electrónica",
        Version = "v1",
        Description =
            "Emisión de comprobantes electrónicos para SUNAT.\n\n" +
            "Toda petición requiere una clave de acceso.\n\n" +
            "**Emisión y consulta** (`/v1/*`): la clave determina qué empresa " +
            "emite, así que el RUC del emisor NO se envía en el cuerpo. " +
            "En Authorize, campo `ApiKey`, escribe:\n\n" +
            "`Bearer fac_dev_UkV5QkFOX0RFU0FSUk9MTE9fMjAyNg`\n\n" +
            "**Administración** (`/admin/*`): usa la clave del operador, que " +
            "es distinta porque da acceso a los datos de todas las empresas. " +
            "En Authorize, campo `AdminKey`, escribe solo:\n\n" +
            "`operador-dev-2026`"
    });

    // DOS ESQUEMAS DE AUTENTICACIÓN, Y ES A PROPÓSITO.
    //
    // Los emisores usan su clave en Authorization: Bearer. Los endpoints de
    // operación usan una clave distinta en X-Admin-Key, porque muestran datos
    // de TODAS las empresas.
    //
    // Declarar los dos en Swagger no es un detalle cosmético: sin el segundo,
    // toda la administración había que probarla escribiendo comandos a mano,
    // y eso hace que se pruebe menos.

    opciones.AddSecurityDefinition("ApiKey", new OpenApiSecurityScheme
    {
        Name = "Authorization",
        Type = SecuritySchemeType.ApiKey,
        In = ParameterLocation.Header,
        Description =
            "Clave del EMISOR. Escribe: Bearer {tu clave}\n\n" +
            "Sirve para /v1/*: emitir comprobantes y consultarlos.",
        Scheme = "Bearer"
    });

    opciones.AddSecurityDefinition("AdminKey", new OpenApiSecurityScheme
    {
        Name = "X-Admin-Key",
        Type = SecuritySchemeType.ApiKey,
        In = ParameterLocation.Header,
        Description =
            "Clave del OPERADOR de la plataforma. Escribe solo la clave, sin prefijo.\n\n" +
            "Sirve para /admin/*: empresas, certificados, series, claves y webhooks."
    });

    opciones.AddSecurityRequirement(new OpenApiSecurityRequirement
    {
        {
            new OpenApiSecurityScheme
            {
                Reference = new OpenApiReference
                {
                    Type = ReferenceType.SecurityScheme,
                    Id = "ApiKey"
                }
            },
            Array.Empty<string>()
        },
        {
            new OpenApiSecurityScheme
            {
                Reference = new OpenApiReference
                {
                    Type = ReferenceType.SecurityScheme,
                    Id = "AdminKey"
                }
            },
            Array.Empty<string>()
        }
    });
});

var app = builder.Build();

// --- Middleware ------------------------------------------------------------

if (app.Environment.IsDevelopment())
{
    app.UseSwagger();

    app.UseSwaggerUI(opciones =>
    {
        opciones.SwaggerEndpoint("/swagger/v1/swagger.json", "Facturación v1");

        // Swagger queda en la raíz: al levantar la API, el navegador abre
        // directamente la documentación.
        opciones.RoutePrefix = "docs";
        opciones.DocumentTitle = "Facturación electrónica";
    });
}

// Sirve el panel de diagnóstico desde wwwroot.
app.UseDefaultFiles();
app.UseStaticFiles();

app.UseMiddleware<AutenticacionApiKey>();

// --- Endpoints -------------------------------------------------------------

app.MapearDiagnostico();
app.MapearAdministracion();
app.MapearWebhooks();
app.MapearNotas();
app.MapearDescargas();

app.MapGet("/health", () => Results.Ok(new { estado = "vivo" }))
   .WithName("Salud")
   .WithTags("Servicio")
   .WithSummary("Comprueba que el servicio responde. No requiere clave.");

app.MapGet("/", () => Results.Ok(new
{
    servicio = "Facturación electrónica",
    version = "v1",
    documentacion = "/docs"
}))
   .WithName("Raiz")
   .WithTags("Servicio")
   .ExcludeFromDescription();


/// Emite un comprobante.
///
/// Responde 202 Accepted: el comprobante quedó registrado, pero TODAVÍA NO
/// fue a SUNAT. Eso lo hará el worker. Esperar aquí a SUNAT dejaría la
/// petición colgada varios segundos y el sistema caería cuando SUNAT caiga.
app.MapPost("/v1/comprobantes", async (
    PeticionComprobante peticion,
    HttpContext contexto,
    ContextoEmisor emisor,
    RepositorioComprobantes repositorio,
    CancellationToken ct) =>
{
    var tenant = emisor.Exigir();

    // --- Validación del contrato ---
    var errores = new List<ValidationResult>();

    if (!Validator.TryValidateObject(
            peticion, new ValidationContext(peticion), errores, validateAllProperties: true))
    {
        return Results.BadRequest(new RespuestaError(
            "La petición no es válida.",
            string.Join(" ", errores.Select(e => e.ErrorMessage))));
    }

    if (peticion.Lineas.Count == 0)
        return Results.BadRequest(new RespuestaError(
            "El comprobante necesita al menos una línea."));

    if (peticion.Moneda != "PEN" && peticion.TipoCambio is null)
        return Results.BadRequest(new RespuestaError(
            "Falta el tipo de cambio.",
            "Los comprobantes en moneda distinta de PEN deben declararlo."));

    // --- Construcción del comprobante ---
    // El emisor sale del tenant, NUNCA de la petición.

    ComprobanteBase comprobante;

    try
    {
        comprobante = ConstruirComprobante(peticion, tenant);
    }
    catch (ArgumentException ex)
    {
        return Results.BadRequest(new RespuestaError("Datos inválidos.", ex.Message));
    }

    // --- Persistencia ---

    var idempotencyKey = contexto.Request.Headers["Idempotency-Key"].ToString();

    try
    {
        var guardado = await repositorio.CrearAsync(
            tenant.Id,
            comprobante,
            extraJson: peticion.Extra is null
                ? null
                : JsonSerializer.Serialize(peticion.Extra),
            idempotencyKey: string.IsNullOrWhiteSpace(idempotencyKey) ? null : idempotencyKey,
            ct: ct);

        var respuesta = RespuestaComprobante.Desde(guardado, peticion.Moneda);

        // Si la clave de idempotencia ya se había usado, no se creó nada:
        // se devuelve el comprobante original con 200, no con 202.
        return guardado.YaExistia
            ? Results.Ok(respuesta)
            : Results.Accepted($"/v1/comprobantes/{guardado.Id}", respuesta);
    }
    catch (InvalidOperationException ex)
    {
        // Serie inexistente o inactiva.
        return Results.BadRequest(new RespuestaError("No se pudo emitir.", ex.Message));
    }
})
.WithName("EmitirComprobante")
.WithTags("Comprobantes")
.WithSummary("Emite una factura o boleta")
.WithDescription(
    "Responde 202: el comprobante queda registrado, pero todavía NO fue a SUNAT. " +
    "Eso lo hace el worker.\n\n" +
    "Envía la cabecera Idempotency-Key para que un reintento no produzca un duplicado: " +
    "si la clave ya se usó, responde 200 con el comprobante original.")
.Produces<RespuestaComprobante>(StatusCodes.Status202Accepted)
.Produces<RespuestaComprobante>(StatusCodes.Status200OK)
.Produces<RespuestaError>(StatusCodes.Status400BadRequest)
.Produces<RespuestaError>(StatusCodes.Status401Unauthorized);


/// Estado de un comprobante.
app.MapGet("/v1/comprobantes/{id:guid}", async (
    Guid id,
    ContextoEmisor emisor,
    RepositorioComprobantes repositorio,
    CancellationToken ct) =>
{
    var tenant = emisor.Exigir();

    var comprobante = await repositorio.ObtenerAsync(tenant.Id, id, ct);

    // Si el comprobante es de otra empresa, Row Level Security hace que
    // simplemente no exista para esta consulta. El 404 es correcto y además
    // no revela que el identificador pertenece a alguien más.
    return comprobante is null
        ? Results.NotFound(new RespuestaError("No se encontró el comprobante."))
        : Results.Ok(RespuestaEstado.Desde(comprobante));
})
.WithName("ConsultarComprobante")
.WithTags("Comprobantes")
.WithSummary("Estado de un comprobante")
.Produces<RespuestaEstado>()
.Produces<RespuestaError>(StatusCodes.Status404NotFound);


/// Lista los comprobantes del emisor.
app.MapGet("/v1/comprobantes", async (
    ContextoEmisor emisor,
    RepositorioComprobantes repositorio,
    int? limite,
    CancellationToken ct) =>
{
    var tenant = emisor.Exigir();

    var comprobantes = await repositorio.ListarAsync(
        tenant.Id, Math.Clamp(limite ?? 50, 1, 200), ct);

    return Results.Ok(comprobantes.Select(RespuestaEstado.Desde));
})
.WithName("ListarComprobantes")
.WithTags("Comprobantes")
.WithSummary("Lista los comprobantes del emisor")
.Produces<IEnumerable<RespuestaEstado>>();


/// Historial de intentos de un comprobante.
app.MapGet("/v1/comprobantes/{id:guid}/historial", async (
    Guid id,
    ContextoEmisor emisor,
    RepositorioComprobantes repositorio,
    CancellationToken ct) =>
{
    var tenant = emisor.Exigir();

    var historial = await repositorio.HistorialAsync(tenant.Id, id, ct);

    return Results.Ok(historial.Select(i => new
    {
        intento = i.IntentoNro,
        desde = i.EstadoAnterior,
        hasta = i.EstadoNuevo,
        codigoSunat = i.CodigoSunat,
        mensaje = i.Mensaje,
        duracionMs = i.DuracionMs,
        fecha = i.CreadoEn
    }));
})
.WithName("HistorialComprobante")
.WithTags("Comprobantes")
.WithSummary("Bitácora de un comprobante")
.WithDescription(
    "Cada cambio de estado, con su código de SUNAT y su duración. " +
    "La bitácora es append-only: nunca se modifica ni se borra.");


/// Datos del emisor autenticado. Útil para verificar que la clave funciona.
app.MapGet("/v1/emisor", (ContextoEmisor emisor) =>
{
    var tenant = emisor.Exigir();

    return Results.Ok(new
    {
        ruc = tenant.Ruc,
        razonSocial = tenant.RazonSocial,
        ambiente = tenant.Ambiente
    });
})
.WithName("Emisor")
.WithTags("Servicio")
.WithSummary("Datos del emisor autenticado")
.WithDescription("Sirve para verificar que una clave de acceso funciona.");

app.Run();


// ---------------------------------------------------------------------------

static ComprobanteBase ConstruirComprobante(
    PeticionComprobante peticion, TenantResuelto tenant)
{
    var emisor = new Emisor
    {
        Ruc = tenant.Ruc,
        RazonSocial = tenant.RazonSocial,
        NombreComercial = tenant.NombreComercial,
        Ubigeo = tenant.Ubigeo,
        Direccion = tenant.Direccion,
        Distrito = tenant.Distrito,
        Provincia = tenant.Provincia,
        Departamento = tenant.Departamento
    };

    var receptor = new Receptor
    {
        TipoDocumento = peticion.Receptor.TipoDocumento,
        NumeroDocumento = peticion.Receptor.NumeroDocumento,
        RazonSocial = peticion.Receptor.RazonSocial,
        Direccion = peticion.Receptor.Direccion
    };

    var lineas = peticion.Lineas.Select((l, indice) => new LineaComprobante
    {
        Numero = indice + 1,
        CodigoProducto = l.CodigoProducto,
        Descripcion = l.Descripcion,
        UnidadMedida = l.UnidadMedida,
        Cantidad = l.Cantidad,
        ValorUnitario = l.ValorUnitario,
        DescuentoPorcentaje = l.DescuentoPorcentaje,
        TipoAfectacionIgv = l.TipoAfectacionIgv,
        PorcentajeIgv = l.PorcentajeIgv
    }).ToList();

    var tipoCambio = peticion.TipoCambio is null ? null : new TipoCambio
    {
        MonedaOrigen = peticion.TipoCambio.MonedaOrigen,
        MonedaDestino = peticion.TipoCambio.MonedaDestino,
        Tasa = peticion.TipoCambio.Tasa,
        Fecha = peticion.TipoCambio.Fecha ?? DateTime.Today
    };

    var fecha = peticion.FechaEmision ?? DateTime.Now;

    return peticion.Tipo switch
    {
        TipoComprobante.Factura => new Factura
        {
            Serie = peticion.Serie,
            FechaEmision = fecha,
            Moneda = peticion.Moneda,
            FormaPago = peticion.FormaPago,
            DescuentoGlobalPorcentaje = peticion.DescuentoGlobalPorcentaje,
            TipoCambio = tipoCambio,
            Emisor = emisor,
            Receptor = receptor,
            Lineas = lineas
        },

        TipoComprobante.Boleta => new Boleta
        {
            Serie = peticion.Serie,
            FechaEmision = fecha,
            Moneda = peticion.Moneda,
            FormaPago = peticion.FormaPago,
            DescuentoGlobalPorcentaje = peticion.DescuentoGlobalPorcentaje,
            TipoCambio = tipoCambio,
            Emisor = emisor,
            Receptor = receptor,
            Lineas = lineas
        },

        _ => throw new ArgumentException(
            $"Tipo de comprobante no soportado por este endpoint: {peticion.Tipo}. " +
            "Las notas de crédito y débito tienen su propia ruta.")
    };
}
