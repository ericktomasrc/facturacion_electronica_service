# =============================================================================
# Entrega 2026-10-11 12:20 - Copia al emisor (opcional) y aviso de la direccion
# (servicio)
#
# Se ejecuta desde la carpeta del servicio:
#   D:\Reyban Consulting\facturacion electronica\facturacion_electronica_service
#   .\entrega-2026-10-11-copia-al-emisor-servicio.ps1
#
#   migraciones\026_copia_al_emisor.sql               NUEVO. tenants.copia_al_emisor,
#        desactivada por defecto. No se aplica sola
#   Facturacion.Persistencia\RepositorioCorreosPortal.cs  Lee si la empresa pidio copia
#   Facturacion.Persistencia\ServicioCorreo.cs            Copia OCULTA, si se pide
#   Facturacion.Api\ServicioCorreosEntrega.cs              La pide si la empresa la quiere
#   Facturacion.Persistencia\RepositorioAdmin.cs           Guarda y lee la casilla
#   Facturacion.Api\EndpointsAdmin.cs                      La casilla viaja con la marca
#   Facturacion.Api\wwwroot\admin.html     Casilla «Mandar una copia ... (opcional)»
#        en Marca, y aviso «Copiala tal cual de la ficha RUC» en la direccion
#
# Solo se reemplazan si siguen IGUAL a los ultimos. Todo o nada. .bak.
# =============================================================================

$ErrorActionPreference = 'Stop'
$raiz = (Get-Location).Path

if (-not (Test-Path (Join-Path $raiz 'Facturacion.Api')) -or -not (Test-Path (Join-Path $raiz 'migraciones'))) {
    Write-Host "No encuentro 'Facturacion.Api' y 'migraciones' aquí ($raiz)." -ForegroundColor Red
    Write-Host "Ejecuta el script desde la raíz del servicio (facturacion_electronica_service). No se tocó nada." -ForegroundColor Red
    exit 1
}

$utf8SinBom = New-Object System.Text.UTF8Encoding $false

function Normalizar([string]$t) { return $t.TrimStart([char]0xFEFF).Replace("`r", '').TrimEnd() }

function Huella([string]$t) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $bytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes((Normalizar $t)))
    return ([System.BitConverter]::ToString($bytes)).Replace('-', '')
}

function Respaldar([string]$completa) {
    $bak = "$completa.bak"
    if (Test-Path $bak) { $bak = "$completa.$(Get-Date -Format 'yyyyMMdd-HHmmss').bak" }
    Copy-Item $completa $bak -Force
    return (Split-Path $bak -Leaf)
}

$plan = New-Object System.Collections.Generic.List[object]

# Una ruta que empieza por '*' se busca por nombre dentro de reyban_plataforma_web\src.
function Planear([string]$ruta, [string]$esperada, [string]$texto) {
    $texto = $texto.Replace("`r", '')
    if ($ruta.StartsWith('*')) {
        $nombre = $ruta.Substring(1)
        $hallados = @(Get-ChildItem -Path (Join-Path $raiz 'reyban_plataforma_web\src') -Recurse -Filter $nombre -File |
            Where-Object { $_.FullName -notmatch '\\node_modules\\' })
        if ($hallados.Count -ne 1) {
            $plan.Add([pscustomobject]@{ Ruta = $nombre; Accion = 'conflicto'; Motivo = "lo encuentro $($hallados.Count) veces dentro de reyban_plataforma_web\src. Dime cuál es." })
            return
        }
        $completa = $hallados[0].FullName
        $ruta = $completa.Substring($raiz.Length).TrimStart('\')
    }
    else { $completa = Join-Path $raiz $ruta }

    $accion = ''; $motivo = ''; $crlf = $false
    if (-not (Test-Path $completa)) {
        if ($esperada -eq '') { $accion = 'nuevo' }
        else { $accion = 'conflicto'; $motivo = 'no existe. ¿Está en otra carpeta?' }
    }
    else {
        $actual = [System.IO.File]::ReadAllText($completa)
        $crlf = $actual.Contains("`r`n")
        if ((Normalizar $actual) -eq (Normalizar $texto)) { $accion = 'igual' }
        elseif ((Huella $actual) -ne $esperada) { $accion = 'conflicto'; $motivo = 'cambió desde que me lo pasaste. Pásamelo de nuevo.' }
        else { $accion = 'reemplazar' }
    }
    $plan.Add([pscustomobject]@{ Ruta = $ruta; Completa = $completa; Accion = $accion; Motivo = $motivo; Texto = $texto; Crlf = $crlf })
}

# --- migraciones\026_copia_al_emisor.sql
Planear 'migraciones\026_copia_al_emisor.sql' '' @'
-- =============================================================================
-- 026 - COPIA AL EMISOR DEL CORREO DE CADA COMPROBANTE (OPCIONAL)
--
-- Decision del 11 de octubre: el emisor puede pedir que le llegue una copia
-- del correo que recibe su cliente con cada comprobante. Va en COPIA OCULTA
-- (el receptor no la ve) al correo de respuesta del emisor.
--
-- DESACTIVADA POR DEFECTO, a proposito: a muchos emisores no les gusta un
-- correo por cada factura que emiten, y ya las ven en su plataforma.
--
-- Sin tildes a proposito: PowerShell 5.1 la manda a psql en ASCII.
-- =============================================================================

BEGIN;

ALTER TABLE tenants
    ADD COLUMN IF NOT EXISTS copia_al_emisor boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN tenants.copia_al_emisor IS
    'Si se manda copia oculta del correo de cada comprobante al correo_respuesta. Opcional; por defecto no.';

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM tenants WHERE copia_al_emisor) THEN
        RAISE NOTICE '026: ya habia empresas con la copia activada (se corrio dos veces).';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
         WHERE table_name = 'tenants' AND column_name = 'copia_al_emisor') THEN
        RAISE EXCEPTION '026: falta la columna copia_al_emisor.';
    END IF;

    RAISE NOTICE '026: copia al emisor lista (desactivada en todas las empresas).';
END $$;

COMMIT;
'@

# --- Facturacion.Persistencia\RepositorioCorreosPortal.cs
Planear 'Facturacion.Persistencia\RepositorioCorreosPortal.cs' '44DCFE54FBE73556C8FDB8925C690413682F09E748E4087E42C65B4D754DDDF3' @'
using Dapper;
using Npgsql;

namespace Facturacion.Persistencia;

/// <summary>Un correo de entrega que toca enviar.</summary>
public record CorreoPendiente(
    Guid Id,
    Guid TenantId,
    Guid ComprobanteId,
    string Para,
    short Intentos);

/// <summary>Todo lo que hace falta para armar el correo de un comprobante.</summary>
public record DatosCorreoPortal(
    bool EmpresaActiva,
    string Ruc,
    string RazonSocial,
    string? NombreComercial,
    string? Identificador,
    string? ColorMarca,
    string? LogoRuta,
    string? CorreoRespuesta,
    string TipoComprobante,
    string Serie,
    int Correlativo,
    DateTime FechaEmision,
    string Moneda,
    decimal ImporteTotal,
    string Estado,

    // Migracion 026. AL FINAL a proposito: Dapper empareja por posicion.
    // Si la empresa pidio copia oculta de cada correo a su correo de respuesta.
    bool CopiaAlEmisor)
{
    public string Numero => $"{Serie}-{Correlativo:D8}";

    public string NombreEmisor =>
        string.IsNullOrWhiteSpace(NombreComercial) ? RazonSocial : NombreComercial!;
}

/// <summary>Lo que el panel enseña del portal para un comprobante.</summary>
public record CorreoPortalAdmin(
    string Para,
    string Estado,
    short Intentos,
    string? UltimoError,
    DateTime? EnviadoEn,
    bool? PdfAdjunto,
    DateTime CreadoEn);

public record AccesoPortalAdmin(
    Guid Id,
    string Origen,
    DateTime CreadoEn,
    DateTime ExpiraEn,
    DateTime? AnuladoEn,
    string? AnuladoMotivo,
    int Usos,
    DateTime? UltimoUsoEn);

/// <summary>
/// La cola del correo de entrega y la administración de los accesos.
///
/// USA EL ROL DE OPERADOR: quien envía recorre la cola de todas las empresas,
/// y anular accesos es cosa del panel. La aplicación no puede anular.
/// </summary>
public sealed class RepositorioCorreosPortal
{
    private readonly string _cadenaOperador;

    public RepositorioCorreosPortal(string cadenaConexionOperador)
    {
        _cadenaOperador = cadenaConexionOperador
            ?? throw new ArgumentNullException(nameof(cadenaConexionOperador));
    }

    private async Task<NpgsqlConnection> AbrirAsync(CancellationToken ct)
    {
        var conexion = new NpgsqlConnection(_cadenaOperador);
        await conexion.OpenAsync(ct);
        return conexion;
    }

    // ------------------------------------------------------------------ cola

    /// <summary>
    /// Toma un lote de correos y los aparta 10 minutos.
    ///
    /// APARTAR ES ADELANTAR proximo_intento_en: si el proceso muere a mitad de
    /// un envío, el correo vuelve a estar disponible solo, sin quedarse
    /// "en curso" para siempre. SKIP LOCKED evita que dos vueltas tomen el
    /// mismo.
    /// </summary>
    public async Task<IReadOnlyList<CorreoPendiente>> TomarPendientesAsync(
        int lote, CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);

        var filas = await conexion.QueryAsync<CorreoPendiente>(new CommandDefinition(
            """
            UPDATE portal_correos c
               SET proximo_intento_en = now() + interval '10 minutes',
                   intentos = c.intentos + 1
             WHERE c.id IN (
                   SELECT id FROM portal_correos
                    WHERE estado = 'PENDIENTE'
                      AND (proximo_intento_en IS NULL OR proximo_intento_en <= now())
                    ORDER BY proximo_intento_en NULLS FIRST, creado_en
                    LIMIT @lote
                      FOR UPDATE SKIP LOCKED)
            RETURNING c.id             AS "Id",
                      c.tenant_id      AS "TenantId",
                      c.comprobante_id AS "ComprobanteId",
                      c.para           AS "Para",
                      c.intentos       AS "Intentos"
            """,
            new { lote }, cancellationToken: ct));

        return filas.ToList();
    }

    public async Task<DatosCorreoPortal?> DatosAsync(
        Guid tenantId, Guid comprobanteId, CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);

        return await conexion.QuerySingleOrDefaultAsync<DatosCorreoPortal>(new CommandDefinition(
            """
            SELECT t.activo           AS "EmpresaActiva",
                   t.ruc              AS "Ruc",
                   t.razon_social     AS "RazonSocial",
                   t.nombre_comercial AS "NombreComercial",
                   t.identificador    AS "Identificador",
                   t.color_marca      AS "ColorMarca",
                   t.logo_ruta        AS "LogoRuta",
                   t.correo_respuesta AS "CorreoRespuesta",
                   c.tipo_comprobante AS "TipoComprobante",
                   c.serie            AS "Serie",
                   c.correlativo      AS "Correlativo",
                   c.fecha_emision    AS "FechaEmision",
                   c.moneda           AS "Moneda",
                   c.importe_total    AS "ImporteTotal",
                   c.estado           AS "Estado",
                   t.copia_al_emisor  AS "CopiaAlEmisor"
              FROM comprobantes c
              JOIN tenants t ON t.id = c.tenant_id
             WHERE c.id = @comprobanteId
               AND c.tenant_id = @tenantId
            """,
            new { tenantId, comprobanteId }, cancellationToken: ct));
    }

    /// <summary>Crea el acceso del correo: 400 días, origen 'correo'.</summary>
    public async Task<Guid> CrearAccesoCorreoAsync(
        Guid tenantId, Guid comprobanteId, string hash, CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);

        return await conexion.ExecuteScalarAsync<Guid>(new CommandDefinition(
            """
            INSERT INTO portal_accesos (tenant_id, comprobante_id, hash, origen, expira_en)
            VALUES (@tenantId, @comprobanteId, @hash, 'correo', now() + interval '400 days')
            RETURNING id
            """,
            new { tenantId, comprobanteId, hash }, cancellationToken: ct));
    }

    public async Task MarcarEnviadoAsync(
        Guid id, Guid accesoId, bool pdfAdjunto, CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);

        await conexion.ExecuteAsync(new CommandDefinition(
            """
            UPDATE portal_correos
               SET estado = 'ENVIADO',
                   enviado_en = now(),
                   acceso_id = @accesoId,
                   pdf_adjunto = @pdfAdjunto,
                   ultimo_error = NULL,
                   proximo_intento_en = NULL
             WHERE id = @id
            """,
            new { id, accesoId, pdfAdjunto }, cancellationToken: ct));
    }

    /// <summary>
    /// Un envío fallido. El acceso que se creó para ese intento se anula: su
    /// enlace no llegó a nadie, y uno nuevo saldrá en el siguiente intento.
    /// </summary>
    public async Task MarcarFalloAsync(
        Guid id, string error, TimeSpan? reintentarEn, Guid? accesoFallido,
        CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);
        await using var transaccion = await conexion.BeginTransactionAsync(ct);

        await conexion.ExecuteAsync(new CommandDefinition(
            """
            UPDATE portal_correos
               SET estado = CASE WHEN @agotado THEN 'AGOTADO' ELSE 'PENDIENTE' END,
                   ultimo_error = left(@error, 1000),
                   proximo_intento_en = CASE WHEN @agotado THEN NULL
                                             ELSE now() + make_interval(secs => @segundos) END
             WHERE id = @id
            """,
            new
            {
                id,
                error,
                agotado = reintentarEn is null,
                segundos = reintentarEn?.TotalSeconds ?? 0
            },
            transaccion, cancellationToken: ct));

        if (accesoFallido is { } accesoId)
            await conexion.ExecuteAsync(new CommandDefinition(
                """
                UPDATE portal_accesos
                   SET anulado_en = now(), anulado_motivo = 'El correo no se pudo enviar.'
                 WHERE id = @accesoId AND anulado_en IS NULL
                """,
                new { accesoId }, transaccion, cancellationToken: ct));

        await transaccion.CommitAsync(ct);
    }

    /// <summary>No se manda y no se reintenta: la empresa ya no está lista.</summary>
    public async Task MarcarOmitidoAsync(Guid id, string motivo, CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);

        await conexion.ExecuteAsync(new CommandDefinition(
            """
            UPDATE portal_correos
               SET estado = 'OMITIDO', ultimo_error = @motivo, proximo_intento_en = NULL
             WHERE id = @id
            """,
            new { id, motivo }, cancellationToken: ct));
    }

    // ----------------------------------------------------------------- panel

    public async Task<(CorreoPortalAdmin? Correo, IReadOnlyList<AccesoPortalAdmin> Accesos)>
        ListarAsync(Guid comprobanteId, CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);

        var correo = await conexion.QuerySingleOrDefaultAsync<CorreoPortalAdmin>(
            new CommandDefinition(
                """
                SELECT para         AS "Para",
                       estado       AS "Estado",
                       intentos     AS "Intentos",
                       ultimo_error AS "UltimoError",
                       enviado_en   AS "EnviadoEn",
                       pdf_adjunto  AS "PdfAdjunto",
                       creado_en    AS "CreadoEn"
                  FROM portal_correos
                 WHERE comprobante_id = @comprobanteId
                """,
                new { comprobanteId }, cancellationToken: ct));

        var accesos = await conexion.QueryAsync<AccesoPortalAdmin>(new CommandDefinition(
            """
            SELECT id             AS "Id",
                   origen         AS "Origen",
                   creado_en      AS "CreadoEn",
                   expira_en      AS "ExpiraEn",
                   anulado_en     AS "AnuladoEn",
                   anulado_motivo AS "AnuladoMotivo",
                   usos           AS "Usos",
                   ultimo_uso_en  AS "UltimoUsoEn"
              FROM portal_accesos
             WHERE comprobante_id = @comprobanteId
             ORDER BY creado_en DESC
            """,
            new { comprobanteId }, cancellationToken: ct));

        return (correo, accesos.ToList());
    }

    /// <summary>
    /// Anula todos los accesos vigentes de un comprobante. Devuelve cuántos.
    ///
    /// Se anulan, no se borran: queda quién los usó, cuántas veces y cuándo
    /// dejaron de servir, que es justo lo que hay que poder responder si el
    /// cliente pregunta.
    /// </summary>
    public async Task<int> AnularAccesosAsync(
        Guid comprobanteId, string motivo, CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);

        return await conexion.ExecuteAsync(new CommandDefinition(
            """
            UPDATE portal_accesos
               SET anulado_en = now(), anulado_motivo = @motivo
             WHERE comprobante_id = @comprobanteId
               AND anulado_en IS NULL
               AND expira_en > now()
            """,
            new { comprobanteId, motivo }, cancellationToken: ct));
    }
}
'@

# --- Facturacion.Persistencia\ServicioCorreo.cs
Planear 'Facturacion.Persistencia\ServicioCorreo.cs' '044BD79E368213BEBA04C261BBAEB720CF36355C4DAA79501778B73E75823308' @'
using MailKit.Net.Smtp;
using MailKit.Security;
using Microsoft.Extensions.Logging;
using MimeKit;

namespace Facturacion.Persistencia;

/// <summary>Configuración del servidor de correo.</summary>
public sealed class OpcionesCorreo
{
    public string Host { get; set; } = "";
    public int Puerto { get; set; } = 587;
    public string Usuario { get; set; } = "";
    public string Clave { get; set; } = "";
    public string Desde { get; set; } = "";
    public string Nombre { get; set; } = "Facturación electrónica";

    /// <summary>
    /// Dirección base del panel, para armar los enlaces de los correos.
    ///
    /// Tiene que ser la que ve el usuario, no la interna del servidor: un
    /// enlace a "localhost" en un correo no lleva a ninguna parte.
    /// </summary>
    public string UrlPanel { get; set; } = "https://localhost:7295";

    /// <summary>
    /// Dirección base del portal del receptor, para el enlace del correo de
    /// entrega. En producción, https://comprobantes.reyban.pe (variable
    /// PORTAL_URL). Vacía: la del panel con /portal, que es lo que sirve en
    /// desarrollo.
    /// </summary>
    public string UrlPortal { get; set; } = "";

    public string UrlPortalEfectiva =>
        string.IsNullOrWhiteSpace(UrlPortal)
            ? UrlPanel.TrimEnd('/') + "/portal"
            : UrlPortal.TrimEnd('/');

    public bool Configurado =>
        !string.IsNullOrWhiteSpace(Host) && !string.IsNullOrWhiteSpace(Desde);
}

/// <summary>
/// Envía los correos del sistema.
///
/// POR QUÉ NO SE ENVÍA DIRECTAMENTE DESDE DONDE HACE FALTA:
///
/// Un servidor de correo puede tardar segundos o estar caído. Si el envío
/// ocurriera dentro de la petición que lo provoca, restablecer una contraseña
/// se quedaría colgado esperando a Gmail.
///
/// Aquí se envía en segundo plano y los fallos se registran: que no llegue un
/// correo no debe romper la operación que lo originó.
/// </summary>
public sealed class ServicioCorreo
{
    private readonly OpcionesCorreo _opciones;
    private readonly ILogger<ServicioCorreo> _log;

    public ServicioCorreo(OpcionesCorreo opciones, ILogger<ServicioCorreo> log)
    {
        _opciones = opciones;
        _log = log;
    }

    public bool Disponible => _opciones.Configurado;

    /// <summary>
    /// Envía un correo. Devuelve false si falla, sin lanzar.
    ///
    /// NO LANZA A PROPÓSITO. Quien llama casi siempre está en medio de otra
    /// cosa —crear un usuario, restablecer una contraseña— y esa cosa ya se
    /// hizo. Fallar ahí dejaría al usuario creado pero la petición en error,
    /// que es el peor de los dos mundos.
    /// </summary>
    public async Task<bool> EnviarAsync(
        string para, string asunto, string cuerpoHtml,
        CancellationToken ct = default)
    {
        if (!Disponible)
        {
            _log.LogWarning(
                "Correo NO configurado: no se envió '{Asunto}' a {Para}. " +
                "Rellena MAIL_HOST y las demás variables en el .env.",
                asunto, para);

            return false;
        }

        try
        {
            var mensaje = new MimeMessage();

            mensaje.From.Add(new MailboxAddress(_opciones.Nombre, _opciones.Desde));
            mensaje.To.Add(MailboxAddress.Parse(para));
            mensaje.Subject = asunto;

            mensaje.Body = new BodyBuilder
            {
                HtmlBody = cuerpoHtml,

                // Versión en texto plano para los clientes que no muestran
                // HTML y para que los filtros de correo no lo marquen como
                // sospechoso.
                TextBody = AQuitarEtiquetas(cuerpoHtml)
            }.ToMessageBody();

            using var cliente = new SmtpClient();

            // STARTTLS en el 587 es lo habitual. En el 465 se usa SSL directo.
            var seguridad = _opciones.Puerto == 465
                ? SecureSocketOptions.SslOnConnect
                : SecureSocketOptions.StartTls;

            await cliente.ConnectAsync(_opciones.Host, _opciones.Puerto, seguridad, ct);

            if (!string.IsNullOrWhiteSpace(_opciones.Usuario))
                await cliente.AuthenticateAsync(_opciones.Usuario, _opciones.Clave, ct);

            await cliente.SendAsync(mensaje, ct);
            await cliente.DisconnectAsync(true, ct);

            _log.LogInformation("Correo '{Asunto}' enviado a {Para}.", asunto, para);

            return true;
        }
        catch (Exception ex)
        {
            _log.LogError(ex,
                "No se pudo enviar '{Asunto}' a {Para}. " +
                "Si usas Gmail, recuerda que hace falta una contraseña de " +
                "aplicación, no la de la cuenta.",
                asunto, para);

            return false;
        }
    }

    // ------------------------------------------------- correo de entrega

    /// <summary>
    /// El correo con el comprobante, en nombre del emisor.
    ///
    /// LO QUE LO HACE DISTINTO DE LOS CORREOS DEL PANEL:
    ///
    ///   - "De": el NOMBRE es el del emisor, la DIRECCIÓN es la nuestra
    ///     (MAIL_DESDE). Mandar desde la dirección del emisor sería suplantar
    ///     su dominio, y los filtros lo tirarían a spam.
    ///   - "Responder a": el correo de respuesta del emisor. Si el cliente
    ///     contesta, le llega a quien le vendió, no a nosotros.
    ///   - Puede llevar el PDF adjunto y el logo incrustado (cid:logo-emisor),
    ///     que se ve aunque el cliente de correo bloquee las imágenes de
    ///     fuera.
    ///   - Puede llevar COPIA OCULTA al emisor (migración 026, opcional y
    ///     desactivada por defecto): el receptor no la ve. Va DESPUÉS de `ct`
    ///     para no romper a quien ya llama pasando `ct` por posición.
    ///
    /// Devuelve null si salió, o el motivo si no. No lanza: quien llama
    /// decide si reintenta.
    /// </summary>
    public async Task<string?> EnviarEntregaAsync(
        string para, string nombreRemitente, string responderA,
        string asunto, string html, string texto,
        AdjuntoCorreo? adjunto, AdjuntoCorreo? logo,
        CancellationToken ct = default,
        string? copiaOculta = null)
    {
        if (!Disponible)
            return "El correo no está configurado (MAIL_HOST, MAIL_DESDE).";

        try
        {
            var mensaje = new MimeMessage();

            mensaje.From.Add(new MailboxAddress(nombreRemitente, _opciones.Desde));
            mensaje.ReplyTo.Add(MailboxAddress.Parse(responderA));
            mensaje.To.Add(MailboxAddress.Parse(para));

            // La copia al emisor, OCULTA. No si es la misma dirección que el
            // receptor (el emisor facturándose a sí mismo): llegaría dos veces.
            if (!string.IsNullOrWhiteSpace(copiaOculta) &&
                !string.Equals(copiaOculta.Trim(), para.Trim(), StringComparison.OrdinalIgnoreCase))
                mensaje.Bcc.Add(MailboxAddress.Parse(copiaOculta.Trim()));

            mensaje.Subject = asunto;

            // Es un correo automático: que nadie conteste con un "fuera de
            // la oficina" que vuelva al emisor como si fuera una respuesta.
            mensaje.Headers.Add("Auto-Submitted", "auto-generated");
            mensaje.Headers.Add("X-Auto-Response-Suppress", "All");

            var cuerpo = new BodyBuilder { HtmlBody = html, TextBody = texto };

            if (logo is not null)
            {
                var recurso = cuerpo.LinkedResources.Add(
                    logo.Nombre, logo.Datos, ContentType.Parse(logo.TipoMime));
                recurso.ContentId = "logo-emisor";
            }

            if (adjunto is not null)
                cuerpo.Attachments.Add(
                    adjunto.Nombre, adjunto.Datos, ContentType.Parse(adjunto.TipoMime));

            mensaje.Body = cuerpo.ToMessageBody();

            using var cliente = new SmtpClient();

            var seguridad = _opciones.Puerto == 465
                ? SecureSocketOptions.SslOnConnect
                : SecureSocketOptions.StartTls;

            await cliente.ConnectAsync(_opciones.Host, _opciones.Puerto, seguridad, ct);

            if (!string.IsNullOrWhiteSpace(_opciones.Usuario))
                await cliente.AuthenticateAsync(_opciones.Usuario, _opciones.Clave, ct);

            await cliente.SendAsync(mensaje, ct);
            await cliente.DisconnectAsync(true, ct);

            _log.LogInformation("Correo de entrega '{Asunto}' enviado.", asunto);

            return null;
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            // En el registro no va la dirección del cliente: es un dato suyo,
            // y ya queda en la cola, que es donde se mira.
            _log.LogWarning(ex, "No se pudo enviar el correo de entrega '{Asunto}'.", asunto);

            return ex.Message;
        }
    }

