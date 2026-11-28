-- WH-385, topic "grn missing photos" (contract ~/ws/fresh/product/tech/app-missing-photo-note.md, B1-B12): public.grn_missing_photos holds one
-- row per photo of a saved GRN that could not be sent, written by public.mark_grn_photo_missing (the ordinary path) and by the held-photo rows
-- (triggers); only the count leaves the server, as data.grn.photos_missing of get_grn_details (the feed half is
-- tests/sync_feed_grn_missing_photos_385.sql). Labels: M1 the report, M2 repeats, M3 refusals, M4 who may, M5 held marked after the accept,
-- M6 held marked before the accept (item and follower), M7 confirmed late, M8 reasons not counted and one count, M10 deletes and the change
-- log, M11 the customer account, M12 the backfill's helper, M13 grants.
-- Fictional data; runs only in migrations.sh's disposable database (real Storage tables and policies); rolls back at the end.
\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.gm_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok, false) THEN RAISE EXCEPTION 'grn missing photos 385: %', label; END IF; END $$;
CREATE FUNCTION pg_temp.gm_login(phone text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE c jsonb; l jsonb; claims jsonb;
BEGIN
  c := public.operator_prepare_otp(phone);
  PERFORM pg_temp.gm_assert(c->>'success' = 'true', 'challenge prepared for ' || phone);
  PERFORM public.operator_finish_otp((c#>>'{data,request_id}')::uuid, true, 'mock-provider-only');
  l := public.operator_verify_otp(phone, c#>>'{data,otp_code}');
  PERFORM pg_temp.gm_assert(l#>>'{data,action}' = 'login', 'login for ' || phone);
  SELECT jsonb_build_object('role', 'authenticated', 'sub', p.auth_user_id, 'session_id', r.id) INTO claims
    FROM public.user_profiles p JOIN warehouse_security.refresh_sessions r ON r.user_id = p.auth_user_id
    WHERE p.mobile = warehouse_security.normalize_phone(phone) ORDER BY r.created_at DESC LIMIT 1;
  RETURN claims;
END $$;
CREATE FUNCTION pg_temp.gm_as(claims jsonb, statement text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE answer jsonb;
BEGIN
  PERFORM set_config('request.jwt.claims', claims::text, true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  BEGIN EXECUTE statement INTO answer;
  EXCEPTION WHEN OTHERS THEN answer := jsonb_build_object('raised', SQLERRM, 'state', SQLSTATE); END;
  EXECUTE 'RESET ROLE';
  RETURN answer;
END $$;
-- The report, as the phone sends it.
CREATE FUNCTION pg_temp.gm_mark(claims jsonb, grn uuid, cid text, role text, line uuid DEFAULT NULL, reason text DEFAULT NULL) RETURNS jsonb
  LANGUAGE sql AS $$
  SELECT pg_temp.gm_as(claims, format('SELECT public.mark_grn_photo_missing(%L::uuid, %L, %L, %L::uuid, %L)', grn, cid, role, line, reason)) $$;
CREATE FUNCTION pg_temp.gm_n(grn uuid) RETURNS bigint LANGUAGE sql AS $$ SELECT count(*) FROM public.grn_missing_photos WHERE grn_id = grn $$;
CREATE FUNCTION pg_temp.gm_ids(grn uuid) RETURNS text LANGUAGE sql AS $$
  SELECT COALESCE(string_agg(client_photo_id, ',' ORDER BY client_photo_id COLLATE "C"), '') FROM public.grn_missing_photos WHERE grn_id = grn $$;
CREATE FUNCTION pg_temp.gm_details(claims jsonb, grn uuid) RETURNS jsonb LANGUAGE sql AS $$
  SELECT pg_temp.gm_as(claims, format('SELECT public.get_grn_details(%L::uuid)', grn)) $$;
-- Held items and held photos, through the product calls.
CREATE FUNCTION pg_temp.gm_body(cust uuid, item uuid, no text) RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_build_object('args', jsonb_build_object('p_sender_name', 'Missing Sender',
    'p_supervisor_id', (SELECT id FROM public.user_profiles WHERE name = 'Missing Administrator'), 'p_supervisor_name', 'Missing Administrator',
    'p_gr_no', no, 'p_date', '2026-04-01T12:00:00Z', 'p_customer_id', cust, 'p_customer_name', 'Missing Customer A', 'p_pricing_mode', 'ONE_TIME',
    'p_issue_number', false, 'p_recorded_at', now() - interval '2 hours',
    'p_items', jsonb_build_array(
      jsonb_build_object('item_id', item, 'item_name', 'Missing Cumin', 'packaging', 'Bag', 'qty', 2, 'weight', 10, 'rack', 'N1', 'package_mark', 'NM'),
      jsonb_build_object('item_id', item, 'item_name', 'Missing Cumin', 'packaging', 'Bag', 'qty', 3, 'weight', 10, 'rack', 'N2', 'package_mark', 'N2')))) $$;
CREATE FUNCTION pg_temp.gm_item(key text, kind text, seq int, cust uuid, body jsonb, extra jsonb DEFAULT '{}'::jsonb) RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_build_object('request_key', key, 'kind', kind, 'body', body, 'seq', seq, 'recorded_at', now() - interval '2 hours',
    'what', jsonb_build_object('document', kind, 'number', key), 'customer_id', cust,
    'refusal', jsonb_build_object('code', 'STOCK_SHORT', 'reason', 'Insufficient stock')) || extra $$;
CREATE FUNCTION pg_temp.gm_hold(claims jsonb, items jsonb) RETURNS void LANGUAGE plpgsql AS $$
DECLARE r jsonb;
BEGIN
  r := pg_temp.gm_as(claims, format('SELECT public.hold_items(%L::jsonb)', items));
  PERFORM pg_temp.gm_assert(r->>'success' = 'true', 'fixture: hand over: ' || r::text);
END $$;
CREATE FUNCTION pg_temp.gm_hid(key text) RETURNS uuid LANGUAGE sql AS $$ SELECT id FROM public.held_items WHERE request_key = key $$;
-- Accepts a held item and returns the GRN the accept made.
CREATE FUNCTION pg_temp.gm_accept(claims jsonb, key text) RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE r jsonb; g uuid;
BEGIN
  r := pg_temp.gm_as(claims, format('SELECT public.decide_held_item(%L::uuid, %L, %L, NULL, NULL::jsonb)', pg_temp.gm_hid(key), 'accept', 'dk-' || key));
  PERFORM pg_temp.gm_assert(r->>'success' = 'true', 'fixture: accept ' || key || ': ' || r::text);
  SELECT id INTO g FROM public.goodsreceived WHERE request_key = key;
  PERFORM pg_temp.gm_assert(g IS NOT NULL, 'fixture: the accept of ' || key || ' made a GRN');
  RETURN g;
END $$;
CREATE FUNCTION pg_temp.gm_line(grn uuid, rack_is text) RETURNS uuid LANGUAGE sql AS $$
  SELECT id FROM public.goodsreceived_trl WHERE gr_id = grn AND rack = rack_is $$;
-- Registers a held photo and uploads its file as its recorder.
CREATE FUNCTION pg_temp.gm_reg_put(claims jsonb, held uuid, cid text, role text, line text DEFAULT NULL) RETURNS void LANGUAGE plpgsql AS $$
DECLARE r jsonb;
BEGIN
  r := pg_temp.gm_as(claims, format('SELECT public.register_held_photo_upload(%L::uuid, %L, %L, %L, 100, %L, %L)', held, cid, role, cid || '.jpg', 'image/jpeg', line));
  PERFORM pg_temp.gm_assert(r->>'success' = 'true', 'fixture: register ' || cid || ': ' || r::text);
  PERFORM set_config('request.jwt.claims', claims::text, true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  INSERT INTO storage.objects(bucket_id, name) VALUES ('grn-images', r->>'storage_path');
  EXECUTE 'RESET ROLE';
END $$;
CREATE FUNCTION pg_temp.gm_held_mark(claims jsonb, held uuid, cid text, role text, line text DEFAULT NULL, reason text DEFAULT 'file_missing') RETURNS void
  LANGUAGE plpgsql AS $$
DECLARE r jsonb;
BEGIN
  r := pg_temp.gm_as(claims, format('SELECT public.mark_held_photo_missing(%L::uuid, %L, %L, %L, %L)', held, cid, role, line, reason));
  PERFORM pg_temp.gm_assert(r->>'success' = 'true' AND r->>'status' = 'missing', 'fixture: held mark ' || cid || ': ' || r::text);
END $$;

-- ===== people and the catalogue =====
INSERT INTO warehouse_security.auth_config(key, value) VALUES
 ('jwt_secret', 'isolated-test-secret-not-for-any-deployment-12345'), ('auth_mode', 'operator'), ('demo_auth_enabled', 'false')
 ON CONFLICT(key) DO UPDATE SET value = excluded.value;
UPDATE public.sms_config SET provider = 'msg91', production_mode = true, msg91_auth_key = 'isolated-test-key',
 msg91_template_id = '000000000000000000000001', msg91_pe_id = '0000000000000000001', msg91_sender_id = 'CITEST'
 WHERE id = (SELECT id FROM public.sms_config ORDER BY id DESC LIMIT 1);
SELECT warehouse_security.bootstrap_first_admin('9888886851', 'Missing Administrator') AS admin_user \gset
INSERT INTO public.user_profiles(auth_user_id, mobile, name, role, active, enrollment_status) VALUES
 (gen_random_uuid(), '919888886852', 'Missing Supervisor', 'supervisor', true, 'approved'),
 (gen_random_uuid(), '919888886853', 'Missing Staff', 'staff', true, 'approved'),
 (gen_random_uuid(), '919888886854', 'Missing Customer Account', 'customer', true, 'approved');
SELECT pg_temp.gm_login('9888886851') AS admin_claims \gset
SELECT pg_temp.gm_login('9888886852') AS supervisor_claims \gset
SELECT pg_temp.gm_login('9888886853') AS staff_claims \gset
SELECT pg_temp.gm_login('9888886854') AS customer_claims \gset
SELECT id AS staff_profile FROM public.user_profiles WHERE mobile = '919888886853' \gset
SELECT pg_temp.gm_assert(pg_temp.gm_as(:'admin_claims'::jsonb, $q$SELECT public.create_customer('Missing Customer A', '9888886861')$q$)->>'success' = 'true', 'customer');
SELECT pg_temp.gm_assert(pg_temp.gm_as(:'admin_claims'::jsonb, $q$SELECT public.create_item('Missing Cumin', 'Bag')$q$)->>'success' = 'true', 'item');
SELECT id AS ca FROM public.customers WHERE name = 'Missing Customer A' \gset
SELECT id AS item_id FROM public.items WHERE name = 'Missing Cumin' \gset
INSERT INTO public.users_customers_new(user_profile_id, customer_id, active)
  SELECT id, :'ca'::uuid, true FROM public.user_profiles WHERE mobile = '919888886854';

-- Two saved GRNs of two lines each (G the subject, H the one nothing is reported on).
SELECT pg_temp.gm_hold(:'staff_claims'::jsonb, jsonb_build_array(
  pg_temp.gm_item('gm-g', 'newGrn', 1, :'ca'::uuid, pg_temp.gm_body(:'ca'::uuid, :'item_id'::uuid, 'GMG1')),
  pg_temp.gm_item('gm-h', 'newGrn', 2, :'ca'::uuid, pg_temp.gm_body(:'ca'::uuid, :'item_id'::uuid, 'GMH1'))));
SELECT pg_temp.gm_accept(:'admin_claims'::jsonb, 'gm-g') AS g \gset
SELECT pg_temp.gm_accept(:'admin_claims'::jsonb, 'gm-h') AS h \gset
SELECT pg_temp.gm_line(:'g'::uuid, 'N1') AS g_l1, pg_temp.gm_line(:'g'::uuid, 'N2') AS g_l2, pg_temp.gm_line(:'h'::uuid, 'N1') AS h_l1 \gset
SELECT pg_temp.gm_assert((SELECT count(*) = 0 FROM public.grn_missing_photos)
  AND pg_temp.gm_details(:'staff_claims'::jsonb, :'g'::uuid)#>'{data,grn,photos_missing}' = '0'::jsonb,
  'M1: a GRN with no missing photo answers photos_missing 0, always present');

-- ===== M1. The report =====
DELETE FROM warehouse_sync.change_log;
SELECT pg_temp.gm_mark(:'staff_claims'::jsonb, :'g'::uuid, '  gp-head  ', 'header', :'g_l1'::uuid, '  file_missing  ') AS m1 \gset
SELECT pg_temp.gm_assert(:'m1'::jsonb = jsonb_build_object('success', true, 'grn_id', :'g', 'client_photo_id', 'gp-head', 'status', 'missing'),
  'M1: staff report a photo: the answer is success, the GRN, the trimmed id and missing: ' || :'m1');
SELECT pg_temp.gm_assert((SELECT count(*) = 1 AND bool_and(client_photo_id = 'gp-head' AND role = 'header' AND grn_item_id IS NULL AND source = 'unsent'
    AND reason = 'file_missing' AND reported_by = :'staff_profile'::uuid) FROM public.grn_missing_photos WHERE grn_id = :'g'::uuid),
  'M1: one row, unsent, by the reporter; a header photo reported with a line id stores no line');
SELECT pg_temp.gm_assert(pg_temp.gm_details(:'staff_claims'::jsonb, :'g'::uuid)#>'{data,grn,photos_missing}' = '1'::jsonb
  AND pg_temp.gm_details(:'staff_claims'::jsonb, :'h'::uuid)#>'{data,grn,photos_missing}' = '0'::jsonb, 'M1: get_grn_details counts it on that GRN only');
-- M10: the report logs its GRN, once, as an update the customer's feed can see.
SELECT pg_temp.gm_assert((SELECT count(*) = 1 AND bool_and(tbl = 'goodsreceived' AND row_key = :'g' AND op = 'U' AND old_customer = :'ca'::uuid
    AND new_customer = :'ca'::uuid AND grn_id = :'g'::uuid) FROM warehouse_sync.change_log),
  'M10: a report logs exactly its GRN as an update with its customer: ' || COALESCE((SELECT string_agg(tbl::text || ':' || row_key::text || ':' || op::text, ',') FROM warehouse_sync.change_log), 'nothing'));

-- ===== M2. Repeats =====
DELETE FROM warehouse_sync.change_log;
SELECT pg_temp.gm_mark(:'staff_claims'::jsonb, :'g'::uuid, 'gp-head', 'header', NULL, 'file_missing') AS m2a \gset
SELECT pg_temp.gm_mark(:'admin_claims'::jsonb, :'g'::uuid, 'gp-head', 'item', :'g_l1'::uuid, 'another reason') AS m2b \gset
SELECT pg_temp.gm_assert(:'m2a'::jsonb = :'m1'::jsonb AND :'m2b'::jsonb = :'m1'::jsonb AND pg_temp.gm_n(:'g'::uuid) = 1
  AND (SELECT role = 'header' AND reason = 'file_missing' AND reported_by = :'staff_profile'::uuid FROM public.grn_missing_photos WHERE grn_id = :'g'::uuid)
  AND (SELECT count(*) = 0 FROM warehouse_sync.change_log),
  'M2: a repeat, also with another reason and by another person, answers the same, keeps the first row and logs nothing: ' || :'m2a' || ' / ' || :'m2b');
SELECT pg_temp.gm_mark(:'supervisor_claims'::jsonb, :'g'::uuid, 'gp-line1', 'item', :'g_l1'::uuid, repeat('r', 600)) AS m2c \gset
SELECT pg_temp.gm_mark(:'admin_claims'::jsonb, :'g'::uuid, 'gp-line2', 'item', :'g_l2'::uuid, '   ') AS m2d \gset
SELECT pg_temp.gm_mark(:'staff_claims'::jsonb, :'g'::uuid, 'gp-noline', 'item') AS m2e \gset
SELECT pg_temp.gm_assert(:'m2c'::jsonb->>'success' = 'true' AND :'m2d'::jsonb->>'success' = 'true' AND :'m2e'::jsonb->>'success' = 'true'
  AND (SELECT grn_item_id = :'g_l1'::uuid AND length(reason) = 500 FROM public.grn_missing_photos WHERE grn_id = :'g'::uuid AND client_photo_id = 'gp-line1')
  AND (SELECT grn_item_id = :'g_l2'::uuid AND reason IS NULL FROM public.grn_missing_photos WHERE grn_id = :'g'::uuid AND client_photo_id = 'gp-line2')
  AND (SELECT grn_item_id IS NULL AND role = 'item' FROM public.grn_missing_photos WHERE grn_id = :'g'::uuid AND client_photo_id = 'gp-noline'),
  'M1: a supervisor and an administrator report too; a line photo keeps its line, a long reason is cut to 500, a blank one is none, a line is optional: '
  || :'m2c' || ' / ' || :'m2d' || ' / ' || :'m2e');
SELECT pg_temp.gm_assert(pg_temp.gm_details(:'staff_claims'::jsonb, :'g'::uuid)#>'{data,grn,photos_missing}' = '4'::jsonb, 'M1: four photos, count 4');

-- ===== M3. Refusals write nothing =====
SELECT count(*) AS n_m3 FROM public.grn_missing_photos \gset
CREATE TEMP TABLE gm_bad(code text, answer jsonb) ON COMMIT DROP;
INSERT INTO gm_bad VALUES
 ('GRN_PHOTO_INVALID', pg_temp.gm_mark(:'staff_claims'::jsonb, :'g'::uuid, '   ', 'header')),
 ('GRN_PHOTO_INVALID', pg_temp.gm_mark(:'staff_claims'::jsonb, :'g'::uuid, NULL, 'header')),
 ('GRN_PHOTO_INVALID', pg_temp.gm_mark(:'staff_claims'::jsonb, :'g'::uuid, repeat('i', 101), 'header')),
 ('GRN_PHOTO_INVALID', pg_temp.gm_mark(:'staff_claims'::jsonb, :'g'::uuid, 'bad-1', 'dispatch')),
 ('GRN_PHOTO_INVALID', pg_temp.gm_mark(:'staff_claims'::jsonb, :'g'::uuid, 'bad-2', NULL)),
 ('GRN_NOT_FOUND', pg_temp.gm_mark(:'staff_claims'::jsonb, gen_random_uuid(), 'bad-3', 'header')),
 ('GRN_PHOTO_LINE_GONE', pg_temp.gm_mark(:'staff_claims'::jsonb, :'g'::uuid, 'bad-4', 'item', :'h_l1'::uuid)),
 ('GRN_PHOTO_LINE_GONE', pg_temp.gm_mark(:'staff_claims'::jsonb, :'g'::uuid, 'bad-5', 'item', gen_random_uuid()));
UPDATE public.goodsreceived SET deleted_at = now() WHERE id = :'h'::uuid;
INSERT INTO gm_bad VALUES ('GRN_NOT_FOUND', pg_temp.gm_mark(:'staff_claims'::jsonb, :'h'::uuid, 'bad-6', 'header'));
UPDATE public.goodsreceived SET deleted_at = NULL WHERE id = :'h'::uuid;
SELECT pg_temp.gm_assert((SELECT count(*) = 9 AND bool_and(NOT (answer ? 'raised') AND answer->>'success' = 'false' AND answer::text LIKE '%' || code || '%') FROM gm_bad)
  AND (SELECT count(*) FROM public.grn_missing_photos) = :'n_m3'::bigint,
  'M3: bad input, an unknown or deleted GRN and a line of another GRN are refused by code and write nothing: '
  || (SELECT string_agg(code || ' => ' || left(answer::text, 100), ' | ') FROM gm_bad));
SELECT pg_temp.gm_assert(pg_temp.gm_mark(:'staff_claims'::jsonb, :'h'::uuid, repeat('i', 100), 'header')->>'success' = 'true', 'M3: an id of 100 characters is accepted');
DELETE FROM public.grn_missing_photos WHERE grn_id = :'h'::uuid;

-- ===== M4 / M11. A customer account, also of the GRN's own customer, and a caller with no profile =====
SELECT pg_temp.gm_mark(:'customer_claims'::jsonb, :'g'::uuid, 'cust-1', 'header') AS m4c \gset
SELECT pg_temp.gm_mark(jsonb_build_object('role', 'authenticated', 'sub', gen_random_uuid()), :'g'::uuid, 'nobody-1', 'header') AS m4n \gset
SELECT pg_temp.gm_assert(:'m4c'::jsonb->>'state' = '42501' AND :'m4n'::jsonb->>'state' = '42501' AND pg_temp.gm_n(:'g'::uuid) = 4,
  'M4: a customer account and a caller with no profile are refused (42501) and write nothing: ' || :'m4c' || ' / ' || :'m4n');
SELECT pg_temp.gm_details(:'customer_claims'::jsonb, :'g'::uuid) AS m11 \gset
SELECT pg_temp.gm_assert(:'m11'::jsonb#>'{data,grn,photos_missing}' = '4'::jsonb, 'M11: the GRN''s customer account gets the count: ' || left(:'m11', 400));
SELECT pg_temp.gm_assert(:'m11'::text !~ 'gp-head|gp-line|gp-noline|client_photo_id|reported_by|file_missing',
  'M11: nothing else about the missing photos leaves the server');

-- ===== M10. A deleted line takes its photos, a deleted GRN all of them =====
DELETE FROM warehouse_sync.change_log;
SELECT pg_temp.gm_as(:'admin_claims'::jsonb, format('SELECT public.update_grn(p_grn_id => %L::uuid, p_items => %L::jsonb)', :'g',
  jsonb_build_array(jsonb_build_object('id', :'g_l2', 'item_id', :'item_id', 'item_name', 'Missing Cumin', 'packaging', 'Bag', 'qty', 3, 'weight', 10, 'rack', 'N2', 'package_mark', 'N2')))) AS m10e \gset
SELECT pg_temp.gm_assert(:'m10e'::jsonb->>'success' = 'true' AND pg_temp.gm_ids(:'g'::uuid) = 'gp-head,gp-line2,gp-noline'
  AND pg_temp.gm_details(:'staff_claims'::jsonb, :'g'::uuid)#>'{data,grn,photos_missing}' = '3'::jsonb,
  'M10: deleting a line removes that line''s photo only: ' || pg_temp.gm_ids(:'g'::uuid) || ' / ' || :'m10e');
SELECT pg_temp.gm_assert(EXISTS (SELECT 1 FROM warehouse_sync.change_log WHERE tbl = 'goodsreceived' AND row_key = :'g'), 'M10: the line delete logs the GRN');
-- A row removed on its own logs its GRN too.
DELETE FROM warehouse_sync.change_log;
DELETE FROM public.grn_missing_photos WHERE grn_id = :'g'::uuid AND client_photo_id = 'gp-noline';
SELECT pg_temp.gm_assert((SELECT count(*) = 1 AND bool_and(tbl = 'goodsreceived' AND row_key = :'g' AND op = 'U') FROM warehouse_sync.change_log), 'M10: a removed row logs its GRN as an update');
DELETE FROM warehouse_sync.change_log;
SELECT pg_temp.gm_as(:'admin_claims'::jsonb, format('SELECT public.delete_grn_safe(%L::uuid)', :'g')) AS m10d \gset
SELECT pg_temp.gm_assert(:'m10d'::jsonb->>'success' = 'true' AND pg_temp.gm_n(:'g'::uuid) = 0, 'M10: deleting the GRN removes its rows: ' || :'m10d');
SELECT pg_temp.gm_assert((SELECT count(*) = 1 AND bool_and(op = 'D') FROM warehouse_sync.change_log WHERE tbl = 'goodsreceived' AND row_key = :'g'),
  'M10: the log keeps the GRN''s delete (D), the cascade does not turn it into an update');

-- ===== M5. Held, accepted, then marked missing: counted on the GRN the accept made =====
SELECT pg_temp.gm_hold(:'staff_claims'::jsonb, jsonb_build_array(pg_temp.gm_item('gm-a', 'newGrn', 10, :'ca'::uuid, pg_temp.gm_body(:'ca'::uuid, :'item_id'::uuid, 'GMA1'))));
SELECT pg_temp.gm_hid('gm-a') AS ha \gset
SELECT pg_temp.gm_reg_put(:'staff_claims'::jsonb, :'ha'::uuid, 'a-late', 'header');
SELECT pg_temp.gm_reg_put(:'staff_claims'::jsonb, :'ha'::uuid, 'a-ok', 'header');
SELECT pg_temp.gm_accept(:'admin_claims'::jsonb, 'gm-a') AS a \gset
SELECT pg_temp.gm_assert(pg_temp.gm_n(:'a'::uuid) = 0, 'M5: pending photos are not counted');
SELECT pg_temp.gm_held_mark(:'staff_claims'::jsonb, :'ha'::uuid, 'a-late', 'header');
SELECT pg_temp.gm_assert((SELECT count(*) = 1 AND bool_and(client_photo_id = 'a-late' AND source = 'held' AND role = 'header' AND reason = 'file_missing'
    AND reported_by = :'staff_profile'::uuid) FROM public.grn_missing_photos WHERE grn_id = :'a'::uuid)
  AND pg_temp.gm_details(:'staff_claims'::jsonb, :'a'::uuid)#>'{data,grn,photos_missing}' = '1'::jsonb, 'M5: a held photo marked missing after the accept is counted');

-- ===== M7. A missing held photo confirmed late: the count drops, and a row of the ordinary path with that id goes too =====
SELECT pg_temp.gm_as(:'staff_claims'::jsonb, format('SELECT public.confirm_held_photo_upload(%L::uuid, %L)', :'ha', 'a-late')) AS m7 \gset
SELECT pg_temp.gm_assert(:'m7'::jsonb->>'success' = 'true' AND pg_temp.gm_n(:'a'::uuid) = 0, 'M7: the late confirm removes the held row: ' || :'m7');
SELECT pg_temp.gm_assert(pg_temp.gm_mark(:'staff_claims'::jsonb, :'a'::uuid, 'a-ok', 'header')->>'success' = 'true' AND pg_temp.gm_n(:'a'::uuid) = 1, 'M7: premise: the same id reported by the ordinary path');
SELECT pg_temp.gm_as(:'staff_claims'::jsonb, format('SELECT public.confirm_held_photo_upload(%L::uuid, %L)', :'ha', 'a-ok')) AS m7b \gset
SELECT pg_temp.gm_assert(:'m7b'::jsonb->>'success' = 'true' AND pg_temp.gm_n(:'a'::uuid) = 0, 'M7: a late confirm removes an unsent row of that id too: ' || :'m7b');

-- ===== M6. Held, marked missing, then accepted: the item and a follower photos item =====
SELECT pg_temp.gm_hold(:'staff_claims'::jsonb, jsonb_build_array(
  pg_temp.gm_item('gm-b', 'newGrn', 20, :'ca'::uuid, pg_temp.gm_body(:'ca'::uuid, :'item_id'::uuid, 'GMB1')),
  pg_temp.gm_item('gm-bp', 'photos', 21, :'ca'::uuid, '{"doc":"grn"}', jsonb_build_object('follows_key', 'gm-b', 'refusal', NULL))));
SELECT pg_temp.gm_hid('gm-b') AS hb, pg_temp.gm_hid('gm-bp') AS hbp \gset
SELECT pg_temp.gm_held_mark(:'staff_claims'::jsonb, :'hb'::uuid, 'b-head', 'header');
SELECT pg_temp.gm_held_mark(:'staff_claims'::jsonb, :'hb'::uuid, 'b-line', 'item', 'index:1');
SELECT pg_temp.gm_held_mark(:'staff_claims'::jsonb, :'hbp'::uuid, 'bp-head', 'header');
SELECT pg_temp.gm_held_mark(:'staff_claims'::jsonb, :'hbp'::uuid, 'bp-line', 'item', 'index:0');
SELECT pg_temp.gm_assert((SELECT count(*) = 0 FROM public.grn_missing_photos WHERE client_photo_id IN ('b-head', 'b-line', 'bp-head', 'bp-line')),
  'M6: nothing is counted while the item is held');
SELECT pg_temp.gm_accept(:'admin_claims'::jsonb, 'gm-b') AS b \gset
SELECT pg_temp.gm_assert((SELECT state = 'accepted' FROM public.held_items WHERE id = :'hbp'::uuid), 'M6: premise: the follower is accepted with its parent');
SELECT pg_temp.gm_assert(pg_temp.gm_ids(:'b'::uuid) = 'b-head,b-line,bp-head,bp-line'
  AND pg_temp.gm_details(:'staff_claims'::jsonb, :'b'::uuid)#>'{data,grn,photos_missing}' = '4'::jsonb,
  'M6: the photos of the item and of its follower marked before the accept are counted: ' || pg_temp.gm_ids(:'b'::uuid));
SELECT pg_temp.gm_assert((SELECT grn_item_id = pg_temp.gm_line(:'b'::uuid, 'N2') FROM public.grn_missing_photos WHERE grn_id = :'b'::uuid AND client_photo_id = 'b-line')
  AND (SELECT grn_item_id = pg_temp.gm_line(:'b'::uuid, 'N1') FROM public.grn_missing_photos WHERE grn_id = :'b'::uuid AND client_photo_id = 'bp-line'),
  'M6: a line photo (index:<n>) lands on the saved line, the follower''s too');

-- ===== M12. The backfill's helper counts an accepted item's missing photos again, once =====
DELETE FROM public.grn_missing_photos WHERE grn_id = :'b'::uuid;
SELECT warehouse_security.grn_missing_from_held(x.id) FROM public.held_items x WHERE x.state = 'accepted' AND x.kind IN ('newGrn', 'photos');
SELECT warehouse_security.grn_missing_from_held(x.id) FROM public.held_items x WHERE x.state = 'accepted' AND x.kind IN ('newGrn', 'photos');
SELECT pg_temp.gm_assert(pg_temp.gm_ids(:'b'::uuid) = 'b-head,b-line,bp-head,bp-line' AND pg_temp.gm_n(:'a'::uuid) = 0,
  'M12: the backfill statement counts each accepted missing photo once, and no confirmed one: ' || pg_temp.gm_ids(:'b'::uuid));

-- A line deleted by a later edit stops counting, and a later change of another held photo does not bring it back.
SELECT pg_temp.gm_line(:'b'::uuid, 'N1') AS b_l1, pg_temp.gm_line(:'b'::uuid, 'N2') AS b_l2 \gset
SELECT pg_temp.gm_as(:'admin_claims'::jsonb, format('SELECT public.update_grn(p_grn_id => %L::uuid, p_items => %L::jsonb)', :'b',
  jsonb_build_array(jsonb_build_object('id', :'b_l1', 'item_id', :'item_id', 'item_name', 'Missing Cumin', 'packaging', 'Bag', 'qty', 2, 'weight', 10, 'rack', 'N1', 'package_mark', 'NM')))) AS m10h \gset
SELECT pg_temp.gm_held_mark(:'staff_claims'::jsonb, :'hb'::uuid, 'b-after', 'header');
SELECT pg_temp.gm_assert(:'m10h'::jsonb->>'success' = 'true' AND pg_temp.gm_ids(:'b'::uuid) = 'b-after,b-head,bp-head,bp-line',
  'M10: the deleted line''s held photo stays uncounted after the item''s photos are read again: ' || pg_temp.gm_ids(:'b'::uuid) || ' / ' || :'m10h');

-- ===== M8. line_gone and document_gone are not counted; one photo by both paths counts once =====
SELECT pg_temp.gm_hold(:'staff_claims'::jsonb, jsonb_build_array(pg_temp.gm_item('gm-c', 'newGrn', 30, :'ca'::uuid, pg_temp.gm_body(:'ca'::uuid, :'item_id'::uuid, 'GMC1'))));
SELECT pg_temp.gm_hid('gm-c') AS hc \gset
SELECT pg_temp.gm_held_mark(:'staff_claims'::jsonb, :'hc'::uuid, 'c-lg-before', 'header', NULL, 'line_gone');
SELECT pg_temp.gm_held_mark(:'staff_claims'::jsonb, :'hc'::uuid, 'c-dg-before', 'header', NULL, 'document_gone');
SELECT pg_temp.gm_accept(:'admin_claims'::jsonb, 'gm-c') AS c \gset
SELECT pg_temp.gm_held_mark(:'staff_claims'::jsonb, :'hc'::uuid, 'c-lg-after', 'item', 'index:0', 'line_gone');
SELECT pg_temp.gm_held_mark(:'staff_claims'::jsonb, :'hc'::uuid, 'c-dg-after', 'header', NULL, 'document_gone');
SELECT pg_temp.gm_assert(pg_temp.gm_n(:'c'::uuid) = 0, 'M8: line_gone and document_gone are not counted, before or after the accept: ' || pg_temp.gm_ids(:'c'::uuid));
SELECT pg_temp.gm_held_mark(:'staff_claims'::jsonb, :'hc'::uuid, 'c-both', 'header', NULL, 'invalid');
SELECT pg_temp.gm_assert(pg_temp.gm_mark(:'staff_claims'::jsonb, :'c'::uuid, 'c-both', 'header', NULL, 'file_missing')->>'success' = 'true'
  AND (SELECT count(*) = 1 AND bool_and(client_photo_id = 'c-both' AND source = 'held' AND reason = 'invalid') FROM public.grn_missing_photos WHERE grn_id = :'c'::uuid),
  'M8: the same photo reported by both paths is one row: ' || pg_temp.gm_ids(:'c'::uuid));
-- A held mark after the GRN is deleted writes nothing and does not fail.
SELECT pg_temp.gm_assert(pg_temp.gm_as(:'admin_claims'::jsonb, format('SELECT public.delete_grn_safe(%L::uuid)', :'c'))->>'success' = 'true', 'fixture: delete the GRN of gm-c');
SELECT pg_temp.gm_held_mark(:'staff_claims'::jsonb, :'hc'::uuid, 'c-gone', 'header');
SELECT pg_temp.gm_assert(pg_temp.gm_n(:'c'::uuid) = 0, 'M10: a held mark after the GRN''s delete counts nothing');

-- ===== M13. Grants: the table and the helpers are closed to the app's roles =====
SELECT pg_temp.gm_assert(NOT EXISTS (SELECT 1 FROM unnest(ARRAY['anon', 'authenticated', 'service_role']) r
    CROSS JOIN unnest(ARRAY['SELECT', 'INSERT', 'UPDATE', 'DELETE']) p WHERE has_table_privilege(r, 'public.grn_missing_photos', p))
  AND (SELECT relrowsecurity FROM pg_class WHERE oid = 'public.grn_missing_photos'::regclass), 'M13: no app role reads or writes grn_missing_photos; row security is on');
SELECT pg_temp.gm_assert(NOT EXISTS (SELECT 1 FROM unnest(ARRAY['anon', 'authenticated', 'service_role']) r CROSS JOIN unnest(ARRAY[
    'warehouse_security.grn_photos_missing(uuid)', 'warehouse_sync.grn_photos_missing_part(uuid)', 'warehouse_security.grn_missing_from_held(uuid)']) f
    WHERE has_function_privilege(r, f, 'EXECUTE'))
  AND NOT has_function_privilege('anon', 'public.mark_grn_photo_missing(uuid,text,text,uuid,text)', 'EXECUTE')
  AND has_function_privilege('authenticated', 'public.mark_grn_photo_missing(uuid,text,text,uuid,text)', 'EXECUTE')
  AND has_function_privilege('service_role', 'public.mark_grn_photo_missing(uuid,text,text,uuid,text)', 'EXECUTE'),
  'M13: the helpers run for no app role; the report is for signed-in accounts and the service role');
\echo 'WH-385 GRN missing photos (M1 to M13) checks passed.'
ROLLBACK;
