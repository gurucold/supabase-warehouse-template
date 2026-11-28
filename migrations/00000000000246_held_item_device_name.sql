-- WH-410, topic "held item device name". Named by topic; its number is taken when the work is assembled for main. It needs the topics
-- "held items store and hand-over", "holding list reads and decisions" and "held photos after accept" (which patches hold_items) applied
-- before it.
--  1. public.held_items.device_name (text, nullable): the phone's own name, as the phone sends it with the items (maker and model plus a
--     short install mark, for example "Samsung SM-A156E · 7F3A"). It is kept as text on the row, not looked up later from the session, so it
--     stays right after the session ends or is signed out. Rows held before this migration stay NULL (their only record of the phone is a
--     user agent, which is never a name). The column `phone` (the user agent of the handing session) stays as it is and is no longer read.
--  2. public.hold_items(p_items jsonb, p_recorder uuid DEFAULT NULL, p_device_name text DEFAULT NULL): the new last parameter is trimmed,
--     cut to 80 characters (never refused) and stored on every row of the call; empty or absent is NULL. The old two-argument function is
--     dropped (two overloads with defaults would be ambiguous); a phone that does not send the name still calls it by its two names.
--     The caller and role checks are unchanged. The function is patched from its present text, as migration 244 does.
--  3. warehouse_security.held_row (the row of get_held_items, get_held_item, their followers and the sync feed) returns `device_name`
--     (only when a name is known; the key is absent otherwise) beside the unchanged `phone`, so a row without a name keeps the same body.
-- App version gate: the app's INTRODUCED_BY_MIGRATION table (src/config/backendFeatures.ts) gets the key `heldDeviceName`, set to this
-- migration's number at assembly. No pg_temp helper is left behind. No role is created, altered or dropped.

DROP FUNCTION IF EXISTS pg_temp.patch_function(regprocedure, text[], text[]);
CREATE FUNCTION pg_temp.patch_function(p_function regprocedure, p_old text[], p_new text[]) RETURNS void
    LANGUAGE plpgsql AS $$
DECLARE
  v_def text := pg_get_functiondef(p_function);
  v_count integer;
  i integer;
BEGIN
  IF array_length(p_old, 1) IS DISTINCT FROM array_length(p_new, 1) THEN
    RAISE EXCEPTION '%: the marker list and the replacement list differ in length', p_function;
  END IF;
  FOR i IN 1 .. array_length(p_old, 1) LOOP
    v_count := (length(v_def) - length(replace(v_def, p_old[i], ''))) / length(p_old[i]);
    IF v_count <> 1 THEN
      RAISE EXCEPTION '%: expected marker % once, found % times', p_function, i, v_count;
    END IF;
    v_def := replace(v_def, p_old[i], p_new[i]);
  END LOOP;
  EXECUTE v_def;
END $$;

-- ===== 1. the column =====
ALTER TABLE public.held_items ADD COLUMN device_name text;
COMMENT ON COLUMN public.held_items.device_name IS
  'WH-410: the name the recording phone sent with the item (at most 80 characters), kept as sent so it survives the session. NULL when none was sent. Never a user agent.';

-- ===== 2. hold_items takes the name =====
SELECT pg_temp.patch_function('public.hold_items(jsonb, uuid)'::regprocedure, ARRAY[
$m$FUNCTION public.hold_items(p_items jsonb, p_recorder uuid DEFAULT NULL::uuid)$m$,
$m$  v_phone text;$m$,
$m$  v_answers := array_fill($m$,
$m$recorded_at, phone, handed_by,$m$,
$m$v_at, v_phone, v_caller,$m$
], ARRAY[
$m$FUNCTION public.hold_items(p_items jsonb, p_recorder uuid DEFAULT NULL::uuid, p_device_name text DEFAULT NULL::text)$m$,
$m$  v_phone text;
  v_device text;$m$,
$m$  -- The phone's own name: trimmed, cut to 80 characters, empty is none.
  v_device := NULLIF(btrim(left(btrim(p_device_name), 80)), '');

  v_answers := array_fill($m$,
$m$recorded_at, phone, device_name, handed_by,$m$,
$m$v_at, v_phone, v_device, v_caller,$m$
]);
DROP FUNCTION public.hold_items(jsonb, uuid);
ALTER FUNCTION public.hold_items(jsonb, uuid, text) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION public.hold_items(jsonb, uuid, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.hold_items(jsonb, uuid, text) TO authenticated, service_role;
COMMENT ON FUNCTION public.hold_items(jsonb, uuid, text) IS
  'WH-304, WH-410: a phone hands over its refused items and what follows them (at most 50, one transaction); an administrator hands over another person''s unsent items (p_recorder). p_device_name is the phone''s own name, stored on each new row. A repeated request key answers its first row.';

-- ===== 3. the row also answers the name =====
CREATE OR REPLACE FUNCTION warehouse_security.held_row(h public.held_items) RETURNS jsonb
  LANGUAGE sql STABLE
  SET search_path TO 'pg_catalog', 'public', 'pg_temp'
AS $$
  SELECT jsonb_build_object(
    'id', h.id,
    'kind', h.kind,
    'what', h.what,
    'customer_name', (SELECT c.name FROM public.customers c WHERE c.id = h.customer_id),
    'recorded_by_name', (SELECT p.name FROM public.user_profiles p WHERE p.id = h.recorded_by),
    'recorded_at', h.recorded_at,
    'phone', h.phone,
    'reason', h.reason,
    'reason_data', CASE WHEN h.reason = 'moved' THEN jsonb_build_object(
        'admin_name', (SELECT p.name FROM public.user_profiles p WHERE p.id = h.handed_by),
        'recorder_name', (SELECT p.name FROM public.user_profiles p WHERE p.id = h.recorded_by),
        'moved_at', h.handed_at) ELSE h.reason_data END,
    'state', h.state,
    'follows', h.follows,
    'needs_decision', h.needs_decision,
    'decided_by_name', (SELECT p.name FROM public.user_profiles p WHERE p.id = h.decided_by),
    'decided_at', h.decided_at,
    'reject_reason', h.reject_reason,
    'result', h.result)
    -- The key only when a name is known: a row without one keeps the same body, so no checksum changes at the upgrade.
    || CASE WHEN h.device_name IS NOT NULL THEN jsonb_build_object('device_name', h.device_name) ELSE '{}'::jsonb END
$$;

DROP FUNCTION pg_temp.patch_function(regprocedure, text[], text[]);
NOTIFY pgrst, 'reload schema';
