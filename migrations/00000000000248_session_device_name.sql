-- WH-411, topic "session device name". Named by topic; its number is taken when the work is assembled for main. It needs migrations 140 (session
-- devices), 163 (issue_session with the network key), 170 (redeem_pairing_code) and the sign-in patches of 154 and 168, all in the numbered
-- chain before it, and the topic "held item device name" (warehouse_security.clean_device_name).
--  1. warehouse_security.refresh_sessions.device_name (text, nullable, at most 80 characters): the phone's own name, as the phone sends it
--     (maker and model plus a short install mark, for example "Samsung SM-A156E · 7F3A"; the same name WH-410 keeps on held items). Sessions
--     made before this migration stay NULL; the user agent column is unchanged.
--  2. warehouse_security.issue_session(p_user, p_session, p_ip, p_user_agent, p_device_name DEFAULT NULL): the new last parameter is cleaned
--     (clean_device_name: cut to 80 characters, never refused, empty is NULL), and a new session stores it. A refresh leaves the stored name alone (the
--     rotation updates the same row). The four-argument function is dropped (two overloads with defaults would be ambiguous); every call
--     with up to four arguments binds to the new one.
--  3. The sign-in RPCs gain a last parameter p_device_name and pass it to issue_session: operator_verify_otp (7 arguments),
--     operator_central_exchange (11), operator_break_glass_sign_in (5) and redeem_pairing_code (4, default NULL; its three-argument form is
--     dropped). The three-argument-shorter signatures of the first three stay as thin wrappers that pass NULL (as migration 140 did), so an
--     edge function that is not updated keeps working. The new signatures have no defaults, apart from redeem_pairing_code.
--  4. public.set_session_device_name(p_device_name text) (authenticated): the signed-in phone names its own session when the session has
--     none (a session made before the app sent a name); a stored name is never overwritten and an empty name changes nothing.
--     refresh_jwt_token is NOT changed: it has a definition file, and tests/definitions.test.mjs forbids a numbered migration to change
--     its signature. migrations/definitions/00_authorize_rpc.sql lets the new function through for any signed-in account.
--  5. public.list_user_sessions returns `device_name` beside the unchanged `user_agent` (NULL when no name is known).
-- App version gate: the app's INTRODUCED_BY_MIGRATION table (src/config/backendFeatures.ts) gets a key (for example `sessionDeviceName`),
-- set to this migration's number at assembly. No pg_temp helper is left behind. No role is created, altered or dropped.

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

-- The body of a function with every call that ends in the user agent (`p_user_agent)`) widened to carry the device name; at least one call
-- must change and the body must be free of the quote tag the clone is written with.
CREATE FUNCTION pg_temp.body_with_device_name(p_function regprocedure) RETURNS text
    LANGUAGE plpgsql AS $$
DECLARE v_body text; v_new text;
BEGIN
  SELECT p.prosrc INTO v_body FROM pg_proc p WHERE p.oid = p_function;
  IF v_body IS NULL OR position('$wh_body$' IN v_body) > 0 THEN
    RAISE EXCEPTION '%: the body is missing or holds the quote tag', p_function;
  END IF;
  v_new := replace(v_body, 'p_user_agent)', 'p_user_agent,p_device_name)');
  IF v_new = v_body THEN
    RAISE EXCEPTION '%: no call that carries p_user_agent was found', p_function;
  END IF;
  RETURN v_new;
END $$;

-- ===== 1. the column =====
ALTER TABLE warehouse_security.refresh_sessions
  ADD COLUMN device_name text CONSTRAINT refresh_sessions_device_name_len CHECK (char_length(device_name) <= 80);
COMMENT ON COLUMN warehouse_security.refresh_sessions.device_name IS
  'WH-411: the name the phone sent at sign-in or on a refresh (at most 80 characters), kept only when the session had none. NULL when none was sent. Never a user agent; deleted with the session.';