    // ------------------------------------------------------------ plantillas

    public Task<bool> EnviarRecuperacionAsync(
        string para, string nombre, string token, CancellationToken ct = default)
    {
        var enlace = $"{_opciones.UrlPanel.TrimEnd('/')}/restablecer.html?token={token}";

        return EnviarAsync(para,
            "Restablece tu contraseña",
            Plantilla(
                "Restablece tu contraseña",
                $"Hola{(string.IsNullOrWhiteSpace(nombre) ? "" : " " + Escapar(nombre))},",
                "Pediste restablecer la contraseña de tu cuenta del panel de " +
                "facturación. Pulsa el botón para elegir una nueva.",
                ("Elegir contraseña nueva", enlace),
                "El enlace caduca en una hora y solo sirve una vez.<br><br>" +
                "Si no fuiste tú, ignora este correo: tu contraseña no ha " +
                "cambiado y nadie ha entrado a tu cuenta."),
            ct);
    }

    public Task<bool> EnviarBienvenidaAsync(
        string para, string nombre, string provisional, int horasVigencia = 48,
        CancellationToken ct = default)
    {
        return EnviarAsync(para,
            "Tu acceso al panel de facturación",
            Plantilla(
                "Bienvenido",
                $"Hola{(string.IsNullOrWhiteSpace(nombre) ? "" : " " + Escapar(nombre))},",
                "Se creó tu cuenta en el panel de facturación electrónica. " +
                "Entra con tu correo y esta contraseña provisional:",
                ("Entrar al panel", _opciones.UrlPanel.TrimEnd('/') + "/login.html"),
                $"<div style=\"font-family:monospace;font-size:18px;" +
                $"background:#f1f3f5;padding:12px 16px;border-radius:8px;" +
                $"margin:16px 0;text-align:center\">{Escapar(provisional)}</div>" +
                $"<strong>Esta contraseña caduca en {horasVigencia} horas.</strong> " +
                "Si no entras antes, pídele al administrador que te la " +
                "restablezca.<br><br>" +
                "Tendrás que cambiarla en tu primer ingreso.<br><br>" +
                "Te recomendamos activar la verificación en dos pasos desde " +
                "&laquo;Mi cuenta&raquo;: este panel da acceso a datos " +
                "sensibles de los clientes."),
            ct);
    }

    public Task<bool> EnviarAvisoContrasenaCambiadaAsync(
        string para, string nombre, CancellationToken ct = default)
    {
        // POR QUÉ SE AVISA: si alguien cambia la contraseña sin que el dueño
        // lo sepa, este correo es lo único que lo alerta. Es barato y a veces
        // es la diferencia entre detectar un acceso indebido el mismo día o
        // no detectarlo nunca.
        return EnviarAsync(para,
            "Tu contraseña cambió",
            Plantilla(
                "Contraseña cambiada",
                $"Hola{(string.IsNullOrWhiteSpace(nombre) ? "" : " " + Escapar(nombre))},",
                "La contraseña de tu cuenta del panel de facturación acaba de " +
                "cambiar.",
                null,
                "<strong>Si no fuiste tú</strong>, avisa al administrador de " +
                "inmediato: alguien más tiene acceso a tu cuenta."),
            ct);
    }

    private string Plantilla(
        string titulo, string saludo, string cuerpo,
        (string Texto, string Url)? boton, string pie)
    {
        var botonHtml = boton is null ? "" : $"""
            <p style="margin:26px 0">
              <a href="{boton.Value.Url}"
                 style="background:#2563eb;color:#ffffff;text-decoration:none;
                        padding:11px 22px;border-radius:8px;display:inline-block;
                        font-weight:500">{Escapar(boton.Value.Texto)}</a>
            </p>
            """;

        return $"""
            <!DOCTYPE html>
            <html lang="es"><head><meta charset="utf-8"></head>
            <body style="margin:0;padding:24px;background:#f6f7f9;
                         font-family:system-ui,-apple-system,'Segoe UI',sans-serif;
                         color:#1b1f24">
              <div style="max-width:520px;margin:0 auto;background:#ffffff;
                          border:1px solid #e3e6ea;border-radius:12px;
                          padding:28px 30px">

                <h1 style="font-size:18px;font-weight:600;margin:0 0 18px">
                  {Escapar(titulo)}</h1>

                <p style="margin:0 0 14px;font-size:15px">{saludo}</p>
                <p style="margin:0;font-size:15px;line-height:1.55">{cuerpo}</p>

                {botonHtml}

                <div style="border-top:1px solid #e3e6ea;margin-top:24px;
                            padding-top:16px;color:#5c6570;font-size:13px;
                            line-height:1.55">{pie}</div>
              </div>

              <div style="max-width:520px;margin:14px auto 0;color:#8a929c;
                          font-size:12px;text-align:center">
                {Escapar(_opciones.Nombre)}
              </div>
            </body></html>
            """;
    }

    private static string Escapar(string texto) =>
        texto.Replace("&", "&amp;").Replace("<", "&lt;").Replace(">", "&gt;");

    private static string AQuitarEtiquetas(string html) =>
        System.Text.RegularExpressions.Regex
            .Replace(html, "<[^>]+>", " ")
            .Replace("&nbsp;", " ")
            .Replace("&laquo;", "\"")
            .Replace("&raquo;", "\"")
            .Replace("&amp;", "&");
}

/// <summary>Un archivo que va en un correo: adjunto o incrustado.</summary>
public sealed record AdjuntoCorreo(string Nombre, string TipoMime, byte[] Datos);
'@

# --- Facturacion.Api\ServicioCorreosEntrega.cs
Planear 'Facturacion.Api\ServicioCorreosEntrega.cs' '552DE49F6ACE2A3B7530458F52D18494BCC797A6162609645B010DC344D134D9' @'
using System.Globalization;
using System.Net;
using Facturacion.Persistencia;

namespace Facturacion.Api;

/// <summary>
/// Manda el correo de entrega del portal: el comprobante aceptado, con el PDF
/// adjunto y un enlace de 400 días.
///
/// LA COLA LA LLENA LA BASE (disparador de la migración 022) en el mismo
/// instante en que el comprobante pasa a aceptado. Esto solo la vacía, cada
/// 30 segundos, igual que los webhooks.
///
/// VIVE EN LA API Y NO EN EL WORKER porque el PDF se genera aquí
/// (PdfDeComprobante). Llevarlo al worker obligaría a duplicar ese código, y
/// dos maneras de hacer el PDF acaban dando dos PDF distintos. La API corre
/// en una sola copia, como el worker. Si algún día corren varias, la cola ya
/// lo aguanta: cada vuelta aparta lo que toma (SKIP LOCKED).
///
/// CADA INTENTO CREA SU PROPIO ACCESO, y si el envío falla, se anula. El
/// identificador del enlace solo existe en claro mientras se arma el correo:
/// en la base queda su hash, así que un intento no puede reutilizar el del
/// anterior.
/// </summary>
public sealed class ServicioCorreosEntrega : BackgroundService
{
    private static readonly TimeSpan Ciclo = TimeSpan.FromSeconds(30);
    private const int Lote = 10;

    /// <summary>Hasta cuánto pesa un PDF para ir adjunto (decidido el 10 oct).</summary>
    private const int TopeAdjunto = 1024 * 1024;

    // Esperas entre intentos. Seis intentos en total, en unas nueve horas: lo
    // bastante para pasar una caída del servidor de correo, no tanto como
    // para que el cliente reciba el comprobante una semana tarde.
    private static readonly TimeSpan[] Esperas =
    {
        TimeSpan.FromMinutes(1), TimeSpan.FromMinutes(5), TimeSpan.FromMinutes(30),
        TimeSpan.FromHours(2), TimeSpan.FromHours(6)
    };

    private readonly RepositorioCorreosPortal _cola;
    private readonly RepositorioComprobantes _comprobantes;
    private readonly IAlmacenArchivos _archivos;
    private readonly ServicioCorreo _correo;
    private readonly OpcionesCorreo _opciones;
    private readonly ILogger<ServicioCorreosEntrega> _log;

    public ServicioCorreosEntrega(
        RepositorioCorreosPortal cola, RepositorioComprobantes comprobantes,
        IAlmacenArchivos archivos, ServicioCorreo correo, OpcionesCorreo opciones,
        ILogger<ServicioCorreosEntrega> log)
    {
        _cola = cola;
        _comprobantes = comprobantes;
        _archivos = archivos;
        _correo = correo;
        _opciones = opciones;
        _log = log;
    }

    protected override async Task ExecuteAsync(CancellationToken ct)
    {
        if (!_correo.Disponible)
        {
            // Los correos se quedan PENDIENTES, no se pierden: saldrán cuando
            // el correo esté configurado y la API se reinicie.
            _log.LogWarning(
                "Correo NO configurado: los correos de entrega del portal se " +
                "quedan en cola sin enviarse.");
            return;
        }

        _log.LogInformation(
            "Correos de entrega del portal: ciclo cada {Ciclo}, enlaces a {Url}.",
            Ciclo, _opciones.UrlPortalEfectiva);

        while (!ct.IsCancellationRequested)
        {
            try
            {
                var lote = await _cola.TomarPendientesAsync(Lote, ct);

                foreach (var pendiente in lote)
                    await ProcesarAsync(pendiente, ct);
            }
            catch (OperationCanceledException) when (ct.IsCancellationRequested)
            {
                break;
            }
            catch (Exception ex)
            {
                // Un fallo de la base no puede tumbar la API entera.
                _log.LogError(ex, "Falló una vuelta de los correos de entrega.");
            }

            try { await Task.Delay(Ciclo, ct); }
            catch (OperationCanceledException) { break; }
        }
    }

    private async Task ProcesarAsync(CorreoPendiente p, CancellationToken ct)
    {
        var d = await _cola.DatosAsync(p.TenantId, p.ComprobanteId, ct);

        // Lo que ya no tiene arreglo no se reintenta: se marca y se explica.
        var motivoOmitir =
            d is null ? "El comprobante ya no existe." :
            !d.EmpresaActiva ? "La empresa está desactivada." :
            d.Identificador is null ? "La empresa no tiene dirección del portal." :
            d.CorreoRespuesta is null ? "La empresa no tiene correo de respuesta." :
            d.Estado is not ("ACEPTADO" or "ACEPTADO_CON_OBSERVACIONES")
                ? $"El comprobante está en estado {d.Estado}." :
            null;

        if (motivoOmitir is not null || d is null)
        {
            await _cola.MarcarOmitidoAsync(p.Id, motivoOmitir ?? "Sin datos.", ct);
            return;
        }

        var pdf = await PdfAdjuntoAsync(p, d, ct);
        var logo = await LogoAsync(d, ct);

        var acceso = AccesoPortal.Nuevo();
        var accesoId = await _cola.CrearAccesoCorreoAsync(
            p.TenantId, p.ComprobanteId, AccesoPortal.Hash(acceso), ct);

        var enlace = $"{_opciones.UrlPortalEfectiva}/{d.Identificador}/e/{acceso}";

        var (asunto, html, texto) = PlantillaEntrega.Armar(d, enlace, pdf is not null, logo is not null);

        // LA COPIA AL EMISOR (migración 026): solo si la pidió, a su correo de
        // respuesta, y oculta. Lleva el mismo enlace que el del receptor: es su
        // propio comprobante, y así ve exactamente lo que recibió su cliente.
        var error = await _correo.EnviarEntregaAsync(
            p.Para, d.NombreEmisor, d.CorreoRespuesta!, asunto, html, texto, pdf, logo, ct,
            copiaOculta: d.CopiaAlEmisor ? d.CorreoRespuesta : null);

        if (error is null)
        {
            await _cola.MarcarEnviadoAsync(p.Id, accesoId, pdf is not null, ct);
            return;
        }

        var espera = p.Intentos > Esperas.Length ? (TimeSpan?)null : Esperas[p.Intentos - 1];

        await _cola.MarcarFalloAsync(p.Id, error, espera, accesoId, ct);
    }

    /// <summary>
    /// El PDF para adjuntar, o null si pesa más de 1 MB o no se pudo hacer.
    /// En los dos casos el correo sale igual, solo con el enlace: un PDF que
    /// falla no puede dejar al cliente sin su comprobante.
    /// </summary>
    private async Task<AdjuntoCorreo?> PdfAdjuntoAsync(
        CorreoPendiente p, DatosCorreoPortal d, CancellationToken ct)
    {
        try
        {
            var datos = await _comprobantes.ObtenerParaPdfAsync(p.TenantId, p.ComprobanteId, ct);
            if (datos is null) return null;

            var comprobante = PdfDeComprobante.Deserializar(datos);
            var bytes = await PdfDeComprobante.GenerarBytesAsync(comprobante, datos, _archivos, ct);

            return bytes.Length <= TopeAdjunto
                ? new AdjuntoCorreo($"{d.Ruc}-{d.TipoComprobante}-{d.Numero}.pdf", "application/pdf", bytes)
                : null;
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            _log.LogWarning(ex, "No se pudo generar el PDF de {Numero} para el correo; va solo el enlace.",
                d.Numero);
            return null;
        }
    }

    private async Task<AdjuntoCorreo?> LogoAsync(DatosCorreoPortal d, CancellationToken ct)
    {
        if (d.LogoRuta is null) return null;

        try
        {
            var bytes = await _archivos.LeerAsync(d.LogoRuta, ct);

            return bytes is not null && Marca.TipoDeImagen(bytes) is { } tipo
                ? new AdjuntoCorreo($"logo.{tipo.Extension}", tipo.TipoMime, bytes)
                : null;
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            return null;
        }
    }
}

/// <summary>
/// El correo que recibe el cliente del emisor.
///
/// SE VE DEL EMISOR, NO DE REYBAN: su nombre, su logo, su color. Tablas y
/// estilos en línea porque es lo único que respetan todos los clientes de
/// correo; nada de hojas de estilo ni de imágenes de fuera.
/// </summary>
public static class PlantillaEntrega
{
    // Los meses a mano y no con CultureInfo("es-PE"): en un contenedor con
    // globalización invariante esa cultura no existe y la llamada lanza.
    private static readonly string[] Meses =
    {
        "enero", "febrero", "marzo", "abril", "mayo", "junio", "julio",
        "agosto", "septiembre", "octubre", "noviembre", "diciembre"
    };

    private static string FechaLarga(DateTime f) => $"{f.Day} de {Meses[f.Month - 1]} de {f.Year}";

    private static string TipoLargo(string tipo) => tipo switch
    {
        "01" => "Factura electrónica",
        "03" => "Boleta de venta electrónica",
        "07" => "Nota de crédito electrónica",
        "08" => "Nota de débito electrónica",
        _ => "Comprobante electrónico"
    };

    private static string TipoCorto(string tipo) => tipo switch
    {
        "01" => "Factura",
        "03" => "Boleta",
        "07" => "Nota de crédito",
        "08" => "Nota de débito",
        _ => "Comprobante"
    };

    private static string Importe(decimal valor, string moneda)
    {
        var simbolo = moneda switch { "PEN" => "S/", "USD" => "US$", "EUR" => "€", _ => moneda };
        return $"{simbolo} {valor.ToString("#,##0.00", CultureInfo.InvariantCulture)}";
    }

    /// <summary>Blanco o casi negro sobre el color de la marca: el que se lea.</summary>
    private static string TextoSobre(string hex)
    {
        static double Canal(int c)
        {
            var v = c / 255.0;
            return v <= 0.03928 ? v / 12.92 : Math.Pow((v + 0.055) / 1.055, 2.4);
        }

        var n = Convert.ToInt32(hex[1..], 16);
        var l = 0.2126 * Canal(n >> 16 & 255) + 0.7152 * Canal(n >> 8 & 255) + 0.0722 * Canal(n & 255);
        return l > 0.4 ? "#111418" : "#ffffff";
    }

    public static (string Asunto, string Html, string Texto) Armar(
        DatosCorreoPortal d, string enlace, bool conPdf, bool conLogo)
    {
        static string E(string? t) => WebUtility.HtmlEncode(t ?? "");

        var color = d.ColorMarca is { Length: 7 } c && c[0] == '#' ? c : "#334155";
        var sobre = TextoSobre(color);
        var nombre = d.NombreEmisor;
        var fecha = d.FechaEmision.ToString("dd/MM/yyyy", CultureInfo.InvariantCulture);
        var importe = Importe(d.ImporteTotal, d.Moneda);
        var hasta = FechaLarga(DateTime.UtcNow.AddDays(400));
        var esBoleta = d.TipoComprobante == "03";

        var asunto = $"{TipoCorto(d.TipoComprobante)} {d.Numero} de {nombre}";

        var notaPdf = conPdf
            ? "Adjuntamos el PDF del comprobante."
            : "El PDF no va adjunto: descárgalo desde el botón.";

        var archivos = esBoleta ? "el PDF" : "el PDF, el XML y el CDR de SUNAT";

        var logoHtml = conLogo
            ? $"""<img src="cid:logo-emisor" alt="{E(nombre)}" style="max-height:56px;max-width:200px;display:block;margin:0 0 18px;border:0">"""
            : "";

        var html = $"""
            <!DOCTYPE html>
            <html lang="es"><head><meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1"></head>
            <body style="margin:0;padding:24px 12px;background:#f5f6f8;font-family:system-ui,-apple-system,'Segoe UI',Roboto,sans-serif;color:#1a1d21">
              <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:520px;margin:0 auto;background:#ffffff;border:1px solid #e2e5ea;border-radius:12px;border-collapse:separate;overflow:hidden">
                <tr><td style="height:5px;background:{color};font-size:0;line-height:0">&nbsp;</td></tr>
                <tr><td style="padding:26px 28px">
                  {logoHtml}
                  <p style="margin:0 0 4px;font-size:15px;color:#5d6672">{E(nombre)} te envió</p>
                  <p style="margin:0 0 18px;font-size:20px;font-weight:600">{E(TipoLargo(d.TipoComprobante))} {E(d.Numero)}</p>
                  <table role="presentation" cellpadding="0" cellspacing="0" style="font-size:15px;margin:0 0 22px">
                    <tr><td style="color:#5d6672;padding:3px 18px 3px 0">Fecha de emisión</td><td>{E(fecha)}</td></tr>
                    <tr><td style="color:#5d6672;padding:3px 18px 3px 0">Importe total</td><td>{E(importe)}</td></tr>
                  </table>
                  <a href="{E(enlace)}" style="background:{color};color:{sobre};text-decoration:none;padding:12px 24px;border-radius:8px;display:inline-block;font-weight:600;font-size:15px">Ver y descargar</a>
                  <p style="margin:18px 0 0;font-size:13.5px;color:#5d6672">{E(notaPdf)}</p>
                </td></tr>
                <tr><td style="border-top:1px solid #e2e5ea;padding:16px 28px;font-size:12.5px;color:#5d6672;line-height:1.6">
                  Desde el botón puedes descargar {E(archivos)} hasta el {E(hasta)}.
                  El enlace es personal: no lo compartas.<br>
                  ¿Dudas sobre este comprobante? Responde a este correo y le llegará a {E(nombre)}.
                </td></tr>
              </table>
              <p style="max-width:520px;margin:12px auto 0;text-align:center;font-size:11.5px;color:#8a929c">{E(d.RazonSocial)} · RUC {E(d.Ruc)}</p>
            </body></html>
            """;

        var texto =
            $"{nombre} te envió: {TipoLargo(d.TipoComprobante)} {d.Numero}\n\n" +
            $"Fecha de emisión: {fecha}\n" +
            $"Importe total: {importe}\n\n" +
            $"Ver y descargar: {enlace}\n\n" +
            $"{notaPdf}\n\n" +
            $"Desde el enlace puedes descargar {archivos} hasta el {hasta}. " +
            "El enlace es personal: no lo compartas.\n" +
            $"¿Dudas? Responde a este correo y le llegará a {nombre}.\n\n" +
            $"{d.RazonSocial} · RUC {d.Ruc}\n";

        return (asunto, html, texto);
    }
}
'@

# --- Facturacion.Persistencia\RepositorioAdmin.cs
Planear 'Facturacion.Persistencia\RepositorioAdmin.cs' '901F1ED4E5F68C347D184F0D89AAA9CEA7621827C248FEE362E71E7406486F4C' @'
using Dapper;
using Npgsql;

namespace Facturacion.Persistencia;

/// <summary>Una empresa vista desde el panel de administración.</summary>
public record TenantAdmin(
    Guid Id,
    string Ruc,
    string RazonSocial,
    string NombreComercial,
    string Ambiente,
    short MaxConcurrencia,
    bool Activo,
    DateTime CreadoEn,
    int Comprobantes,
    bool TieneCertificado,
    DateTime? CertificadoVence,
    int Series,
    int Claves,
    string? UsuarioSol,
    bool TieneClaveSol,
    bool GreHabilitado,
    string? GreClientId,
    bool TieneGreSecret,

    // La marca (migración 020). LogoVersion es un resumen de la ruta del
    // logo: cambia cuando se sube otro, y así el panel sabe que tiene que
    // volver a pedir la imagen en vez de enseñar la que tiene guardada. La
    // ruta en sí no sale del servicio.
    string? Identificador,
    string? ColorMarca,
    string? CorreoRespuesta,
    string? LogoVersion,

    // El alta (migración 024). DAPPER EMPAREJA POR POSICIÓN: estas columnas
    // van al final de la consulta en este mismo orden.
    string EstadoAlta,
    DateTime? AltaConfirmadaEn,
    DateTime? AbandonadaEn,
    string? ClaveAltaNombre,
    string? ClaveAltaPrefijo,

    // La dirección, para poder corregirla desde el panel, y si alguien la
    // revisó a propósito.
    string Ubigeo,
    string Direccion,
    string Distrito,
    string Provincia,
    string Departamento,
    DateTime? DireccionRevisadaEn,

    // Migración 026, AL FINAL: copia oculta al emisor de cada correo de
    // comprobante. Opcional, desactivada por defecto.
    bool CopiaAlEmisor)
{
    public bool EsProduccion => Ambiente == "produccion";

    public bool TieneLogo => LogoVersion is not null;

    /// <summary>Puede emitir guías en producción.</summary>
    public bool GreListo =>
        GreHabilitado &&
        !string.IsNullOrWhiteSpace(GreClientId) &&
        TieneGreSecret;
}

/// <summary>Datos para dar de alta una empresa.</summary>
public class NuevoTenant
{
    public string Ruc { get; set; } = "";
    public string RazonSocial { get; set; } = "";
    public string NombreComercial { get; set; } = "";
    public string Ubigeo { get; set; } = "150101";
    public string Direccion { get; set; } = "";
    public string Distrito { get; set; } = "";
    public string Provincia { get; set; } = "";
    public string Departamento { get; set; } = "";
    public string Ambiente { get; set; } = "beta";
    public string UsuarioSol { get; set; } = "MODDATOS";
    public short MaxConcurrencia { get; set; } = 1;

    /// <summary>
    /// El {empresa} del portal. Opcional al dar de alta: se puede poner
    /// después, pero una sola vez.
    /// </summary>
    public string? Identificador { get; set; }
}

/// <summary>Cómo terminó un intento de guardar la marca.</summary>
public enum ResultadoMarca
{
    Guardada,
    NoExiste,

    /// <summary>
    /// Ya tenía otro identificador. No se guardó NADA de la petición: ni el
    /// color ni el correo. A medias sería peor, porque el panel diría
    /// "error" y la mitad sí habría cambiado.
    /// </summary>
    IdentificadorFijo
}

/// <summary>Solo para leer el identificador actual con FOR UPDATE.</summary>
public record IdentificadorTenant(Guid Id, string? Identificador);

/// <summary>Lo que hace falta para guardar o servir el logo.</summary>
public record LogoTenant(string Ruc, string? LogoRuta);

/// <summary>Una serie de numeración.</summary>
/// <param name="Comprobantes">
/// Cuántos comprobantes se emitieron con esta serie. Determina si se puede
/// eliminar: con uno solo, ya hay histórico que conservar.
/// </param>
public record SerieAdmin(
    Guid Id,
    string TipoComprobante,
    string Serie,
    int UltimoCorrelativo,
    bool Activo,
    DateTime CreadoEn,
    int Comprobantes)
{
    /// <summary>
    /// Una serie sin comprobantes se puede borrar sin consecuencias.
    /// Con comprobantes, borrarla dejaría huérfano el rastro de esa
    /// numeración, y eso es un problema tributario, no de datos.
    /// </summary>
    public bool SePuedeEliminar => Comprobantes == 0;
}

/// <summary>Una clave de acceso, sin el secreto.</summary>
public record ClaveAdmin(
    Guid Id,
    string Nombre,
    string Prefijo,
    bool Activo,
    DateTime? UltimoUso,
    DateTime CreadoEn);

/// <summary>
/// Administración de empresas, series y claves de acceso.
///
/// Usa el rol de operador porque trabaja sobre todas las empresas y porque
/// crea filas en tablas que la aplicación normal solo puede leer.
///
/// TODO lo que hay aquí se hacía hasta ahora escribiendo SQL a mano. Eso
/// funciona mientras el sistema lo maneja quien lo construyó, y deja de
/// funcionar el día que hay que delegarlo. Un alta de empresa no debería
/// requerir saber PostgreSQL.
/// </summary>
public sealed class RepositorioAdmin
{
    private readonly string _cadenaOperador;

