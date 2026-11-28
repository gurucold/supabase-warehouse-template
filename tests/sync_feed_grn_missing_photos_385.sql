-- WH-385, feed side (contract app-missing-photo-note.md B9 and B11): the goodsreceived row of the change feed carries photos_missing only
-- when it is above 0, for administrators, staff and the GRN's customer account; a report, a repeat and a removed line reach the phones as
-- the contract says; the daily checksums match the copy. tests/migrations.sh pipes tests/sync_feed_contract.sql in front of this file, in
-- the sync feed database; this file commits. Fictional data only.
\set ON_ERROR_STOP on

INSERT INTO public.user_profiles(auth_user_id, mobile, name, role, active, enrollment_status) VALUES
 (gen_random_uuid(), '919888886862', 'Missing Feed Staff', 'staff', true, 'approved'),
 (gen_random_uuid(), '919888886863', 'Missing Feed Reader', 'customer', true, 'approved');
SELECT pg_temp.sf_login('9888886862') AS staff_claims \gset
SELECT pg_temp.sf_login('9888886863') AS reader_claims \gset
SELECT pg_temp.sf_assert(pg_temp.sf_as(:'sf_admin_claims'::jsonb, 'SELECT public.create_customer(''Missing Feed North'', ''9888886871'')')->>'success' = 'true', 'customer');
SELECT pg_temp.sf_assert(pg_temp.sf_as(:'sf_admin_claims'::jsonb, 'SELECT public.create_item(''Missing Feed Onions'', ''Bag'')')->>'success' = 'true', 'item');
SELECT id AS north FROM public.customers WHERE name = 'Missing Feed North' \gset
SELECT id AS onions FROM public.items WHERE name = 'Missing Feed Onions' \gset
SELECT pg_temp.sf_assert(pg_temp.sf_as(:'sf_admin_claims'::jsonb, format('SELECT to_jsonb(public.assign_customer_to_user(%L, %L::uuid, %L))', '919888886863', :'north', 'Missing feed fixture'))::text = 'true',
  'customer account assigned');
SELECT pg_temp.sf_save_grn(:'sf_admin_claims'::jsonb, 'MPF1', :'north'::uuid, pg_temp.sf_lines(:'onions'::uuid, 2, 'MPA')) AS g1 \gset
SELECT pg_temp.sf_save_grn(:'sf_admin_claims'::jsonb, 'MPF2', :'north'::uuid, pg_temp.sf_lines(:'onions'::uuid, 1, 'MPB')) AS g2 \gset
SELECT id AS l1 FROM public.goodsreceived_trl WHERE gr_id = :'g1'::uuid AND package_mark = 'MPA1' \gset

