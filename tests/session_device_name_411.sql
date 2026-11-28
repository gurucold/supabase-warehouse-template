-- WH-411, topic "session device name": the phone's own name on its session. Covered: every sign-in path (SMS code, central exchange,
-- central exchange through the facility's own code, break-glass, pairing code) with a name and without one; the name trimmed, cut to 80
-- characters and blank as none; a refresh keeps it; public.set_session_device_name fills a missing name once, never overwrites, acts only
-- on the caller's own session; list_user_sessions returns it beside the user agent; the old signatures and the grants.
-- Labels: N1 sign-in paths, N2 the name's form, N3 refresh, N4 set_session_device_name, N5 the list, N6 signatures and grants.
-- Fictional data; runs only in migrations.sh's disposable, network-disabled database; every fixture row rolls back.
\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.dn_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok,false) THEN RAISE EXCEPTION 'session device name: %',label; END IF; END $$;
-- Calls a statement as the signed-in account with these claims; the answer, or {"raised": message, "state": sqlstate}.
CREATE FUNCTION pg_temp.dn_as(claims jsonb, statement text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE answer jsonb;
BEGIN
  PERFORM set_config('request.jwt.claims', claims::text, true);
  SET LOCAL ROLE authenticated;
  BEGIN EXECUTE statement INTO answer;
  EXCEPTION WHEN OTHERS THEN RESET ROLE; RETURN jsonb_build_object('raised', SQLERRM, 'state', SQLSTATE); END;
  RESET ROLE;
  RETURN answer;
END $$;
CREATE FUNCTION pg_temp.dn_code(phone text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE challenge jsonb;
BEGIN
  UPDATE public.otp_verifications SET created_at = created_at - interval '61 seconds' WHERE phone_number = phone;
  challenge := public.operator_prepare_otp(phone);
  PERFORM pg_temp.dn_assert(challenge->>'success'='true', 'a code is prepared: '||challenge::text);
  PERFORM public.operator_finish_otp((challenge#>>'{data,request_id}')::uuid, true, 'mock-provider-only');
  RETURN challenge#>>'{data,otp_code}';
END $$;
-- The session row of a refresh token.
CREATE FUNCTION pg_temp.dn_row(p_refresh text) RETURNS warehouse_security.refresh_sessions LANGUAGE sql AS $$
  SELECT s FROM warehouse_security.refresh_sessions s WHERE s.token_hash = encode(extensions.digest(p_refresh,'sha256'),'hex') $$;
-- The session a sign-in answer opened: found by the answer's own refresh token, so no other session can stand in for it.
CREATE FUNCTION pg_temp.dn_of(answer jsonb) RETURNS warehouse_security.refresh_sessions LANGUAGE plpgsql AS $$
DECLARE s warehouse_security.refresh_sessions;
BEGIN
  s := pg_temp.dn_row(COALESCE(answer#>>'{data,session,refresh_token}', answer#>>'{session,refresh_token}'));
  PERFORM pg_temp.dn_assert(s.id IS NOT NULL, 'the sign-in answer carries a session that is stored: ' || left(answer::text, 300));
  RETURN s;
END $$;
CREATE FUNCTION pg_temp.dn_claims(p_refresh text) RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_build_object('role','authenticated','sub',(pg_temp.dn_row(p_refresh)).user_id,'session_id',(pg_temp.dn_row(p_refresh)).id) $$;
-- A session made directly, optionally with a name; returns the refresh token.
CREATE FUNCTION pg_temp.dn_in(p_user uuid, p_name text DEFAULT NULL) RETURNS text LANGUAGE sql AS $$
  SELECT warehouse_security.issue_session(p_user, NULL, NULL, 'okhttp/4.9.2', p_name)->>'refresh_token' $$;
CREATE FUNCTION pg_temp.dn_set(claims jsonb, p_name text) RETURNS jsonb LANGUAGE sql AS $$
  SELECT pg_temp.dn_as(claims, format('SELECT public.set_session_device_name(%L)', p_name)) $$;

INSERT INTO warehouse_security.auth_config(key,value) VALUES
 ('jwt_secret','isolated-test-secret-not-for-any-deployment-12345'),
 ('auth_mode','operator'),('demo_auth_enabled','false'),('refresh_grace_seconds','60'),('central_issuer','https://login.association.example.test'),
 ('central_local_code','off'),('central_admin_trust','yes'),
 ('otp_global_hourly_cap','300'),('otp_unknown_hourly_cap','60'),('otp_phone_daily_cap','30'),('otp_trusted_daily_reserve','10')
 ON CONFLICT(key) DO UPDATE SET value=excluded.value;
UPDATE warehouse_security.operator_otp_global_limit SET hourly_count=0,unknown_count=0,window_started=now() WHERE id;
UPDATE public.sms_config SET provider='msg91',production_mode=true,msg91_auth_key='isolated-test-key',
 msg91_template_id='000000000000000000000001',msg91_pe_id='0000000000000000001',msg91_sender_id='DNTEST'
 WHERE id=(SELECT id FROM public.sms_config ORDER BY id DESC LIMIT 1);
SELECT warehouse_security.bootstrap_first_admin('9888886111','Name Administrator') AS admin_user \gset
INSERT INTO public.user_profiles(auth_user_id,mobile,name,role,active,enrollment_status) VALUES
 (gen_random_uuid(),'919888886112','Name Supervisor','supervisor',true,'approved'),
 (gen_random_uuid(),'919888886113','Name Staff','staff',true,'approved'),
 (gen_random_uuid(),'919888886114','Name Customer','customer',true,'approved'),
 (gen_random_uuid(),'919888886115','Name Code Staff','staff',true,'approved'),
 (gen_random_uuid(),'919888886116','Name Leaver','staff',true,'approved');
SELECT auth_user_id AS sup_user, id AS sup_profile FROM public.user_profiles WHERE mobile='919888886112' \gset
SELECT auth_user_id AS staff_user, id AS staff_profile FROM public.user_profiles WHERE mobile='919888886113' \gset
SELECT auth_user_id AS cust_user FROM public.user_profiles WHERE mobile='919888886114' \gset
SELECT auth_user_id AS leaver_user FROM public.user_profiles WHERE mobile='919888886116' \gset
DELETE FROM warehouse_security.refresh_sessions;

-- ===== N1. Every sign-in path, with a name and without =====
-- SMS code: the seven-argument form and the six-argument form an edge function that is not updated calls.
SELECT pg_temp.dn_code('919888886114') AS code1 \gset
SELECT public.operator_verify_otp('919888886114', :'code1', NULL, NULL, '203.0.113.20', 'okhttp/4.9.2', 'Samsung SM-A156E (7F3A)') AS v1 \gset
SELECT pg_temp.dn_assert(:'v1'::jsonb #>> '{data,action}' = 'login' AND (pg_temp.dn_of(:'v1'::jsonb)).device_name = 'Samsung SM-A156E (7F3A)'
  AND (pg_temp.dn_of(:'v1'::jsonb)).user_agent = 'okhttp/4.9.2' AND (pg_temp.dn_of(:'v1'::jsonb)).created_ip = '203.0.113.20'::inet,
  'N1: the SMS code sign-in stores the name beside the address and the user agent: ' || :'v1');
SELECT pg_temp.dn_code('919888886114') AS code2 \gset
SELECT public.operator_verify_otp('919888886114', :'code2', NULL, NULL, '203.0.113.21', 'okhttp/4.9.2') AS v2 \gset
SELECT pg_temp.dn_assert(:'v2'::jsonb #>> '{data,action}' = 'login' AND (pg_temp.dn_of(:'v2'::jsonb)).device_name IS NULL
  AND (pg_temp.dn_of(:'v2'::jsonb)).user_agent = 'okhttp/4.9.2', 'N1: the six-argument code sign-in signs in with no name: ' || :'v2');

-- Central exchange: eleven arguments, then ten.
SELECT public.operator_central_exchange('https://login.association.example.test', 'central-user-0411a', '919888886114', 'token-id-0000000000411001',
  now() + interval '5 minutes', NULL, NULL, '203.0.113.30', NULL, 'okhttp/4.9.2', 'Redmi Note 12 (0B1C)') AS e1 \gset
SELECT pg_temp.dn_assert(:'e1'::jsonb #>> '{data,action}' = 'login' AND (pg_temp.dn_of(:'e1'::jsonb)).device_name = 'Redmi Note 12 (0B1C)',
  'N1: the central exchange stores the name: ' || :'e1');
SELECT public.operator_central_exchange('https://login.association.example.test', 'central-user-0411a', '919888886114', 'token-id-0000000000411002',
  now() + interval '5 minutes', NULL, NULL, '203.0.113.31', NULL, 'okhttp/4.9.2') AS e2 \gset
SELECT pg_temp.dn_assert(:'e2'::jsonb #>> '{data,action}' = 'login' AND (pg_temp.dn_of(:'e2'::jsonb)).device_name IS NULL,
  'N1: the ten-argument exchange signs in with no name: ' || :'e2');

-- Central exchange that needs the facility's own code (the profile is not linked yet): the session is made by the code check inside it.
UPDATE warehouse_security.auth_config SET value = 'on' WHERE key = 'central_local_code';
SELECT pg_temp.dn_code('919888886115') AS code3 \gset
SELECT public.operator_central_exchange('https://login.association.example.test', 'central-user-0411b', '919888886115', 'token-id-0000000000411003',
  now() + interval '5 minutes', NULL, NULL, '203.0.113.32', :'code3', 'okhttp/4.9.2', 'Pixel 7a (9D2E)') AS e3 \gset
SELECT pg_temp.dn_assert(:'e3'::jsonb #>> '{data,action}' = 'login' AND (pg_temp.dn_of(:'e3'::jsonb)).device_name = 'Pixel 7a (9D2E)',
  'N1: the exchange through the facility''s code carries the name to the session the code check makes: ' || :'e3');
-- The same person, now linked, with the code still asked.
SELECT pg_temp.dn_code('919888886115') AS code4 \gset
SELECT public.operator_central_exchange('https://login.association.example.test', 'central-user-0411b', '919888886115', 'token-id-0000000000411004',
  now() + interval '5 minutes', NULL, NULL, '203.0.113.33', :'code4', 'okhttp/4.9.2', 'Pixel 7a (4A4A)') AS e4 \gset
SELECT pg_temp.dn_assert(:'e4'::jsonb #>> '{data,action}' = 'login' AND (pg_temp.dn_of(:'e4'::jsonb)).device_name = 'Pixel 7a (4A4A)',
  'N1: the linked exchange with the facility''s code stores the name: ' || :'e4');
SELECT pg_temp.dn_assert((SELECT count(*) >= 2 AND bool_and(s.device_name IS NOT NULL) FROM warehouse_security.refresh_sessions s
    JOIN public.user_profiles p ON p.auth_user_id = s.user_id WHERE p.mobile = '919888886115'),
  'N1: no session those two exchanges made is left without the name');
UPDATE warehouse_security.auth_config SET value = 'off' WHERE key = 'central_local_code';

-- Break-glass: five arguments, then four. A worker's break-glass code typed in the ordinary code screen too.
SELECT (warehouse_security.break_glass_code('9888886112'))->>'code' AS bg1 \gset
SELECT public.operator_break_glass_sign_in('9888886112', :'bg1', '203.0.113.40', 'okhttp/4.9.2', 'Nokia G42 (5C6D)') AS g1 \gset
SELECT pg_temp.dn_assert(:'g1'::jsonb #>> '{data,action}' = 'login' AND (pg_temp.dn_of(:'g1'::jsonb)).device_name = 'Nokia G42 (5C6D)'
  AND (pg_temp.dn_of(:'g1'::jsonb)).hard_expires_at IS NOT NULL, 'N1: the break-glass sign-in stores the name and keeps its end: ' || :'g1');
SELECT (warehouse_security.break_glass_code('9888886112'))->>'code' AS bg2 \gset
SELECT public.operator_break_glass_sign_in('9888886112', :'bg2', '203.0.113.41', 'okhttp/4.9.2') AS g2 \gset
SELECT pg_temp.dn_assert(:'g2'::jsonb #>> '{data,action}' = 'login' AND (pg_temp.dn_of(:'g2'::jsonb)).device_name IS NULL,
  'N1: the four-argument break-glass sign-in signs in with no name: ' || :'g2');
SELECT (warehouse_security.break_glass_code('9888886113'))->>'code' AS bg3 \gset
SELECT public.operator_verify_otp('919888886113', :'bg3', NULL, NULL, '203.0.113.42', 'okhttp/4.9.2', 'Moto G54 (7E8F)') AS g3 \gset
SELECT pg_temp.dn_assert(:'g3'::jsonb #>> '{data,action}' = 'login' AND (pg_temp.dn_of(:'g3'::jsonb)).device_name = 'Moto G54 (7E8F)',
  'N1: a break-glass code in the code sign-in stores the name too: ' || :'g3');

-- Pairing code of a local-only facility: four arguments, then three.
INSERT INTO warehouse_security.auth_config(key,value) VALUES ('ingress_mode','local-only') ON CONFLICT(key) DO UPDATE SET value=excluded.value;
SELECT (warehouse_security.make_pairing_code_for_phone('919888886113'))->>'code' AS pc1 \gset
SELECT public.redeem_pairing_code(:'pc1', '203.0.113.50', 'okhttp/4.9.2', 'Samsung SM-M146B (1122)') AS p1 \gset
SELECT pg_temp.dn_assert(:'p1'::jsonb->>'ok' = 'true' AND (pg_temp.dn_of(:'p1'::jsonb)).device_name = 'Samsung SM-M146B (1122)'
  AND (pg_temp.dn_of(:'p1'::jsonb)).user_agent = 'okhttp/4.9.2', 'N1: the pairing sign-in stores the name: ' || left(:'p1', 200));
SELECT (warehouse_security.make_pairing_code_for_phone('919888886113'))->>'code' AS pc2 \gset
SELECT public.redeem_pairing_code(:'pc2', '203.0.113.51', 'okhttp/4.9.2') AS p2 \gset
SELECT pg_temp.dn_assert(:'p2'::jsonb->>'ok' = 'true' AND (pg_temp.dn_of(:'p2'::jsonb)).device_name IS NULL,
  'N1: the three-argument pairing call signs in with no name: ' || left(:'p2', 200));

-- ===== N2. The name's form: trimmed, cut to 80 characters, blank is none =====
SELECT pg_temp.dn_code('919888886114') AS code5 \gset
SELECT public.operator_verify_otp('919888886114', :'code5', NULL, NULL, NULL, 'okhttp/4.9.2', '  ' || repeat('n', 80) || repeat('z', 20) || '  ') AS f1 \gset
SELECT pg_temp.dn_assert((pg_temp.dn_of(:'f1'::jsonb)).device_name = repeat('n', 80), 'N2: a name of 100 characters is cut to 80, not refused: ' || COALESCE((pg_temp.dn_of(:'f1'::jsonb)).device_name, 'NULL'));
SELECT pg_temp.dn_assert((pg_temp.dn_row(pg_temp.dn_in(:'cust_user'::uuid, '   Spaced Phone (AB12)   '))).device_name = 'Spaced Phone (AB12)', 'N2: surrounding spaces are trimmed');
SELECT pg_temp.dn_assert((pg_temp.dn_row(pg_temp.dn_in(:'cust_user'::uuid, repeat('a', 79) || ' bcd'))).device_name = repeat('a', 79), 'N2: a cut that ends in a space is trimmed again');
SELECT pg_temp.dn_assert((pg_temp.dn_row(pg_temp.dn_in(:'cust_user'::uuid, '      '))).device_name IS NULL
  AND (pg_temp.dn_row(pg_temp.dn_in(:'cust_user'::uuid, ''))).device_name IS NULL, 'N2: a blank or empty name is stored as none');
SELECT pg_temp.dn_assert((SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conname = 'refresh_sessions_device_name_len') LIKE '%80%', 'N2: the length limit is checked by the table');

-- ===== N3. A refresh keeps the name =====
SELECT (pg_temp.dn_of(:'v1'::jsonb)).id AS v1_id \gset
SELECT public.refresh_jwt_token(:'v1'::jsonb #>> '{data,session,refresh_token}') AS r1 \gset
SELECT pg_temp.dn_assert(:'r1'::jsonb->>'success' = 'true' AND (pg_temp.dn_row(:'r1'::jsonb->>'refresh_token')).device_name = 'Samsung SM-A156E (7F3A)'
  AND (pg_temp.dn_row(:'r1'::jsonb->>'refresh_token')).id = :'v1_id'::uuid,
  'N3: a refresh keeps the stored name on the same session: ' || left(:'r1', 200));

-- ===== N4. set_session_device_name =====
SELECT pg_temp.dn_in(:'staff_user'::uuid) AS s1 \gset
SELECT pg_temp.dn_in(:'staff_user'::uuid) AS s2 \gset
SELECT pg_temp.dn_in(:'sup_user'::uuid) AS o1 \gset
SELECT pg_temp.dn_claims(:'s1') AS s1_claims \gset
-- A blank name changes nothing and still answers success.
SELECT pg_temp.dn_set(:'s1_claims'::jsonb, '    ') AS blank \gset
SELECT pg_temp.dn_set(:'s1_claims'::jsonb, NULL) AS nul \gset
SELECT pg_temp.dn_assert(:'blank'::jsonb = '{"success":true}'::jsonb AND :'nul'::jsonb = '{"success":true}'::jsonb AND (pg_temp.dn_row(:'s1')).device_name IS NULL,
  'N4: a blank or missing name changes nothing: ' || :'blank' || ' / ' || :'nul');
SELECT pg_temp.dn_set(:'s1_claims'::jsonb, '  ' || repeat('f', 90) || ' ') AS fill \gset
SELECT pg_temp.dn_assert(:'fill'::jsonb = '{"success":true}'::jsonb AND (pg_temp.dn_row(:'s1')).device_name = repeat('f', 80),
  'N4: a session without a name gets one, trimmed and cut to 80: ' || :'fill');
SELECT pg_temp.dn_assert((pg_temp.dn_row(:'s2')).device_name IS NULL AND (pg_temp.dn_row(:'o1')).device_name IS NULL,
  'N4: only the caller''s own session is named, not the same person''s other session nor another person''s');
SELECT pg_temp.dn_set(:'s1_claims'::jsonb, 'Second Name') AS again \gset
SELECT pg_temp.dn_assert(:'again'::jsonb = '{"success":true}'::jsonb AND (pg_temp.dn_row(:'s1')).device_name = repeat('f', 80), 'N4: a stored name is never overwritten: ' || :'again');
SELECT pg_temp.dn_set(pg_temp.dn_claims(:'r1'::jsonb->>'refresh_token'), 'Other Name') AS signed_in_name \gset
SELECT pg_temp.dn_assert((pg_temp.dn_row(:'r1'::jsonb->>'refresh_token')).device_name = 'Samsung SM-A156E (7F3A)', 'N4: the name given at sign-in is not overwritten: ' || :'signed_in_name');
-- The caller's account with another person's session id names nothing (refused by the gate or ignored by the body).
SELECT pg_temp.dn_set(jsonb_build_object('role','authenticated','sub', :'staff_user', 'session_id', (pg_temp.dn_row(:'o1')).id), 'Stolen Name') AS foreign_s \gset
SELECT pg_temp.dn_assert((pg_temp.dn_row(:'o1')).device_name IS NULL, 'N4: another person''s session cannot be named: ' || :'foreign_s');
-- A customer account names its own session.
SELECT pg_temp.dn_in(:'cust_user'::uuid) AS c1 \gset
SELECT pg_temp.dn_set(pg_temp.dn_claims(:'c1'), 'Customer Phone (C0C0)') AS cust_set \gset
SELECT pg_temp.dn_assert(:'cust_set'::jsonb = '{"success":true}'::jsonb AND (pg_temp.dn_row(:'c1')).device_name = 'Customer Phone (C0C0)', 'N4: a customer account names its own session: ' || :'cust_set');
-- A deactivated account is refused and writes nothing.
SELECT pg_temp.dn_in(:'leaver_user'::uuid) AS l1 \gset
SELECT pg_temp.dn_claims(:'l1') AS leaver_claims \gset
UPDATE public.user_profiles SET active = false WHERE auth_user_id = :'leaver_user'::uuid;
SELECT pg_temp.dn_set(:'leaver_claims'::jsonb, 'Leaver Phone') AS leaver \gset
SELECT pg_temp.dn_assert(:'leaver'::jsonb->>'state' = '42501' AND NOT EXISTS (SELECT 1 FROM warehouse_security.refresh_sessions WHERE device_name = 'Leaver Phone'),
  'N4: a deactivated account is refused: ' || :'leaver');

-- ===== N5. The list returns the name beside the user agent =====
SELECT pg_temp.dn_in(:'admin_user'::uuid, 'Admin Phone (AAAA)') AS a1 \gset
SELECT pg_temp.dn_as(pg_temp.dn_claims(:'a1'), format('SELECT public.list_user_sessions(%L)', :'staff_profile')) AS listed \gset
SELECT pg_temp.dn_assert(:'listed'::jsonb->>'success' = 'true'
  AND (SELECT bool_and(s ? 'device_name' AND s->>'user_agent' = 'okhttp/4.9.2') FROM jsonb_array_elements(:'listed'::jsonb #> '{data,sessions}') s)
  AND EXISTS (SELECT 1 FROM jsonb_array_elements(:'listed'::jsonb #> '{data,sessions}') s WHERE (s->>'id')::uuid = (pg_temp.dn_row(:'s1')).id AND s->>'device_name' = repeat('f', 80))
  AND EXISTS (SELECT 1 FROM jsonb_array_elements(:'listed'::jsonb #> '{data,sessions}') s WHERE (s->>'id')::uuid = (pg_temp.dn_row(:'s2')).id AND s->'device_name' = 'null'::jsonb),
  'N5: each session carries device_name (null when unnamed) beside the unchanged user agent: ' || :'listed');

-- ===== N6. Signatures and grants =====
SELECT pg_temp.dn_assert(to_regprocedure('warehouse_security.issue_session(uuid,uuid,inet,text)') IS NULL
  AND to_regprocedure('public.redeem_pairing_code(text,text,text)') IS NULL, 'N6: the replaced signatures are gone (no ambiguous overload)');
SELECT pg_temp.dn_assert(NOT has_function_privilege('authenticated','warehouse_security.issue_session(uuid,uuid,inet,text,text)','EXECUTE')
  AND NOT has_function_privilege('anon','warehouse_security.issue_session(uuid,uuid,inet,text,text)','EXECUTE'), 'N6: issue_session stays internal');
SELECT pg_temp.dn_assert(NOT EXISTS (SELECT 1 FROM unnest(ARRAY['anon','authenticated']) r, unnest(ARRAY[
   'public.operator_verify_otp(text,text,text,text,inet,text,text)',
   'public.operator_central_exchange(text,text,text,text,timestamptz,text,text,inet,text,text,text)',
   'public.operator_break_glass_sign_in(text,text,inet,text,text)','public.redeem_pairing_code(text,text,text,text)']) f
   WHERE has_function_privilege(r, f, 'EXECUTE'))
  AND (SELECT bool_and(has_function_privilege('service_role', f, 'EXECUTE')) FROM unnest(ARRAY[
   'public.operator_verify_otp(text,text,text,text,inet,text,text)',
   'public.operator_central_exchange(text,text,text,text,timestamptz,text,text,inet,text,text,text)',
   'public.operator_break_glass_sign_in(text,text,inet,text,text)','public.redeem_pairing_code(text,text,text,text)']) f),
  'N6: the new sign-in signatures are for the service role alone');
SELECT pg_temp.dn_assert(NOT has_function_privilege('anon','public.set_session_device_name(text)','EXECUTE')
  AND has_function_privilege('authenticated','public.set_session_device_name(text)','EXECUTE')
  AND has_function_privilege('service_role','public.set_session_device_name(text)','EXECUTE'), 'N6: set_session_device_name is for signed-in accounts');
\echo 'WH-411 session device name (N1 to N6) checks passed.'
ROLLBACK;