    public RepositorioAdmin(string cadenaConexionOperador)
    {
        _cadenaOperador = cadenaConexionOperador
            ?? throw new ArgumentNullException(nameof(cadenaConexionOperador));
    }

    private async Task<NpgsqlConnection> AbrirAsync(CancellationToken ct)
    {
        var conexion = new NpgsqlConnection(_cadenaOperador);
        await conexion.OpenAsync(ct);
        return conexion;
    }

    // ------------------------------------------------------------- empresas

    public async Task<IReadOnlyList<TenantAdmin>> ListarTenantsAsync(
        CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);

        var filas = await conexion.QueryAsync<TenantAdmin>(
            new CommandDefinition(
                """
                SELECT t.id               AS "Id",
                       t.ruc              AS "Ruc",
                       t.razon_social     AS "RazonSocial",
                       t.nombre_comercial AS "NombreComercial",
                       t.ambiente         AS "Ambiente",
                       t.max_concurrencia AS "MaxConcurrencia",
                       t.activo           AS "Activo",
                       t.creado_en        AS "CreadoEn",

                       (SELECT count(*)::int FROM comprobantes c
                         WHERE c.tenant_id = t.id)              AS "Comprobantes",

                       EXISTS (SELECT 1 FROM certificados ce
                                WHERE ce.tenant_id = t.id AND ce.activo)
                                                                AS "TieneCertificado",

                       (SELECT ce.valido_hasta FROM certificados ce
                         WHERE ce.tenant_id = t.id AND ce.activo
                         LIMIT 1)                               AS "CertificadoVence",

                       (SELECT count(*)::int FROM series s
                         WHERE s.tenant_id = t.id AND s.activo)  AS "Series",

                       (SELECT count(*)::int FROM api_keys k
                         WHERE k.tenant_id = t.id AND k.activo)  AS "Claves",

                       t.usuario_sol      AS "UsuarioSol",
                       (t.clave_sol_cifrada IS NOT NULL) AS "TieneClaveSol",
                       t.gre_habilitado   AS "GreHabilitado",
                       t.gre_client_id    AS "GreClientId",
                       (t.gre_client_secret_cifrado IS NOT NULL) AS "TieneGreSecret",

                       t.identificador    AS "Identificador",
                       t.color_marca      AS "ColorMarca",
                       t.correo_respuesta AS "CorreoRespuesta",
                       md5(t.logo_ruta)   AS "LogoVersion",

                       t.estado_alta        AS "EstadoAlta",
                       t.alta_confirmada_en AS "AltaConfirmadaEn",
                       t.abandonada_en      AS "AbandonadaEn",
                       ka.nombre            AS "ClaveAltaNombre",
                       ka.prefijo::text     AS "ClaveAltaPrefijo",

                       t.ubigeo::text       AS "Ubigeo",
                       t.direccion          AS "Direccion",
                       t.distrito           AS "Distrito",
                       t.provincia          AS "Provincia",
                       t.departamento       AS "Departamento",
                       t.direccion_revisada_en AS "DireccionRevisadaEn",

                       t.copia_al_emisor    AS "CopiaAlEmisor"

                  FROM tenants t
                  LEFT JOIN claves_alta ka ON ka.id = t.creado_por_clave_alta
                 -- Alfabético por razón social. Con cincuenta empresas, el
                 -- orden por fecha de alta obliga a recorrer toda la lista
                 -- para encontrar una; el alfabético permite ir directo.
                 ORDER BY t.razon_social
                """,
                cancellationToken: ct));

        return filas.ToList();
    }

    public async Task<Guid> CrearTenantAsync(
        NuevoTenant nuevo, CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);

        return await conexion.ExecuteScalarAsync<Guid>(new CommandDefinition(
            """
            INSERT INTO tenants
                (ruc, razon_social, nombre_comercial, ubigeo, direccion,
                 distrito, provincia, departamento, ambiente, usuario_sol,
                 max_concurrencia, identificador, direccion_revisada_en)
            VALUES
                (@Ruc, @RazonSocial, @NombreComercial, @Ubigeo, @Direccion,
                 @Distrito, @Provincia, @Departamento, @Ambiente, @UsuarioSol,
                 @MaxConcurrencia, @Identificador,
                 -- El panel ya no trae LIMA por defecto y exige la
                 -- dirección: quien la escribió la revisó.
                 now())
            RETURNING id
            """,
            nuevo, cancellationToken: ct));
    }

    public async Task<bool> ActualizarTenantAsync(
        Guid id, bool? activo, short? maxConcurrencia,
        CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);

        var filas = await conexion.ExecuteAsync(new CommandDefinition(
            """
            UPDATE tenants
               SET activo = COALESCE(@activo, activo),
                   max_concurrencia = COALESCE(@maxConcurrencia, max_concurrencia)
             WHERE id = @id
            """,
            new { id, activo, maxConcurrencia }, cancellationToken: ct));

        return filas > 0;
    }

    /// <summary>
    /// Corrige la dirección y la marca como revisada.
    ///
    /// LOS COMPROBANTES YA EMITIDOS NO CAMBIAN: su XML se firmó con la que
    /// tenían. Esto vale para los siguientes.
    /// </summary>
    public async Task<bool> GuardarDireccionAsync(
        Guid id, string ubigeo, string direccion, string distrito,
        string provincia, string departamento, CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);

        var filas = await conexion.ExecuteAsync(new CommandDefinition(
            """
            UPDATE tenants
               SET ubigeo = @ubigeo,
                   direccion = @direccion,
                   distrito = @distrito,
                   provincia = @provincia,
                   departamento = @departamento,
                   direccion_revisada_en = now()
             WHERE id = @id
            """,
            new { id, ubigeo, direccion, distrito, provincia, departamento },
            cancellationToken: ct));

        return filas > 0;
    }

    // ---------------------------------------------------------------- marca

    /// <summary>
    /// Guarda el identificador del portal, el color y el correo de respuesta.
    ///
    /// EL COLOR Y EL CORREO SE REEMPLAZAN SIEMPRE: null los quita. El panel
    /// manda los tres campos cada vez, así que lo que llega es el estado
    /// completo que se quiere.
    ///
    /// EL IDENTIFICADOR SOLO SE PONE SI NO HABÍA. Si ya había uno y llega
    /// otro, no se guarda nada y se devuelve IdentificadorFijo con el actual.
    /// La base lo impediría igual (disparador de la 020), pero aquí se
    /// detecta antes para dar un mensaje claro y no dejar nada a medias.
    ///
    /// Un identificador que ya usa otra empresa sale como PostgresException
    /// 23505: lo traduce el endpoint.
    /// </summary>
    public async Task<(ResultadoMarca Resultado, string? IdentificadorActual)> GuardarMarcaAsync(
        Guid id, string? identificador, string? colorMarca, string? correoRespuesta,
        bool copiaAlEmisor, CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);
        await using var transaccion = await conexion.BeginTransactionAsync(ct);

        // FOR UPDATE: dos pestañas guardando a la vez no pueden poner cada
        // una un identificador distinto.
        var fila = await conexion.QuerySingleOrDefaultAsync<IdentificadorTenant>(
            new CommandDefinition(
                """
                SELECT id AS "Id", identificador AS "Identificador"
                  FROM tenants
                 WHERE id = @id
                   FOR UPDATE
                """,
                new { id }, transaccion, cancellationToken: ct));

        if (fila is null)
            return (ResultadoMarca.NoExiste, null);

        if (fila.Identificador is not null &&
            identificador is not null &&
            identificador != fila.Identificador)
            return (ResultadoMarca.IdentificadorFijo, fila.Identificador);

        await conexion.ExecuteAsync(new CommandDefinition(
            """
            UPDATE tenants
               SET identificador    = COALESCE(identificador, @identificador),
                   color_marca      = @colorMarca,
                   correo_respuesta = @correoRespuesta,
                   -- Sin correo de respuesta no hay a dónde mandar la copia.
                   copia_al_emisor  = @copiaAlEmisor AND @correoRespuesta::text IS NOT NULL
             WHERE id = @id
            """,
            new { id, identificador, colorMarca, correoRespuesta, copiaAlEmisor },
            transaccion, cancellationToken: ct));

        await transaccion.CommitAsync(ct);

        return (ResultadoMarca.Guardada, fila.Identificador ?? identificador);
    }

    /// <summary>El RUC (para la carpeta del almacén) y la ruta del logo actual.</summary>
    public async Task<LogoTenant?> ObtenerLogoAsync(Guid id, CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);

        return await conexion.QuerySingleOrDefaultAsync<LogoTenant>(new CommandDefinition(
            """
            SELECT ruc AS "Ruc", logo_ruta AS "LogoRuta"
              FROM tenants
             WHERE id = @id
            """,
            new { id }, cancellationToken: ct));
    }

    /// <summary>
    /// Apunta la empresa a un logo ya guardado en el almacén.
    ///
    /// EL LOGO ANTERIOR NO SE BORRA del almacén: solo deja de apuntarse.
    /// Pesa unos kilobytes, y así un cambio por error se deshace volviendo a
    /// apuntar la ruta vieja.
    /// </summary>
    public async Task<bool> GuardarLogoAsync(Guid id, string ruta, CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);

        var filas = await conexion.ExecuteAsync(new CommandDefinition(
            "UPDATE tenants SET logo_ruta = @ruta WHERE id = @id",
            new { id, ruta }, cancellationToken: ct));

        return filas > 0;
    }

    /// <summary>
    /// Guarda las credenciales SOL de una empresa. La clave se cifra igual
    /// que los certificados.
    ///
    /// DEBE SER EL USUARIO SOL SECUNDARIO del contribuyente, nunca el
    /// principal. El principal puede hacer todo en el portal de SUNAT:
    /// declarar, pagar, modificar datos. Ese nivel de acceso no tiene por
    /// qué vivir en la base de datos de un proveedor.
    /// </summary>
    public async Task<bool> GuardarCredencialesSolAsync(
        Guid tenantId, string usuario, string clave,
        IProtectorDeSecretos protector, CancellationToken ct = default)
    {
        if (string.IsNullOrWhiteSpace(usuario))
            throw new ArgumentException("Falta el usuario SOL.", nameof(usuario));

        if (string.IsNullOrWhiteSpace(clave))
            throw new ArgumentException("Falta la clave SOL.", nameof(clave));

        var cifrada = protector.ProtegerTexto(clave);

        await using var conexion = await AbrirAsync(ct);

        var filas = await conexion.ExecuteAsync(new CommandDefinition(
            """
            UPDATE tenants
               SET usuario_sol = @usuario,
                   clave_sol_cifrada = @cifrada
             WHERE id = @tenantId
            """,
            new { tenantId, usuario, cifrada }, cancellationToken: ct));

        return filas > 0;
    }

    /// <summary>
    /// Guarda las credenciales de la API de guías de remisión.
    ///
    /// SON DISTINTAS DE LAS CREDENCIALES SOL. El contribuyente las genera en
    /// su menú SOL, opción "Credenciales de API SUNAT", una sola vez, y solo
    /// sirven para guías.
    ///
    /// Una empresa que emita facturas y guías tendrá los dos juegos: la clave
    /// SOL para las facturas, y estas dos para las guías.
    /// </summary>
    public async Task<bool> GuardarCredencialesGreAsync(
        Guid tenantId, string clientId, string clientSecret,
        IProtectorDeSecretos protector, CancellationToken ct = default)
    {
        if (string.IsNullOrWhiteSpace(clientId))
            throw new ArgumentException("Falta el client_id.", nameof(clientId));

        if (string.IsNullOrWhiteSpace(clientSecret))
            throw new ArgumentException("Falta el client_secret.", nameof(clientSecret));

        var cifrado = protector.ProtegerTexto(clientSecret);

        await using var conexion = await AbrirAsync(ct);

        var filas = await conexion.ExecuteAsync(new CommandDefinition(
            """
            UPDATE tenants
               SET gre_client_id = @clientId,
                   gre_client_secret_cifrado = @cifrado,

                   -- Guardar las credenciales habilita las guías: no tiene
                   -- sentido tenerlas cargadas y el módulo apagado.
                   gre_habilitado = true
             WHERE id = @tenantId
            """,
            new { tenantId, clientId = clientId.Trim(), cifrado },
            cancellationToken: ct));

        return filas > 0;
    }

    /// <summary>Activa o desactiva la emisión de guías.</summary>
    public async Task<bool> CambiarGreHabilitadoAsync(
        Guid tenantId, bool habilitado, CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);

        var filas = await conexion.ExecuteAsync(new CommandDefinition(
            "UPDATE tenants SET gre_habilitado = @habilitado WHERE id = @tenantId",
            new { tenantId, habilitado }, cancellationToken: ct));

        return filas > 0;
    }

    /// <summary>
    /// Cambia el ambiente de una empresa entre beta y producción.
    ///
    /// Quien llame debe haber comprobado antes que está lista: pasar a
    /// producción sin certificado válido o sin clave SOL hace que todas sus
    /// facturas fallen desde el primer minuto.
    /// </summary>
    public async Task<bool> CambiarAmbienteAsync(
        Guid tenantId, string ambiente, CancellationToken ct = default)
    {
        if (ambiente is not ("beta" or "produccion"))
            throw new ArgumentException(
                "El ambiente solo puede ser 'beta' o 'produccion'.", nameof(ambiente));

        await using var conexion = await AbrirAsync(ct);

        var filas = await conexion.ExecuteAsync(new CommandDefinition(
            "UPDATE tenants SET ambiente = @ambiente WHERE id = @tenantId",
            new { tenantId, ambiente }, cancellationToken: ct));

        return filas > 0;
    }

    // --------------------------------------------------------------- series

    public async Task<IReadOnlyList<SerieAdmin>> ListarSeriesAsync(
        Guid tenantId, CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);

        var filas = await conexion.QueryAsync<SerieAdmin>(
            new CommandDefinition(
                """
                SELECT s.id                 AS "Id",
                       s.tipo_comprobante   AS "TipoComprobante",
                       s.serie              AS "Serie",
                       s.ultimo_correlativo AS "UltimoCorrelativo",
                       s.activo             AS "Activo",
                       s.creado_en          AS "CreadoEn",

                       (SELECT count(*)::int FROM comprobantes c
                         WHERE c.tenant_id = s.tenant_id
                           AND c.tipo_comprobante = s.tipo_comprobante
                           AND c.serie = s.serie)  AS "Comprobantes"

                  FROM series s
                 WHERE s.tenant_id = @tenantId
                 -- La más reciente primero.
                 --
                 -- El orden por tipo y serie se lee mejor, pero obliga a
                 -- buscar en toda la tabla la que acabas de crear. Como una
                 -- empresa tiene pocas series, la comodidad de verla arriba
                 -- pesa más que la prolijidad del agrupamiento.
                 ORDER BY s.creado_en DESC
                """,
                new { tenantId }, cancellationToken: ct));

        return filas.ToList();
    }

    /// <summary>
    /// Da de alta una serie.
    ///
    /// EL CORRELATIVO INICIAL PUEDE NO SER CERO, y eso importa: cuando una
    /// empresa migra desde otro sistema, ya emitió comprobantes con esa serie.
    /// Empezar de nuevo en 1 generaría duplicados que SUNAT rechazaría, y
    /// obligaría a resolverlo con la administración tributaria.
    /// </summary>
    public async Task<Guid> CrearSerieAsync(
        Guid tenantId, string tipoComprobante, string serie,
        int correlativoInicial = 0, CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);

        return await conexion.ExecuteScalarAsync<Guid>(new CommandDefinition(
            """
            INSERT INTO series (tenant_id, tipo_comprobante, serie, ultimo_correlativo)
            VALUES (@tenantId, @tipoComprobante, @serie, @correlativoInicial)
            ON CONFLICT (tenant_id, tipo_comprobante, serie)
            DO UPDATE SET activo = true
            RETURNING id
            """,
            new { tenantId, tipoComprobante, serie, correlativoInicial },
            cancellationToken: ct));
    }

    /// <summary>
    /// Elimina una serie, pero SOLO si nunca se usó.
    ///
    /// La comprobación va dentro del mismo DELETE, no en una consulta previa:
    /// entre comprobar y borrar hay una ventana en la que alguien podría
    /// emitir un comprobante con esa serie. Hacerlo en una sola sentencia
    /// cierra esa ventana.
    ///
    /// Devuelve false si la serie no existe o si ya tiene comprobantes.
    /// </summary>
    public async Task<bool> EliminarSerieAsync(
        Guid tenantId, Guid serieId, CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);

        var filas = await conexion.ExecuteAsync(new CommandDefinition(
            """
            DELETE FROM series s
             WHERE s.id = @serieId
               AND s.tenant_id = @tenantId
               AND NOT EXISTS (
                     SELECT 1 FROM comprobantes c
                      WHERE c.tenant_id = s.tenant_id
                        AND c.tipo_comprobante = s.tipo_comprobante
                        AND c.serie = s.serie)
            """,
            new { tenantId, serieId }, cancellationToken: ct));

        return filas > 0;
    }

    /// <summary>
    /// Activa o desactiva una serie.
    ///
    /// Desactivarla impide emitir con ella, pero NO toca el histórico: los
    /// comprobantes ya emitidos siguen consultándose y descargándose igual.
    /// Es lo que se hace cuando una sucursal cierra, cuando cambia el esquema
    /// de numeración, o cuando hay que cerrar una serie y abrir otra.
    /// </summary>
    public async Task<bool> CambiarEstadoSerieAsync(
        Guid tenantId, Guid serieId, bool activo, CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);

        var filas = await conexion.ExecuteAsync(new CommandDefinition(
            """
            UPDATE series SET activo = @activo
             WHERE id = @serieId AND tenant_id = @tenantId
            """,
            new { tenantId, serieId, activo }, cancellationToken: ct));

        return filas > 0;
    }

    // --------------------------------------------------------------- claves

    public async Task<IReadOnlyList<ClaveAdmin>> ListarClavesAsync(
        Guid tenantId, CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);

        var filas = await conexion.QueryAsync<ClaveAdmin>(
            new CommandDefinition(
                """
                SELECT id         AS "Id",
                       nombre     AS "Nombre",
                       prefijo    AS "Prefijo",
                       activo     AS "Activo",
                       ultimo_uso AS "UltimoUso",
                       creado_en  AS "CreadoEn"
                  FROM api_keys
                 WHERE tenant_id = @tenantId
                 ORDER BY creado_en DESC
                """,
                new { tenantId }, cancellationToken: ct));

        return filas.ToList();
    }

    /// <summary>
    /// Crea una clave de acceso y devuelve el secreto EN CLARO.
    ///
    /// ES LA ÚNICA VEZ QUE ESE VALOR EXISTE FUERA DEL CLIENTE. En la base solo
    /// queda su hash, igual que con una contraseña. Si el cliente la pierde,
    /// no hay forma de recuperarla: se revoca y se emite otra.
    ///
    /// Eso es una molestia deliberada. La alternativa —guardarla en claro para
    /// poder mostrarla después— significaría que cualquiera con acceso a la
    /// base puede suplantar a todos tus clientes.
    /// </summary>
    public async Task<(Guid Id, string Clave)> CrearClaveAsync(
        Guid tenantId, string nombre, bool produccion = false,
        CancellationToken ct = default)
    {
        var clave = RepositorioTenants.GenerarClave(produccion);
        var hash = RepositorioTenants.CalcularHash(clave);
        var prefijo = clave[..Math.Min(20, clave.Length)];

        await using var conexion = await AbrirAsync(ct);

        var id = await conexion.ExecuteScalarAsync<Guid>(new CommandDefinition(
            """
            INSERT INTO api_keys (tenant_id, nombre, prefijo, hash)
            VALUES (@tenantId, @nombre, @prefijo, @hash)
            RETURNING id
            """,
            new { tenantId, nombre, prefijo, hash }, cancellationToken: ct));

        return (id, clave);
    }

    /// <summary>
    /// Revoca una clave. No se borra: se desactiva.
    ///
    /// Borrarla dejaría sin rastro quién tenía acceso y hasta cuándo, y esa
    /// es justo la pregunta que hay que poder responder después de un
    /// incidente de seguridad.
    /// </summary>
    public async Task<bool> RevocarClaveAsync(
        Guid claveId, CancellationToken ct = default)
    {
        await using var conexion = await AbrirAsync(ct);

        var filas = await conexion.ExecuteAsync(new CommandDefinition(
            """
            UPDATE api_keys
               SET activo = false, revocado_en = now()
             WHERE id = @claveId AND activo
            """,
            new { claveId }, cancellationToken: ct));

        return filas > 0;
    }
}
'@

# --- Facturacion.Api\EndpointsAdmin.cs
Planear 'Facturacion.Api\EndpointsAdmin.cs' 'AB46329D719A4CE663052DC8527C6C92900BB4C40CCB6E6C56DF0B4E9ED210CB' @'
using System.Security.Cryptography;
using Facturacion.Persistencia;
using Microsoft.AspNetCore.Mvc;

namespace Facturacion.Api;

