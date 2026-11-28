-- WH-297 / WH-386: the phones' change log is quiet while public.import_history writes, and the import rotates the log at its end.
--
-- Why: the import wrote 4.4 log rows per imported GRN (money marks, lot rate facts, lock facts included) and then rotated the log
-- (BULK_IMPORT), which throws every one of them away: every phone erases its copy and loads again. Measured +68% on the import.
--
-- How it turns on: import_history (migration 192) already sets warehouse.import = 'on' for its own transaction (transaction-local). It now also
-- sets warehouse_sync.quiet = 'on', transaction-local, right beside it, and clears it again (and rotates the log, reason BULK_IMPORT) just
-- before it clears warehouse.import. warehouse_sync.log_change() returns at its first statement when the setting is 'on' AND the session's
-- login role is a superuser (session_user, which a SECURITY DEFINER function and SET ROLE do not change; the import runs as supabase_admin through
-- psql). An ordinary session (PostgREST: authenticator; a staff or service role call) that sets the setting itself is still logged.
--
-- Why it cannot stay on: set_config(..., true) lasts until the end of the transaction, and the import is one transaction (import.mjs: BEGIN ...
-- COMMIT; and a refusal inside import_history rolls its sub-transaction back, setting included). A failed or dry-run import rolls back every row
-- AND the rotation, so there is nothing for a phone to miss. A committed import commits the rotation in the same transaction as the rows: a phone
-- sees the rows and the new log id together, and its next call answers reload_all BULK_IMPORT (the trigger on import_batches rotates at the
-- first insert too; that one stays). A phone reloading erases its money answers and marks (syncEngine clearData) and reads lot rates live
-- (get_sync_page), so the skipped money marks and lot_rate facts are not needed.
--
-- Not changed: the truncate triggers, the import_batches trigger, the money and lot_rate logic, a normal save (one extra setting read, a
-- GUC lookup that finds nothing). No grant, owner, search_path or table changes. scripts/import.mjs is unchanged: it only calls import_history.

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

-- ===== 1. the triggers do nothing while the import is quiet =====
SELECT pg_temp.patch_function('warehouse_sync.log_change()'::regprocedure, ARRAY[
$m$IF TG_OP <> 'INSERT' THEN o := to_jsonb(OLD); END IF;$m$
], ARRAY[
$m$-- WH-386: quiet while import_history runs (its own transaction sets the marker; only a superuser login is believed).
  IF current_setting('warehouse_sync.quiet', true) = 'on'
     AND COALESCE((SELECT r.rolsuper FROM pg_catalog.pg_roles r WHERE r.rolname = session_user), false) THEN
    RETURN NULL;
  END IF;
  IF TG_OP <> 'INSERT' THEN o := to_jsonb(OLD); END IF;$m$
]);

-- ===== 2. the import sets the marker, and clears it and rotates the log at its end =====
SELECT pg_temp.patch_function('public.import_history(jsonb, boolean)'::regprocedure, ARRAY[
$m$PERFORM set_config('warehouse.import', 'on', true);$m$,
$m$PERFORM set_config('warehouse.import', '', true);$m$
], ARRAY[
$m$PERFORM set_config('warehouse.import', 'on', true);
    PERFORM set_config('warehouse_sync.quiet', 'on', true);$m$,
$m$PERFORM set_config('warehouse_sync.quiet', '', true);
    PERFORM warehouse_sync.rotate_log('BULK_IMPORT');
    PERFORM set_config('warehouse.import', '', true);$m$
]);

DROP FUNCTION pg_temp.patch_function(regprocedure, text[], text[]);
