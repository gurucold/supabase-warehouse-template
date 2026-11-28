-- WH-386, topic "sync log quiet during bulk import": while public.import_history writes, the change log stays quiet, and the import rotates
-- the log at its end (reason BULK_IMPORT); a dry run, a refused or a rolled-back import leaves the log and its id as they were; the marker
-- warehouse_sync.quiet never outlives the import; it silences only a superuser's session, so an app session that sets it is still logged;
-- normal writes are logged. (a) to (e) are the cases of the card; the phone's side (d) is tests/sync_feed_import_quiet_386.sql.
-- The one row the import still logs is its own actor profile, written before the marker is set (and discarded by the rotation).
-- Fictional data; runs only in migrations.sh's disposable, network-disabled database; rolls back at the end.
\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.iq_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok,false) THEN RAISE EXCEPTION 'import quiet log: %',label; END IF; END $$;
CREATE FUNCTION pg_temp.iq_login(phone text) RETURNS jsonb LANGUAGE plpgsql AS $$
 DECLARE c jsonb; l jsonb; claims jsonb;
 BEGIN
  c:=public.operator_prepare_otp(phone);
  PERFORM pg_temp.iq_assert(c->>'success'='true','challenge prepared for '||phone);
  PERFORM public.operator_finish_otp((c#>>'{data,request_id}')::uuid,true,'mock-provider-only');
  l:=public.operator_verify_otp(phone,c#>>'{data,otp_code}');
  PERFORM pg_temp.iq_assert(l#>>'{data,action}'='login','login for '||phone);
  SELECT jsonb_build_object('role','authenticated','sub',p.auth_user_id,'session_id',r.id) INTO claims
   FROM public.user_profiles p JOIN warehouse_security.refresh_sessions r ON r.user_id=p.auth_user_id
   WHERE p.mobile=warehouse_security.normalize_phone(phone) ORDER BY r.created_at DESC LIMIT 1;
  RETURN claims;
 END $$;
CREATE FUNCTION pg_temp.iq_as(claims jsonb, statement text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE answer jsonb;
BEGIN
  PERFORM set_config('request.jwt.claims',claims::text,true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  BEGIN EXECUTE statement INTO answer;
  EXCEPTION WHEN OTHERS THEN answer := jsonb_build_object('raised', SQLERRM, 'state', SQLSTATE); END;
  EXECUTE 'RESET ROLE';
  RETURN answer;
END $$;
-- The import as scripts/import.sh calls it: the service role.
CREATE FUNCTION pg_temp.iq_import(apply boolean) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE answer jsonb;
BEGIN
  PERFORM set_config('request.jwt.claims','{"role":"service_role"}',true);
  EXECUTE 'SET LOCAL ROLE service_role';
  BEGIN answer := public.import_history('{}'::jsonb, apply);
  EXCEPTION WHEN OTHERS THEN answer := jsonb_build_object('raised', SQLERRM, 'state', SQLSTATE); END;
  EXECUTE 'RESET ROLE';
  RETURN answer;
END $$;
CREATE FUNCTION pg_temp.iq_marker() RETURNS text LANGUAGE sql AS $$ SELECT COALESCE(current_setting('warehouse_sync.quiet', true), '') $$;
-- What the log holds, besides the import actor's own profile row.
CREATE FUNCTION pg_temp.iq_logged() RETURNS text LANGUAGE sql AS $$
  SELECT COALESCE(string_agg(c.tbl || ':' || c.row_key, ', '), '') FROM warehouse_sync.change_log c
   WHERE NOT (c.tbl = 'user_profiles' AND c.row_key = (SELECT p.id::text FROM public.user_profiles p WHERE p.auth_user_id = '00000000-0000-4000-8000-696d706f7274')) $$;
CREATE FUNCTION pg_temp.iq_logged_customer(p_name text) RETURNS boolean LANGUAGE sql AS $$
  SELECT EXISTS (SELECT 1 FROM warehouse_sync.change_log c JOIN public.customers u ON c.row_key = u.id::text WHERE c.tbl = 'customers' AND u.name = p_name) $$;

INSERT INTO warehouse_security.auth_config(key,value) VALUES
 ('jwt_secret','isolated-test-secret-not-for-any-deployment-12345'),
 ('auth_mode','operator'),('demo_auth_enabled','false')
 ON CONFLICT(key) DO UPDATE SET value=excluded.value;
UPDATE public.sms_config SET provider='msg91',production_mode=true,msg91_auth_key='isolated-test-key',
 msg91_template_id='000000000000000000000001',msg91_pe_id='0000000000000000001',msg91_sender_id='CITEST';
SELECT warehouse_security.bootstrap_first_admin('9888886801','Quiet Import Administrator') AS boot \gset
SELECT pg_temp.iq_login('9888886801') AS admin_claims \gset
INSERT INTO public.customers(name,mobile) VALUES ('Quiet Import Traders','9888886802') RETURNING id AS trader \gset
INSERT INTO public.items(name,packaging) VALUES ('Quiet Import Potato','Bag') RETURNING id AS item_id \gset
SELECT pg_temp.iq_assert(pg_temp.iq_as(:'admin_claims'::jsonb, format($q$SELECT public.replace_item_rates(%L::uuid,NULL,'monthly',(current_date - 700),
  '[{"weight_min":0,"weight_max":100,"unit_price":5,"labour_rate":1,"tax_percent":0}]'::jsonb)$q$, :'item_id'))->>'success'='true', 'fixture: rates');
SELECT pg_temp.iq_assert(pg_temp.iq_as(:'admin_claims'::jsonb, $q$SELECT public.set_record_payments(true)$q$)->>'success'='true', 'fixture: record payments on');
UPDATE warehouse_security.charging_rule SET step_days = 15, minimum_days = 30, days_counted = 'legacy', rounding = 'up', invoice_as_goods_leave = true WHERE id;

-- One GRN, its dispatch, its invoice and a payment: lock facts, lot rate facts and money marks would all be logged outside the quiet.
DELETE FROM warehouse_import.stage_grns; DELETE FROM warehouse_import.stage_grn_lines; DELETE FROM warehouse_import.stage_dispatches;
DELETE FROM warehouse_import.stage_dispatch_lines; DELETE FROM warehouse_import.stage_invoices; DELETE FROM warehouse_import.stage_invoice_lines;
DELETE FROM warehouse_import.stage_payments;
INSERT INTO warehouse_import.stage_grns(line,gr_no,gr_date,customer,pricing) VALUES (2,'A0386','2023-05-05','Quiet Import Traders','MONTHLY');
INSERT INTO warehouse_import.stage_grn_lines(line,gr_no,gr_date,line_no,item,packaging,qty,weight,rack,mark,stock_now) VALUES
 (2,'A0386','2023-05-05',1,'Quiet Import Potato','Bag',100,50,'A1','ET',40);
INSERT INTO warehouse_import.stage_dispatches(line,disp_no,disp_date,customer) VALUES (2,'I0386','2023-06-14','Quiet Import Traders');
INSERT INTO warehouse_import.stage_dispatch_lines(line,disp_no,disp_date,gr_no,gr_date,grn_line,qty) VALUES (2,'I0386','2023-06-14','A0386','2023-05-05',1,60);
INSERT INTO warehouse_import.stage_invoices(line,inv_label,inv_no,inv_prefix,inv_date,customer,gr_no,gr_date,labour,tax,total) VALUES
 (2,'GC/386',386,'GC/','2023-06-20','Quiet Import Traders','A0386','2023-05-05',120.00,0.00,4250.00);
INSERT INTO warehouse_import.stage_invoice_lines(line,inv_label,inv_no,inv_date,item,packaging,qty,disp_no,disp_date,grn_line,months,rate,labour_rate,tax_pct,storage,labour,tax_amount) VALUES
 (2,'GC/386',386,'2023-06-20','Quiet Import Potato','Bag',60,'I0386','2023-06-14',1,1.5,45.00,2.00,0,4130.00,120.00,0.00);
INSERT INTO warehouse_import.stage_payments(line,receipt,pay_date,customer,inv_label,inv_no,inv_date,amount,mode) VALUES
 (2,'IQ-R386','2023-06-30','Quiet Import Traders','GC/386',386,'2023-06-20',3250.00,'Cash');

SELECT warehouse_sync.rotate_log('RESET');
SELECT log_id AS log0 FROM warehouse_sync.state \gset
DELETE FROM warehouse_sync.change_log;

-- ===== (b) A dry run and a rolled-back import leave the log as it was =====
SELECT pg_temp.iq_import(false) AS dry \gset
SELECT pg_temp.iq_assert(:'dry'::jsonb->>'success' = 'true' AND :'dry'::jsonb->>'applied' = 'false', 'fixture: the dry run is clean: ' || :'dry');
SELECT pg_temp.iq_assert((SELECT log_id = :'log0'::uuid AND log_id_reason = 'RESET' FROM warehouse_sync.state) AND (SELECT count(*) = 0 FROM warehouse_sync.change_log),
  '(b) a dry run leaves the log, its id and its reason as they were');
SELECT pg_temp.iq_assert(pg_temp.iq_marker() = '', '(b) the marker is empty after a dry run: ' || pg_temp.iq_marker());
SAVEPOINT rolled;
SELECT pg_temp.iq_assert(pg_temp.iq_import(true)->>'applied' = 'true', 'fixture: an apply that is rolled back');
ROLLBACK TO SAVEPOINT rolled;
SELECT pg_temp.iq_assert((SELECT log_id = :'log0'::uuid AND log_id_reason = 'RESET' FROM warehouse_sync.state) AND (SELECT count(*) = 0 FROM warehouse_sync.change_log)
  AND pg_temp.iq_marker() = '', '(b) a rolled-back import leaves the log and its id as before and the marker empty');

-- ===== (a) A committed import writes no change-log row, and its own end rotates the log =====
-- The batch trigger (which also rotates at the first insert) is off for this apply, so the id can only move by the import's end.
ALTER TABLE warehouse_security.import_batches DISABLE TRIGGER zz_change_feed_import;
SELECT pg_temp.iq_import(true) AS applied \gset
ALTER TABLE warehouse_security.import_batches ENABLE ALWAYS TRIGGER zz_change_feed_import;
SELECT pg_temp.iq_assert(:'applied'::jsonb->>'success' = 'true' AND :'applied'::jsonb->>'applied' = 'true', 'fixture: the import applies: ' || :'applied');
SELECT pg_temp.iq_assert((SELECT count(*) = 1 FROM public.goodsreceived WHERE gr_no = 'A0386') AND (SELECT count(*) = 1 FROM public.dispatch WHERE disp_no = 'I0386')
  AND (SELECT count(*) = 1 FROM public.invoice WHERE inv_no = 386 AND import_batch_id IS NOT NULL) AND (SELECT count(*) = 1 FROM public.payments WHERE import_batch_id IS NOT NULL AND amount = 3250.00),
  'fixture: the GRN, the dispatch, the invoice and the payment were imported');
SELECT pg_temp.iq_assert(pg_temp.iq_logged() = '', '(a) the import logs nothing it writes: ' || left(pg_temp.iq_logged(), 600));
SELECT pg_temp.iq_assert((SELECT log_id <> :'log0'::uuid AND log_id_reason = 'BULK_IMPORT' FROM warehouse_sync.state), '(a) the import rotates the log at its end, reason BULK_IMPORT');
SELECT pg_temp.iq_assert(pg_temp.iq_marker() = '', '(a) the marker is cleared before the call returns: ' || pg_temp.iq_marker());

-- ===== (e) Normal writes are logged again, in the same transaction too =====
SELECT pg_temp.iq_assert(pg_temp.iq_as(:'admin_claims'::jsonb, $q$SELECT public.create_customer('Quiet After Import', '9888886803')$q$)->>'success'='true', 'fixture: a save after the import');
SELECT pg_temp.iq_assert(pg_temp.iq_logged_customer('Quiet After Import'), '(e) a normal save after the import is logged');

-- A refused apply (an imported document changed) leaves the log id, and logging still works.
SELECT log_id AS log1 FROM warehouse_sync.state \gset
UPDATE warehouse_import.stage_invoices SET total = 4251.00 WHERE inv_no = 386;
SELECT pg_temp.iq_import(true) AS refused \gset
SELECT pg_temp.iq_assert(:'refused'::jsonb->>'success' = 'false' AND :'refused'::jsonb->>'applied' = 'false', 'fixture: a changed document is refused: ' || :'refused');
SELECT pg_temp.iq_assert((SELECT log_id = :'log1'::uuid FROM warehouse_sync.state) AND pg_temp.iq_marker() = '', '(b) a refused import leaves the log id and an empty marker');
UPDATE public.customers SET city = 'Quiet City' WHERE id = :'trader'::uuid;
SELECT pg_temp.iq_assert(pg_temp.iq_logged_customer('Quiet Import Traders'), '(e) a write after a refused import is logged');

-- ===== (c) The marker is believed only from a superuser session =====
-- Control: the installer's session (a superuser, as the import connects), also acting through a SECURITY DEFINER call, is silenced by it.
SELECT set_config('warehouse_sync.quiet', 'on', true);
SELECT pg_temp.iq_assert(pg_temp.iq_as(:'admin_claims'::jsonb, $q$SELECT public.create_customer('Quiet Superuser Session', '9888886804')$q$)->>'success'='true', 'fixture: a save with the marker, superuser session');
SELECT pg_temp.iq_assert(NOT pg_temp.iq_logged_customer('Quiet Superuser Session'), '(c) premise: with the marker on, a superuser session''s write is not logged');
-- The app's login (PostgREST's authenticator) sets the same marker and saves: logged.
SELECT set_config('request.jwt.claims', :'admin_claims', true);
SET SESSION AUTHORIZATION authenticator;
SET LOCAL ROLE authenticated;
SELECT set_config('warehouse_sync.quiet', 'on', true);
SELECT session_user AS app_session, public.create_customer('Quiet App Session', '9888886805')->>'success' AS app_saved \gset
RESET ROLE;
RESET SESSION AUTHORIZATION;
SELECT pg_temp.iq_assert(:'app_session' = 'authenticator' AND :'app_saved' = 'true', 'fixture: the save ran in a session of the app''s login: ' || :'app_session');
SELECT pg_temp.iq_assert(pg_temp.iq_logged_customer('Quiet App Session'), '(c) a session that is no superuser sets the marker and its save is still logged');
SELECT set_config('warehouse_sync.quiet', '', true);

\echo 'WH-386 quiet change log during a bulk import checks passed.'
ROLLBACK;