/// <summary>
/// Administración de la plataforma: empresas, certificados, series y claves.
///
/// Todo esto se hacía hasta ahora escribiendo SQL a mano, lo cual funciona
/// mientras el sistema lo maneja quien lo construyó. Deja de funcionar el día
/// que hay que delegarlo, y ese día llega antes de lo que parece.
/// </summary>
public static class EndpointsAdmin
{
    public static void MapearAdministracion(this WebApplication app)
    {
        // CADA ACCIÓN EXIGE SU PROPIO PERMISO, no un rol entero.
        //
        // Quien da de alta clientes no necesita cargar certificados, y quien
        // atiende llamadas no necesita crear empresas. Repartirlo así permite
        // dar a cada persona exactamente lo que usa.
        var grupo = app.MapGroup("/admin")
            .AddEndpointFilter<AutenticacionPanel>()
            .WithTags("Administración");

        // ------------------------------------------------------------ empresas

        grupo.MapGet("/tenants", async (
            RepositorioAdmin admin, CancellationToken ct) =>
            Results.Ok(await admin.ListarTenantsAsync(ct)))
            .AddEndpointFilter(new ExigirPermiso(Permiso.EmpresasVer))
        .WithSummary("Lista las empresas");

        grupo.MapPost("/tenants", async (
            NuevoTenant nuevo, RepositorioAdmin admin, CancellationToken ct) =>
        {
            if (nuevo.Ruc.Length != 11 || !nuevo.Ruc.All(char.IsDigit))
                return Results.BadRequest(new RespuestaError(
                    "RUC inválido.", "Debe tener exactamente 11 dígitos."));

            if (string.IsNullOrWhiteSpace(nuevo.RazonSocial))
                return Results.BadRequest(new RespuestaError(
                    "Falta la razón social."));

            // El identificador del portal es opcional al dar de alta.
            nuevo.Identificador = Marca.LimpiarIdentificador(nuevo.Identificador);

            if (Marca.ProblemaIdentificador(nuevo.Identificador) is { } problema)
                return Results.BadRequest(new RespuestaError(
                    "El identificador del portal no es válido.", problema));

            // LA DIRECCIÓN, COMPLETA Y COHERENTE CON EL UBIGEO (diseño §13.4).
            // El formulario ya no trae LIMA por defecto: lo que llega lo
            // escribió alguien, y por eso queda como revisada.
            var (dir, problemaDir) = Direccion.Revisar(
                nuevo.Ubigeo, nuevo.Direccion, nuevo.Distrito, nuevo.Provincia, nuevo.Departamento);

            if (dir is null)
                return Results.BadRequest(new RespuestaError("La dirección no es válida.", problemaDir));

            nuevo.Ubigeo = dir.Ubigeo;
            nuevo.Direccion = dir.Direccion;
            nuevo.Distrito = dir.Distrito;
            nuevo.Provincia = dir.Provincia;
            nuevo.Departamento = dir.Departamento;

            try
            {
                var id = await admin.CrearTenantAsync(nuevo, ct);
                return Results.Ok(new { id, mensaje = "Empresa creada." });
            }
            catch (Npgsql.PostgresException ex) when (
                ex.SqlState == "23505" && ex.ConstraintName == "ux_tenants_identificador")
            {
                return Results.Conflict(IdentificadorEnUso(nuevo.Identificador));
            }
            catch (Npgsql.PostgresException ex) when (ex.SqlState == "23505")
            {
                // Violación de unicidad: el RUC ya existe (ux_tenants_ruc_vigente,
                // desde la 024: entre las empresas no abandonadas).
                return Results.Conflict(new RespuestaError(
                    "Ese RUC ya está registrado.",
                    "Cada empresa se da de alta una sola vez. Si la creó la plataforma y " +
                    "sale «sin confirmar», espera a que se confirme o se dé por abandonada."));
            }
        })
        .AddEndpointFilter(new ExigirPermiso(Permiso.EmpresasEditar))
        .WithSummary("Da de alta una empresa");

        grupo.MapPatch("/tenants/{id:guid}", async (
            Guid id, ActualizacionTenant cambios,
            RepositorioAdmin admin, CancellationToken ct) =>
        {
            bool actualizado;

            try
            {
                actualizado = await admin.ActualizarTenantAsync(
                    id, cambios.Activo, cambios.MaxConcurrencia, ct);
            }
            catch (Npgsql.PostgresException ex) when (ex.SqlState == "P0001")
            {
                // El disparador de la 024: un alta abandonada no se reactiva.
                return Results.Conflict(new RespuestaError(
                    "Esta empresa no se puede reactivar.", ex.MessageText));
            }

            return actualizado
                ? Results.Ok(new { mensaje = "Empresa actualizada." })
                : Results.NotFound(new RespuestaError("No se encontró la empresa."));
        })
        .AddEndpointFilter(new ExigirPermiso(Permiso.EmpresasEditar))
        .WithSummary("Activa, desactiva o ajusta la concurrencia");

        // --------------------------------------------------------------- marca

        grupo.MapPut("/tenants/{id:guid}/marca", async (
            Guid id, CambioMarca cambio,
            RepositorioAdmin admin, CancellationToken ct) =>
        {
            var identificador = Marca.LimpiarIdentificador(cambio.Identificador);
            var color = Marca.LimpiarColor(cambio.ColorMarca);
            var correo = Marca.LimpiarCorreo(cambio.CorreoRespuesta);

            if (Marca.ProblemaIdentificador(identificador) is { } pi)
                return Results.BadRequest(new RespuestaError(
                    "El identificador del portal no es válido.", pi));

            if (Marca.ProblemaColor(color) is { } pc)
                return Results.BadRequest(new RespuestaError("El color no es válido.", pc));

            if (Marca.ProblemaCorreo(correo) is { } pr)
                return Results.BadRequest(new RespuestaError(
                    "El correo de respuesta no es válido.", pr));

            try
            {
                var (resultado, actual) = await admin.GuardarMarcaAsync(
                    id, identificador, color, correo, cambio.CopiaAlEmisor ?? false, ct);

                return resultado switch
                {
                    ResultadoMarca.NoExiste =>
                        Results.NotFound(new RespuestaError("No se encontró la empresa.")),

                    ResultadoMarca.IdentificadorFijo =>
                        Results.Conflict(new RespuestaError(
                            "El identificador del portal no se puede cambiar.",
                            $"Esta empresa ya es «{actual}». Es la dirección que va " +
                            "en los correos ya enviados: cambiarla rompería esos " +
                            "enlaces. No se guardó nada.")),

                    _ => Results.Ok(new { mensaje = "Marca guardada.", identificador = actual })
                };
            }
            catch (Npgsql.PostgresException ex) when (
                ex.SqlState == "23505" && ex.ConstraintName == "ux_tenants_identificador")
            {
                return Results.Conflict(IdentificadorEnUso(identificador));
            }
        })
        .AddEndpointFilter(new ExigirPermiso(Permiso.EmpresasEditar))
        .WithSummary("Guarda el identificador del portal, el color y el correo de respuesta")
        .WithDescription(
            "Se mandan los tres campos cada vez. El color y el correo se " +
            "reemplazan: vacío los quita. El identificador solo se puede poner " +
            "una vez; si ya tiene uno y llega otro, responde 409 y no guarda " +
            "nada.");

        grupo.MapGet("/tenants/{id:guid}/logo", async (
            Guid id, HttpContext contexto,
            RepositorioAdmin admin, IAlmacenArchivos archivos, CancellationToken ct) =>
        {
            var logo = await admin.ObtenerLogoAsync(id, ct);

            if (logo?.LogoRuta is not { } ruta)
                return Results.NotFound(new RespuestaError("Esta empresa no tiene logo."));

            var datos = await archivos.LeerAsync(ruta, ct);

            if (datos is null || Marca.TipoDeImagen(datos) is not { } tipo)
                return Results.NotFound(new RespuestaError(
                    "No se encontró el archivo del logo en el almacén."));

            // La dirección lleva ?v=<versión>, que cambia al subir otro logo.
            // Por eso se puede guardar un día sin miedo a enseñar el viejo.
            contexto.Response.Headers.CacheControl = "private, max-age=86400";
            contexto.Response.Headers["X-Content-Type-Options"] = "nosniff";

            return Results.File(datos, tipo.TipoMime);
        })
        .AddEndpointFilter(new ExigirPermiso(Permiso.EmpresasVer))
        .WithSummary("El logo de la empresa, para verlo en el panel");

        grupo.MapPost("/tenants/{id:guid}/logo", async (
            Guid id, IFormFile archivo,
            RepositorioAdmin admin, IAlmacenArchivos archivos, CancellationToken ct) =>
        {
            if (archivo.Length == 0)
                return Results.BadRequest(new RespuestaError("El archivo está vacío."));

            if (archivo.Length > Marca.LogoMaximoBytes)
                return Results.BadRequest(new RespuestaError(
                    "El logo es demasiado grande.",
                    $"Pesa {archivo.Length / 1024} KB y el máximo es " +
                    $"{Marca.LogoMaximoBytes / 1024} KB. Exporta una versión más " +
                    "pequeña: en el PDF se imprime a 50 puntos de alto."));

            using var memoria = new MemoryStream();
            await archivo.CopyToAsync(memoria, ct);
            var datos = memoria.ToArray();

            if (Marca.TipoDeImagen(datos) is not { } tipo)
                return Results.BadRequest(new RespuestaError(
                    "El logo tiene que ser PNG o JPG.",
                    "Se comprueba por el contenido del archivo, no por su nombre."));

            if (Marca.ProblemaAlDibujar(datos) is { } problema)
                return Results.BadRequest(new RespuestaError("No se puede usar ese logo.", problema));

            var empresa = await admin.ObtenerLogoAsync(id, ct);

            if (empresa is null)
                return Results.NotFound(new RespuestaError("No se encontró la empresa."));

            // El nombre sale del contenido: el mismo logo subido dos veces es
            // el mismo archivo, y uno distinto nunca pisa al anterior.
            var huella = Convert.ToHexString(SHA256.HashData(datos))[..16].ToLowerInvariant();

            var ruta = await archivos.GuardarAsync(
                empresa.Ruc, DateTime.UtcNow, $"logo-{huella}.{tipo.Extension}", datos, ct);

            await admin.GuardarLogoAsync(id, ruta, ct);

            return Results.Ok(new { mensaje = "Logo guardado. Ya sale en los PDF." });
        })
        .DisableAntiforgery()
        .AddEndpointFilter(new ExigirPermiso(Permiso.EmpresasEditar))
        .WithSummary("Sube el logo de la empresa")
        .WithDescription(
            "PNG o JPG, máximo 300 KB. Se comprueba que se puede dibujar antes " +
            "de guardarlo. El anterior no se borra del almacén: solo deja de " +
            "usarse.");

        // ------------------------------------------------- credenciales SOL

        grupo.MapPost("/tenants/{id:guid}/credenciales-sol", async (
            Guid id, CredencialesSol credenciales,
            RepositorioAdmin admin, IProtectorDeSecretos protector,
            CancellationToken ct) =>
        {
            if (credenciales.Usuario.Equals("MODDATOS", StringComparison.OrdinalIgnoreCase))
            {
                return Results.BadRequest(new RespuestaError(
                    "MODDATOS es el usuario del ambiente de pruebas.",
                    "Para producción hace falta el usuario SOL secundario real " +
                    "del contribuyente."));
            }

            try
            {
                var guardadas = await admin.GuardarCredencialesSolAsync(
                    id, credenciales.Usuario, credenciales.Clave, protector, ct);

                return guardadas
                    ? Results.Ok(new { mensaje = "Credenciales guardadas y cifradas." })
                    : Results.NotFound(new RespuestaError("No se encontró la empresa."));
            }
            catch (ArgumentException ex)
            {
                return Results.BadRequest(new RespuestaError("Datos inválidos.", ex.Message));
            }
        })
        .AddEndpointFilter(new ExigirPermiso(Permiso.ProduccionCambiar))
        .WithSummary("Guarda las credenciales SOL del contribuyente")
        .WithDescription(
            "La clave se cifra igual que el certificado.\n\n" +
            "Debe ser el usuario SOL SECUNDARIO, nunca el principal: el " +
            "principal puede declarar, pagar y modificar datos en el portal " +
            "de SUNAT, y ese nivel de acceso no tiene por qué vivir aquí.");

        // ------------------------------------------- credenciales de guías

        grupo.MapPost("/tenants/{id:guid}/credenciales-gre", async (
            Guid id, CredencialesGre credenciales,
            RepositorioAdmin admin, IProtectorDeSecretos protector,
            CancellationToken ct) =>
        {
            try
            {
                var guardadas = await admin.GuardarCredencialesGreAsync(
                    id, credenciales.ClientId, credenciales.ClientSecret,
                    protector, ct);

                return guardadas
                    ? Results.Ok(new
                    {
                        mensaje =
                            "Credenciales de guías guardadas y cifradas. " +
                            "La emisión de guías queda habilitada."
                    })
                    : Results.NotFound(new RespuestaError("No se encontró la empresa."));
            }
            catch (ArgumentException ex)
            {
                return Results.BadRequest(new RespuestaError("Datos inválidos.", ex.Message));
            }
        })
        .AddEndpointFilter(new ExigirPermiso(Permiso.ProduccionCambiar))
        .WithSummary("Guarda las credenciales de API para guías de remisión")
        .WithDescription(
            "El client_id y el client_secret los genera el contribuyente en " +
            "su menú SOL, opción 'Credenciales de API SUNAT'.\n\n" +
            "Son DISTINTAS de la clave SOL: esta sirve para las facturas, " +
            "aquellas solo para guías. Una empresa que emita ambas cosas " +
            "necesita los dos juegos.");

        grupo.MapPost("/tenants/{id:guid}/gre-habilitado", async (
            Guid id, CambioGreHabilitado cambio,
            RepositorioAdmin admin, CancellationToken ct) =>
        {
            var cambiado = await admin.CambiarGreHabilitadoAsync(
                id, cambio.Habilitado, ct);

            return cambiado
                ? Results.Ok(new
                {
                    mensaje = cambio.Habilitado
                        ? "Emisión de guías habilitada."
                        : "Emisión de guías deshabilitada."
                })
                : Results.NotFound(new RespuestaError("No se encontró la empresa."));
        })
        .AddEndpointFilter(new ExigirPermiso(Permiso.ProduccionCambiar))
        .WithSummary("Activa o desactiva la emisión de guías");

        grupo.MapGet("/tenants/{id:guid}/revision-produccion", async (
            Guid id, ProveedorCredenciales credenciales, CancellationToken ct) =>
            Results.Ok(await credenciales.RevisarAsync(id, ct)))
            .AddEndpointFilter(new ExigirPermiso(Permiso.EmpresasVer))
            .WithSummary("Comprueba si la empresa puede pasar a producción")
            .WithDescription(
                "Revisa certificado, credenciales SOL y series. Pasar a " +
                "producción sin alguno de ellos hace que todas las facturas " +
                "de esa empresa fallen desde el primer minuto.");

        grupo.MapPost("/tenants/{id:guid}/ambiente", async (
            Guid id, CambioAmbiente cambio,
            RepositorioAdmin admin, ProveedorCredenciales credenciales,
            CancellationToken ct) =>
        {
            // Volver a beta siempre se permite: es la salida cuando algo va mal.
            if (cambio.Ambiente == "beta")
            {
                var vuelto = await admin.CambiarAmbienteAsync(id, "beta", ct);

                return vuelto
                    ? Results.Ok(new { mensaje = "La empresa volvió al ambiente de pruebas." })
                    : Results.NotFound(new RespuestaError("No se encontró la empresa."));
            }

            // Pasar a producción NO. Se comprueba antes.
            var revision = await credenciales.RevisarAsync(id, ct);

            if (!revision.Listo)
            {
                return Results.BadRequest(new RespuestaError(
                    "La empresa todavía no puede pasar a producción.",
                    string.Join(" ", revision.Faltantes)));
            }

            var cambiado = await admin.CambiarAmbienteAsync(id, "produccion", ct);

            return cambiado
                ? Results.Ok(new
                {
                    mensaje = "La empresa pasó a producción.",
                    advertencias = revision.Advertencias
                })
                : Results.NotFound(new RespuestaError("No se encontró la empresa."));
        })
        .AddEndpointFilter(new ExigirPermiso(Permiso.ProduccionCambiar))
        .WithSummary("Cambia el ambiente de la empresa")
        .WithDescription(
            "Pasar a producción exige superar la revisión previa. Volver a " +
            "beta siempre se permite: es la salida cuando algo va mal.");

        // -------------------------------------------------------- certificados

        grupo.MapPost("/tenants/{id:guid}/certificado", async (
            Guid id,
            IFormFile archivo,

            // LA CONTRASEÑA VA EN EL CUERPO, NO EN LA DIRECCIÓN.
            //
            // Antes llegaba como ?clave=... y una dirección queda escrita en
            // los registros de acceso del proxy, en los de cualquier
            // intermediario y en las trazas de error. La contraseña de un
            // certificado no puede acabar en un log.
            [FromForm] string? clave,
            AlmacenCertificados certificados,
            CancellationToken ct) =>
        {
            if (archivo.Length == 0)
                return Results.BadRequest(new RespuestaError("El archivo está vacío."));

            // Un PFX legítimo no llega a este tamaño. El límite evita que
            // alguien suba un archivo enorme y agote la memoria del proceso.
            if (archivo.Length > 512 * 1024)
                return Results.BadRequest(new RespuestaError(
                    "El archivo es demasiado grande.",
                    "Un certificado PFX pesa unos pocos kilobytes."));

            using var memoria = new MemoryStream();
            await archivo.CopyToAsync(memoria, ct);

            try
            {
                var certificadoId = await certificados.GuardarAsync(
                    id, memoria.ToArray(), clave ?? "", ct);

                return Results.Ok(new
                {
                    id = certificadoId,
                    mensaje = "Certificado guardado y cifrado."
                });
            }
            catch (InvalidOperationException ex)
            {
                // Contraseña incorrecta, certificado vencido, o sin llave
                // privada. El mensaje de AlmacenCertificados ya explica cuál.
                return Results.BadRequest(new RespuestaError(
                    "No se pudo guardar el certificado.", ex.Message));
            }
        })
        .DisableAntiforgery()
        .AddEndpointFilter(new ExigirPermiso(Permiso.CertificadosGestionar))
        .WithSummary("Carga el certificado digital de una empresa")
        .WithDescription(
            "El archivo .pfx se cifra antes de guardarse. Solo se descifra en " +
            "memoria y solo en el momento de firmar.\\n\\n" +
            "Reemplaza al certificado activo anterior, que queda desactivado " +
            "en la misma operación: nunca hay dos activos ni un hueco sin " +
            "ninguno.");

        grupo.MapGet("/tenants/{id:guid}/certificados", async (
            Guid id, AlmacenCertificados certificados, CancellationToken ct) =>
            Results.Ok(await certificados.ListarAsync(id, ct)))
            .AddEndpointFilter(new ExigirPermiso(Permiso.EmpresasVer))
            .WithSummary("Lista los certificados de una empresa");

        grupo.MapDelete("/tenants/{id:guid}/certificados/{certificadoId:guid}", async (
            Guid id, Guid certificadoId,
            AlmacenCertificados certificados, CancellationToken ct) =>
        {
            var eliminado = await certificados.EliminarAsync(id, certificadoId, ct);

            return eliminado
                ? Results.Ok(new { mensaje = "Certificado eliminado." })
                : Results.Conflict(new RespuestaError(
                    "No se puede eliminar este certificado.",
                    "O está activo, o ya firmó comprobantes. Un certificado " +
                    "que firmó hay que conservarlo: sin él no se puede " +
                    "verificar esas firmas durante una fiscalización."));
        })
        .AddEndpointFilter(new ExigirPermiso(Permiso.CertificadosGestionar))
        .WithSummary("Elimina un certificado nunca usado")
        .WithDescription(
            "Para el caso de haber cargado el archivo equivocado. Solo " +
            "funciona si el certificado está inactivo y nunca firmó nada.");

        // -------------------------------------------------------------- series

        grupo.MapGet("/tenants/{id:guid}/series", async (
            Guid id, RepositorioAdmin admin, CancellationToken ct) =>
            Results.Ok(await admin.ListarSeriesAsync(id, ct)))
            .AddEndpointFilter(new ExigirPermiso(Permiso.EmpresasVer))
            .WithSummary("Lista las series de una empresa");

        grupo.MapPost("/tenants/{id:guid}/series", async (
            Guid id, NuevaSerie nueva,
            RepositorioAdmin admin, CancellationToken ct) =>
        {
            if (string.IsNullOrWhiteSpace(nueva.Serie) || nueva.Serie.Length != 4)
                return Results.BadRequest(new RespuestaError(
                    "Serie inválida.",
                    "Debe tener 4 caracteres. Ej: F001 para facturas, B001 para boletas."));

            var serieId = await admin.CrearSerieAsync(
                id, nueva.TipoComprobante, nueva.Serie.ToUpperInvariant(),
                nueva.CorrelativoInicial, ct);

            return Results.Ok(new { id = serieId, mensaje = "Serie dada de alta." });
        })
        .AddEndpointFilter(new ExigirPermiso(Permiso.EmpresasEditar))
        .WithSummary("Da de alta una serie")
        .WithDescription(
            "El correlativo inicial normalmente es 0, pero si la empresa migra " +
            "desde otro sistema hay que poner el último número que ya emitió. " +
            "Empezar de nuevo en 1 generaría duplicados que SUNAT rechaza.");

        grupo.MapDelete("/tenants/{id:guid}/series/{serieId:guid}", async (
            Guid id, Guid serieId, RepositorioAdmin admin, CancellationToken ct) =>
        {
            var eliminada = await admin.EliminarSerieAsync(id, serieId, ct);

            return eliminada
                ? Results.Ok(new { mensaje = "Serie eliminada." })
                : Results.Conflict(new RespuestaError(
                    "No se puede eliminar esta serie.",
                    "Ya tiene comprobantes emitidos. Borrarla dejaría huérfano " +
                    "el rastro de esa numeración. Desactívala: deja de poder " +
                    "emitir y el histórico queda intacto."));
        })
        .AddEndpointFilter(new ExigirPermiso(Permiso.EmpresasEditar))
        .WithSummary("Elimina una serie sin usar")
        .WithDescription(
            "Solo funciona si la serie nunca emitió comprobantes. En caso " +
            "contrario hay que desactivarla.");

        grupo.MapPatch("/tenants/{id:guid}/series/{serieId:guid}", async (
            Guid id, Guid serieId, CambioEstadoSerie cambio,
            RepositorioAdmin admin, CancellationToken ct) =>
        {
            var cambiada = await admin.CambiarEstadoSerieAsync(
                id, serieId, cambio.Activo, ct);

            return cambiada
                ? Results.Ok(new { mensaje = cambio.Activo
                    ? "Serie reactivada." : "Serie desactivada." })
                : Results.NotFound(new RespuestaError("No se encontró la serie."));
        })
        .AddEndpointFilter(new ExigirPermiso(Permiso.EmpresasEditar))
        .WithSummary("Activa o desactiva una serie")
        .WithDescription(
            "Una serie desactivada no puede emitir, pero sus comprobantes " +
            "siguen consultándose y descargándose igual.");

        // -------------------------------------------------------------- claves

        grupo.MapGet("/tenants/{id:guid}/claves", async (
            Guid id, RepositorioAdmin admin, CancellationToken ct) =>
            Results.Ok(await admin.ListarClavesAsync(id, ct)))
            .AddEndpointFilter(new ExigirPermiso(Permiso.EmpresasVer))
            .WithSummary("Lista las claves de acceso de una empresa");

        grupo.MapPost("/tenants/{id:guid}/claves", async (
            Guid id, NuevaClave nueva,
            RepositorioAdmin admin, CancellationToken ct) =>
        {
            var (claveId, secreto) = await admin.CrearClaveAsync(
                id, nueva.Nombre, nueva.Produccion, ct);

            return Results.Ok(new
            {
                id = claveId,
                clave = secreto,
                aviso =
                    "Esta es la ÚNICA vez que se muestra la clave. En la base " +
                    "solo queda su hash. Si se pierde, hay que revocarla y " +
                    "emitir otra."
            });
        })
        .AddEndpointFilter(new ExigirPermiso(Permiso.ClavesGestionar))
        .WithSummary("Emite una clave de acceso")
        .WithDescription(
            "Devuelve el secreto en claro UNA sola vez. Después ya no se puede " +
            "recuperar, igual que con una contraseña.");

        grupo.MapDelete("/claves/{claveId:guid}", async (
            Guid claveId, RepositorioAdmin admin, CancellationToken ct) =>
        {
            var revocada = await admin.RevocarClaveAsync(claveId, ct);

            return revocada
                ? Results.Ok(new { mensaje = "Clave revocada." })
                : Results.NotFound(new RespuestaError(
                    "No se encontró la clave, o ya estaba revocada."));
        })
        .AddEndpointFilter(new ExigirPermiso(Permiso.ClavesGestionar))
        .WithSummary("Revoca una clave")
        .WithDescription(
            "La clave se desactiva, no se borra. Borrarla dejaría sin rastro " +
            "quién tuvo acceso y hasta cuándo, que es justo lo que hay que " +
            "poder responder después de un incidente.");
    }

    private static RespuestaError IdentificadorEnUso(string? identificador) =>
        new("Ese identificador ya lo usa otra empresa.",
            $"«{identificador}» está tomado. Prueba con el nombre comercial y la " +
            "ciudad, por ejemplo ferreteria-lopez-arequipa.");
}

public record ActualizacionTenant(bool? Activo, short? MaxConcurrencia);

/// <param name="CopiaAlEmisor">
/// Migración 026: copia oculta de cada correo de comprobante al correo de
/// respuesta. Opcional; si no viene, queda desactivada.
/// </param>
public record CambioMarca(
    string? Identificador, string? ColorMarca, string? CorreoRespuesta, bool? CopiaAlEmisor = null);

public record NuevaSerie(
    string TipoComprobante,
    string Serie,
    int CorrelativoInicial = 0);

public record NuevaClave(string Nombre, bool Produccion = false);

public record CambioEstadoSerie(bool Activo);

public record CredencialesSol(string Usuario, string Clave);

public record CambioAmbiente(string Ambiente);

public record CredencialesGre(string ClientId, string ClientSecret);

public record CambioGreHabilitado(bool Habilitado);
'@