-- ===== 2. issue_session takes the name (otherwise as migration 163) =====
DROP FUNCTION warehouse_security.issue_session(uuid, uuid, inet, text);
CREATE FUNCTION warehouse_security.issue_session(p_user uuid, p_session uuid DEFAULT NULL::uuid, p_ip inet DEFAULT NULL::inet, p_user_agent text DEFAULT NULL::text, p_device_name text DEFAULT NULL::text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'extensions'
    AS $$
DECLARE refresh text; session_id uuid; sliding boolean; idle_seconds integer := warehouse_security.session_idle_seconds(); max_seconds integer := warehouse_security.session_max_seconds();
  new_key bytea;
  -- The phone's own name: cleaned and cut to 80 characters, empty is none.
  v_device text := warehouse_security.clean_device_name(p_device_name);
BEGIN
  SELECT p.enrollment_status = 'approved' INTO sliding FROM public.user_profiles p WHERE p.auth_user_id = p_user AND p.active;
  IF NOT FOUND THEN RAISE EXCEPTION 'Active account required' USING ERRCODE = 'P0002'; END IF;
  refresh := encode(extensions.gen_random_bytes(32), 'hex');
  IF p_session IS NULL THEN
    INSERT INTO warehouse_security.refresh_sessions(user_id, token_hash, expires_at, last_refreshed_at, created_ip, user_agent, device_name)
    VALUES (p_user, encode(extensions.digest(refresh, 'sha256'), 'hex'),
      now() + CASE WHEN sliding THEN make_interval(secs => idle_seconds) ELSE interval '7 days' END, now(), p_ip, left(p_user_agent, 300), v_device)
    RETURNING id, lan_key INTO session_id, new_key;
    -- The person's expired sessions go first; then only the newest 10 stay (the new one always does), ranked by last use, so a live
    -- session is never given up for an expired one. The tokens recorded for a deleted session go with it
    -- (consumed_refresh_tokens.session_id ON DELETE CASCADE), so none of them is accepted or recognised afterwards.
    DELETE FROM warehouse_security.refresh_sessions s
    WHERE s.user_id = p_user AND s.id <> session_id
      AND (s.expires_at <= now() OR s.hard_expires_at <= now()
        OR s.id NOT IN (SELECT k.id FROM warehouse_security.refresh_sessions k
          WHERE k.user_id = p_user AND k.id <> session_id AND k.expires_at > now() AND (k.hard_expires_at IS NULL OR k.hard_expires_at > now())
          ORDER BY COALESCE(k.last_refreshed_at, k.created_at) DESC, k.id LIMIT 9));
  ELSE
    -- A sliding session ends at the earlier of the idle time after this refresh and the absolute limit after sign-in; one already
    -- past the absolute limit (the operator lowered it) is not renewed. A session with a hard end (break-glass) never passes it.
    -- (A refresh never changes the stored device name; set_session_device_name fills a missing one.)
    UPDATE warehouse_security.refresh_sessions s SET token_hash = encode(extensions.digest(refresh, 'sha256'), 'hex'),
      last_refreshed_at = now(),
      expires_at = least(
        CASE WHEN sliding THEN least(now() + make_interval(secs => idle_seconds), s.created_at + make_interval(secs => max_seconds))
             ELSE s.expires_at END,
        COALESCE(s.hard_expires_at, 'infinity'::timestamptz))
    WHERE s.id = p_session AND s.user_id = p_user AND s.expires_at > now()
      AND (s.hard_expires_at IS NULL OR s.hard_expires_at > now())
      AND (NOT sliding OR s.created_at + make_interval(secs => max_seconds) > now())
    RETURNING s.id INTO session_id;
    IF session_id IS NULL THEN RAISE EXCEPTION 'Session expired'; END IF;
  END IF;
  -- Migration 163: a sign-in (new session) carries the session's warehouse network key; a refresh never does.
  IF new_key IS NOT NULL THEN
    RETURN warehouse_security.sign_access_token(p_user, session_id) || jsonb_build_object('refresh_token', refresh,
      'lan_key_id', session_id, 'lan_key', encode(new_key, 'hex'));
  END IF;
  RETURN warehouse_security.sign_access_token(p_user, session_id) || jsonb_build_object('refresh_token', refresh);
END $$;
ALTER FUNCTION warehouse_security.issue_session(uuid, uuid, inet, text, text) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.issue_session(uuid, uuid, inet, text, text) FROM PUBLIC, anon, authenticated;

-- ===== 3. the sign-in RPCs pass the name on =====
-- 3a. operator_verify_otp: the seven-argument function is the six-argument body with the issue_session call widened.
DO $do$
BEGIN
  EXECUTE 'CREATE FUNCTION public.operator_verify_otp(p_phone_number text, p_otp_code text, p_name text, p_display_name text, p_ip_address inet, p_user_agent text, p_device_name text) RETURNS jsonb '
    || 'LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''pg_catalog'', ''public'', ''extensions'' AS $wh_body$'
    || pg_temp.body_with_device_name('public.operator_verify_otp(text,text,text,text,inet,text)'::regprocedure) || '$wh_body$';
  EXECUTE format('COMMENT ON FUNCTION public.operator_verify_otp(text,text,text,text,inet,text,text) IS %L',
    obj_description('public.operator_verify_otp(text,text,text,text,inet,text)'::regprocedure, 'pg_proc'));
END $do$;
ALTER FUNCTION public.operator_verify_otp(text, text, text, text, inet, text, text) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION public.operator_verify_otp(text, text, text, text, inet, text, text) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.operator_verify_otp(text, text, text, text, inet, text, text) TO service_role;

-- 3b. operator_central_exchange: its two calls (the facility-code check through operator_verify_otp, and issue_session) carry the name.
DO $do$
BEGIN
  EXECUTE 'CREATE FUNCTION public.operator_central_exchange(p_issuer text, p_subject text, p_phone_number text, p_token_id text, p_token_expires_at timestamptz, '
    || 'p_name text, p_display_name text, p_ip_address inet, p_otp_code text, p_user_agent text, p_device_name text) RETURNS jsonb '
    || 'LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''pg_catalog'', ''public'', ''extensions'' AS $wh_body$'
    || pg_temp.body_with_device_name('public.operator_central_exchange(text,text,text,text,timestamptz,text,text,inet,text,text)'::regprocedure) || '$wh_body$';
  EXECUTE format('COMMENT ON FUNCTION public.operator_central_exchange(text,text,text,text,timestamptz,text,text,inet,text,text,text) IS %L',
    obj_description('public.operator_central_exchange(text,text,text,text,timestamptz,text,text,inet,text,text)'::regprocedure, 'pg_proc'));
END $do$;
ALTER FUNCTION public.operator_central_exchange(text, text, text, text, timestamptz, text, text, inet, text, text, text) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION public.operator_central_exchange(text, text, text, text, timestamptz, text, text, inet, text, text, text) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.operator_central_exchange(text, text, text, text, timestamptz, text, text, inet, text, text, text) TO service_role;

-- 3c. operator_break_glass_sign_in: the one issue_session call carries the name.
DO $do$
BEGIN
  EXECUTE 'CREATE FUNCTION public.operator_break_glass_sign_in(p_phone_number text, p_code text, p_ip_address inet, p_user_agent text, p_device_name text) RETURNS jsonb '
    || 'LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''pg_catalog'', ''public'', ''extensions'' AS $wh_body$'
    || pg_temp.body_with_device_name('public.operator_break_glass_sign_in(text,text,inet,text)'::regprocedure) || '$wh_body$';
  EXECUTE format('COMMENT ON FUNCTION public.operator_break_glass_sign_in(text,text,inet,text,text) IS %L',
    obj_description('public.operator_break_glass_sign_in(text,text,inet,text)'::regprocedure, 'pg_proc'));
END $do$;
ALTER FUNCTION public.operator_break_glass_sign_in(text, text, inet, text, text) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION public.operator_break_glass_sign_in(text, text, inet, text, text) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.operator_break_glass_sign_in(text, text, inet, text, text) TO service_role;

-- 3d. The signatures before the name: thin wrappers (grants as before, kept by CREATE OR REPLACE).
CREATE OR REPLACE FUNCTION public.operator_verify_otp(p_phone_number text, p_otp_code text, p_name text, p_display_name text, p_ip_address inet, p_user_agent text) RETURNS jsonb
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'extensions'
    AS $$ SELECT public.operator_verify_otp(p_phone_number, p_otp_code, p_name, p_display_name, p_ip_address, p_user_agent, NULL::text) $$;
CREATE OR REPLACE FUNCTION public.operator_central_exchange(p_issuer text, p_subject text, p_phone_number text, p_token_id text, p_token_expires_at timestamptz, p_name text, p_display_name text, p_ip_address inet, p_otp_code text, p_user_agent text) RETURNS jsonb
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'extensions'
    AS $$ SELECT public.operator_central_exchange(p_issuer, p_subject, p_phone_number, p_token_id, p_token_expires_at, p_name, p_display_name, p_ip_address, p_otp_code, p_user_agent, NULL::text) $$;
CREATE OR REPLACE FUNCTION public.operator_break_glass_sign_in(p_phone_number text, p_code text, p_ip_address inet, p_user_agent text) RETURNS jsonb
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'extensions'
    AS $$ SELECT public.operator_break_glass_sign_in(p_phone_number, p_code, p_ip_address, p_user_agent, NULL::text) $$;
COMMENT ON FUNCTION public.operator_verify_otp(text, text, text, text, inet, text) IS 'WH-411: the signature before the device name was added; calls the seven-argument form with NULL.';
COMMENT ON FUNCTION public.operator_central_exchange(text, text, text, text, timestamptz, text, text, inet, text, text) IS 'WH-411: the signature before the device name was added; calls the eleven-argument form with NULL.';
COMMENT ON FUNCTION public.operator_break_glass_sign_in(text, text, inet, text) IS 'WH-411: the signature before the device name was added; calls the five-argument form with NULL.';

-- 3e. redeem_pairing_code (local-only facility): the fourth parameter has a default; the three-argument function goes.
DO $do$
BEGIN
  EXECUTE 'CREATE FUNCTION public.redeem_pairing_code(p_code text, p_ip text, p_user_agent text, p_device_name text DEFAULT NULL::text) RETURNS jsonb '
    || 'LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''pg_catalog'', ''public'', ''extensions'' AS $wh_body$'
    || pg_temp.body_with_device_name('public.redeem_pairing_code(text,text,text)'::regprocedure) || '$wh_body$';
END $do$;
DROP FUNCTION public.redeem_pairing_code(text, text, text);
ALTER FUNCTION public.redeem_pairing_code(text, text, text, text) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION public.redeem_pairing_code(text, text, text, text) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.redeem_pairing_code(text, text, text, text) TO service_role;

-- ===== 4. public.set_session_device_name: a session without a name gets one =====
-- For a session made before the app sent a name (or by an app that did not): the signed-in phone names its own session. It fills a
-- missing name only (a stored name is never overwritten, and an empty name changes nothing). Any signed-in account, for its own session
-- (the session id comes from the caller's token). refresh_jwt_token is not changed: a function with a definition file keeps its signature.
CREATE FUNCTION public.set_session_device_name(p_device_name text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'extensions'
    AS $$
DECLARE v_name text := warehouse_security.clean_device_name(p_device_name); v_session text := auth.jwt()->>'session_id';
BEGIN
  PERFORM warehouse_security.authorize_rpc('set_session_device_name', jsonb_build_object());
  IF v_name IS NOT NULL AND v_session ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN
    UPDATE warehouse_security.refresh_sessions s SET device_name = v_name
    WHERE s.id = v_session::uuid AND s.user_id = auth.uid() AND s.device_name IS NULL;
  END IF;
  RETURN jsonb_build_object('success', true);
END $$;
ALTER FUNCTION public.set_session_device_name(text) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION public.set_session_device_name(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.set_session_device_name(text) TO authenticated, service_role;
COMMENT ON FUNCTION public.set_session_device_name(text) IS 'WH-411: the signed-in phone names its own session when the session has no name yet (control and format characters removed, trimmed, at most 80 characters; a stored name is kept). Answers {success:true} whatever happened.';

-- ===== 5. the list returns the name =====
SELECT pg_temp.patch_function('public.list_user_sessions(uuid)'::regprocedure, ARRAY[
$m$'id', s.id, 'user_agent', s.user_agent,$m$
], ARRAY[
$m$'id', s.id, 'user_agent', s.user_agent, 'device_name', s.device_name,$m$
]);

DROP FUNCTION pg_temp.body_with_device_name(regprocedure);
DROP FUNCTION pg_temp.patch_function(regprocedure, text[], text[]);

NOTIFY pgrst, 'reload schema';
