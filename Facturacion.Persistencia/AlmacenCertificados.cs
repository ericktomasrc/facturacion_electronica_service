using System.Security.Cryptography.X509Certificates;
using Dapper;

namespace Facturacion.Persistencia;

/// <summary>Datos legibles de un certificado, para mostrar en el panel.</summary>
public record CertificadoInfo(
    Guid Id,
    string Subject,
    string Huella,
    DateTime? ValidoDesde,
    DateTime ValidoHasta,
    bool Activo)
{
    public bool EstaVencido => ValidoHasta < DateTime.UtcNow;

    public int DiasParaVencer =>
        (int)Math.Ceiling((ValidoHasta - DateTime.UtcNow).TotalDays);

    /// <summary>
    /// Un certificado vencido detiene por completo la facturación del cliente,
    /// y el aviso nunca llega solo. Conviene alertar con semanas de margen:
    /// renovar uno toma días, no horas.
    /// </summary>
    public bool RequiereAlerta(int diasDeAviso = 30) =>
        Activo && DiasParaVencer <= diasDeAviso;
}

/// <summary>
/// Guarda y recupera los certificados digitales de cada empresa.
///
/// EL CERTIFICADO ES LA LLAVE CON LA QUE SE FIRMA EN NOMBRE DE OTRO. Por eso
/// aquí nunca aparece en claro: entra cifrado, sale descifrado solo en memoria
/// y solo cuando hay que firmar, y jamás se escribe a disco.
///
/// El esquema garantiza además que haya un único certificado activo por
/// empresa. Dos activos significarían que nadie sabe con cuál se está firmando.
/// </summary>
public sealed class AlmacenCertificados
{
    private readonly FabricaSesiones _sesiones;
    private readonly IProtectorDeSecretos _protector;

    public AlmacenCertificados(FabricaSesiones sesiones, IProtectorDeSecretos protector)
    {
        _sesiones = sesiones ?? throw new ArgumentNullException(nameof(sesiones));
        _protector = protector ?? throw new ArgumentNullException(nameof(protector));
    }

    /// <summary>
    /// Guarda un certificado y lo deja como el activo del tenant.
    ///
    /// Desactiva el anterior en la misma transacción: el esquema no admite dos
    /// activos, y hacerlo en pasos separados dejaría una ventana donde el
    /// cliente no tiene ninguno.
    /// </summary>
    public async Task<Guid> GuardarAsync(
        Guid tenantId,
        byte[] contenidoPfx,
        string clavePfx,
        CancellationToken ct = default)
    {
        ArgumentNullException.ThrowIfNull(contenidoPfx);

        // Se abre aquí para extraer los datos legibles y, de paso, verificar
        // que el archivo y la clave son correctos ANTES de guardar nada.
        using var certificado = AbrirPfx(contenidoPfx, clavePfx);

        if (!certificado.HasPrivateKey)
            throw new InvalidOperationException(
                "El archivo no contiene la llave privada. Sin ella no se puede " +
                "firmar: necesitas el .pfx completo, no solo el certificado público.");

        if (certificado.NotAfter < DateTime.Now)
            throw new InvalidOperationException(
                $"El certificado venció el {certificado.NotAfter:yyyy-MM-dd}. " +
                "SUNAT rechaza todo lo firmado con un certificado vencido.");

        var pfxCifrado = _protector.Proteger(contenidoPfx);
        var claveCifrada = _protector.ProtegerTexto(clavePfx);

        await using var sesion = await _sesiones.AbrirAsync(tenantId, ct);

        await sesion.Conexion.ExecuteAsync(new CommandDefinition(
            """
            UPDATE certificados
               SET activo = false
             WHERE tenant_id = @tenantId AND activo
            """,
            new { tenantId },
            sesion.Transaccion, cancellationToken: ct));

        var id = await sesion.Conexion.ExecuteScalarAsync<Guid>(new CommandDefinition(
            """
            INSERT INTO certificados
                (tenant_id, pfx_cifrado, clave_cifrada, subject, huella,
                 valido_desde, valido_hasta, activo)
            VALUES
                (@tenantId, @pfxCifrado, @claveCifrada, @subject, @huella,
                 @validoDesde, @validoHasta, true)
            RETURNING id
            """,
            new
            {
                tenantId,
                pfxCifrado,
                claveCifrada,
                subject = certificado.Subject,
                huella = certificado.Thumbprint,
                validoDesde = certificado.NotBefore.ToUniversalTime(),
                validoHasta = certificado.NotAfter.ToUniversalTime()
            },
            sesion.Transaccion, cancellationToken: ct));

        await sesion.ConfirmarAsync(ct);

        return id;
    }

