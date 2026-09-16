using Dapper;
using Facturacion.Cpe;
using Npgsql;

namespace Facturacion.Persistencia;

/// <summary>Resultado de comprobar si una empresa puede pasar a producción.</summary>
public record RevisionProduccion(
    bool Listo,
    IReadOnlyList<string> Faltantes,
    IReadOnlyList<string> Advertencias);

/// <summary>
/// Entrega la configuración de SUNAT lista para usar, según el ambiente de
/// cada empresa.
///
/// POR QUÉ ESTÁ AQUÍ Y NO EN EL WORKER:
///
/// Descifrar la clave SOL requiere la llave maestra, y esa solo debe vivir en
/// un sitio. Si cada proceso que necesita credenciales tuviera su propio
/// código de descifrado, habría cuatro lugares donde equivocarse.
///
/// El worker pide "dame la configuración de esta empresa" y recibe algo listo
/// para enviar, sin saber si es beta o producción ni cómo se guardó la clave.
/// </summary>
public sealed class ProveedorCredenciales
{
    private readonly string _cadenaOperador;
    private readonly IProtectorDeSecretos _protector;

    public ProveedorCredenciales(
        string cadenaConexionOperador, IProtectorDeSecretos protector)
    {
        _cadenaOperador = cadenaConexionOperador
            ?? throw new ArgumentNullException(nameof(cadenaConexionOperador));

        _protector = protector ?? throw new ArgumentNullException(nameof(protector));
    }

    /// <summary>
    /// Configuración de SUNAT para una empresa.
    ///
    /// En beta usa las credenciales públicas de pruebas. En producción
    /// descifra las del contribuyente.
    /// </summary>
    public async Task<ConfiguracionSunat> ObtenerAsync(
        Guid tenantId, CancellationToken ct = default)
    {
        await using var conexion = new NpgsqlConnection(_cadenaOperador);
        await conexion.OpenAsync(ct);

        var fila = await conexion.QuerySingleOrDefaultAsync<FilaCredenciales>(
            new CommandDefinition(
                """
                SELECT ruc               AS "Ruc",
                       ambiente          AS "Ambiente",
                       usuario_sol       AS "UsuarioSol",
                       clave_sol_cifrada AS "ClaveCifrada",
                       activo            AS "Activo"
                  FROM tenants
                 WHERE id = @tenantId
                """,
                new { tenantId }, cancellationToken: ct));

        if (fila is null)
            throw new InvalidOperationException(
                "El emisor no existe. Puede haberse eliminado mientras un " +
                "comprobante suyo esperaba en la cola.");

        if (!fila.Activo)
            throw new InvalidOperationException(
                "El emisor está desactivado. Sus comprobantes no deben enviarse " +
                "hasta que se reactive.");

        if (fila.Ambiente != "produccion")
            return ConfiguracionSunat.Beta(fila.Ruc);

        // --- Producción ---

        if (string.IsNullOrWhiteSpace(fila.UsuarioSol))
            throw new InvalidOperationException(
                "El emisor está en producción pero no tiene usuario SOL " +
                "configurado. Cárgalo desde el panel antes de emitir.");

        if (fila.ClaveCifrada is null || fila.ClaveCifrada.Length == 0)
            throw new InvalidOperationException(
                "El emisor está en producción pero no tiene clave SOL guardada. " +
                "Cárgala desde el panel antes de emitir.");

        string clave;

        try
        {
            clave = _protector.DesprotegerTexto(fila.ClaveCifrada);
        }
        catch (Exception ex)
        {
            // Si la llave maestra cambió, esto falla para TODAS las empresas
            // a la vez. El mensaje lo dice para que nadie busque el problema
            // en la empresa concreta.
            throw new InvalidOperationException(
                "No se pudo descifrar la clave SOL. Si esto ocurre con varias " +
                "empresas a la vez, la llave maestra del sistema cambió o se " +
                "perdió.", ex);
        }

        return ConfiguracionSunat.Produccion(
            fila.Ruc, fila.UsuarioSol!, clave);
    }