SELECT pg_temp.sf_phone('admin', :'sf_admin_claims'::jsonb);
SELECT pg_temp.sf_phone('staff', :'staff_claims'::jsonb);
SELECT pg_temp.sf_phone('reader', :'reader_claims'::jsonb);
SELECT pg_temp.sf_first_load(p) FROM unnest(ARRAY['admin', 'staff', 'reader']) p;
-- B9: a GRN with none has no key at all.
SELECT pg_temp.sf_assert((SELECT count(*) = 2 AND bool_and(NOT row ? 'photos_missing') FROM pg_temp.sf_copy WHERE slot = p AND e = 'goodsreceived' AND id IN (:'g1', :'g2')),
  'B9: a GRN with no missing photo has no photos_missing key on ' || p || '''s phone') FROM unnest(ARRAY['admin', 'staff', 'reader']) p;
SELECT v AS g2_v FROM pg_temp.sf_copy WHERE slot = 'staff' AND e = 'goodsreceived' AND id = :'g2' \gset

-- The report reaches every phone as an upsert of the GRN with the count.
SELECT pg_temp.sf_assert(pg_temp.sf_as(:'staff_claims'::jsonb, format('SELECT public.mark_grn_photo_missing(%L::uuid, %L, %L)', :'g1', 'mpf-head', 'header'))->>'success' = 'true', 'fixture: report one');
SELECT pg_temp.sf_assert(pg_temp.sf_as(:'staff_claims'::jsonb, format('SELECT public.mark_grn_photo_missing(%L::uuid, %L, %L, %L::uuid)', :'g1', 'mpf-line', 'item', :'l1'))->>'success' = 'true', 'fixture: report two');
SELECT pg_temp.sf_pull(p) FROM unnest(ARRAY['admin', 'staff', 'reader']) p;
SELECT pg_temp.sf_assert((SELECT row->'photos_missing' = '2'::jsonb FROM pg_temp.sf_copy WHERE slot = p AND e = 'goodsreceived' AND id = :'g1')
  AND pg_temp.sf_ops(p, 'goodsreceived', :'g1', pg_temp.sf_last_pull(p)) = 'upsert',
  'B9: ' || p || ' receives the GRN after the report, with photos_missing 2') FROM unnest(ARRAY['admin', 'staff', 'reader']) p;
SELECT pg_temp.sf_assert((SELECT NOT row ? 'photos_missing' AND v = :'g2_v' FROM pg_temp.sf_copy WHERE slot = 'staff' AND e = 'goodsreceived' AND id = :'g2'),
  'B9: the other GRN''s row and checksum value are unchanged');
SELECT pg_temp.sf_assert(pg_temp.sf_diff(p) = '', 'B9: the copy of ' || p || ' equals a fresh load: ' || pg_temp.sf_diff(p)) FROM unnest(ARRAY['admin', 'staff', 'reader']) p;
SELECT pg_temp.sf_assert(pg_temp.sf_check_direct('staff') = '', 'B9: the staff copy equals the direct reads plus the agreed keys: ' || pg_temp.sf_check_direct('staff'));
-- B11: the customer account gets the integer and no other new key, and nothing about the photos.
SELECT pg_temp.sf_assert(pg_temp.sf_check_direct('reader', pg_temp.sf_list('q1_customer_hidden_columns'), true) = '',
  'B11: the customer''s copy equals its direct reads plus photos_missing: ' || pg_temp.sf_check_direct('reader', pg_temp.sf_list('q1_customer_hidden_columns'), true));
SELECT pg_temp.sf_assert(NOT EXISTS (SELECT 1 FROM pg_temp.sf_copy WHERE slot = 'reader' AND row::text ~ 'mpf-head|mpf-line|client_photo_id|reported_by'),
  'B11: no photo id or reporter is in the customer''s copy');

-- The daily checksums agree with the copy that holds the new key.
SELECT position AS pos, copy AS ck FROM pg_temp.sf_device WHERE phone = 'reader' \gset
SELECT pg_temp.sf_as(:'reader_claims'::jsonb, format(pg_temp.sf('call_checksums'), :'pos', :'ck')) AS sums \gset
SELECT pg_temp.sf_assert((SELECT count(*) = 1 AND bool_and((s->>pg_temp.sf('f_settled'))::boolean
      AND (s->>pg_temp.sf('f_count'))::bigint = (SELECT count(*) FROM pg_temp.sf_copy c WHERE c.slot = 'reader' AND c.e = 'goodsreceived')
      AND (s->>pg_temp.sf('f_sum'))::numeric = (SELECT COALESCE(sum(('x' || lpad(left(c.v, 15), 16, '0'))::bit(64)::bigint::numeric), 0) % 1152921504606846976
            FROM pg_temp.sf_copy c WHERE c.slot = 'reader' AND c.e = 'goodsreceived'))
    FROM jsonb_array_elements(:'sums'::jsonb->pg_temp.sf('f_entities')) s WHERE s->>pg_temp.sf('f_e') = 'goodsreceived'),
  'B9: the goodsreceived checksum matches the copy after the sync: ' || left(:'sums', 400));

-- A repeat sends nothing.
SELECT pg_temp.sf_assert(pg_temp.sf_as(:'staff_claims'::jsonb, format('SELECT public.mark_grn_photo_missing(%L::uuid, %L, %L)', :'g1', 'mpf-head', 'header'))->>'success' = 'true', 'fixture: repeat');
SELECT pg_temp.sf_pull('staff');
SELECT pg_temp.sf_assert(pg_temp.sf_ops('staff', 'goodsreceived', :'g1', pg_temp.sf_last_pull('staff')) = '', 'B9: a repeated report changes nothing on the phone');
-- A deleted line takes its photo: the count drops on the phones.
SELECT pg_temp.sf_update_grn(:'sf_admin_claims'::jsonb, :'g1'::uuid,
  (SELECT jsonb_agg(x) FROM jsonb_array_elements(pg_temp.sf_current_lines(:'g1'::uuid)) x WHERE x->>'id' <> :'l1'), :'north'::uuid) AS edited \gset
SELECT pg_temp.sf_pull(p) FROM unnest(ARRAY['admin', 'staff', 'reader']) p;
SELECT pg_temp.sf_assert((SELECT row->'photos_missing' = '1'::jsonb FROM pg_temp.sf_copy WHERE slot = p AND e = 'goodsreceived' AND id = :'g1') AND pg_temp.sf_diff(p) = '',
  'B10: ' || p || ' holds photos_missing 1 after the line is deleted') FROM unnest(ARRAY['admin', 'staff', 'reader']) p;
-- When the last one goes, the key goes.
DELETE FROM public.grn_missing_photos WHERE grn_id = :'g1'::uuid;
SELECT pg_temp.sf_pull('reader');
SELECT pg_temp.sf_assert((SELECT NOT row ? 'photos_missing' FROM pg_temp.sf_copy WHERE slot = 'reader' AND e = 'goodsreceived' AND id = :'g1') AND pg_temp.sf_diff('reader') = '',
  'B9: with no missing photo left the row has no photos_missing key');
-- A GRN deleted with a missing photo reaches the phones as a delete.
SELECT pg_temp.sf_assert(pg_temp.sf_as(:'staff_claims'::jsonb, format('SELECT public.mark_grn_photo_missing(%L::uuid, %L, %L)', :'g2', 'mpf-two', 'header'))->>'success' = 'true', 'fixture: report on the second GRN');
SELECT pg_temp.sf_pull(p) FROM unnest(ARRAY['admin', 'staff', 'reader']) p;
SELECT pg_temp.sf_assert(pg_temp.sf_as(:'sf_admin_claims'::jsonb, format('SELECT public.delete_grn_safe(%L::uuid)', :'g2'))->>'success' = 'true', 'fixture: delete the second GRN');
SELECT pg_temp.sf_pull(p) FROM unnest(ARRAY['admin', 'staff', 'reader']) p;
SELECT pg_temp.sf_assert(NOT (:'g2' = ANY (pg_temp.sf_held(p, 'goodsreceived'))) AND pg_temp.sf_diff(p) = '', 'B10: the deleted GRN leaves ' || p || '''s phone') FROM unnest(ARRAY['admin', 'staff', 'reader']) p;

\echo 'WH-385 sync feed missing photo count (B9 to B11) checks passed.'
