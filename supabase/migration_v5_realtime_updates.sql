-- ================================================================
-- NOBODY CARES — v5 Realtime UPDATE Events Migration
-- ================================================================
--
-- Run AFTER migration_v4_radar.sql.
--
-- Problem:
--   Content is created via a two-phase flow:
--     1. INSERT with is_deleted = true  (upload slot reserved)
--     2. UPDATE setting is_deleted = false  (upload-confirm activates it)
--
--   The Realtime subscription only listened for INSERT events.
--   INSERT fires when the content is still invisible (is_deleted = true).
--   The activation UPDATE was never detected, so nearby stationary users
--   would not see new content until their next periodic refresh or movement.
--
-- Fixes:
--   1. Set REPLICA IDENTITY FULL on the content table so that Realtime
--      UPDATE events include all columns (required for server-side
--      filtering on cell_id and client-side is_deleted checks).
--   2. Ensure the content table is in the supabase_realtime publication
--      so Postgres Changes are broadcast for INSERT + UPDATE events.
--
-- Both statements are idempotent — safe to re-run.
-- ================================================================


-- ================================================================
-- 1. REPLICA IDENTITY FULL
-- ================================================================
-- Supabase Realtime requires FULL replica identity for UPDATE and DELETE
-- events to include all row columns. Without this, server-side filters
-- (e.g., cell_id matching) may not work for UPDATE events, and the
-- client cannot inspect the new is_deleted value.
--
-- Setting FULL when it's already FULL is a harmless no-op.

ALTER TABLE content REPLICA IDENTITY FULL;


-- ================================================================
-- 2. Ensure content table is in the Realtime publication
-- ================================================================
-- Supabase Realtime reads from the `supabase_realtime` publication.
-- If the content table is not a member, no Postgres Change events
-- are emitted for it at all (INSERT or UPDATE).
--
-- This is idempotent: skips if the table is already published.

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_publication_tables
        WHERE pubname = 'supabase_realtime' AND tablename = 'content'
    ) THEN
        ALTER PUBLICATION supabase_realtime ADD TABLE content;
    END IF;
END;
$$;