    /// <summary>
    /// Comprueba si una empresa está lista para emitir en producción.
    ///
    /// POR QUÉ ESTA COMPROBACIÓN EXISTE:
    ///
    /// Pasar a producción sin certificado, sin clave SOL o sin series hace que
    /// TODAS las facturas de esa empresa fallen desde el primer minuto. El
    /// cliente lo nota antes que tú, y la primera impresión de un servicio de
    /// facturación es difícil de recuperar.
    ///
    /// Comprobarlo antes cuesta una consulta.
    /// </summary>
    public async Task<RevisionProduccion> RevisarAsync(
        Guid tenantId, CancellationToken ct = default)
    {
        await using var conexion = new NpgsqlConnection(_cadenaOperador);
        await conexion.OpenAsync(ct);

        var datos = await conexion.QuerySingleOrDefaultAsync<FilaRevision>(
            new CommandDefinition(
                """
                SELECT t.ruc               AS "Ruc",
                       t.razon_social      AS "RazonSocial",
                       t.usuario_sol       AS "UsuarioSol",
                       (t.clave_sol_cifrada IS NOT NULL) AS "TieneClave",
                       t.direccion         AS "Direccion",
                       t.ubigeo            AS "Ubigeo",

                       (SELECT count(*)::int FROM series s
                         WHERE s.tenant_id = t.id AND s.activo)   AS "Series",

                       (SELECT count(*)::int FROM api_keys k
                         WHERE k.tenant_id = t.id AND k.activo)   AS "Claves",

                       (SELECT c.subject FROM certificados c
                         WHERE c.tenant_id = t.id AND c.activo
                         LIMIT 1)                                 AS "CertificadoSubject",

                       (SELECT c.valido_hasta FROM certificados c
                         WHERE c.tenant_id = t.id AND c.activo
                         LIMIT 1)                                 AS "CertificadoVence"

                  FROM tenants t
                 WHERE t.id = @tenantId
                """,
                new { tenantId }, cancellationToken: ct));

        if (datos is null)
            return new RevisionProduccion(false, ["El emisor no existe."], []);

        var d = datos;
        var faltantes = new List<string>();
        var advertencias = new List<string>();

        if (string.IsNullOrWhiteSpace(d.CertificadoSubject))
            faltantes.Add(
                "No tiene certificado digital. Sin él no se puede firmar, y " +
                "SUNAT rechaza todo lo que no esté firmado.");
        else
        {
            // Un certificado autofirmado sirve en beta pero NO en producción:
            // SUNAT valida la cadena de confianza contra las entidades
            // acreditadas por INDECOPI.
            //
            // Detectarlo aquí evita el escenario peor: descubrirlo cuando el
            // cliente ya está emitiendo y todo le sale rechazado.
            if (d.CertificadoSubject!.Contains("PRUEBA", StringComparison.OrdinalIgnoreCase)
                || d.CertificadoSubject.Contains("TEST", StringComparison.OrdinalIgnoreCase))
            {
                faltantes.Add(
                    $"El certificado parece de pruebas ({d.CertificadoSubject}). " +
                    "En producción hace falta uno emitido por una entidad " +
                    "certificadora acreditada ante INDECOPI.");
            }

            if (d.CertificadoVence is not null && d.CertificadoVence < DateTime.UtcNow)
                faltantes.Add(
                    $"El certificado venció el {d.CertificadoVence:yyyy-MM-dd}.");

            else if (d.CertificadoVence is not null &&
                     d.CertificadoVence < DateTime.UtcNow.AddDays(30))
            {
                advertencias.Add(
                    $"El certificado vence el {d.CertificadoVence:yyyy-MM-dd}. " +
                    "Renovarlo toma días.");
            }
        }

        if (string.IsNullOrWhiteSpace(d.UsuarioSol) ||
            d.UsuarioSol!.Equals("MODDATOS", StringComparison.OrdinalIgnoreCase))
        {
            faltantes.Add(
                "No tiene usuario SOL de producción. MODDATOS solo funciona en " +
                "el ambiente de pruebas.");
        }

        if (!d.TieneClave)
            faltantes.Add("No tiene clave SOL guardada.");

        if (d.Series == 0)
            faltantes.Add("No tiene series activas. Sin una serie no puede emitir.");

        if (d.Claves == 0)
            advertencias.Add(
                "No tiene claves de acceso. El cliente no podrá conectarse " +
                "hasta que se le emita una.");

        if (string.IsNullOrWhiteSpace(d.Direccion))
            advertencias.Add(
                "No tiene dirección. Aparece vacía en la representación impresa.");

        return new RevisionProduccion(faltantes.Count == 0, faltantes, advertencias);
    }

    // SON CLASES, NO record struct.
    //
    // Dapper no materializa bien un struct envuelto en Nullable: devuelve
    // null aunque la fila exista, y sin lanzar ningún error. El fallo aparece
    // como "no se encontró" cuando en realidad sí estaba.
    private sealed record FilaCredenciales(
        string Ruc, string Ambiente, string? UsuarioSol,
        byte[]? ClaveCifrada, bool Activo);

    private sealed record FilaRevision(
        string Ruc, string RazonSocial, string? UsuarioSol, bool TieneClave,
        string Direccion, string Ubigeo, int Series, int Claves,
        string? CertificadoSubject, DateTime? CertificadoVence);
}