# --- Facturacion.Api\wwwroot\admin.html
Planear 'Facturacion.Api\wwwroot\admin.html' '0CEC019A2B73A4E7D9860B8E2379E0CB352635E13A259C866277D628933578EB' @'
<!DOCTYPE html>
<html lang="es">
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Empresas · Facturación electrónica</title>
    <style>
           :root {
               --fondo: #f6f7f9;
               --panel: #ffffff;
               --sutil: #f1f3f5;
               --borde: #e3e6ea;
               --borde-fuerte: #cfd4da;
               --texto: #1b1f24;
               --tenue: #5c6570;
               --apagado: #8a929c;
               --acento: #2563eb;
               --acento-fondo: #eef4ff;
               --ok: #15803d;
               --ok-fondo: #eaf6ee;
               --aviso: #a16207;
               --aviso-fondo: #fdf5e3;
               --mal: #b91c1c;
               --mal-fondo: #fdeded;
               --radio: 8px;
           }

           @media (prefers-color-scheme: dark) {
               :root {
                   --fondo: #0f1115;
                   --panel: #171a21;
                   --sutil: #1c212b;
                   --borde: #262b36;
                   --borde-fuerte: #3a4152;
                   --texto: #e6e8ec;
                   --tenue: #98a1ae;
                   --apagado: #6f7884;
                   --acento: #4493f8;
                   --acento-fondo: #12233c;
                   --ok: #3fb950;
                   --ok-fondo: #122a18;
                   --aviso: #d29922;
                   --aviso-fondo: #2b2311;
                   --mal: #f85149;
                   --mal-fondo: #2d1516;
               }
           }

           * {
               box-sizing: border-box;
           }

           body {
               margin: 0;
               padding: 22px;
               background: var(--fondo);
               color: var(--texto);
               font: 15px/1.55 ui-sans-serif, system-ui, "Segoe UI", sans-serif;
           }

           .contenedor {
               max-width: 1180px;
               margin: 0 auto;
           }

           header {
               display: flex;
               align-items: center;
               justify-content: space-between;
               gap: 16px;
               margin-bottom: 6px;
               flex-wrap: wrap;
           }

           h1 {
               font-size: 19px;
               margin: 0;
               font-weight: 500;
           }

           nav {
               display: flex;
               gap: 18px;
               border-bottom: 1px solid var(--borde);
               margin-bottom: 16px;
           }

               nav a {
                   color: var(--tenue);
                   text-decoration: none;
                   font-size: 14px;
                   padding: 0 2px 9px;
                   border-bottom: 2px solid transparent;
                   margin-bottom: -1px;
               }

                   nav a:hover {
                       color: var(--texto);
                   }

                   nav a.activo {
                       color: var(--texto);
                       border-bottom-color: var(--acento);
                   }

           input, select, button {
               font: inherit;
               font-size: 14px;
               color: var(--texto);
               background: var(--panel);
               border: 1px solid var(--borde);
               border-radius: var(--radio);
               padding: 7px 11px;
           }

               input:focus, select:focus {
                   outline: none;
                   border-color: var(--acento);
               }

           button {
               cursor: pointer;
           }

               button:hover:not(:disabled) {
                   border-color: var(--borde-fuerte);
               }

               button:disabled {
                   opacity: .5;
                   cursor: default;
               }

               button.principal {
                   background: var(--acento);
                   border-color: var(--acento);
                   color: #fff;
                   font-weight: 500;
               }

                   button.principal:hover:not(:disabled) {
                       filter: brightness(1.08);
                   }

               button.peligro {
                   color: var(--mal);
                   border-color: var(--borde);
               }

               button.mini {
                   padding: 4px 10px;
                   font-size: 13px;
               }

           .barra {
               display: flex;
               gap: 10px;
               align-items: center;
               margin-bottom: 12px;
           }

           .buscador {
               flex: 1;
               max-width: 340px;
               position: relative;
           }

               .buscador input {
                   width: 100%;
                   padding-left: 32px;
               }

               .buscador svg {
                   position: absolute;
                   left: 10px;
                   top: 9px;
                   width: 15px;
                   height: 15px;
                   stroke: var(--apagado);
                   fill: none;
                   stroke-width: 2;
               }

           .maestro-detalle {
               display: grid;
               grid-template-columns: 266px minmax(0,1fr);
               gap: 14px;
               align-items: start;
           }

           @media (max-width:880px) {
               .maestro-detalle {
                   grid-template-columns: 1fr;
               }
           }

           .tarjeta {
               background: var(--panel);
               border: 1px solid var(--borde);
               border-radius: 12px;
           }

           .lista {
               max-height: calc(100vh - 210px);
               overflow-y: auto;
           }

           .fila-empresa {
               padding: 10px 13px;
               border-bottom: 1px solid var(--borde);
               cursor: pointer;
           }

               .fila-empresa:last-child {
                   border-bottom: none;
               }

               .fila-empresa:hover {
                   background: var(--sutil);
               }

               .fila-empresa.activa {
                   background: var(--acento-fondo);
               }

                   .fila-empresa.activa .nombre {
                       color: var(--acento);
                   }

               .fila-empresa.inactiva {
                   opacity: .55;
               }

               .fila-empresa .nombre {
                   font-size: 14px;
                   display: flex;
                   align-items: center;
                   gap: 6px;
               }

               .fila-empresa .ruc {
                   font-size: 12px;
                   color: var(--tenue);
                   font-family: ui-monospace, Consolas, monospace;
               }

           .pie-lista {
               padding: 9px 13px;
               font-size: 12px;
               color: var(--apagado);
               border-top: 1px solid var(--borde);
           }

           .detalle {
               padding: 18px 20px;
           }

           .cabecera-detalle {
               display: flex;
               align-items: flex-start;
               justify-content: space-between;
               gap: 14px;
               margin-bottom: 16px;
           }

               .cabecera-detalle h2 {
                   font-size: 17px;
                   margin: 0;
                   font-weight: 500;
               }

               .cabecera-detalle .sub {
                   font-size: 13px;
                   color: var(--tenue);
                   font-family: ui-monospace, Consolas, monospace;
                   margin-top: 2px;
               }

           .insignia {
               font-size: 12px;
               padding: 3px 10px;
               border-radius: var(--radio);
               white-space: nowrap;
           }

           .i-ok {
               background: var(--ok-fondo);
               color: var(--ok);
           }

           .i-aviso {
               background: var(--aviso-fondo);
               color: var(--aviso);
           }

           .i-mal {
               background: var(--mal-fondo);
               color: var(--mal);
           }

           .i-tenue {
               background: var(--sutil);
               color: var(--tenue);
           }

           /* Webhook registrado por la API (la plataforma), no a mano. */
           .i-api {
               background: var(--acento-fondo);
               color: var(--acento);
           }

           .metricas {
               display: grid;
               grid-template-columns: repeat(auto-fit,minmax(130px,1fr));
               gap: 10px;
               margin-bottom: 18px;
           }

           .metrica {
               background: var(--sutil);
               border-radius: var(--radio);
               padding: 11px 13px;
           }

               .metrica .et {
                   font-size: 12px;
                   color: var(--tenue);
               }

               .metrica .va {
                   font-size: 15px;
                   margin-top: 2px;
               }

           .pestanas {
               display: flex;
               gap: 16px;
               border-bottom: 1px solid var(--borde);
               margin-bottom: 14px;
           }

           .pestana {
               font-size: 13px;
               color: var(--tenue);
               cursor: pointer;
               padding: 0 2px 8px;
               border-bottom: 2px solid transparent;
               margin-bottom: -1px;
               background: none;
               border-top: none;
               border-left: none;
               border-right: none;
           }

               .pestana:hover {
                   color: var(--texto);
               }

               .pestana.activa {
                   color: var(--texto);
                   border-bottom-color: var(--acento);
               }

           table {
               width: 100%;
               border-collapse: collapse;
               font-size: 13.5px;
           }

           th {
               text-align: left;
               color: var(--tenue);
               font-weight: 400;
               padding: 6px 8px;
               border-bottom: 1px solid var(--borde);
               font-size: 12.5px;
           }

           td {
               padding: 9px 8px;
               border-bottom: 1px solid var(--borde);
           }

           tr:last-child td {
               border-bottom: none;
           }

           .mono {
               font-family: ui-monospace, Consolas, monospace;
               font-size: 13px;
           }

           .recorte {
               overflow: hidden;
               text-overflow: ellipsis;
               white-space: nowrap;
           }

           td.mal, .mal {
               color: var(--mal);
           }

           /* La fila recién creada. El resaltado se va solo a los pocos segundos:
        sirve para encontrarla, no para quedarse ahí. */
           tr.fila-inactiva td:not(:last-child) {
               opacity: .55;
           }

           tr.recien {
               background: var(--ok-fondo);
           }

               tr.recien td:first-child {
                   box-shadow: inset 3px 0 0 var(--ok);
               }

           .filtro-tabla {
               display: flex;
               align-items: center;
               justify-content: space-between;
               gap: 12px;
               margin-bottom: 8px;
           }

               .filtro-tabla .buscador {
                   max-width: 260px;
                   flex: 1;
               }

                   .filtro-tabla .buscador input {
                       padding: 6px 11px 6px 30px;
                       font-size: 13.5px;
                   }

                   .filtro-tabla .buscador svg {
                       top: 8px;
                       width: 14px;
                       height: 14px;
                   }

               .filtro-tabla .conteo {
                   font-size: 12.5px;
                   color: var(--tenue);
               }

           .tenue {
               color: var(--tenue);
           }

           .vacio {
               color: var(--tenue);
               font-size: 14px;
               padding: 14px 0;
           }


           .usuario {
               display: flex;
               align-items: center;
               gap: 12px;
               font-size: 13.5px;
               color: var(--tenue);
           }

               .usuario .rol {
                   background: var(--sutil);
                   border-radius: var(--radio);
                   padding: 2px 9px;
                   font-size: 12px;
               }

               .usuario a {
                   color: var(--acento);
                   text-decoration: none;
               }

                   .usuario a:hover {
                       text-decoration: underline;
                   }

           .rejilla {
               display: grid;
               grid-template-columns: repeat(auto-fit,minmax(170px,1fr));
               gap: 11px;
               margin: 14px 0;
           }

           label {
               display: block;
               font-size: 12px;
               color: var(--tenue);
               margin-bottom: 4px;
           }

               label input, label select {
                   width: 100%;
               }

           .err {
               color: var(--mal);
               font-size: 12px;
               margin-top: 3px;
               min-height: 14px;
           }

           label.invalido input {
               border-color: var(--mal);
           }

           /* El input de archivo nativo no se puede estilizar: se oculta y se usa
        una etiqueta como botón. El input sigue ahí, así que el teclado y los
        lectores de pantalla lo siguen alcanzando. */
           .archivo {
               position: relative;
           }

               .archivo input[type=file] {
                   position: absolute;
                   inset: 0;
                   opacity: 0;
                   width: 100%;
                   height: 100%;
                   cursor: pointer;
               }

               .archivo .caja {
                   display: flex;
                   align-items: center;
                   gap: 9px;
                   border: 1px dashed var(--borde-fuerte);
                   border-radius: var(--radio);
                   padding: 8px 11px;
                   background: var(--panel);
                   font-size: 13.5px;
                   color: var(--tenue);
               }

               .archivo:hover .caja {
                   border-color: var(--acento);
                   color: var(--texto);
               }

               .archivo.con-archivo .caja {
                   border-style: solid;
                   border-color: var(--ok);
                   color: var(--texto);
               }

               .archivo .caja svg {
                   width: 16px;
                   height: 16px;
                   stroke: currentColor;
                   fill: none;
                   stroke-width: 2;
                   flex: none;
               }

               .archivo .nombre-archivo {
                   overflow: hidden;
                   text-overflow: ellipsis;
                   white-space: nowrap;
               }

           #avisos {
               position: fixed;
               top: 18px;
               right: 18px;
               z-index: 60;
               display: flex;
               flex-direction: column;
               gap: 8px;
               max-width: 370px;
           }

           .flotante {
               background: var(--panel);
               border: 1px solid var(--borde);
               border-left: 3px solid var(--acento);
               border-radius: var(--radio);
               padding: 11px 14px;
               font-size: 14px;
               box-shadow: 0 6px 22px rgba(0,0,0,.14);
               animation: entrar .16s ease-out;
           }

               .flotante.ok {
                   border-left-color: var(--ok);
               }

               .flotante.mal {
                   border-left-color: var(--mal);
               }

               .flotante .t {
                   font-weight: 500;
               }

               .flotante .d {
                   color: var(--tenue);
                   font-size: 13px;
                   margin-top: 2px;
               }

           @keyframes entrar {
               from {
                   opacity: 0;
                   transform: translateX(14px);
               }
           }

           .velo {
               position: fixed;
               inset: 0;
               background: rgba(15,18,23,.5);
               z-index: 70;
               display: none;
               align-items: center;
               justify-content: center;
               padding: 20px;
           }

               .velo.visible {
                   display: flex;
               }

           .modal {
               background: var(--panel);
               border: 1px solid var(--borde);
               border-radius: 14px;
               padding: 22px 24px;
               width: 100%;
               max-width: 560px;
               max-height: 88vh;
               overflow-y: auto;
           }

               .modal h3 {
                   margin: 0 0 4px;
                   font-size: 17px;
                   font-weight: 500;
               }

               .modal .ayuda {
                   margin: 0 0 4px;
                   color: var(--tenue);
                   font-size: 13.5px;
               }

               .modal .botones {
                   display: flex;
                   gap: 8px;
                   justify-content: flex-end;
                   margin-top: 18px;
               }

           /* El logo se enseña sobre blanco en los dos temas: así va a salir
        en el PDF y en el correo, que son blancos. */
           .logo-caja {
               width: 200px;
               height: 76px;
               border: 1px dashed var(--borde-fuerte);
               border-radius: var(--radio);
               background: #fff;
               display: flex;
               align-items: center;
               justify-content: center;
               padding: 8px;
               flex: none;
           }

               .logo-caja img {
                   max-width: 100%;
                   max-height: 100%;
               }

               .logo-caja .tenue {
                   font-size: 13px;
                   color: #8a929c;
               }

           .direccion-portal {
               background: var(--sutil);
               border-radius: var(--radio);
               padding: 11px 13px;
               margin-bottom: 8px;
               font-size: 14px;
           }

           .muestra-color {
               display: flex;
               gap: 8px;
               align-items: center;
           }

               .muestra-color input[type=color] {
                   width: 46px;
                   height: 36px;
                   padding: 2px;
                   flex: none;
                   cursor: pointer;
               }

           .secreto {
               background: var(--ok-fondo);
               border: 1px solid var(--ok);
               border-radius: var(--radio);
               padding: 13px 15px;
               margin-top: 12px;
           }

               .secreto code {
                   display: block;
                   font-family: ui-monospace,Consolas,monospace;
                   font-size: 14px;
                   word-break: break-all;
                   margin: 9px 0;
                   color: var(--ok);
               }

           /* Las claves de alta (024): encima de la lista de empresas. */
           .bloque-altas {
               padding: 14px 18px;
               margin-bottom: 14px;
           }

               .bloque-altas.alerta {
                   border-color: var(--mal);
               }

               .bloque-altas .cab {
                   display: flex;
                   justify-content: space-between;
                   align-items: center;
                   gap: 12px;
                   flex-wrap: wrap;
               }

               .bloque-altas h3 {
                   margin: 0;
                   font-size: 14px;
                   font-weight: 600;
               }

               .bloque-altas .explica {
                   font-size: 12.5px;
                   color: var(--tenue);
                   margin-top: 2px;
               }

           /* Un aviso que se lee de una línea, con la raya del color del aviso. */
           .aviso-linea {
               border-left: 2px solid var(--aviso);
               padding-left: 11px;
               font-size: 12.5px;
               color: var(--aviso);
               margin: 6px 0 12px;
           }

               .aviso-linea.ok {
                   border-left-color: var(--ok);
                   color: var(--ok);
               }
    </style>
