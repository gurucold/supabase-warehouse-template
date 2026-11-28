-- WH-385, topic "grn missing photos" (contract tech/app-missing-photo-note.md, slice B). Named by topic; its number is taken when the work is
-- assembled for main. It needs the held-photo topics (held item photos, held photo missing, held photos after accept) and the sync feed topics
-- applied before it.
--  1. public.grn_missing_photos: one row per photo that was taken with a saved GRN and could not be sent, keyed (grn_id, client_photo_id). Both
--     paths write it: the phone's report of an unsent-queue photo (mark_grn_photo_missing) and the held path (triggers on held_item_photos and
--     held_items). No one reads the table; only the count leaves the server.
--  2. warehouse_security.grn_photos_missing(grn): the count. get_grn_details answers it as data.grn.photos_missing (always, 0 when none), and the
--     goodsreceived feed row carries photos_missing only when it is above 0 (rows with none keep the same body, so no checksum changes).
--  3. public.mark_grn_photo_missing(p_grn_id, p_client_photo_id, p_role, p_grn_item_id, p_reason): administrators, supervisors and staff (a
--     customer account is refused by authorize_rpc); idempotent. Refusals GRN_PHOTO_INVALID, GRN_NOT_FOUND, GRN_PHOTO_LINE_GONE write nothing.
--  4. A held photo marked missing (before or after the accept) is counted on the GRN the accept made; one confirmed late removes its row; a
--     held photo given up as line_gone or document_gone is not counted; a deleted line or GRN takes its rows with it.
--  5. A row written or removed logs its GRN as an update in the change feed (format stays 8).
-- The feed and details functions are patched by text with marker counts. The authorize_rpc line is in definitions/00_authorize_rpc.sql.
-- The pg_temp helper is dropped at the end. No role is created, altered or dropped.

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

-- ===== 1. the table =====
CREATE TABLE public.grn_missing_photos (
  grn_id          uuid NOT NULL REFERENCES public.goodsreceived(id) ON DELETE CASCADE,
  client_photo_id text NOT NULL CHECK (client_photo_id = btrim(client_photo_id) AND length(client_photo_id) BETWEEN 1 AND 100),
  role            text NOT NULL CHECK (role IN ('header', 'item')),
  grn_item_id     uuid REFERENCES public.goodsreceived_trl(id) ON DELETE CASCADE,
  source          text NOT NULL CHECK (source IN ('unsent', 'held')),
  reason          text CHECK (reason IS NULL OR length(reason) <= 500),
  reported_by     uuid,
  created_at      timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (grn_id, client_photo_id)
);
CREATE INDEX grn_missing_photos_item_idx ON public.grn_missing_photos (grn_item_id);
ALTER TABLE public.grn_missing_photos OWNER TO supabase_admin;
ALTER TABLE public.grn_missing_photos ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.grn_missing_photos FROM PUBLIC, anon, authenticated, service_role;
COMMENT ON TABLE public.grn_missing_photos IS
  'WH-385: photos taken with a saved GRN that could not be sent (unsent queue or held path), one row per client photo id. Only the count leaves the server.';

-- ===== 2. the count and the feed part =====
CREATE FUNCTION warehouse_security.grn_photos_missing(p_grn uuid) RETURNS integer
  LANGUAGE sql STABLE SECURITY DEFINER
  SET search_path TO 'pg_catalog', 'public', 'pg_temp'
AS $$
  SELECT count(*)::integer FROM public.grn_missing_photos m WHERE m.grn_id = p_grn;
$$;
ALTER FUNCTION warehouse_security.grn_photos_missing(uuid) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.grn_photos_missing(uuid) FROM PUBLIC, anon, authenticated, service_role;

-- The key the feed row of a GRN adds: {"photos_missing": n} when n is above 0, else nothing.
CREATE FUNCTION warehouse_sync.grn_photos_missing_part(p_grn uuid) RETURNS jsonb
  LANGUAGE sql STABLE SECURITY DEFINER
  SET search_path TO 'pg_catalog', 'public', 'pg_temp'
