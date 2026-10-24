-- =============================================================================
-- 040 — LAS GUÍAS TAMBIÉN AVISAN (24 oct 2026)
--
-- Hasta hoy el webhook solo avisaba de los comprobantes (005): una guía
-- aceptada o rechazada no llegaba a la plataforma, que tendría que preguntar
-- una y otra vez mientras el camión espera. Ahora, igual que con las
-- facturas, un disparador sobre `guias` encola el aviso:
--
--   guia.aceptada   ACEPTADO / ACEPTADO_CON_OBSERVACIONES
--   guia.rechazada  RECHAZADO
--   guia.anulada    ANULADO (registrada después de anularla en SOL)
--
-- El cuerpo lleva `guiaId` (y NO `comprobanteId`: así quien recibe no lo
-- confunde con una factura). `webhook_entregas.comprobante_id` queda nulo.
--
-- Nada se borra. Se puede correr dos veces.
-- =============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION encolar_evento_guia() RETURNS trigger AS $$
DECLARE
    tipo_evento text;
    w record;
BEGIN
    IF NEW.estado = OLD.estado THEN
        RETURN NEW;
    END IF;

    tipo_evento := CASE NEW.estado
        WHEN 'ACEPTADO' THEN 'guia.aceptada'
        WHEN 'ACEPTADO_CON_OBSERVACIONES' THEN 'guia.aceptada'
        WHEN 'RECHAZADO' THEN 'guia.rechazada'
        WHEN 'ANULADO' THEN 'guia.anulada'
        ELSE NULL
    END;

    IF tipo_evento IS NULL THEN
        RETURN NEW;
    END IF;

    FOR w IN
        SELECT id FROM webhooks
         WHERE tenant_id = NEW.tenant_id
           AND activo
           AND (cardinality(eventos) = 0 OR tipo_evento = ANY(eventos))
    LOOP
        INSERT INTO webhook_entregas
            (webhook_id, tenant_id, tipo, comprobante_id, cuerpo)
        VALUES (
            w.id,
            NEW.tenant_id,
            tipo_evento,
            NULL,
            jsonb_build_object(
                'tipo', tipo_evento,
                'guiaId', NEW.id,
                'numero', NEW.serie || '-' || lpad(NEW.correlativo::text, 8, '0'),
                'tipoGuia', NEW.tipo_guia,
                'serie', NEW.serie,
                'correlativo', NEW.correlativo,
                'fechaEmision', NEW.fecha_emision,
                'fechaTraslado', NEW.fecha_traslado,
                'estado', NEW.estado,
                'codigoSunat', NEW.codigo_sunat,
                'mensajeSunat', NEW.mensaje_sunat,
                'ocurridoEn', now()
            ));
    END LOOP;

    RETURN NEW;
END
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS tg_guias_evento ON guias;
CREATE TRIGGER tg_guias_evento
    AFTER UPDATE OF estado ON guias
    FOR EACH ROW EXECUTE FUNCTION encolar_evento_guia();

COMMIT;

DO $$ BEGIN RAISE NOTICE '040: las guías avisan por webhook (aceptada, rechazada, anulada). Nada se borró.'; END $$;