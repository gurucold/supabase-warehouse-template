-- WH-386, feed side (card "For Test" (d)): after a committed bulk import a phone's next call answers reload_all BULK_IMPORT, and the fresh
-- load holds the imported GRN with its lot and lock facts, although the import logged none of them (the rest of the topic "sync log quiet
-- during bulk import" is tests/import_quiet_log_386.sql). tests/migrations.sh pipes tests/sync_feed_contract.sql in front of this file, in
-- the sync feed database; this file commits. Fictional data only.
\set ON_ERROR_STOP on

INSERT INTO public.user_profiles(auth_user_id, mobile, name, role, active, enrollment_status) VALUES
 (gen_random_uuid(), '919888886882', 'Quiet Feed Staff', 'staff', true, 'approved');
SELECT pg_temp.sf_login('9888886882') AS staff_claims \gset
SELECT pg_temp.sf_assert(pg_temp.sf_as(:'sf_admin_claims'::jsonb, 'SELECT public.create_customer(''Quiet Feed Traders'', ''9888886881'')')->>'success' = 'true', 'customer');
SELECT pg_temp.sf_assert(pg_temp.sf_as(:'sf_admin_claims'::jsonb, 'SELECT public.create_item(''Quiet Feed Potato'', ''Bag'')')->>'success' = 'true', 'item');

SELECT pg_temp.sf_phone('admin', :'sf_admin_claims'::jsonb);
SELECT pg_temp.sf_phone('staff', :'staff_claims'::jsonb);
SELECT pg_temp.sf_first_load(p) FROM unnest(ARRAY['admin', 'staff']) p;

DELETE FROM warehouse_import.stage_grns; DELETE FROM warehouse_import.stage_grn_lines; DELETE FROM warehouse_import.stage_dispatches;
DELETE FROM warehouse_import.stage_dispatch_lines; DELETE FROM warehouse_import.stage_invoices; DELETE FROM warehouse_import.stage_invoice_lines;
DELETE FROM warehouse_import.stage_payments;
INSERT INTO warehouse_import.stage_grns(line,gr_no,gr_date,customer,pricing) VALUES (2,'QF386','2023-05-05','Quiet Feed Traders','MONTHLY');
INSERT INTO warehouse_import.stage_grn_lines(line,gr_no,gr_date,line_no,item,packaging,qty,weight,rack,mark,stock_now) VALUES
 (2,'QF386','2023-05-05',1,'Quiet Feed Potato','Bag',100,50,'A1','QF',40);
INSERT INTO warehouse_import.stage_dispatches(line,disp_no,disp_date,customer) VALUES (2,'QFD386','2023-06-14','Quiet Feed Traders');
INSERT INTO warehouse_import.stage_dispatch_lines(line,disp_no,disp_date,gr_no,gr_date,grn_line,qty) VALUES
 (2,'QFD386','2023-06-14','QF386','2023-05-05',1,60);

SELECT log_id AS log_before FROM warehouse_sync.state \gset
SELECT pg_temp.sf_try('service_role', '{"role":"service_role"}'::jsonb, 'SELECT public.import_history(''{}''::jsonb, true)') AS imported \gset
SELECT pg_temp.sf_assert(:'imported'::jsonb#>>'{answer,success}' = 'true' AND :'imported'::jsonb#>>'{answer,applied}' = 'true', 'fixture: the import applies: ' || :'imported');
SELECT id AS grn FROM public.goodsreceived WHERE gr_no = 'QF386' AND import_batch_id IS NOT NULL \gset
SELECT id AS lot FROM public.goodsreceived_trl WHERE gr_id = :'grn'::uuid \gset
SELECT pg_temp.sf_assert((SELECT log_id <> :'log_before'::uuid AND log_id_reason = 'BULK_IMPORT' FROM warehouse_sync.state), '386d: the committed import rotated the log (BULK_IMPORT)');
SELECT pg_temp.sf_assert(NOT EXISTS (SELECT 1 FROM warehouse_sync.change_log WHERE grn_id = :'grn'::uuid OR row_key IN (:'grn', :'lot')),
  '386d: the import logged nothing about the imported GRN');

SELECT pg_temp.sf_pull(p) AS ignored FROM unnest(ARRAY['admin', 'staff']) p;
SELECT pg_temp.sf_assert((SELECT count(*) = 1 FROM pg_temp.sf_event WHERE phone = p AND pull = pg_temp.sf_last_pull(p) AND kind = 'reload_all' AND detail = pg_temp.sf('r_bulk')),
  '386d: the next call of ' || p || '''s phone answers reload_all BULK_IMPORT') FROM unnest(ARRAY['admin', 'staff']) p;
SELECT pg_temp.sf_assert(:'grn' = ANY (pg_temp.sf_held(p, 'goodsreceived')) AND :'lot' = ANY (pg_temp.sf_held(p, 'goodsreceived_trl'))
  AND (SELECT (row->>'stock')::int = 40 AND row ? 'item_rate' FROM pg_temp.sf_copy WHERE slot = p AND e = 'goodsreceived_trl' AND id = :'lot')
  AND (SELECT (row->>'imported')::boolean FROM pg_temp.sf_copy WHERE slot = p AND e = pg_temp.sf('e_grn_lock') AND id = :'grn'),
  '386d: the reloaded copy of ' || p || ' holds the imported GRN, its lot with its rate key and stock, and its lock facts') FROM unnest(ARRAY['admin', 'staff']) p;
SELECT pg_temp.sf_assert(pg_temp.sf_diff(p) = '', '386d: the copy of ' || p || ' equals a fresh load: ' || pg_temp.sf_diff(p)) FROM unnest(ARRAY['admin', 'staff']) p;
-- After the import the log is live again: an ordinary save reaches the phone as a change.
SELECT pg_temp.sf_save_grn(:'sf_admin_claims'::jsonb, 'QFA386', (SELECT id FROM public.customers WHERE name = 'Quiet Feed Traders'),
  pg_temp.sf_lines((SELECT id FROM public.items WHERE name = 'Quiet Feed Potato'), 1, 'QFA')) AS after_grn \gset
SELECT pg_temp.sf_pull('staff');
SELECT pg_temp.sf_assert(pg_temp.sf_ops('staff', 'goodsreceived', :'after_grn', pg_temp.sf_last_pull('staff')) = 'upsert'
  AND NOT EXISTS (SELECT 1 FROM pg_temp.sf_event WHERE phone = 'staff' AND pull = pg_temp.sf_last_pull('staff') AND kind = 'reload_all'),
  '386e: a save after the import is logged and reaches the phone without a reload');

\echo 'WH-386 sync feed after a quiet bulk import checks passed.'