AS $$
  SELECT CASE WHEN n > 0 THEN jsonb_build_object('photos_missing', n) ELSE '{}'::jsonb END
    FROM (SELECT warehouse_security.grn_photos_missing(p_grn) AS n) c;
$$;
ALTER FUNCTION warehouse_sync.grn_photos_missing_part(uuid) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_sync.grn_photos_missing_part(uuid) FROM PUBLIC, anon, authenticated, service_role;

-- ===== 3. the ordinary path: the phone reports a photo it could not send =====
CREATE FUNCTION public.mark_grn_photo_missing(p_grn_id uuid, p_client_photo_id text, p_role text, p_grn_item_id uuid DEFAULT NULL,
                                              p_reason text DEFAULT NULL)
    RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'pg_temp'
    AS $$
DECLARE
  v_id text := btrim(p_client_photo_id);
  v_reason text := left(NULLIF(btrim(p_reason), ''), 500);
  v_caller uuid;
BEGIN
  PERFORM warehouse_security.authorize_rpc('mark_grn_photo_missing', jsonb_build_object('p_grn_id', p_grn_id));
  SELECT pr.id INTO v_caller FROM public.user_profiles pr WHERE pr.auth_user_id = auth.uid();
  IF v_caller IS NULL OR COALESCE(warehouse_security.active_role(), '') NOT IN ('admin', 'supervisor', 'staff') THEN
    RAISE EXCEPTION 'Staff access required' USING ERRCODE = '42501';
  END IF;

  IF v_id IS NULL OR v_id = '' OR length(v_id) > 100 THEN
    RETURN warehouse_security.refuse('GRN_PHOTO_INVALID', 'The photo has no id.');
  END IF;
  IF p_role IS NULL OR p_role NOT IN ('header', 'item') THEN
    RETURN warehouse_security.refuse('GRN_PHOTO_INVALID', 'The photo role must be header or item.');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.goodsreceived g WHERE g.id = p_grn_id AND g.deleted_at IS NULL) THEN
    RETURN warehouse_security.refuse('GRN_NOT_FOUND', 'That GRN is not there.');
  END IF;
  IF p_grn_item_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.goodsreceived_trl t WHERE t.id = p_grn_item_id AND t.gr_id = p_grn_id) THEN
    RETURN warehouse_security.refuse('GRN_PHOTO_LINE_GONE', 'The GRN line this photo belongs to is not there.');
  END IF;

  INSERT INTO public.grn_missing_photos (grn_id, client_photo_id, role, grn_item_id, source, reason, reported_by)
  VALUES (p_grn_id, v_id, p_role, CASE WHEN p_role = 'item' THEN p_grn_item_id END, 'unsent', v_reason, v_caller)
  ON CONFLICT (grn_id, client_photo_id) DO NOTHING;
  RETURN jsonb_build_object('success', true, 'grn_id', p_grn_id, 'client_photo_id', v_id, 'status', 'missing');
