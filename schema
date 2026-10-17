-- STAGE MANAGER MUELLE - Esquema base PostgreSQL 15+ (logística + motor magnético)
-- Extensiones
CREATE EXTENSION IF NOT EXISTS "pgcrypto";
CREATE EXTENSION IF NOT EXISTS btree_gist;

-- ===== Tipos =====
CREATE TYPE unit_state AS ENUM ('almacen','carga','transito','muelle','escenario','desmontaje','retorno','incidencia');
CREATE TYPE tag_kind   AS ENUM ('qr','rfid','ble');
CREATE TYPE ring_kind  AS ENUM ('soportes','rigging','cableado','fungibles','personal');
CREATE TYPE shipment_state AS ENUM ('planificado','cargando','en_ruta','en_muelle','descargado','retornando','cerrado');

-- ===== Organización y eventos =====
CREATE TABLE companies (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL,
  settings jsonb NOT NULL DEFAULT '{}'
);

CREATE TABLE venues (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL,
  region text,
  geo point,
  meta jsonb NOT NULL DEFAULT '{}'
);

CREATE TABLE events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL REFERENCES companies(id),
  venue_id uuid REFERENCES venues(id),
  name text NOT NULL,
  starts_at timestamptz NOT NULL,
  ends_at timestamptz NOT NULL,
  stage_plan jsonb NOT NULL DEFAULT '{}',   -- referencia al plano 2D/3D
  CHECK (ends_at > starts_at)
);

-- ===== Muelles y slots =====
CREATE TABLE docks (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  venue_id uuid NOT NULL REFERENCES venues(id),
  label text NOT NULL,
  max_vehicle_len_m numeric(5,2),
  meta jsonb NOT NULL DEFAULT '{}'
);

CREATE TABLE shipments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  event_id uuid NOT NULL REFERENCES events(id),
  label text NOT NULL,                      -- p.ej. "T1 Estructura"
  plate text,
  driver text,
  state shipment_state NOT NULL DEFAULT 'planificado',
  cargo_volume_m3 numeric(7,2),
  axle_load_kg jsonb NOT NULL DEFAULT '{}', -- reparto de peso por eje
  tacho jsonb NOT NULL DEFAULT '{}'         -- conducción/descansos
);

CREATE TABLE dock_slots (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  dock_id uuid NOT NULL REFERENCES docks(id),
  shipment_id uuid NOT NULL REFERENCES shipments(id),
  slot tstzrange NOT NULL,
  -- impide solapar reservas en el mismo muelle
  EXCLUDE USING gist (dock_id WITH =, slot WITH &&)
);

-- ===== Catálogo y motor magnético =====
CREATE TABLE items (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL REFERENCES companies(id),
  sku text NOT NULL,
  name text NOT NULL,
  category text,
  weight_kg numeric(8,2),
  dims_cm jsonb,                            -- {l,w,h}
  specs jsonb NOT NULL DEFAULT '{}',
  UNIQUE (company_id, sku)
);

-- Regla: al elegir parent_item, se añaden dependencias por anillo
CREATE TABLE magnetic_rules (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  parent_item_id uuid NOT NULL REFERENCES items(id),
  ring ring_kind NOT NULL,
  child_item_id uuid REFERENCES items(id),  -- NULL si es personal/tiempo
  qty_formula text NOT NULL DEFAULT '1',    -- ej. "ceil(parent_qty/4)"
  condition jsonb NOT NULL DEFAULT '{}',    -- ej. {"viento_kmh_gt":40}
  labor jsonb                               -- {rol, horas, nivel_min}
);
CREATE INDEX ON magnetic_rules (parent_item_id, ring);

-- ===== Flightcases / unidades de carga =====
CREATE TABLE load_units (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL REFERENCES companies(id),
  code text NOT NULL,
  shipment_id uuid REFERENCES shipments(id),
  load_order int,                           -- orden LIFO calculado
  state unit_state NOT NULL DEFAULT 'almacen',
  weight_kg numeric(8,2),
  volume_m3 numeric(6,3),
  contents jsonb NOT NULL DEFAULT '[]',     -- packing list
  UNIQUE (company_id, code)
);

CREATE TABLE unit_tags (
  tag text PRIMARY KEY,
  kind tag_kind NOT NULL,
  unit_id uuid NOT NULL REFERENCES load_units(id) ON DELETE CASCADE
);

-- ===== Trazabilidad =====
CREATE TABLE scan_events (
  id bigserial PRIMARY KEY,
  unit_id uuid NOT NULL REFERENCES load_units(id),
  state unit_state NOT NULL,
  scanned_at timestamptz NOT NULL DEFAULT now(),
  scanned_by uuid,
  location jsonb,                           -- geo o zona BLE
  origin text NOT NULL DEFAULT 'online',    -- 'online' | 'mesh' (sync offline)
  notes text
);
CREATE INDEX ON scan_events (unit_id, scanned_at DESC);

-- Mantiene load_units.state con el último escaneo
CREATE OR REPLACE FUNCTION sync_unit_state() RETURNS trigger AS $$
BEGIN
  UPDATE load_units SET state = NEW.state WHERE id = NEW.unit_id;
  RETURN NEW;
END $$ LANGUAGE plpgsql;

CREATE TRIGGER trg_scan_state AFTER INSERT ON scan_events
FOR EACH ROW EXECUTE FUNCTION sync_unit_state();

-- ===== Meteo / PRL (telemetría; en producción usar hypertable Timescale) =====
CREATE TABLE weather_readings (
  event_id uuid NOT NULL REFERENCES events(id),
  at timestamptz NOT NULL,
  wind_kmh numeric(5,1),
  gust_kmh numeric(5,1),
  rain_mm numeric(5,1),
  lightning_km numeric(5,1),
  PRIMARY KEY (event_id, at)
);

CREATE TABLE safety_alerts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  event_id uuid NOT NULL REFERENCES events(id),
  raised_at timestamptz NOT NULL DEFAULT now(),
  kind text NOT NULL,                       -- 'viento','rayo','lluvia'
  threshold jsonb NOT NULL,
  confirmed_by uuid,                        -- confirmación humana de la acción
  confirmed_at timestamptz,
  action text
);