    /// <summary>
    /// Recupera el certificado activo del tenant, listo para firmar.
    ///
    /// Quien lo reciba es responsable de liberarlo. Contiene material
    /// criptográfico sensible y no debe quedar vivo más de lo necesario.
    /// </summary>
    public async Task<X509Certificate2?> ObtenerActivoAsync(
        Guid tenantId, CancellationToken ct = default)
    {
        await using var sesion = await _sesiones.AbrirAsync(tenantId, ct);

        var fila = await sesion.Conexion.QuerySingleOrDefaultAsync<(byte[] Pfx, byte[] Clave)?>(
            new CommandDefinition(
                """
                SELECT pfx_cifrado AS "Pfx", clave_cifrada AS "Clave"
                  FROM certificados
                 WHERE tenant_id = @tenantId AND activo
                 LIMIT 1
                """,
                new { tenantId },
                sesion.Transaccion, cancellationToken: ct));

        await sesion.ConfirmarAsync(ct);

        if (fila is null) return null;

        var pfx = _protector.Desproteger(fila.Value.Pfx);
        var clave = _protector.DesprotegerTexto(fila.Value.Clave);

        return AbrirPfx(pfx, clave);
    }

    /// <summary>Lista los certificados del tenant, sin material sensible.</summary>
    public async Task<IReadOnlyList<CertificadoInfo>> ListarAsync(
        Guid tenantId, CancellationToken ct = default)
    {
        await using var sesion = await _sesiones.AbrirAsync(tenantId, ct);

        var filas = await sesion.Conexion.QueryAsync<CertificadoInfo>(
            new CommandDefinition(
                """
                SELECT id           AS "Id",
                       subject      AS "Subject",
                       huella       AS "Huella",
                       valido_desde AS "ValidoDesde",
                       valido_hasta AS "ValidoHasta",
                       activo       AS "Activo"
                  FROM certificados
                 WHERE tenant_id = @tenantId
                 ORDER BY creado_en DESC
                """,
                new { tenantId },
                sesion.Transaccion, cancellationToken: ct));

        await sesion.ConfirmarAsync(ct);

        return filas.ToList();
    }

    /// <summary>
    /// Abre el PFX.
    ///
    /// POR QUÉ SE PRUEBAN VARIAS FORMAS DE CARGARLO:
    ///
    /// En Windows, abrir un PFX puede exigir escribir la llave privada en un
    /// almacén del sistema, y el proceso no siempre tiene permiso para el
    /// almacén de máquina. Cuando eso ocurre, .NET lanza exactamente la misma
    /// excepción que cuando la contraseña es incorrecta.
    ///
    /// Una versión anterior de este método daba por hecho que era la
    /// contraseña. El mensaje sonaba útil y mandaba a buscar en la dirección
    /// equivocada: la contraseña estaba bien y el problema eran los permisos.
    ///
    /// Ahora se intentan varias combinaciones y, si todas fallan, se incluye
    /// el mensaje REAL del sistema en vez de una conjetura.
    /// </summary>
    private static X509Certificate2 AbrirPfx(byte[] contenido, string clave)
    {
        // Un PFX es una estructura DER y siempre empieza con 0x30 0x82.
        // Comprobarlo permite afirmar con certeza que el archivo no es un
        // certificado, en vez de culpar a la contraseña.
        if (contenido.Length < 2 || contenido[0] != 0x30 || contenido[1] != 0x82)
            throw new InvalidOperationException(
                "El archivo no parece un certificado PFX. Comprueba que sea el " +
                "archivo .pfx o .p12 que entregó la entidad certificadora, y no " +
                "un .cer, un .pem o un comprimido.");

        // En orden de preferencia:
        //
        //   Ephemeral  la llave vive solo en memoria y no toca ningún almacén.
        //              Es lo que queremos: el certificado ya se guarda cifrado
        //              en la base, no hace falta dejar rastro en el sistema.
        //
        //   UserKeySet almacén del usuario que ejecuta el proceso. Casi
        //              siempre disponible.
        //
        //   MachineKeySet  almacén de máquina. Puede requerir permisos
        //              elevados, y ahí es donde suele fallar.
        var intentos = new[]
        {
            X509KeyStorageFlags.Exportable | X509KeyStorageFlags.EphemeralKeySet,
            X509KeyStorageFlags.Exportable | X509KeyStorageFlags.UserKeySet,
            X509KeyStorageFlags.Exportable | X509KeyStorageFlags.MachineKeySet,
            X509KeyStorageFlags.Exportable
        };

        Exception? ultimoError = null;

        foreach (var opciones in intentos)
        {
            try
            {
                var certificado = new X509Certificate2(contenido, clave, opciones);

                // EphemeralKeySet a veces devuelve un certificado cuya llave
                // privada no sirve para firmar. Se comprueba antes de darlo
                // por bueno: descubrirlo aquí es barato, descubrirlo al firmar
                // una factura real no lo es.
                if (certificado.HasPrivateKey && certificado.GetRSAPrivateKey() is not null)
                    return certificado;

                certificado.Dispose();

                ultimoError ??= new InvalidOperationException(
                    "El certificado se abrió pero su llave privada no es " +
                    "utilizable para firmar.");
            }
            catch (Exception ex)
            {
                ultimoError = ex;
            }
        }

        // Ninguna forma funcionó. Se entrega el mensaje real del sistema,
        // sin interpretarlo: adivinar la causa es lo que nos hizo perder
        // tiempo la vez anterior.
        throw new InvalidOperationException(
            "No se pudo abrir el certificado. El sistema respondió: " +
            (ultimoError?.Message ?? "sin detalle") +
            ". Si la contraseña es correcta, revisa los permisos del proceso " +
            "sobre el almacén de certificados de Windows.",
            ultimoError);
    }
}