</head>
<body>

    <div id="avisos"></div>

    <div class="velo" id="velo-confirmar">
        <div class="modal" style="max-width:430px">
            <h3 id="cf-titulo"></h3>
            <p class="ayuda" id="cf-texto"></p>
            <div class="botones">
                <button id="cf-cancelar">Cancelar</button>
                <button id="cf-aceptar" class="principal">Confirmar</button>
            </div>
        </div>
    </div>

    <div class="velo" id="velo-nueva">
        <div class="modal">
            <h3>Nueva empresa</h3>
            <p class="ayuda">
                Lo normal es dar de alta al cliente <strong>desde la
                plataforma</strong>, que crea la empresa aquí sola. Este
                formulario es para un cliente que integra por API sin la
                plataforma. Después habrá que cargarle un certificado, dar de
                alta al menos una serie y emitirle una clave de acceso.
            </p>

            <div class="rejilla">
                <label>
                    RUC<input id="n-ruc" maxlength="11" placeholder="20601234567">
                    <div class="err" id="e-ruc"></div>
                </label>
                <label>
                    Razón social<input id="n-razon" placeholder="Comercial Andina EIRL">
                    <div class="err" id="e-razon"></div>
                </label>
                <label>Nombre comercial<input id="n-comercial" placeholder="opcional"></label>
                <label>
                    Identificador del portal<input id="n-identificador" maxlength="40" placeholder="opcional · ferreteria-lopez">
                    <div class="err" id="e-identificador"></div>
                </label>
                <!-- SIN VALORES POR DEFECTO, a propósito (024): un LIMA puesto
                     de antemano no se distingue de uno revisado, y un cliente de
                     Arequipa terminaba emitiendo con dirección de Lima. -->
                <label>
                    Dirección fiscal<input id="n-direccion" placeholder="Av. Ejército 101">
                    <div class="err" id="e-direccion"></div>
                </label>
                <label>Distrito<input id="n-distrito" placeholder="como en la ficha RUC"></label>
                <label>Provincia<input id="n-provincia"></label>
                <label>Departamento<input id="n-departamento"></label>
                <label>
                    Ubigeo<input id="n-ubigeo" maxlength="6" inputmode="numeric" placeholder="6 dígitos">
                    <div class="err" id="e-ubigeo"></div>
                </label>
                <label>
                    Ambiente
                    <select id="n-ambiente">
                        <option value="beta">beta (pruebas)</option>
                        <option value="produccion">producción</option>
                    </select>
                </label>
                <label>Usuario SOL<input id="n-sol" value="MODDATOS"></label>
            </div>

            <div class="botones">
                <button id="nv-cancelar">Cancelar</button>
                <button id="nv-crear" class="principal">Crear empresa</button>
            </div>
        </div>
    </div>

    <div class="contenedor">
        <header>
            <h1>Facturación electrónica</h1>
            <div id="usuario-actual" class="usuario"></div>
        </header>

        <nav>
            <a href="/diagnostico.html">Estado del servicio</a>
            <a href="/admin.html" class="activo">Empresas</a>
            <a href="/comprobantes.html">Comprobantes</a>
            <a href="/cuenta.html">Mi cuenta</a>
        </nav>

        <div id="raiz">
            <div class="tarjeta" style="padding:18px 20px">
                <span class="vacio">Cargando…</span>
            </div>
        </div>
    </div>

    <script src="/fechas.js"></script>
    <script>
        // NO SE USA "$" COMO NOMBRE DE FUNCIÓN. Browser Link, la herramienta de
        // Visual Studio que recarga la página al guardar, inyecta jQuery y espera
        // encontrarlo ahí. Definir otra cosa rompe su script con un error que parece
        // del panel y no lo es.
        const elem = id => document.getElementById(id);
        const esc = t => String(t ?? "").replace(/[&<>"']/g,
            c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));

        const estado = {
            empresas: [],
            seleccionada: null,

            // Buscador de la lista de empresas. Tiene nombre propio a propósito:
            // "filtro" a secas se confundía con los filtros de las pestañas, que son
            // otra cosa, y esa colisión rompía la página al arrancar.
            filtroEmpresas: "",

            pestana: "series",
            series: [],
            claves: [],
            certificados: [],
            webhooks: [],
            entregas: [],
            cambiosWebhook: [],
            revision: null,

            // Las claves de alta (024). Solo con altas.gestionar.
            clavesAlta: [],
            altasAbierto: false,

            // Identificador de lo recién creado en cada pestaña, para resaltarlo.
            recien: { series: null, claves: null, certificado: null, webhooks: null },

            // Filtro de texto de cada pestaña. Son independientes: buscar en claves
            // no debe alterar lo que ves al volver a series.
            filtro: { series: "", claves: "", certificado: "", webhooks: "" }
        };


        // ---------------------------------------------------------------- sesión
        //
        // La autenticación va por cookie, no por una clave escrita en la página.
        //
        // La cookie es HttpOnly, así que este JavaScript NO puede leerla: el
        // navegador la envía sola en cada petición. Si algún día se cuela un script
        // malicioso, no podrá robar la sesión.

        let usuarioActual = null;


        // ------------------------------------------------------------------- menú
        //
        // El menú se arma según los permisos del usuario: cada quien ve solo las
        // pantallas que puede usar.
        //
        // OCULTAR NO ES PROTEGER. El servidor comprueba el permiso en cada petición;
        // esto solo evita mostrar opciones que darían un error al pulsarlas.

        const PANTALLAS = [
            { url: "/diagnostico.html", texto: "Estado del servicio", permiso: "diagnostico.ver" },
            { url: "/admin.html", texto: "Empresas", permiso: "empresas.ver" },
            { url: "/comprobantes.html", texto: "Comprobantes", permiso: "comprobantes.ver" },
            { url: "/usuarios.html", texto: "Usuarios", permiso: "usuarios.gestionar" },
            { url: "/cuenta.html", texto: "Mi cuenta", permiso: null }
        ];

        const puede = permiso => usuarioActual?.permisos?.includes(permiso) === true;

        function pintarMenu() {
            const menu = document.querySelector("nav");
            if (!menu) return;

            const actual = location.pathname;

            menu.innerHTML = PANTALLAS
                .filter(p => p.permiso === null || puede(p.permiso))
                .map(p => `<a href="${p.url}" class="${actual === p.url ? "activo" : ""}">
                     ${esc(p.texto)}</a>`)
                .join("");
        }

        async function cargarUsuario() {
            const r = await fetch("/admin/yo");

            if (r.status === 401) {
                location.href = "/login.html";
                return false;
            }

            usuarioActual = await r.json();

            const caja = elem("usuario-actual");

            if (caja) {
                caja.innerHTML =
                    `<span>${esc(usuarioActual.nombre || usuarioActual.correo)}</span>` +
                    `<span class="rol">${esc(usuarioActual.rol)}</span>` +
                    `<a href="#" id="salir">Salir</a>`;

                elem("salir").onclick = async e => {
                    e.preventDefault();
                    await fetch("/admin/sesion", { method: "DELETE" });
                    location.href = "/login.html";
                };
            }

            pintarMenu();

            return true;
        }

        const esAdministrador = () => usuarioActual?.esAdministrador === true;


        // ------------------------------------------------------------------ avisos

        function avisar(titulo, detalle = "", tipo = "") {
            const caja = document.createElement("div");
            caja.className = "flotante " + tipo;

            caja.innerHTML = `<div class="t">${esc(titulo)}</div>` +
                (detalle ? `<div class="d">${esc(detalle)}</div>` : "");

            elem("avisos").appendChild(caja);

            // Los errores duran más: hay que poder leerlos con calma.
            setTimeout(() => caja.remove(), tipo === "mal" ? 8000 : 4000);
        }

        function confirmar(titulo, texto, textoBoton = "Confirmar") {
            return new Promise(resolver => {
                elem("cf-titulo").textContent = titulo;
                elem("cf-texto").textContent = texto;
                elem("cf-aceptar").textContent = textoBoton;
                elem("velo-confirmar").classList.add("visible");

                const cerrar = r => {
                    elem("velo-confirmar").classList.remove("visible");
                    resolver(r);
                };

                elem("cf-aceptar").onclick = () => cerrar(true);
                elem("cf-cancelar").onclick = () => cerrar(false);
            });
        }

        // --------------------------------------------------------------------- api

        async function api(ruta, opciones = {}) {
            const r = await fetch(ruta, opciones);

            if (r.status === 401) {
                location.href = "/login.html";
                throw new Error("Sesión caducada.");
            }

            const cuerpo = await r.json().catch(() => ({}));

            if (!r.ok) {
                const error = new Error(cuerpo.error || `Error ${r.status}`);
                error.detalle = cuerpo.detalle || "";
                throw error;
            }

            return cuerpo;
        }

        async function iniciar() {
            try {
                estado.empresas = await api("/admin/tenants");
                await cargarClavesAlta();
                pintar();
            } catch (e) {
                elem("raiz").innerHTML =
                    `<div class="tarjeta" style="padding:18px 20px;color:var(--mal)">
             ${esc(e.message)}</div>`;
            }
        }

        // ----------------------------------------------------------------- pintado

        function empresasVisibles() {
            const f = estado.filtroEmpresas.trim().toLowerCase();

            if (!f) return estado.empresas;

            return estado.empresas.filter(e =>
                e.razonSocial.toLowerCase().includes(f) || e.ruc.includes(f));
        }

        function pintar() {
            const visibles = empresasVisibles();

            elem("raiz").innerHTML = `
        ${bloqueClavesAlta()}

        <div class="barra">
          <div class="buscador">
            <svg viewBox="0 0 24 24"><circle cx="11" cy="11" r="7"/><path d="M20 20l-3.5-3.5"/></svg>
            <input id="buscar" placeholder="Buscar por RUC o nombre" value="${esc(estado.filtroEmpresas)}">
          </div>
          ${puede("empresas.editar")
                    ? `<button class="principal" id="btn-nueva">Nueva empresa</button>` : ""}
        </div>

        <div class="maestro-detalle">
          <div class="tarjeta">
            <div class="lista" id="lista">
              ${visibles.length === 0
                    ? `<div class="vacio" style="padding:16px 13px">
                     ${estado.empresas.length === 0
                        ? "Todavía no hay empresas."
                        : "Ninguna empresa coincide con la búsqueda."}</div>`
                    : visibles.map(filaEmpresa).join("")}
            </div>
            <div class="pie-lista">
              ${visibles.length === estado.empresas.length
                    ? `${estado.empresas.length} ${estado.empresas.length === 1 ? "empresa" : "empresas"}`
                    : `${visibles.length} de ${estado.empresas.length}`}
            </div>
          </div>

          <div class="tarjeta detalle" id="detalle">
            ${estado.seleccionada ? "" : `<div class="vacio">Elige una empresa de la lista.</div>`}
          </div>
        </div>`;

            const buscar = elem("buscar");

            buscar.oninput = () => {
                estado.filtroEmpresas = buscar.value;

                // Se repinta solo la lista para no perder el foco del buscador.
                const posicion = buscar.selectionStart;
                pintar();
                const nuevo = elem("buscar");
                nuevo.focus();
                nuevo.setSelectionRange(posicion, posicion);
            };

            if (elem("btn-nueva")) elem("btn-nueva").onclick = abrirNueva;

            enlazarClavesAlta();

            document.querySelectorAll("[data-empresa]").forEach(fila =>
                fila.onclick = () => seleccionar(fila.dataset.empresa));

            if (estado.seleccionada) pintarDetalle();
        }

        function filaEmpresa(e) {
            const activa = estado.seleccionada?.id === e.id;
            const alerta = problemaDe(e);

            return `
        <div class="fila-empresa ${activa ? "activa" : ""} ${e.activo ? "" : "inactiva"}"
             data-empresa="${e.id}" title="${alerta ? esc(alerta) : ""}">
          <div class="nombre">
            ${esc(e.razonSocial)}
            ${alerta ? `<span style="color:var(--aviso);font-size:13px">&#9679;</span>` : ""}
          </div>
          <div class="ruc">${esc(e.ruc)}${e.ambiente === "produccion" ? " · producción" : ""}</div>
          ${e.estadoAlta === "sin_confirmar"
                    ? `<div style="font-size:12px;color:var(--aviso)">sin confirmar desde ${fechaHora(e.creadoEn)}</div>`
                    : e.estadoAlta === "abandonada"
                        ? `<div style="font-size:12px;color:var(--tenue)">alta abandonada</div>`
                        : ""}
        </div>`;
        }

        /// Lo que hace falta mirar en esta empresa. Aparece como punto en la lista
        /// para que los problemas se vean sin abrir una por una.
        function problemaDe(e) {
            if (!e.activo) return null;

            // La creó la plataforma y todavía no confirmó que guardó lo suyo.
            if (e.estadoAlta === "sin_confirmar")
                return `Alta sin confirmar desde ${fechaHora(e.creadoEn)}. Si la plataforma ` +
                    "no llegó a guardarla, el próximo alta de este RUC la dará por abandonada.";

            if (!e.tieneCertificado) return "Sin certificado: no puede emitir.";

            const dias = Math.ceil((new Date(e.certificadoVence) - new Date()) / 86400000);

            if (dias < 0) return "Certificado vencido: no puede emitir.";
            if (dias <= 30) return `El certificado vence en ${dias} días.`;
            if (e.series === 0) return "Sin series: no puede emitir.";
            if (e.claves === 0) return "Sin claves: el cliente no puede conectarse.";
            if (!e.direccionRevisadaEn) return "Dirección sin revisar: puede tener los valores por defecto.";

            return null;
        }

        function pintarDetalle() {
            const t = estado.seleccionada;

            elem("detalle").innerHTML = `
        <div class="cabecera-detalle">
          <div>
            <h2>${esc(t.razonSocial)}</h2>
            <div class="sub">${esc(t.ruc)} · ${t.ambiente}</div>
            ${origenAlta(t)}
          </div>
          <div style="display:flex;gap:8px;align-items:center">
            ${t.estadoAlta === "sin_confirmar"
                    ? `<span class="insignia i-aviso" title="La plataforma todavía no confirmó que la guardó.">sin confirmar</span>` : ""}
            ${t.estadoAlta === "abandonada"
                    ? `<span class="insignia i-tenue" title="Abandonada el ${fechaHora(t.abandonadaEn)}">abandonada</span>`
                    : `<span class="insignia ${t.activo ? "i-ok" : "i-tenue"}">
              ${t.activo ? "Activa" : "Inactiva"}</span>`}
            ${puede("empresas.editar") && t.estadoAlta !== "abandonada"
                    ? `<button class="mini" id="btn-alternar">
                   ${t.activo ? "Desactivar" : "Activar"}</button>` : ""}
          </div>
        </div>

        <div class="metricas">
          <div class="metrica">
            <div class="et">Certificado</div>
            <div class="va">${estadoCertificado(t)}</div>
          </div>
          <div class="metrica">
            <div class="et">Comprobantes</div>
            <div class="va">${t.comprobantes.toLocaleString("es-PE")}</div>
          </div>
          <div class="metrica">
            <div class="et">Series activas</div>
            <div class="va">${t.series}</div>
          </div>
          <div class="metrica">
            <div class="et">Claves activas</div>
            <div class="va">${t.claves}</div>
          </div>
        </div>

        <div class="pestanas">
          ${pestanasVisibles().map(p => `
            <button class="pestana ${estado.pestana === p ? "activa" : ""}"
                    data-pestana="${p}">${nombrePestana(p)}</button>`).join("")}
        </div>

        <div id="cuerpo-pestana"><div class="vacio">Cargando…</div></div>`;

            if (elem("btn-alternar")) elem("btn-alternar").onclick = alternarActiva;

            document.querySelectorAll("[data-pestana]").forEach(boton =>
                boton.onclick = () => {
                    estado.pestana = boton.dataset.pestana;
                    pintarDetalle();
                });

            cargarPestana();
        }

        /// Las pestañas del detalle también dependen de los permisos.
        ///
        /// Sin esto, alguien de soporte vería la pestaña de certificados y al pulsar
        /// recibiría un 403. Es mejor no mostrar lo que no se puede usar.
        function pestanasVisibles() {
            const todas = [
                { clave: "series", permiso: "empresas.ver" },
                { clave: "marca", permiso: "empresas.ver" },
                { clave: "claves", permiso: "claves.gestionar" },
                { clave: "certificado", permiso: "certificados.gestionar" },
                { clave: "webhooks", permiso: "webhooks.gestionar" },
                { clave: "produccion", permiso: "produccion.cambiar" }
            ];

            return todas.filter(p => puede(p.permiso)).map(p => p.clave);
        }

        const nombrePestana = p => ({
            series: "Series",
            marca: "Marca",
            claves: "Claves de acceso",
            certificado: "Certificado",
            webhooks: "Webhooks",
            produccion: "Producción"
        }[p]);

        function estadoCertificado(t) {
            if (!t.tieneCertificado)
                return `<span style="color:var(--mal)">Falta</span>`;

            const dias = Math.ceil((new Date(t.certificadoVence) - new Date()) / 86400000);

            if (dias < 0) return `<span style="color:var(--mal)">Vencido</span>`;
            if (dias <= 30) return `<span style="color:var(--aviso)">Vence en ${dias} d</span>`;

            return `<span style="color:var(--ok)">Vence en ${dias} d</span>`;
        }

        // -------------------------------------------------------------- pestañas

        async function cargarPestana() {
            const id = estado.seleccionada.id;
            const cuerpo = elem("cuerpo-pestana");

            try {
                if (estado.pestana === "series") {
                    estado.series = await api(`/admin/tenants/${id}/series`);
                    cuerpo.innerHTML = vistaSeries();
                    elem("btn-serie").onclick = crearSerie;

                    // El ejemplo del recuadro sigue al tipo elegido: así se ve la inicial
                    // que toca antes de escribir, no después del rechazo.
                    const tipo = elem("s-tipo");

                    if (tipo) tipo.onchange = () => {
                        const campo = elem("s-serie");
                        if (campo) campo.placeholder = serieSugerida(tipo.value);
                    };

                    enlazarAccionesSerie();

                    enlazarFiltro("series", () => {
                        elem("tabla-series").innerHTML = tablaSeries();
                        enlazarAccionesSerie();
                    });

                } else if (estado.pestana === "claves") {
                    estado.claves = await api(`/admin/tenants/${id}/claves`);
                    cuerpo.innerHTML = vistaClaves();
                    elem("btn-clave").onclick = crearClave;

                    enlazarRevocar();

                    enlazarFiltro("claves", () => {
                        elem("tabla-claves").innerHTML = tablaClaves();
                        enlazarRevocar();
                    });

                } else if (estado.pestana === "marca") {
                    // No hace falta pedir nada: la marca viene con la lista de
                    // empresas, que ya está cargada.
                    cuerpo.innerHTML = vistaMarca();
                    enlazarMarca();

                } else if (estado.pestana === "produccion") {
                    estado.revision = await api(`/admin/tenants/${id}/revision-produccion`);

                    cuerpo.innerHTML = vistaProduccion();

                    elem("btn-sol").onclick = guardarCredenciales;
                    elem("btn-ambiente").onclick = cambiarAmbiente;
                    elem("btn-gre").onclick = guardarCredencialesGre;

                } else if (estado.pestana === "webhooks") {
                    estado.webhooks = await api(`/admin/tenants/${id}/webhooks`);
                    estado.entregas = await api(`/admin/tenants/${id}/webhook-entregas?limite=20`);
                    estado.cambiosWebhook = await api(`/admin/tenants/${id}/webhook-cambios?limite=20`);

                    cuerpo.innerHTML = vistaWebhooks();
                    elem("btn-webhook").onclick = crearWebhook;

                    enlazarAccionesWebhook();

                    enlazarFiltro("webhooks", () => {
                        elem("tabla-webhooks").innerHTML = tablaWebhooks();
                        enlazarAccionesWebhook();
                    });

                } else {
                    estado.certificados = await api(`/admin/tenants/${id}/certificados`);
                    cuerpo.innerHTML = vistaCertificado();
                    elem("btn-certificado").onclick = subirCertificado;

                    enlazarAccionesCertificado();

                    enlazarFiltro("certificado", () => {
                        elem("tabla-certificado").innerHTML = tablaCertificados();
                        enlazarAccionesCertificado();
                    });

                    // El input de archivo está oculto: hay que reflejar el nombre elegido
                    // en la caja visible, o el usuario no sabe si seleccionó algo.
                    elem("c-archivo").onchange = e => {
                        const archivo = e.target.files[0];

                        elem("nombre-archivo").textContent =
                            archivo ? archivo.name : "Elegir archivo .pfx o .p12";

                        elem("envoltura-archivo").classList.toggle("con-archivo", !!archivo);
                    };
                }
            } catch (e) {
                cuerpo.innerHTML = `<div class="vacio" style="color:var(--mal)">${esc(e.message)}</div>`;
            }
        }

        function vistaSeries() {
            return `
        <div class="rejilla" style="margin-top:0">
          <label>Tipo
            <select id="s-tipo">
              <option value="01">Factura</option>
              <option value="03">Boleta</option>
              <option value="04">Liquidación de compra</option>
              <option value="07">Nota de crédito</option>
              <option value="08">Nota de débito</option>
              <option value="09">Guía de remisión remitente</option>
              <option value="20">Comprobante de retención</option>
              <option value="31">Guía de remisión transportista</option>
              <option value="40">Comprobante de percepción</option>
            </select></label>
          <label>Serie<input id="s-serie" maxlength="4" placeholder="F001">
            <div class="err" id="e-serie"></div></label>
          <label>Último correlativo ya emitido<input id="s-corr" type="number" value="0"></label>
        </div>

        <div style="display:flex;align-items:center;gap:12px;margin-bottom:16px">
          <button id="btn-serie">Agregar serie</button>
          <span class="tenue" style="font-size:12.5px">
            Si la empresa viene de otro sistema, pon el último número que ya emitió.
          </span>
        </div>

        ${estado.series.length === 0
                    ? `<div class="vacio" style="border-top:1px solid var(--borde)">
               Sin series. Hace falta al menos una para poder emitir.</div>`
                    : barraFiltro("series", estado.series.length, filtrar("series").length) +
                    `<div id="tabla-series">${tablaSeries()}</div>`}`;
        }

        function tablaSeries() {
            const filas = filtrar("series");

            if (filas.length === 0)
                return `<div class="vacio">Ninguna serie coincide con la búsqueda.</div>`;

            return `<table>
          <tr><th>Tipo</th><th>Serie</th>
              <th title="El último correlativo que se puso al crear la serie (el que ya se había emitido en otro sistema o en beta).">Último al crearla</th>
              <th>Emitidos</th><th>Último emitido</th><th>Siguiente</th>
              <th>Estado</th><th style="text-align:right">Acciones</th></tr>
          ${filas.map(s => `<tr class="${s.id === estado.recien.series ? "recien" : ""}
                                        ${s.activo ? "" : "fila-inactiva"}">
            <td>${nombreTipo(s.tipoComprobante)}</td>
            <td class="mono">${esc(s.serie)}</td>
            <!-- Se calcula: último correlativo menos los emitidos aquí. Cada
                 comprobante gasta un número, también los rechazados. -->
            <td class="mono">${Math.max(s.ultimoCorrelativo - s.comprobantes, 0)}</td>
            <td>${s.comprobantes}</td>
            <td class="mono">${s.comprobantes > 0
                    ? `${esc(s.serie)}-${String(s.ultimoCorrelativo).padStart(8, "0")}`
                    : `<span class="tenue">—</span>`}</td>
            <td class="tenue">${s.ultimoCorrelativo + 1}</td>
            <td>${s.activo
                    ? `<span class="insignia i-ok">activa</span>`
                    : `<span class="insignia i-tenue">cerrada</span>`}</td>
            <td style="text-align:right;white-space:nowrap">
              ${accionesSerie(s)}
            </td>
          </tr>`).join("")}
        </table>`;
        }

        /// Qué se puede hacer con una serie depende de si ya se usó.
        ///
        /// Sin comprobantes se puede borrar sin consecuencias. Con comprobantes
        /// solo se puede cerrar: borrarla dejaría huérfano el rastro de esa
        /// numeración, y eso es un problema tributario, no de datos.
        function accionesSerie(s) {
            if (s.sePuedeEliminar)
                return `<button class="mini peligro" data-borrar-serie="${s.id}"
                  data-serie-nombre="${esc(s.serie)}">Eliminar</button>`;

            return s.activo
                ? `<button class="mini" data-cerrar-serie="${s.id}"
             data-serie-nombre="${esc(s.serie)}"
             title="Deja de poder emitir. El histórico no se toca.">Cerrar</button>`
                : `<button class="mini" data-abrir-serie="${s.id}"
             data-serie-nombre="${esc(s.serie)}">Reactivar</button>`;
        }

        function vistaClaves() {
            return `
        <div class="rejilla" style="margin-top:0">
          <label>Nombre de la clave<input id="k-nombre" placeholder="ERP producción"></label>
        </div>

        <div style="display:flex;align-items:center;gap:12px;margin-bottom:16px">
          <button id="btn-clave">Emitir clave</button>
          <span class="tenue" style="font-size:12.5px">
            El secreto se muestra una sola vez.
          </span>
        </div>

        <div id="k-resultado"></div>

        ${estado.claves.length === 0
                    ? `<div class="vacio" style="border-top:1px solid var(--borde)">
               Sin claves. El cliente todavía no puede conectarse.</div>`
                    : barraFiltro("claves", estado.claves.length, filtrar("claves").length) +
                    `<div id="tabla-claves">${tablaClaves()}</div>`}`;
        }

        function tablaClaves() {
            const filas = filtrar("claves");

            if (filas.length === 0)
                return `<div class="vacio">Ninguna clave coincide con la búsqueda.</div>`;

            return `<table>
          <tr><th>Nombre</th><th>Prefijo</th><th>Creada</th><th>Último uso</th>
              <th>Estado</th><th></th></tr>
          ${filas.map(k => `<tr class="${k.id === estado.recien.claves ? "recien" : ""}">
            <td>${esc(k.nombre)}</td>
            <td class="mono">${esc(k.prefijo)}…</td>
            <td class="tenue">${diaDe(k.creadoEn)}</td>
            <td class="tenue">${k.ultimoUso ? diaDe(k.ultimoUso) : "nunca"}</td>
            <td>${k.activo
                    ? `<span class="insignia i-ok">activa</span>`
                    : `<span class="insignia i-tenue">revocada</span>`}</td>
            <td>${k.activo
                    ? `<button class="mini peligro" data-revocar="${k.id}">Revocar</button>`
                    : ""}</td>
          </tr>`).join("")}
        </table>`;
        }

        function vistaCertificado() {
            return `
        <div class="rejilla" style="margin-top:0">
          <label>Archivo del certificado
            <span class="archivo" id="envoltura-archivo">
              <input id="c-archivo" type="file" accept=".pfx,.p12">
              <span class="caja">
                <svg viewBox="0 0 24 24"><path d="M12 16V4m0 0L8 8m4-4l4 4"/><path d="M4 16v3a1 1 0 001 1h14a1 1 0 001-1v-3"/></svg>
                <span class="nombre-archivo" id="nombre-archivo">Elegir archivo .pfx o .p12</span>
              </span>
            </span>
          </label>
          <label>Contraseña del certificado
            <input id="c-clave" type="password" placeholder="la que entregó el cliente"></label>
        </div>

        <div style="display:flex;align-items:center;gap:12px;margin-bottom:16px">
          <button id="btn-certificado">Cargar certificado</button>
          <span class="tenue" style="font-size:12.5px">
            Se cifra antes de guardarse y reemplaza al activo anterior.
          </span>
        </div>

        <div id="c-resultado"></div>

        ${estado.certificados.length === 0
                    ? `<div class="vacio" style="border-top:1px solid var(--borde)">
               Sin certificado. Esta empresa no puede firmar ni emitir.</div>`
                    : barraFiltro("certificado", estado.certificados.length,
                        filtrar("certificado").length) +
                    `<div id="tabla-certificado">${tablaCertificados()}</div>`}`;
        }

        function tablaCertificados() {
            const filas = filtrar("certificado");

            if (filas.length === 0)
                return `<div class="vacio">Ningún certificado coincide con la búsqueda.</div>`;

            return `<table>
          <tr><th>Titular</th><th>Vence</th><th>Firmó</th><th>Estado</th>
              <th style="text-align:right">Acciones</th></tr>
          ${filas.map(c => `<tr class="${c.id === estado.recien.certificado ? "recien" : ""}
                                        ${c.activo ? "" : "fila-inactiva"}">
            <td style="font-size:13px">${esc(c.subject)}</td>
            <td class="mono">${dia(c.validoHasta)}</td>
            <td>${c.comprobantesFirmados}</td>
            <td>${c.activo
                    ? `<span class="insignia ${c.diasParaVencer <= 30 ? "i-aviso" : "i-ok"}">
                     activo · ${c.diasParaVencer} d</span>`
                    : `<span class="insignia i-tenue">reemplazado</span>`}</td>
            <td style="text-align:right;white-space:nowrap">
              ${c.sePuedeEliminar
                    ? `<button class="mini peligro" data-borrar-cert="${c.id}">Eliminar</button>`
                    : `<span class="tenue" style="font-size:12px"
                     title="${c.activo
                        ? "Es el certificado en uso."
                        : "Firmó comprobantes: hay que conservarlo para poder verificar esas firmas."}">
                     ${c.activo ? "en uso" : "se conserva"}</span>`}
            </td>
          </tr>`).join("")}
        </table>`;
        }

        /// Busca el texto en cualquier campo de la fila.
        ///
        /// Se concatenan todos los valores en vez de comparar campo por campo:
        /// así el buscador sirve para lo que el usuario tenga en la cabeza, sea el
        /// número de serie, el tipo, una fecha o el nombre de una clave, sin que
        /// haya que anticipar por cuál va a buscar.
        function coincide(fila, filtro, extras = []) {
            const f = filtro.trim().toLowerCase();
            if (!f) return true;

            const texto = [...Object.values(fila), ...extras]
                .filter(v => v !== null && v !== undefined && typeof v !== "object")
                .join(" ")
                .toLowerCase();

            return texto.includes(f);
        }

        /// Cabecera con buscador y conteo, común a las tres pestañas.
        function barraFiltro(clave, total, visibles) {
            return `
        <div class="filtro-tabla">
          <div class="buscador">
            <svg viewBox="0 0 24 24"><circle cx="11" cy="11" r="7"/><path d="M20 20l-3.5-3.5"/></svg>
            <input id="f-${clave}" placeholder="Buscar" value="${esc(estado.filtro[clave])}">
          </div>
          <span class="conteo">${visibles === total
                    ? `${total} ${total === 1 ? "registro" : "registros"}`
                    : `${visibles} de ${total}`}</span>
        </div>`;
        }

        /// Reengancha el buscador sin repintar la pestaña entera, para no perder
        /// el foco ni el cursor mientras se escribe.
        function enlazarFiltro(clave, repintarTabla) {
            const campo = elem("f-" + clave);
            if (!campo) return;

            campo.oninput = () => {
                estado.filtro[clave] = campo.value;
                repintarTabla();

                const conteo = document.querySelector(".filtro-tabla .conteo");
                if (conteo) conteo.textContent = textoConteo(clave);
            };
        }

        function enlazarRevocar() {
            document.querySelectorAll("[data-revocar]").forEach(b =>
                b.onclick = () => revocar(b.dataset.revocar));
        }

        function enlazarAccionesSerie() {
            document.querySelectorAll("[data-borrar-serie]").forEach(b =>
                b.onclick = () => eliminarSerie(b.dataset.borrarSerie, b.dataset.serieNombre));

            document.querySelectorAll("[data-cerrar-serie]").forEach(b =>
                b.onclick = () => cambiarSerie(b.dataset.cerrarSerie, false, b.dataset.serieNombre));

            document.querySelectorAll("[data-abrir-serie]").forEach(b =>
                b.onclick = () => cambiarSerie(b.dataset.abrirSerie, true, b.dataset.serieNombre));
        }

        function enlazarAccionesCertificado() {
            document.querySelectorAll("[data-borrar-cert]").forEach(b =>
                b.onclick = () => eliminarCertificado(b.dataset.borrarCert));
        }

        function textoConteo(clave) {
            const total = estado[clave === "certificado" ? "certificados" : clave].length;
            const visibles = filtrar(clave).length;

            return visibles === total
                ? `${total} ${total === 1 ? "registro" : "registros"}`
                : `${visibles} de ${total}`;
        }

        function filtrar(clave) {
            const f = estado.filtro[clave];

            if (clave === "series")
                return estado.series.filter(x =>
                    coincide(x, f, [nombreTipo(x.tipoComprobante)]));

            if (clave === "claves")
                return estado.claves.filter(x => coincide(x, f));

            if (clave === "webhooks")
                return estado.webhooks.filter(x => coincide(x, f, x.eventos ?? []));

            return estado.certificados.filter(x => coincide(x, f));
        }

        // ------------------------------------------------------------------ marca
        //
        // Cómo ve a la empresa su cliente: el portal donde descarga sus
        // comprobantes, el correo que recibe y el PDF.
        //
        // LAS MISMAS REGLAS QUE Marca.cs Y QUE LA MIGRACIÓN 020. Las de aquí
        // solo sirven para avisar mientras se escribe; las que mandan son las
        // del servidor.

        const DOMINIO_PORTAL = "comprobantes.reyban.pe";

        const RESERVADOS = ["api", "e", "portal", "admin", "www", "static",
            "assets", "health", "docs"];

        function problemaIdentificador(v) {
            if (!v) return "";
            if (v.length < 3 || v.length > 40) return "Entre 3 y 40 caracteres.";
            if (!/^[a-z0-9][a-z0-9-]{1,38}[a-z0-9]$/.test(v))
                return "Solo minúsculas sin tilde, números y guiones, sin guion al principio ni al final.";
            if (v.includes("--")) return "Sin dos guiones seguidos.";
            if (RESERVADOS.includes(v)) return `«${v}» está reservado. Elige otro.`;
            return "";
        }

        /// Una sugerencia sacada del nombre. SOLO SE SUGIERE: el
        /// identificador no se puede cambiar después, así que lo decide una
        /// persona, no el nombre comercial, que sí puede cambiar.
        function sugerirIdentificador(t) {
            const base = (t.nombreComercial || t.razonSocial || "")
                .normalize("NFD").replace(/[\u0300-\u036f]/g, "")
                .toLowerCase()
                .replace(/\b(s\.?a\.?c\.?|e\.?i\.?r\.?l\.?|s\.?r\.?l\.?|s\.?a\.?a\.?|s\.?a\.?)$/, "")
                .replace(/[^a-z0-9]+/g, "-")
                .replace(/^-+|-+$/g, "")
                .slice(0, 40)
                .replace(/-+$/g, "");

            return problemaIdentificador(base) ? "" : base;
        }

        function vistaMarca() {
            const t = estado.seleccionada;
            const editar = puede("empresas.editar");
            const dis = editar ? "" : "disabled";
            const sugerido = sugerirIdentificador(t);

            return `
        <p class="ayuda" style="margin-top:0">
          Cómo ve a esta empresa su cliente: en el portal donde descarga sus
          comprobantes, en el correo que recibe y en el PDF.
        </p>

        ${vistaDireccion(t, editar)}

        <h2>Dirección del portal</h2>
        ${t.identificador
                    ? `<div class="direccion-portal">
               ${DOMINIO_PORTAL}/<strong class="mono" style="font-size:14px">${esc(t.identificador)}</strong>
             </div>
             <div class="tenue" style="font-size:12.5px;margin-bottom:22px">
               Ya no se puede cambiar: es la dirección que va en los correos enviados.
             </div>`
                    : `<div class="rejilla" style="margin-top:0">
               <label>Identificador
                 <input id="m-identificador" maxlength="40" ${dis}
                        placeholder="${esc(sugerido || "ferreteria-lopez")}">
                 <div class="err" id="e-identificador"></div></label>
             </div>
             <div class="direccion-portal tenue" id="m-direccion">
               ${DOMINIO_PORTAL}/<span class="mono">…</span>
             </div>
             <div class="tenue" style="font-size:12.5px;margin-bottom:22px;
                                      border-left:2px solid var(--aviso);padding-left:11px">
               <strong>Se pone una sola vez.</strong> Va en la dirección de cada
               correo que se mande a los clientes de esta empresa, y cambiarlo
               rompería esos enlaces. Minúsculas, números y guiones.
               ${sugerido && editar
                        ? `<a href="#" id="m-sugerencia" style="color:var(--acento)">Usar «${esc(sugerido)}»</a>`
                        : ""}
             </div>`}

        <h2>Correo y color</h2>
        <div class="rejilla" style="margin-top:0">
          <label>Correo de respuesta
            <input id="m-correo" type="email" maxlength="254" ${dis}
                   value="${esc(t.correoRespuesta ?? "")}" placeholder="ventas@empresa.pe">
            <div class="err" id="e-correo"></div></label>
          <label>Color de la marca
            <span class="muestra-color">
              <input id="m-color-elegir" type="color" ${dis}
                     value="${esc(t.colorMarca ?? "#2563eb")}" title="Elegir color">
              <input id="m-color" maxlength="7" ${dis}
                     value="${esc(t.colorMarca ?? "")}" placeholder="vacío: sin color">
            </span>
            <div class="err" id="e-color"></div></label>
        </div>

        <div class="tenue" style="font-size:12.5px;margin-bottom:14px">
          Las respuestas de sus clientes al correo del comprobante llegan a ese
          correo. <strong>Sin él, no se les manda correo.</strong>
        </div>

        <!-- Migración 026: OPCIONAL y desactivada por defecto. -->
        <label style="display:flex;gap:10px;align-items:flex-start;margin:0 0 16px;font-weight:normal">
          <input id="m-copia" type="checkbox" ${dis} ${t.copiaAlEmisor ? "checked" : ""}
                 style="width:auto;margin-top:3px">
          <span>
            <strong>Mandar una copia de cada comprobante al correo de respuesta</strong>
            <span class="tenue">(opcional)</span><br>
            <span class="tenue" style="font-size:12.5px">
              Va en copia oculta: su cliente no la ve. Desmarcado, solo le llega a su
              cliente; la empresa ve igual todos sus comprobantes en la plataforma.
              Sin correo de respuesta, no se manda.
            </span>
          </span>
        </label>

        ${editar ? `<button class="principal" id="btn-marca">Guardar</button>` : ""}

        <h2 style="margin-top:26px">Logo</h2>
        <div style="display:flex;gap:16px;align-items:center;flex-wrap:wrap;margin-bottom:10px">
          <div class="logo-caja">
            ${t.tieneLogo
                    ? `<img src="/admin/tenants/${t.id}/logo?v=${encodeURIComponent(t.logoVersion)}"
                      alt="Logo de ${esc(t.razonSocial)}">`
                    : `<span class="tenue">Sin logo</span>`}
          </div>

          ${editar ? `
            <div style="display:flex;gap:10px;align-items:center;flex-wrap:wrap">
              <span class="archivo" id="envoltura-logo" style="min-width:220px">
                <input id="l-archivo" type="file" accept=".png,.jpg,.jpeg,image/png,image/jpeg">
                <span class="caja">
                  <svg viewBox="0 0 24 24"><path d="M12 16V4m0 0L8 8m4-4l4 4"/><path d="M4 16v3a1 1 0 001 1h14a1 1 0 001-1v-3"/></svg>
                  <span class="nombre-archivo" id="nombre-logo">Elegir PNG o JPG</span>
                </span>
              </span>
              <button id="btn-logo">${t.tieneLogo ? "Cambiar logo" : "Subir logo"}</button>
            </div>` : ""}
        </div>

        <div class="tenue" style="font-size:12.5px">
          PNG o JPG, máximo 300 KB. En el PDF sale a la izquierda del recuadro del
          RUC, a 50 puntos de alto. Mejor con fondo transparente o blanco.
        </div>
        <div id="l-resultado"></div>`;
        }

        function enlazarMarca() {
            const campo = elem("m-identificador");

            if (campo) {
                const reflejar = () => {
                    const v = campo.value.trim().toLowerCase();
                    const problema = problemaIdentificador(v);

                    elem("e-identificador").textContent = problema;
                    campo.parentElement.classList.toggle("invalido", !!problema);

                    elem("m-direccion").innerHTML =
                        `${DOMINIO_PORTAL}/<span class="mono">${esc(v || "…")}</span>`;
                };

                campo.oninput = reflejar;

                const sugerencia = elem("m-sugerencia");
                if (sugerencia) sugerencia.onclick = ev => {
                    ev.preventDefault();
                    campo.value = sugerirIdentificador(estado.seleccionada);
                    reflejar();
                    campo.focus();
                };
            }

            // El selector de color y el texto se siguen el uno al otro. El
            // texto manda: vacío significa "sin color".
            const elegir = elem("m-color-elegir");
            const texto = elem("m-color");

            if (elegir && texto) {
                elegir.oninput = () => { texto.value = elegir.value; };
                texto.oninput = () => {
                    if (/^#[0-9a-fA-F]{6}$/.test(texto.value.trim()))
                        elegir.value = texto.value.trim().toLowerCase();
                };
            }

            if (elem("btn-marca")) elem("btn-marca").onclick = guardarMarca;
            if (elem("btn-direccion")) elem("btn-direccion").onclick = guardarDireccion;
            if (elem("btn-logo")) elem("btn-logo").onclick = subirLogo;

            const archivo = elem("l-archivo");
            if (archivo) archivo.onchange = ev => {
                const f = ev.target.files[0];
                elem("nombre-logo").textContent = f ? f.name : "Elegir PNG o JPG";
                elem("envoltura-logo").classList.toggle("con-archivo", !!f);
            };
        }

        async function guardarMarca() {
            const t = estado.seleccionada;
            const campo = elem("m-identificador");
            const identificador = campo ? campo.value.trim().toLowerCase() : null;
            const correo = elem("m-correo").value.trim();
            const color = elem("m-color").value.trim().toLowerCase();

            let valido = true;

            const marcar = (id, mensaje) => {
                elem("e-" + id).textContent = mensaje;
                elem("m-" + id).parentElement.classList.toggle("invalido", !!mensaje);
                if (mensaje) valido = false;
            };

            if (campo) marcar("identificador", problemaIdentificador(identificador));

            marcar("correo", !correo || /^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(correo)
                ? "" : "No tiene forma de correo.");

            elem("e-color").textContent =
                !color || /^#[0-9a-f]{6}$/.test(color) ? "" : "Tiene que ir como #rrggbb.";
            if (elem("e-color").textContent) valido = false;

            if (!valido) return;

            // FIJAR EL IDENTIFICADOR SE CONFIRMA APARTE, porque no tiene vuelta.
            if (identificador) {
                const seguro = await confirmar(
                    "Fijar la dirección del portal",
                    `La dirección de ${t.razonSocial} será ${DOMINIO_PORTAL}/${identificador}. ` +
                    "No se podrá cambiar nunca: va en cada correo que se mande a sus clientes.",
                    "Sí, fijarla");

                if (!seguro) return;
            }

            const boton = elem("btn-marca");
            boton.disabled = true;

            try {
                await api(`/admin/tenants/${t.id}/marca`, {
                    method: "PUT",
                    headers: { "Content-Type": "application/json" },
                    body: JSON.stringify({
                        identificador: identificador || null,
                        colorMarca: color || null,
                        correoRespuesta: correo || null,
                        copiaAlEmisor: elem("m-copia")?.checked ?? false
                    })
                });

                avisar("Marca guardada", "", "ok");
                await recargar();

            } catch (ex) {
                avisar(ex.message, ex.detalle, "mal");
                boton.disabled = false;
            }
        }

        async function subirLogo() {
            const archivo = elem("l-archivo").files[0];
            const resultado = elem("l-resultado");

            if (!archivo) {
                resultado.innerHTML =
                    `<div style="color:var(--mal);margin-top:10px">Elige el archivo del logo.</div>`;
                return;
            }

            // Se avisa antes de subir para no gastar el viaje. El servidor lo
            // vuelve a comprobar, y además mira que de verdad sea PNG o JPG.
            if (archivo.size > 300 * 1024) {
                resultado.innerHTML =
                    `<div style="color:var(--mal);margin-top:10px">Pesa
                 ${Math.ceil(archivo.size / 1024)} KB y el máximo es 300 KB.</div>`;
                return;
            }

            const datos = new FormData();
            datos.append("archivo", archivo);

            const boton = elem("btn-logo");
            boton.disabled = true;
            resultado.innerHTML = `<div class="tenue" style="margin-top:10px">Comprobando y guardando…</div>`;

            try {
                const r = await api(`/admin/tenants/${estado.seleccionada.id}/logo`,
                    { method: "POST", body: datos });

                avisar("Logo guardado", r.mensaje, "ok");
                await recargar();

            } catch (ex) {
                resultado.innerHTML =
                    `<div style="color:var(--mal);margin-top:10px">${esc(ex.message)}<br>
             <span class="tenue">${esc(ex.detalle || "")}</span></div>`;
                boton.disabled = false;
            }
        }

        function vistaProduccion() {
            const t = estado.seleccionada;
            const r = estado.revision;

            return `
        <div style="background:var(--sutil);border-radius:var(--radio);
                    padding:13px 15px;margin-bottom:18px">
          <div style="display:flex;align-items:center;justify-content:space-between;
                      gap:12px;flex-wrap:wrap">
            <div>
              <div style="font-size:14px">Ambiente actual:
                <strong>${t.ambiente === "produccion" ? "Producción" : "Beta (pruebas)"}</strong>
              </div>
              <div class="tenue" style="font-size:12.5px;margin-top:2px">
                ${t.ambiente === "produccion"
                    ? "Los comprobantes van a SUNAT de verdad y tienen valor legal."
                    : "Los comprobantes van al ambiente de pruebas y no tienen validez."}
              </div>
            </div>
            <button id="btn-ambiente" class="${t.ambiente === "produccion" ? "" : "principal"}">
              ${t.ambiente === "produccion" ? "Volver a pruebas" : "Pasar a producción"}
            </button>
          </div>
        </div>

        <h2>Credenciales SOL</h2>
        <div class="rejilla" style="margin-top:0">
          <label>Usuario SOL secundario
            <input id="s-usuario" placeholder="FACTURA01"
                   value="${esc(t.usuarioSol && t.usuarioSol !== "MODDATOS" ? t.usuarioSol : "")}">
            <div class="err" id="e-usuario"></div></label>
          <label>Clave SOL
            <input id="s-clave" type="password"
                   placeholder="${t.tieneClaveSol ? "•••••• (guardada)" : "la del usuario secundario"}">
          </label>
        </div>

        <div style="display:flex;align-items:center;gap:12px;margin-bottom:18px">
          <button id="btn-sol">Guardar credenciales</button>
          <span class="tenue" style="font-size:12.5px">
            La clave se cifra igual que el certificado.
          </span>
        </div>

        <div class="tenue" style="font-size:12.5px;margin-bottom:22px;
                                  border-left:2px solid var(--borde);padding-left:11px">
          Debe ser el usuario SOL <strong>secundario</strong> del contribuyente,
          nunca el principal. El principal puede declarar, pagar y modificar datos
          en el portal de SUNAT, y ese nivel de acceso no tiene por qué vivir aquí.
        </div>

        <h2>Guías de remisión</h2>
        <p class="ayuda" style="margin-top:0">
          Las guías usan un canal distinto al de las facturas: no es SOAP con
          clave SOL, sino una API REST con credenciales propias. El contribuyente
          las genera en su menú SOL, opción &laquo;Credenciales de API SUNAT&raquo;.
        </p>

        <div style="display:flex;align-items:center;gap:12px;margin-bottom:14px">
          ${t.greListo
                    ? `<span class="insignia i-ok">habilitadas</span>`
                    : `<span class="insignia i-tenue">sin configurar</span>`}
          ${t.greClientId
                    ? `<span class="tenue mono" style="font-size:12.5px">
                 ${esc(t.greClientId)}</span>` : ""}
        </div>

        <div class="rejilla" style="margin-top:0">
          <label>client_id
            <input id="g-client" placeholder="el que generó en su menú SOL"
                   value="${esc(t.greClientId ?? "")}"></label>
          <label>client_secret
            <input id="g-secret" type="password"
                   placeholder="${t.tieneGreSecret ? "•••••• (guardado)" : "el secreto"}">
          </label>
        </div>

        <div style="display:flex;align-items:center;gap:12px;margin-bottom:22px">
          <button id="btn-gre">Guardar credenciales de guías</button>
          <span class="tenue" style="font-size:12.5px">
            El secreto se cifra igual que el certificado.
          </span>
        </div>

        <h2>Revisión previa</h2>
        ${r.listo
                    ? `<div class="secreto">Todo listo. Esta empresa puede emitir en producción.</div>`
                    : `<div style="background:var(--mal-fondo);border:1px solid var(--mal);
                         border-radius:var(--radio);padding:13px 15px">
               <strong style="color:var(--mal)">Falta lo siguiente:</strong>
               <ul style="margin:8px 0 0;padding-left:20px;font-size:13.5px">
                 ${r.faltantes.map(f => `<li>${esc(f)}</li>`).join("")}
               </ul>
             </div>`}

        ${r.advertencias.length === 0 ? "" : `
          <div style="background:var(--aviso-fondo);border:1px solid var(--aviso);
                      border-radius:var(--radio);padding:13px 15px;margin-top:12px">
            <strong style="color:var(--aviso)">Conviene revisar:</strong>
            <ul style="margin:8px 0 0;padding-left:20px;font-size:13.5px">
              ${r.advertencias.map(a => `<li>${esc(a)}</li>`).join("")}
            </ul>
          </div>`}`;
        }

        async function guardarCredenciales() {
            const usuario = elem("s-usuario").value.trim();
            const clave = elem("s-clave").value;

            elem("e-usuario").textContent = "";

            if (!usuario) {
                elem("e-usuario").textContent = "Escribe el usuario SOL.";
                return;
            }

            if (!clave) {
                avisar("Falta la clave SOL",
                    "Escríbela aunque ya hubiera una guardada: no se puede leer.", "mal");
                return;
            }

            const boton = elem("btn-sol");
            boton.disabled = true;

            try {
                await api(`/admin/tenants/${estado.seleccionada.id}/credenciales-sol`, {
                    method: "POST",
                    headers: { "Content-Type": "application/json" },
                    body: JSON.stringify({ usuario, clave })
                });

                avisar("Credenciales guardadas y cifradas", "", "ok");

                elem("s-clave").value = "";
                await recargar();

            } catch (e) {
                avisar(e.message, e.detalle, "mal");
            } finally {
                boton.disabled = false;
            }
        }

        async function guardarCredencialesGre() {
            const clientId = elem("g-client").value.trim();
            const secret = elem("g-secret").value;

            if (!clientId) {
                avisar("Falta el client_id", "", "mal");
                return;
            }

            if (!secret) {
                avisar("Falta el client_secret",
                    "Escríbelo aunque ya hubiera uno guardado: no se puede leer.", "mal");
                return;
            }

            const boton = elem("btn-gre");
            boton.disabled = true;

            try {
                const r = await api(`/admin/tenants/${estado.seleccionada.id}/credenciales-gre`, {
                    method: "POST",
                    headers: { "Content-Type": "application/json" },
                    body: JSON.stringify({ clientId, clientSecret: secret })
                });

                avisar("Credenciales de guías guardadas", r.mensaje, "ok");

                elem("g-secret").value = "";
                await recargar();

            } catch (e) {
                avisar(e.message, e.detalle, "mal");
            } finally {
                boton.disabled = false;
            }
        }

        async function cambiarAmbiente() {
            const t = estado.seleccionada;
            const aProduccion = t.ambiente !== "produccion";

            const seguro = await confirmar(
                aProduccion ? "Pasar a producción" : "Volver al ambiente de pruebas",

                aProduccion
                    ? `${t.razonSocial} empezará a emitir comprobantes REALES ante SUNAT, ` +
                    "con valor legal. Los correlativos que consuma no se pueden recuperar."
                    : `${t.razonSocial} volverá a emitir contra el ambiente de pruebas. ` +
                    "Los comprobantes que emita dejarán de tener validez legal.",

                aProduccion ? "Pasar a producción" : "Volver a pruebas");

            if (!seguro) return;

            try {
                const r = await api(`/admin/tenants/${t.id}/ambiente`, {
                    method: "POST",
                    headers: { "Content-Type": "application/json" },
                    body: JSON.stringify({ ambiente: aProduccion ? "produccion" : "beta" })
                });

                avisar(r.mensaje,
                    r.advertencias?.length ? r.advertencias.join(" ") : "", "ok");

                await recargar();

            } catch (e) {
                avisar(e.message, e.detalle, "mal");
            }
        }

        function vistaWebhooks() {
            return `
        <div class="rejilla" style="margin-top:0">
          <label>Nombre<input id="w-nombre" placeholder="ERP del cliente"></label>
          <label>URL de destino
            <input id="w-url" placeholder="https://sistema-del-cliente.com/avisos">
            <div class="err" id="e-url"></div></label>
        </div>

        <div style="display:flex;align-items:center;gap:12px;margin-bottom:16px">
          <button id="btn-webhook">Registrar webhook</button>
          <span class="tenue" style="font-size:12.5px">
            El secreto de firma se muestra una sola vez.
          </span>
        </div>

        <div id="w-resultado"></div>

        ${estado.webhooks.length === 0
                    ? `<div class="vacio" style="border-top:1px solid var(--borde)">
               Sin webhooks. El cliente tendrá que consultar el estado por su cuenta.
               Si usa la plataforma, se registra solo al pulsar «Conectar» allí.</div>`
                    : barraFiltro("webhooks", estado.webhooks.length,
                        filtrar("webhooks").length) +
                    `<div id="tabla-webhooks">${tablaWebhooks()}</div>`}

        ${estado.entregas.length === 0 ? "" : `
          <h2 style="margin-top:26px">Últimas entregas</h2>
          ${tablaEntregas()}`}

        ${estado.cambiosWebhook.length === 0 ? "" : `
          <h2 style="margin-top:26px">Cambios</h2>
          <p class="tenue" style="font-size:12.5px;margin:-4px 0 10px">
            Altas y rotaciones hechas con una clave de acceso, y activaciones desde
            aquí. Si ves un cambio que no esperabas, busca ese prefijo en
            <strong>Claves de acceso</strong> y revócala.</p>
          ${tablaCambiosWebhook()}`}`;
        }

        const nombreAccionWebhook = a => ({
            alta: "Registrado",
            rotacion: "Secreto rotado",
            activado: "Activado",
            desactivado: "Desactivado"
        }[a] || a);

        function tablaCambiosWebhook() {
            return `<table>
          <tr><th>Cuándo</th><th>Qué</th><th>URL</th><th>Quién</th></tr>
          ${estado.cambiosWebhook.map(c => `<tr>
            <td class="tenue" style="white-space:nowrap">${fechaHora(c.creadoEn)}</td>
            <td>${esc(nombreAccionWebhook(c.accion))}</td>
            <td class="mono recorte" style="max-width:300px;font-size:12.5px"
                title="${esc(c.urlAntes && c.urlAntes !== c.urlDespues
                    ? `${c.urlAntes} → ${c.urlDespues}` : c.urlDespues)}">
              ${c.urlAntes && c.urlAntes !== c.urlDespues
                    ? `<span class="tenue">${esc(c.urlAntes)}</span> → ` : ""}${esc(c.urlDespues)}</td>
            <td>${c.hechoDesde === "api"
                    ? `<span class="mono" style="font-size:12.5px">${esc(c.prefijoClave ?? "")}…</span>`
                    : `<span class="tenue">panel</span>`}</td>
          </tr>`).join("")}
        </table>`;
        }

        function tablaWebhooks() {
            const filas = filtrar("webhooks");

            if (filas.length === 0)
                return `<div class="vacio">Ningún webhook coincide con la búsqueda.</div>`;

            return `<table>
          <tr><th>Nombre</th><th>URL</th><th>Pendientes</th><th>Agotadas</th>
              <th>Estado</th><th style="text-align:right">Acciones</th></tr>
          ${filas.map(w => `<tr class="${w.id === estado.recien.webhooks ? "recien" : ""}
                                        ${w.activo ? "" : "fila-inactiva"}">
            <td>${esc(w.nombre)}
              ${w.origen === "api"
                    ? `<div style="margin-top:4px"><span class="insignia i-api"
                         title="Lo registró la plataforma con la clave de la empresa. La URL y el secreto los mantiene ella al conectar; aquí solo se prueba o se desactiva.">registrado por la API</span></div>`
                    : ""}</td>
            <td class="mono recorte" title="${esc(w.url)}"
                style="max-width:230px">${esc(w.url)}</td>
            <td>${w.pendientes}</td>
            <td class="${w.agotados > 0 ? "mal" : ""}">${w.agotados}</td>
            <td title="Secreto vigente desde ${esc(fechaHora(w.secretoCambiadoEn))}">${w.activo
                    ? `<span class="insignia i-ok">activo</span>`
                    : `<span class="insignia i-tenue">inactivo</span>`}</td>
            <td style="text-align:right;white-space:nowrap">
              <button class="mini" data-probar-wh="${w.id}">Probar</button>
              <button class="mini" data-alternar-wh="${w.id}"
                      data-activo="${w.activo}">${w.activo ? "Desactivar" : "Activar"}</button>
            </td>
          </tr>`).join("")}
        </table>`;
        }

        function tablaEntregas() {
            return `<table>
          <tr><th>Evento</th><th>Estado</th><th>Intentos</th><th>Detalle</th>
              <th>Cuándo</th><th></th></tr>
          ${estado.entregas.map(e => `<tr>
            <td class="mono" style="font-size:12.5px">${esc(e.tipo)}</td>
            <td>${insigniaEntrega(e.estado)}</td>
            <td>${e.intentos}</td>
            <td class="recorte tenue" style="max-width:260px"
                title="${esc(e.ultimoError ?? "")}">
              ${e.ultimoCodigo ? `HTTP ${e.ultimoCodigo}` : ""}
              ${esc(e.ultimoError ?? "")}</td>
            <td class="tenue">${fechaHora(e.creadoEn)}</td>
            <td>${e.estado === "AGOTADO"
                    ? `<button class="mini" data-reintentar-entrega="${e.id}">Reintentar</button>`
                    : ""}</td>
          </tr>`).join("")}
        </table>`;
        }

        const insigniaEntrega = estado => ({
            ENTREGADO: `<span class="insignia i-ok">entregado</span>`,
            PENDIENTE: `<span class="insignia i-aviso">pendiente</span>`,
            AGOTADO: `<span class="insignia i-mal">agotado</span>`
        }[estado] || esc(estado));

        function enlazarAccionesWebhook() {
            document.querySelectorAll("[data-probar-wh]").forEach(b =>
                b.onclick = () => probarWebhook(b.dataset.probarWh));

            document.querySelectorAll("[data-alternar-wh]").forEach(b =>
                b.onclick = () => alternarWebhook(
                    b.dataset.alternarWh, b.dataset.activo !== "true"));

            document.querySelectorAll("[data-reintentar-entrega]").forEach(b =>
                b.onclick = () => reintentarEntrega(b.dataset.reintentarEntrega));
        }

        async function crearWebhook() {
            const url = elem("w-url").value.trim();
            const caja = elem("e-url");

            if (!/^https?:\/\/.+/i.test(url)) {
                caja.textContent = "Debe ser una dirección completa, con https:// delante.";
                elem("w-url").parentElement.classList.add("invalido");
                return;
            }

            caja.textContent = "";
            elem("w-url").parentElement.classList.remove("invalido");

            const boton = elem("btn-webhook");
            boton.disabled = true;

            try {
                const r = await api(`/admin/tenants/${estado.seleccionada.id}/webhooks`, {
                    method: "POST",
                    headers: { "Content-Type": "application/json" },
                    body: JSON.stringify({
                        nombre: elem("w-nombre").value.trim() || "Sin nombre",
                        url,
                        eventos: []
                    })
                });

                // Igual que con las claves: el secreto se muestra fijo, no como aviso
                // flotante. Es la única vez que existe fuera del cliente.
                elem("w-resultado").innerHTML = `
          <div class="secreto">
            <strong>Entrega este secreto al cliente ahora.</strong>
            <code>${esc(r.secreto)}</code>
            <button class="mini" id="btn-copiar-secreto">Copiar</button>
            <div class="tenue" style="font-size:12.5px;margin-top:8px">${esc(r.aviso)}</div>
          </div>`;

                elem("btn-copiar-secreto").onclick = async () => {
                    await navigator.clipboard.writeText(r.secreto);
                    avisar("Secreto copiado", "", "ok");
                };

                elem("w-nombre").value = "";
                elem("w-url").value = "";

                marcarRecien("webhooks", r.id);

                estado.webhooks = await api(`/admin/tenants/${estado.seleccionada.id}/webhooks`);

                const tabla = elem("tabla-webhooks");
                if (tabla) { tabla.innerHTML = tablaWebhooks(); enlazarAccionesWebhook(); }
                else cargarPestana();

            } catch (e) {
                avisar(e.message, e.detalle, "mal");
            } finally {
                boton.disabled = false;
            }
        }

        async function probarWebhook(id) {
            try {
                const r = await api(
                    `/admin/tenants/${estado.seleccionada.id}/webhooks/${id}/prueba`,
                    { method: "POST" });

                avisar("Aviso de prueba encolado", r.mensaje, "ok");

                // Se espera al ciclo del despachador antes de refrescar, o la entrega
                // aparecería siempre como pendiente y parecería que no funciona.
                setTimeout(() => {
                    if (estado.pestana === "webhooks") cargarPestana();
                }, 12000);

            } catch (e) { avisar(e.message, e.detalle, "mal"); }
        }

        async function alternarWebhook(id, activar) {
            // Desactivar el de la API deja a la plataforma sin avisos de SUNAT
            // hasta que alguien pulse «Conectar» otra vez. Se pregunta antes.
            const w = estado.webhooks.find(x => x.id === id);

            if (!activar && w && w.origen === "api") {
                const seguro = await confirmar(
                    "Desactivar el webhook de la API",
                    "La plataforma dejará de enterarse de lo que responde SUNAT para " +
                    "esta empresa, y sus comprobantes se quedarán «en camino». Volverá " +
                    "a funcionar cuando se pulse «Conectar» en la plataforma.",
                    "Desactivar");

                if (!seguro) return;
            }

            try {
                await api(`/admin/tenants/${estado.seleccionada.id}/webhooks/${id}`, {
                    method: "PATCH",
                    headers: { "Content-Type": "application/json" },
                    body: JSON.stringify({ activo: activar })
                });

                avisar(activar ? "Webhook activado" : "Webhook desactivado", "", "ok");
                await cargarPestana();

            } catch (e) { avisar(e.message, e.detalle, "mal"); }
        }

        async function reintentarEntrega(id) {
            try {
                await api(`/admin/webhook-entregas/${id}/reintentar`, { method: "POST" });

                avisar("Entrega devuelta a la cola",
                    "Se enviará en el siguiente ciclo.", "ok");

                setTimeout(() => {
                    if (estado.pestana === "webhooks") cargarPestana();
                }, 12000);

            } catch (e) { avisar(e.message, e.detalle, "mal"); }
        }

        // LOS NUEVE TIPOS QUE EL SISTEMA EMITE.
        //
        // Faltaban seis, y el panel los enseñaba como el número crudo. Peor aún: el
        // desplegable de "agregar serie" solo ofrecía cuatro, así que una empresa
        // nueva no podía recibir su L001, su R001 ni su V001 desde aquí.
        const nombreTipo = t => ({
            "01": "Factura",
            "03": "Boleta",
            "04": "Liquidación de compra",
            "07": "Nota de crédito",
            "08": "Nota de débito",
            "09": "Guía de remisión remitente",
            "20": "Comprobante de retención",
            "31": "Guía de remisión transportista",
            "40": "Comprobante de percepción"
        }[t] || t);

        // LA INICIAL DE LA SERIE LA FIJA SUNAT y no es negociable. Se usa para
        // sugerir el ejemplo correcto al cambiar de tipo, porque teclear "F001" en
        // una liquidación es el error más fácil de cometer aquí.
        const serieSugerida = t =>
        ({
            "01": "F001", "03": "B001", "04": "L001", "07": "F001", "08": "F001",
            "09": "T001", "20": "R001", "31": "V001", "40": "P001"
        }[t] || "F001");

        // -------------------------------------------------------- dirección fiscal
        //
        // La que sale en cada comprobante. «Revisada» quiere decir que alguien
        // la escribió a propósito: una dirección con los valores por defecto
        // no se distingue de una buena, y por eso cuenta la fecha (024).

        function vistaDireccion(t, editar) {
            const dis = editar ? "" : "disabled";

            return `
        <h2>Dirección fiscal</h2>
        ${t.direccionRevisadaEn
                    ? `<div class="aviso-linea ok">Revisada el ${fechaHora(t.direccionRevisadaEn)}.</div>`
                    : `<div class="aviso-linea"><strong>Sin revisar.</strong> Puede tener los valores
                 por defecto (LIMA). Compárala con la ficha RUC y guárdala: hasta entonces, la
                 plataforma no deja activar la facturación de un cliente nuevo.</div>`}

        <div class="rejilla" style="margin-top:0">
          <label>Dirección<input id="d-direccion" ${dis} value="${esc(t.direccion ?? "")}"></label>
          <label>Distrito<input id="d-distrito" ${dis} value="${esc(t.distrito ?? "")}"></label>
          <label>Provincia<input id="d-provincia" ${dis} value="${esc(t.provincia ?? "")}"></label>
          <label>Departamento<input id="d-departamento" ${dis} value="${esc(t.departamento ?? "")}"></label>
          <label>Ubigeo<input id="d-ubigeo" ${dis} maxlength="6" inputmode="numeric"
                              value="${esc(t.ubigeo ?? "")}"></label>
        </div>
        <div class="err" id="e-dir" style="margin:-6px 0 8px"></div>

        <div class="aviso-linea" style="margin-bottom:8px">
          <strong>Cópiala tal cual de la ficha RUC.</strong> Sale en cada comprobante, y
          SUNAT no la corrige: el ubigeo tiene que ser el del distrito, y la provincia y el
          departamento, los de ese distrito.
        </div>
        <div class="tenue" style="font-size:12.5px;margin-bottom:12px">
          Los comprobantes ya emitidos no cambian: llevan la dirección con la que se firmaron.
        </div>

        ${editar ? `<button id="btn-direccion" style="margin-bottom:26px">Guardar dirección</button>` : ""}`;
        }

        async function guardarDireccion() {
            const t = estado.seleccionada;
            const valor = id => elem(id).value.trim();

            const cuerpo = {
                direccion: valor("d-direccion"),
                distrito: valor("d-distrito"),
                provincia: valor("d-provincia"),
                departamento: valor("d-departamento"),
                ubigeo: valor("d-ubigeo")
            };

            elem("e-dir").textContent = "";

            const boton = elem("btn-direccion");
            boton.disabled = true;

            try {
                const r = await api(`/admin/tenants/${t.id}/direccion`, {
                    method: "PUT",
                    headers: { "Content-Type": "application/json" },
                    body: JSON.stringify(cuerpo)
                });

                avisar("Dirección guardada", r.mensaje, "ok");
                await recargar();

            } catch (ex) {
                // El motivo exacto (por ejemplo, el ubigeo es de otro
                // departamento) queda a la vista, no solo en el aviso.
                elem("e-dir").textContent = ex.detalle || ex.message;
                boton.disabled = false;
            }
        }

        /// Quién creó la empresa: el panel o una clave de alta (la plataforma).
        function origenAlta(t) {
            if (!t.claveAltaNombre)
                return "";

            const confirmada = t.estadoAlta === "confirmada" && t.altaConfirmadaEn
                ? ` · confirmada el ${fechaHora(t.altaConfirmadaEn)}` : "";

            return `<div class="tenue" style="font-size:12.5px;margin-top:3px">
                Creada por la clave de alta «${esc(t.claveAltaNombre)}»
                (<span class="mono">${esc(t.claveAltaPrefijo)}…</span>) el
                ${fechaHora(t.creadoEn)}${confirmada}</div>`;
        }

        // ---------------------------------------------------------- claves de alta
        //
        // La clave con la que la plataforma crea emisores (024). Solo crea: no
        // lee ni cambia las empresas que ya existen. Si se filtra, lo peor es
        // que alguien ocupe el RUC de un cliente; por eso el tope diario, el
        // aviso al alcanzarlo y la fecha del último uso a la vista.

        const DIAS_SIN_USO = 90;

        async function cargarClavesAlta() {
            if (!puede("altas.gestionar")) return;

            estado.clavesAlta = await api("/admin/claves-alta");

            // Una clave en su tope se ve sin tener que abrir nada.
            if (estado.clavesAlta.some(k => k.activo && k.altasHoy >= k.topeDiario))
                estado.altasAbierto = true;
        }

        const diasDesde = f => f ? Math.floor((new Date() - new Date(f)) / 86400000) : null;

        function bloqueClavesAlta() {
            if (!puede("altas.gestionar")) return "";

            const activas = estado.clavesAlta.filter(k => k.activo);
            const enTope = activas.filter(k => k.altasHoy >= k.topeDiario);

            return `
        <div class="tarjeta bloque-altas ${enTope.length ? "alerta" : ""}">
          <div class="cab">
            <div>
              <h3>Claves de alta
                ${enTope.length
                    ? `<span class="insignia i-mal" style="margin-left:6px">tope alcanzado hoy</span>` : ""}
              </h3>
              <div class="explica">
                Con ellas la plataforma crea empresas aquí. Solo crean: no leen ni cambian las existentes.
                ${activas.length} ${activas.length === 1 ? "activa" : "activas"}.
              </div>
            </div>
            <button class="mini" id="btn-altas-abrir">${estado.altasAbierto ? "Ocultar" : "Ver"}</button>
          </div>

          ${estado.altasAbierto ? `
            <div class="rejilla">
              <label>Nombre<input id="ka-nombre" maxlength="100" placeholder="Plataforma producción"></label>
              <label>Tope por día<input id="ka-tope" type="number" min="1" max="100" value="20"></label>
            </div>
            <div style="display:flex;align-items:center;gap:12px;margin-bottom:12px;flex-wrap:wrap">
              <button id="btn-alta-emitir">Emitir clave de alta</button>
              <span class="tenue" style="font-size:12.5px">
                Se muestra una sola vez. Va al .env de la plataforma (FACTURACION_CLAVE_ALTA).
              </span>
            </div>
            <div id="ka-resultado"></div>
            ${tablaClavesAlta()}` : ""}
        </div>`;
        }

        function tablaClavesAlta() {
            if (estado.clavesAlta.length === 0)
                return `<div class="vacio" style="border-top:1px solid var(--borde)">
                  Ninguna todavía. Sin una, la plataforma no puede crear empresas.</div>`;

            return `<table>
          <tr><th>Nombre</th><th>Prefijo</th><th>Hoy</th><th>Total</th>
              <th>Último uso</th><th>Estado</th><th></th></tr>
          ${estado.clavesAlta.map(k => {
                const enTope = k.activo && k.altasHoy >= k.topeDiario;
                const sinUso = diasDesde(k.ultimoUso ?? k.creadoEn);
                const vieja = k.activo && sinUso !== null && sinUso >= DIAS_SIN_USO;

                return `<tr class="${k.activo ? "" : "fila-inactiva"}">
              <td>${esc(k.nombre)}
                <div class="tenue" style="font-size:12px">
                  emitida el ${diaDe(k.creadoEn)}${k.creadaPor ? ` por ${esc(k.creadaPor)}` : ""}</div></td>
              <td class="mono">${esc(k.prefijo)}…</td>
              <td class="${enTope ? "mal" : ""}" style="white-space:nowrap">${k.altasHoy} de ${k.topeDiario}</td>
              <td>${k.altasTotal}</td>
              <td class="tenue">
                ${k.ultimoUso ? fechaHora(k.ultimoUso) : "nunca"}
                ${vieja ? `<div style="color:var(--aviso);font-size:12px"
                     title="Una clave que nadie usa solo sirve para que alguien la encuentre.">
                     ${sinUso} días sin usarse: ¿sigue haciendo falta?</div>` : ""}</td>
              <td>${k.activo
                    ? `<span class="insignia i-ok">activa</span>`
                    : `<span class="insignia i-tenue" title="${k.revocadaPor ? "por " + esc(k.revocadaPor) : ""}">
                         revocada el ${diaDe(k.revocadoEn)}</span>`}</td>
              <td>${k.activo
                    ? `<button class="mini peligro" data-revocar-alta="${k.id}"
                               data-nombre="${esc(k.nombre)}">Revocar</button>` : ""}</td>
            </tr>`;
            }).join("")}
        </table>`;
        }

        function enlazarClavesAlta() {
            const abrir = elem("btn-altas-abrir");
            if (!abrir) return;

            abrir.onclick = () => {
                estado.altasAbierto = !estado.altasAbierto;
                pintar();
            };

            if (elem("btn-alta-emitir")) elem("btn-alta-emitir").onclick = emitirClaveAlta;

            document.querySelectorAll("[data-revocar-alta]").forEach(b =>
                b.onclick = () => revocarClaveAlta(b.dataset.revocarAlta, b.dataset.nombre));
        }

        async function emitirClaveAlta() {
            const nombre = elem("ka-nombre").value.trim();
            const tope = parseInt(elem("ka-tope").value || "20", 10);

            if (!nombre) {
                avisar("Ponle un nombre", "Dónde se va a usar: «Plataforma producción», por ejemplo.", "mal");
                return;
            }

            const boton = elem("btn-alta-emitir");
            boton.disabled = true;

            try {
                const r = await api("/admin/claves-alta", {
                    method: "POST",
                    headers: { "Content-Type": "application/json" },
                    body: JSON.stringify({ nombre, topeDiario: tope })
                });

                estado.clavesAlta = await api("/admin/claves-alta");
                pintar();

                // Se muestra fija y DESPUÉS de repintar: es la única vez que
                // existe, y un repintado la borraría.
                elem("ka-resultado").innerHTML = `
          <div class="secreto" style="margin-bottom:12px">
            <strong>Cópiala ahora y pégala en el .env de la plataforma.</strong>
            <code>${esc(r.clave)}</code>
            <button class="mini" id="btn-copiar-alta">Copiar</button>
            <div class="tenue" style="font-size:12.5px;margin-top:8px">${esc(r.aviso)}</div>
          </div>`;

                elem("btn-copiar-alta").onclick = async () => {
                    await navigator.clipboard.writeText(r.clave);
                    avisar("Clave de alta copiada", "", "ok");
                };

            } catch (e) {
                avisar(e.message, e.detalle, "mal");
                boton.disabled = false;
            }
        }

        async function revocarClaveAlta(id, nombre) {
            const seguro = await confirmar(
                `Revocar la clave de alta «${nombre}»`,
                "La plataforma que la use dejará de poder crear empresas de inmediato. Las " +
                "empresas que ya creó no cambian. No se puede deshacer: habría que emitir otra.",
                "Revocar");

            if (!seguro) return;

            try {
                await api(`/admin/claves-alta/${id}`, { method: "DELETE" });
                avisar("Clave de alta revocada", "", "ok");
                estado.clavesAlta = await api("/admin/claves-alta");
                pintar();
            } catch (e) { avisar(e.message, e.detalle, "mal"); }
        }

        // ----------------------------------------------------------------- acciones

        function seleccionar(id) {
            estado.seleccionada = estado.empresas.find(e => e.id === id);

            // La primera pestaña que el usuario pueda ver, no siempre "series":
            // alguien sin empresas.ver no debería aterrizar en una pantalla vacía.
            const visibles = pestanasVisibles();
            estado.pestana = visibles[0] ?? "series";

            pintar();
        }

        async function recargar() {
            const id = estado.seleccionada?.id;
            estado.empresas = await api("/admin/tenants");
            estado.seleccionada = id ? estado.empresas.find(e => e.id === id) : null;
            pintar();
        }

        function abrirNueva() {
            ["ruc", "razon", "identificador", "direccion", "ubigeo"].forEach(c => {
                elem("e-" + c).textContent = "";
                elem("n-" + c).parentElement.classList.remove("invalido");
            });

            elem("velo-nueva").classList.add("visible");
            elem("n-ruc").focus();
        }

        elem("nv-cancelar").onclick = () =>
            elem("velo-nueva").classList.remove("visible");

        elem("nv-crear").onclick = crearEmpresa;

        async function crearEmpresa() {
            const ruc = elem("n-ruc").value.trim();
            const razon = elem("n-razon").value.trim();

            let valido = true;

            const marcar = (campo, mensaje) => {
                elem("e-" + campo).textContent = mensaje;
                elem("n-" + campo).parentElement.classList.toggle("invalido", !!mensaje);
                if (mensaje) valido = false;
            };

            // Validar antes de llamar no sustituye la validación del servidor, que es
            // la que de verdad protege. Solo evita un viaje y señala el campo exacto.
            marcar("ruc", /^\d{11}$/.test(ruc) ? "" : "Debe tener 11 dígitos.");
            marcar("razon", razon.length >= 3 ? "" : "Escribe la razón social.");

            const identificador = elem("n-identificador").value.trim().toLowerCase();
            marcar("identificador", problemaIdentificador(identificador));

            // La dirección entera, sin valores por defecto. El servidor
            // comprueba además que el ubigeo sea del departamento escrito.
            const faltaDir = ["n-direccion", "n-distrito", "n-provincia", "n-departamento"]
                .some(id => !elem(id).value.trim());
            marcar("direccion", faltaDir ? "Completa dirección, distrito, provincia y departamento." : "");
            marcar("ubigeo", /^\d{6}$/.test(elem("n-ubigeo").value.trim()) ? "" : "Son 6 dígitos.");

            if (!valido) return;

            const boton = elem("nv-crear");
            boton.disabled = true;

            try {
                await api("/admin/tenants", {
                    method: "POST",
                    headers: { "Content-Type": "application/json" },
                    body: JSON.stringify({
                        ruc, razonSocial: razon,
                        nombreComercial: elem("n-comercial").value.trim(),
                        direccion: elem("n-direccion").value.trim(),
                        distrito: elem("n-distrito").value.trim(),
                        provincia: elem("n-provincia").value.trim(),
                        departamento: elem("n-departamento").value.trim(),
                        ubigeo: elem("n-ubigeo").value.trim(),
                        ambiente: elem("n-ambiente").value,
                        usuarioSol: elem("n-sol").value.trim(),
                        identificador: identificador || null,
                        maxConcurrencia: 1
                    })
                });

                elem("velo-nueva").classList.remove("visible");
                elem("n-ruc").value = "";
                elem("n-razon").value = "";
                elem("n-comercial").value = "";
                ["n-direccion", "n-distrito", "n-provincia", "n-departamento", "n-ubigeo",
                    "n-identificador"].forEach(id => elem(id).value = "");

                avisar("Empresa creada",
                    "Ahora hace falta el certificado, una serie y una clave.", "ok");

                await recargar();

            } catch (e) {
                avisar(e.message, e.detalle, "mal");
            } finally {
                boton.disabled = false;
            }
        }

        async function alternarActiva() {
            const t = estado.seleccionada;

            if (t.activo) {
                const seguro = await confirmar(
                    "Desactivar empresa",
                    `${t.razonSocial} dejará de poder emitir de inmediato y sus claves ` +
                    `dejarán de funcionar. Los comprobantes ya emitidos no se ven afectados.`,
                    "Desactivar");

                if (!seguro) return;
            }

            try {
                await api(`/admin/tenants/${t.id}`, {
                    method: "PATCH",
                    headers: { "Content-Type": "application/json" },
                    body: JSON.stringify({ activo: !t.activo })
                });

                avisar(t.activo ? "Empresa desactivada" : "Empresa activada", "", "ok");
                await recargar();

            } catch (e) { avisar(e.message, e.detalle, "mal"); }
        }

        /// Resalta lo recién creado y quita la marca a los pocos segundos.
        ///
        /// Dejarla fija haría que, tras varias altas, media tabla quedara marcada
        /// y la marca dejaría de significar nada.
        function marcarRecien(pestana, id) {
            estado.recien[pestana] = id;

            setTimeout(() => {
                if (estado.recien[pestana] !== id) return;

                estado.recien[pestana] = null;

                const tabla = elem("tabla-" + pestana);
                if (!tabla) return;

                if (pestana === "series") {
                    tabla.innerHTML = tablaSeries();
                    enlazarAccionesSerie();
                } else if (pestana === "claves") {
                    tabla.innerHTML = tablaClaves();
                    enlazarRevocar();
                } else {
                    tabla.innerHTML = tablaCertificados();
                    enlazarAccionesCertificado();
                }
            }, 6000);
        }

        async function crearSerie() {
            const serie = elem("s-serie").value.trim().toUpperCase();

            if (serie.length !== 4) {
                elem("e-serie").textContent = "Debe tener 4 caracteres. Ej: F001, B001.";
                elem("s-serie").parentElement.classList.add("invalido");
                return;
            }

            elem("e-serie").textContent = "";
            elem("s-serie").parentElement.classList.remove("invalido");

            const boton = elem("btn-serie");
            boton.disabled = true;

            try {
                const creada = await api(`/admin/tenants/${estado.seleccionada.id}/series`, {
                    method: "POST",
                    headers: { "Content-Type": "application/json" },
                    body: JSON.stringify({
                        tipoComprobante: elem("s-tipo").value,
                        serie,
                        correlativoInicial: parseInt(elem("s-corr").value || "0", 10)
                    })
                });

                marcarRecien("series", creada.id);

                avisar(`Serie ${serie} lista`,
                    "Si ya existía, solo se reactivó: el correlativo no cambió.", "ok");

                elem("s-serie").value = "";
                elem("s-corr").value = "0";

                await recargar();



            } catch (e) {
                avisar(e.message, e.detalle, "mal");
                boton.disabled = false;
            }
        }

        async function crearClave() {
            const boton = elem("btn-clave");
            boton.disabled = true;

            try {
                const r = await api(`/admin/tenants/${estado.seleccionada.id}/claves`, {
                    method: "POST",
                    headers: { "Content-Type": "application/json" },
                    body: JSON.stringify({
                        nombre: elem("k-nombre").value.trim() || "Sin nombre",
                        produccion: estado.seleccionada.ambiente === "produccion"
                    })
                });

                // Se muestra fija, no como aviso flotante: es la única vez que este valor
                // existe fuera del cliente. Un aviso que desaparece solo sería un error.
                elem("k-resultado").innerHTML = `
          <div class="secreto">
            <strong>Copia esta clave ahora y entrégasela al cliente.</strong>
            <code>${esc(r.clave)}</code>
            <button class="mini" id="btn-copiar">Copiar</button>
            <div class="tenue" style="font-size:12.5px;margin-top:8px">${esc(r.aviso)}</div>
          </div>`;

                elem("btn-copiar").onclick = async () => {
                    await navigator.clipboard.writeText(r.clave);
                    avisar("Clave copiada", "", "ok");
                };

                marcarRecien("claves", r.id);

                // Se actualiza la lista sin repintar el detalle, para no borrar la clave
                // que el operador todavía no ha copiado.
                estado.claves = await api(`/admin/tenants/${estado.seleccionada.id}/claves`);
                estado.empresas = await api("/admin/tenants");

                const tabla = elem("tabla-claves");
                if (tabla) { tabla.innerHTML = tablaClaves(); enlazarRevocar(); }

            } catch (e) {
                avisar(e.message, e.detalle, "mal");
            } finally {
                boton.disabled = false;
            }
        }

        async function eliminarSerie(id, nombre) {
            const seguro = await confirmar(
                `Eliminar la serie ${nombre}`,
                "Esta serie nunca emitió comprobantes, así que se puede borrar sin " +
                "consecuencias. Si después la necesitas, hay que volver a darla de alta.",
                "Eliminar");

            if (!seguro) return;

            try {
                await api(`/admin/tenants/${estado.seleccionada.id}/series/${id}`,
                    { method: "DELETE" });

                avisar(`Serie ${nombre} eliminada`, "", "ok");
                await recargar();

            } catch (e) { avisar(e.message, e.detalle, "mal"); }
        }

        async function cambiarSerie(id, activar, nombre) {
            if (!activar) {
                const seguro = await confirmar(
                    `Cerrar la serie ${nombre}`,
                    "Dejará de poder emitir comprobantes. Los que ya emitió NO se tocan: " +
                    "siguen consultándose y descargándose igual. Puedes reactivarla después.",
                    "Cerrar serie");

                if (!seguro) return;
            }

            try {
                await api(`/admin/tenants/${estado.seleccionada.id}/series/${id}`, {
                    method: "PATCH",
                    headers: { "Content-Type": "application/json" },
                    body: JSON.stringify({ activo: activar })
                });

                avisar(activar ? `Serie ${nombre} reactivada` : `Serie ${nombre} cerrada`,
                    "", "ok");

                await recargar();

            } catch (e) { avisar(e.message, e.detalle, "mal"); }
        }

        async function eliminarCertificado(id) {
            const seguro = await confirmar(
                "Eliminar certificado",
                "Este certificado nunca firmó comprobantes y no está en uso, así que se " +
                "puede borrar. Es lo que se hace cuando se cargó el archivo equivocado.",
                "Eliminar");

            if (!seguro) return;

            try {
                await api(`/admin/tenants/${estado.seleccionada.id}/certificados/${id}`,
                    { method: "DELETE" });

                avisar("Certificado eliminado", "", "ok");
                await recargar();

            } catch (e) { avisar(e.message, e.detalle, "mal"); }
        }

        async function revocar(id) {
            const seguro = await confirmar(
                "Revocar clave",
                "El sistema que la use dejará de poder emitir de inmediato. No se puede " +
                "deshacer: habría que emitir una clave nueva.",
                "Revocar");

            if (!seguro) return;

            try {
                await api(`/admin/claves/${id}`, { method: "DELETE" });
                avisar("Clave revocada", "", "ok");
                await recargar();
            } catch (e) { avisar(e.message, e.detalle, "mal"); }
        }

        async function subirCertificado() {
            const archivo = elem("c-archivo").files[0];
            const resultado = elem("c-resultado");

            if (!archivo) {
                resultado.innerHTML =
                    `<div style="color:var(--mal);margin-top:10px">Elige el archivo .pfx.</div>`;
                return;
            }

            // LA CONTRASEÑA VA EN EL CUERPO, NO EN LA DIRECCIÓN. Una dirección
            // queda escrita en los registros del proxy y de cualquier
            // intermediario; el cuerpo no.
            const datos = new FormData();
            datos.append("archivo", archivo);
            datos.append("clave", elem("c-clave").value);

            const boton = elem("btn-certificado");
            boton.disabled = true;
            resultado.innerHTML = `<div class="tenue" style="margin-top:10px">Cifrando y guardando…</div>`;

            try {
                const cargado = await api(
                    `/admin/tenants/${estado.seleccionada.id}/certificado`,
                    { method: "POST", body: datos });

                avisar("Certificado cargado y cifrado", "", "ok");

                elem("c-clave").value = "";

                await recargar();
                marcarRecien("certificado", cargado.id);

            } catch (e) {
                resultado.innerHTML =
                    `<div style="color:var(--mal);margin-top:10px">${esc(e.message)}<br>
             <span class="tenue">${esc(e.detalle || "")}</span></div>`;

                boton.disabled = false;
            }
        }

        cargarUsuario().then(ok => { if (ok) iniciar(); });
    </script>
</body>
</html>
'@

# --- Todo o nada -------------------------------------------------------------
$conflictos = @($plan | Where-Object { $_.Accion -eq 'conflicto' })
if ($conflictos.Count -gt 0) {
    Write-Host ''
    Write-Host 'NO SE TOCÓ NINGÚN ARCHIVO. Esto no cuadra:' -ForegroundColor Red
    foreach ($c in $conflictos) { Write-Host "  $($c.Ruta)`n      $($c.Motivo)" -ForegroundColor Red }
    Write-Host ''
    exit 2
}