END $$;
ALTER FUNCTION public.mark_grn_photo_missing(uuid, text, text, uuid, text) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION public.mark_grn_photo_missing(uuid, text, text, uuid, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.mark_grn_photo_missing(uuid, text, text, uuid, text) TO authenticated, service_role;
COMMENT ON FUNCTION public.mark_grn_photo_missing(uuid, text, text, uuid, text) IS
  'WH-385: the phone reports a photo of a saved GRN it could not send; administrators, supervisors and staff; idempotent by client photo id.';

-- ===== 4. the held path: fed into the same table =====
-- For each header or item photo of the held item whose document the accept made: a confirmed photo clears its row (the photo arrived after all);
-- a missing one (reason not line_gone or document_gone) is recorded, on its line when that can be told. A line that no longer belongs to the GRN
-- is skipped (nothing left to belong to).
CREATE FUNCTION warehouse_security.grn_missing_from_held(p_held uuid) RETURNS void
  LANGUAGE plpgsql SECURITY DEFINER
  SET search_path TO 'pg_catalog', 'public', 'pg_temp'
AS $$
DECLARE
  v_uuid constant text := '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$';
  h public.held_items;
  x public.held_item_photos;
  v_map jsonb;
  v_doc uuid;
  v_line uuid;
  v_mapped boolean;
BEGIN
  SELECT i.* INTO h FROM public.held_items i WHERE i.id = p_held;
  IF NOT FOUND THEN RETURN; END IF;
  -- A photos item that follows a GRN keeps no mapping of its own: its lines are resolved with the item it follows.
  v_map := COALESCE(h.item_mapping, (SELECT f.item_mapping FROM public.held_items f WHERE f.id = h.follows), '[]'::jsonb);
  FOR x IN SELECT p.* FROM public.held_item_photos p
            WHERE p.held_id = p_held AND p.role IN ('header', 'item') AND p.state IN ('confirmed', 'missing') LOOP
    v_doc := warehouse_security.held_document(p_held, x.role);
    IF v_doc IS NULL OR NOT EXISTS (SELECT 1 FROM public.goodsreceived g WHERE g.id = v_doc AND g.deleted_at IS NULL) THEN
      CONTINUE;
    END IF;
    IF x.state = 'confirmed' THEN
      DELETE FROM public.grn_missing_photos m WHERE m.grn_id = v_doc AND m.client_photo_id = x.client_photo_id;
      CONTINUE;
    END IF;
    IF x.reason IN ('line_gone', 'document_gone') THEN CONTINUE; END IF;
    v_line := NULL;
    v_mapped := false;
    IF x.role = 'item' THEN
      IF x.line_ref ~ '^index:[0-9]{1,6}$' THEN
        SELECT true, (e ->> 'item_id')::uuid INTO v_mapped, v_line FROM jsonb_array_elements(v_map) e
         WHERE e ->> 'index' = substr(x.line_ref, 7) LIMIT 1;
      ELSIF x.line_ref ~* v_uuid THEN
        v_mapped := true;
        v_line := x.line_ref::uuid;
      END IF;
      -- A line the save made and an edit deleted, or a line of another GRN: the photo has nothing to belong to.
      IF COALESCE(v_mapped, false) AND (v_line IS NULL
         OR NOT EXISTS (SELECT 1 FROM public.goodsreceived_trl t WHERE t.id = v_line AND t.gr_id = v_doc)) THEN
        CONTINUE;
      END IF;
    END IF;
    INSERT INTO public.grn_missing_photos (grn_id, client_photo_id, role, grn_item_id, source, reason, reported_by)
    VALUES (v_doc, x.client_photo_id, x.role, v_line, 'held', left(x.reason, 500), x.uploaded_by)
    ON CONFLICT (grn_id, client_photo_id) DO NOTHING;
  END LOOP;
END $$;
ALTER FUNCTION warehouse_security.grn_missing_from_held(uuid) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.grn_missing_from_held(uuid) FROM PUBLIC, anon, authenticated, service_role;

-- The two triggers: a photo row changes (marked missing, confirmed late), and an item is accepted (a photo marked missing before the accept).
CREATE FUNCTION warehouse_security.grn_missing_held_photo_trigger() RETURNS trigger
  LANGUAGE plpgsql SECURITY DEFINER
  SET search_path TO 'pg_catalog', 'public', 'pg_temp'
AS $$
BEGIN
  PERFORM warehouse_security.grn_missing_from_held(NEW.held_id);
  RETURN NULL;
END $$;
ALTER FUNCTION warehouse_security.grn_missing_held_photo_trigger() OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.grn_missing_held_photo_trigger() FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION warehouse_security.grn_missing_held_item_trigger() RETURNS trigger
  LANGUAGE plpgsql SECURITY DEFINER
  SET search_path TO 'pg_catalog', 'public', 'pg_temp'
AS $$
BEGIN
  PERFORM warehouse_security.grn_missing_from_held(NEW.id);
  RETURN NULL;
END $$;
ALTER FUNCTION warehouse_security.grn_missing_held_item_trigger() OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.grn_missing_held_item_trigger() FROM PUBLIC, anon, authenticated, service_role;

CREATE TRIGGER grn_missing_from_held_photo AFTER INSERT OR UPDATE OF state, document_id ON public.held_item_photos
  FOR EACH ROW WHEN (NEW.state IN ('confirmed', 'missing')) EXECUTE FUNCTION warehouse_security.grn_missing_held_photo_trigger();
CREATE TRIGGER grn_missing_from_held_item AFTER UPDATE OF state, result ON public.held_items
  FOR EACH ROW WHEN (NEW.state = 'accepted' AND NEW.kind IN ('newGrn', 'photos')) EXECUTE FUNCTION warehouse_security.grn_missing_held_item_trigger();

-- ===== 5. the change log: a row written or removed touches its GRN =====
-- When the GRN row is already gone (the cascade of its delete) nothing is logged, so its own delete entry stays a delete.
CREATE FUNCTION warehouse_sync.grn_missing_log() RETURNS trigger
  LANGUAGE plpgsql SECURITY DEFINER
  SET search_path TO 'pg_catalog', 'public', 'pg_temp'
AS $$
DECLARE
  g uuid := COALESCE(NEW.grn_id, OLD.grn_id);
  c uuid;
BEGIN
  SELECT x.customer_id INTO c FROM public.goodsreceived x WHERE x.id = g;
  IF FOUND THEN
    PERFORM warehouse_sync.log_entry('goodsreceived', g::text, 'U', c, c, g, NULL);
  END IF;
  RETURN NULL;
END $$;
ALTER FUNCTION warehouse_sync.grn_missing_log() OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_sync.grn_missing_log() FROM PUBLIC, anon, authenticated, service_role;

CREATE TRIGGER zz_grn_missing_log AFTER INSERT OR DELETE ON public.grn_missing_photos
  FOR EACH ROW EXECUTE FUNCTION warehouse_sync.grn_missing_log();
ALTER TABLE public.grn_missing_photos ENABLE ALWAYS TRIGGER zz_grn_missing_log;

-- ===== 6. the count in the feed row and in GRN details =====
SELECT pg_temp.patch_function('warehouse_sync.entity_rows(text, uuid, uuid[], text, text[], text, integer)'::regprocedure, ARRAY[
$m$to_jsonb(x) FROM %s t CROSS JOIN LATERAL$m$,
$m$v_tbl, v_cols, v_where,$m$
], ARRAY[
$m$to_jsonb(x)%s FROM %s t CROSS JOIN LATERAL$m$,
$m$CASE WHEN p_entity = 'goodsreceived' THEN ' || warehouse_sync.grn_photos_missing_part(t.id)' ELSE '' END, v_tbl, v_cols, v_where,$m$
]);

SELECT pg_temp.patch_function('public.get_grn_details(uuid)'::regprocedure, ARRAY[
$m$        RETURN warehouse_security.customer_answer(v_result);

    EXCEPTION$m$
], ARRAY[
$m$        -- WH-385: how many photos taken with this GRN could not be sent (the integer only, for every role that gets the GRN).
        v_result := jsonb_set(v_result, '{data,grn,photos_missing}', to_jsonb(warehouse_security.grn_photos_missing(p_grn_id)));

        RETURN warehouse_security.customer_answer(v_result);

    EXCEPTION$m$
]);

-- ===== 7. backfill: the missing photos of items already accepted =====
SELECT warehouse_security.grn_missing_from_held(h.id) FROM public.held_items h WHERE h.state = 'accepted' AND h.kind IN ('newGrn', 'photos');

DROP FUNCTION pg_temp.patch_function(regprocedure, text[], text[]);
NOTIFY pgrst, 'reload schema';
