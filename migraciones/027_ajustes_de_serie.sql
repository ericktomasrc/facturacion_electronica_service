-- =============================================================================
-- 027 - BITACORA DE CORRELATIVOS DE SERIE
--
-- Decision del 11 de octubre (series-cartera-y-validaciones.md):
--
--   * "Ajustar correlativo": el ultimo correlativo de una serie solo se puede
--     SUBIR, nunca bajar, y cada ajuste queda anotado aqui: de cuanto a cuanto,
--     quien, cuando y por que. Caso tipico: el cliente se fue con la F001 en
--     la 600, siguio emitiendo fuera hasta la 780 y vuelve.
--
--   * Alta de una serie con correlativo distinto de 0: tambien se anota
--     (accion 'alta', desde 0), porque es decir "la 1 a la N ya existen".
--
-- serie_id SIN clave foranea, a proposito: una serie sin comprobantes se puede
-- eliminar, y su rastro aqui tiene que quedar. Por eso tambien se guardan el
-- tipo y el nombre de la serie.
--
-- NADA SE BORRA: solo SELECT e INSERT. Ni UPDATE ni DELETE para nadie.
--
-- Idempotente. Sin tildes a proposito: PowerShell 5.1 la manda a psql en ASCII.
-- =============================================================================

BEGIN;

CREATE TABLE IF NOT EXISTS serie_ajustes (
    id                bigserial   PRIMARY KEY,
    tenant_id         uuid        NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
    serie_id          uuid        NOT NULL,
    tipo_comprobante  varchar(2)  NOT NULL,
    serie             varchar(4)  NOT NULL,

    -- 'alta':   la serie se creo empezando en "hasta" (desde = 0)
    -- 'ajuste': se subio el ultimo correlativo de "desde" a "hasta"
    accion            text        NOT NULL,

    desde             integer     NOT NULL,
    hasta             integer     NOT NULL,
    motivo            text        NOT NULL,

    -- Quien lo hizo, desde el panel. El correo se copia: si el usuario cambia
    -- de correo despues, aqui queda el que tenia ese dia.
    usuario_id        uuid,
    correo            text        NOT NULL,

    creado_en         timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT ck_serie_ajustes_accion CHECK (accion IN ('alta', 'ajuste')),
    CONSTRAINT ck_serie_ajustes_sube   CHECK (desde >= 0 AND hasta > desde),
    CONSTRAINT ck_serie_ajustes_tope   CHECK (hasta <= 99999999),
    CONSTRAINT ck_serie_ajustes_motivo CHECK (length(btrim(motivo)) BETWEEN 1 AND 500)
);

CREATE INDEX IF NOT EXISTS ix_serie_ajustes_tenant
    ON serie_ajustes (tenant_id, creado_en DESC);

CREATE INDEX IF NOT EXISTS ix_serie_ajustes_serie
    ON serie_ajustes (serie_id);

COMMENT ON TABLE serie_ajustes IS
    'Bitacora de correlativos: altas de serie con correlativo inicial y ajustes hacia arriba. Solo se escribe y se lee.';

ALTER TABLE serie_ajustes ENABLE ROW LEVEL SECURITY;
ALTER TABLE serie_ajustes FORCE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS aislamiento_tenant ON serie_ajustes;

CREATE POLICY aislamiento_tenant ON serie_ajustes
    USING (tenant_id = app_tenant_actual())
    WITH CHECK (tenant_id = app_tenant_actual());

-- Solo el panel (operador) la usa. La aplicacion no la necesita.
REVOKE ALL ON serie_ajustes FROM PUBLIC;
GRANT SELECT, INSERT ON serie_ajustes TO facturacion_operador;
GRANT USAGE, SELECT ON SEQUENCE serie_ajustes_id_seq TO facturacion_operador;

DO $$
BEGIN
    IF has_table_privilege('facturacion_operador', 'serie_ajustes', 'DELETE')
       OR has_table_privilege('facturacion_operador', 'serie_ajustes', 'UPDATE') THEN
        RAISE EXCEPTION '027: el operador no deberia poder borrar ni cambiar la bitacora.';
    END IF;

    RAISE NOTICE '027: bitacora de correlativos lista.';
END $$;

COMMIT;