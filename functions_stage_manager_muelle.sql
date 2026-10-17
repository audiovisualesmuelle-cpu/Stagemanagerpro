-- STAGE MANAGER MUELLE - Funciones: motor magnético + orden de carga LIFO
-- Requiere schema_stage_manager_muelle.sql

-- 1) Cantidades sin fórmulas de texto (evita ejecutar texto arbitrario en la BBDD):
--    cantidad_hija = ceil(cantidad_padre / per_units) * qty_per
ALTER TABLE magnetic_rules
  ADD COLUMN IF NOT EXISTS qty_per numeric NOT NULL DEFAULT 1,
  ADD COLUMN IF NOT EXISTS per_units int NOT NULL DEFAULT 1 CHECK (per_units > 0);
ALTER TABLE magnetic_rules DROP COLUMN IF EXISTS qty_formula;

-- Paso de montaje en el que se necesita cada flightcase (1 = lo primero en usarse)
ALTER TABLE load_units
  ADD COLUMN IF NOT EXISTS assembly_step int NOT NULL DEFAULT 1;

-- 2) Expansión recursiva de los 5 anillos
--    Condiciones soportadas en magnetic_rules.condition:
--      {"viento_kmh_gt": 40}  -> la regla solo aplica si el viento previsto supera ese valor
CREATE OR REPLACE FUNCTION expand_magnetic(
  p_item uuid,
  p_qty int,
  p_wind_kmh numeric DEFAULT NULL
) RETURNS TABLE (
  depth int,
  ring ring_kind,
  parent_item_id uuid,
  item_id uuid,
  qty int,
  labor jsonb
) LANGUAGE sql STABLE AS $$
  WITH RECURSIVE tree AS (
    SELECT 1 AS depth, r.ring, r.parent_item_id, r.child_item_id AS item_id,
           (ceil(p_qty::numeric / r.per_units) * r.qty_per)::int AS qty,
           r.labor,
           ARRAY[p_item, r.child_item_id] AS path
    FROM magnetic_rules r
    WHERE r.parent_item_id = p_item
      AND (r.condition->>'viento_kmh_gt' IS NULL
           OR COALESCE(p_wind_kmh, 0) > (r.condition->>'viento_kmh_gt')::numeric)
    UNION ALL
    SELECT t.depth + 1, r.ring, r.parent_item_id, r.child_item_id,
           (ceil(t.qty::numeric / r.per_units) * r.qty_per)::int,
           r.labor,
           t.path || r.child_item_id
    FROM tree t
    JOIN magnetic_rules r ON r.parent_item_id = t.item_id
    WHERE t.depth < 5                                  -- límite de profundidad
      AND r.child_item_id IS NOT NULL
      AND r.child_item_id <> ALL (t.path)              -- evita ciclos
      AND (r.condition->>'viento_kmh_gt' IS NULL
           OR COALESCE(p_wind_kmh, 0) > (r.condition->>'viento_kmh_gt')::numeric)
  )
  SELECT depth, ring, parent_item_id, item_id, qty, labor FROM tree;
$$;

-- Ejemplo: 2 torres de pantalla LED con viento previsto de 45 km/h
-- SELECT * FROM expand_magnetic('<uuid_item>', 2, 45);

-- 3) Orden de carga LIFO por envío
--    Lo que se usa antes en el montaje se carga el último (sale primero al abrir).
--    Dentro del mismo paso, lo más pesado va al frente del camión (carga baja y estable).
--    load_order = 1 es lo primero en entrar (fondo del camión).
CREATE OR REPLACE FUNCTION assign_lifo_order(p_shipment uuid)
RETURNS int LANGUAGE plpgsql AS $$
DECLARE n int;
BEGIN
  WITH ranked AS (
    SELECT id,
           row_number() OVER (
             ORDER BY assembly_step DESC, weight_kg DESC NULLS LAST, id
           ) AS ord
    FROM load_units
    WHERE shipment_id = p_shipment
  )
  UPDATE load_units u
     SET load_order = ranked.ord
    FROM ranked
   WHERE u.id = ranked.id;
  GET DIAGNOSTICS n = ROW_COUNT;

  -- Resumen de carga del envío (volumen total y peso)
  UPDATE shipments s
     SET cargo_volume_m3 = sub.vol
    FROM (SELECT COALESCE(sum(volume_m3), 0) AS vol
            FROM load_units WHERE shipment_id = p_shipment) sub
   WHERE s.id = p_shipment;

  RETURN n;
END $$;

-- NOTA: esta versión ordena pero no reparte peso por eje ni comprueba MMA.
-- Pendiente: algoritmo de cubicaje 3D (bin packing) y cálculo de carga por eje.