Write-Host ''
foreach ($p in $plan) {
    if ($p.Accion -eq 'reemplazar') {
        $copia = Respaldar $p.Completa
        $salida = if ($p.Crlf) { $p.Texto.Replace("`n", "`r`n") } else { $p.Texto }
        [System.IO.File]::WriteAllText($p.Completa, $salida, $utf8SinBom)
        Write-Host "  REEMPLAZADO  $($p.Ruta)  (copia: $copia)" -ForegroundColor Green
    }
    elseif ($p.Accion -eq 'nuevo') {
        New-Item -ItemType Directory -Path (Split-Path $p.Completa) -Force | Out-Null
        [System.IO.File]::WriteAllText($p.Completa, $p.Texto.Replace("`n", "`r`n"), $utf8SinBom)
        Write-Host "  NUEVO        $($p.Ruta)" -ForegroundColor Green
    }
    else {
        Write-Host "  IGUAL        $($p.Ruta)  (sin cambios)" -ForegroundColor DarkGray
    }
}

Write-Host ''
Write-Host 'FALTA APLICAR LA 026. Desde esta misma carpeta:' -ForegroundColor Yellow
Write-Host '    Get-Content migraciones\026_copia_al_emisor.sql -Raw | docker compose exec -T postgres psql -U facturacion_owner -d facturacion -v ON_ERROR_STOP=1' -ForegroundColor Yellow
Write-Host 'Despues reinicia la API del servicio (el worker no cambia).' -ForegroundColor Cyan
Write-Host ''
