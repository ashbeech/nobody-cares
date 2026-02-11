-- ================================================================
-- NOBODY CARES — v3 Fixes Migration
-- ================================================================
--
-- Run AFTER migration.sql and migration_v2_security.sql.
--
-- Fixes:
--   1. BUG: blocks.blocker_id missing DEFAULT auth.uid() — blocking is broken
--   2. BUG: reports.reporter_id missing DEFAULT auth.uid() — reporting is broken
--   3. BUG RISK: Two overloaded get_nearby_content functions — PostgREST ambiguity
--   4. CLEANUP: Redundant reports columns (resolved/resolved_at/resolved_by)
--   5. CLEANUP: Redundant blocks_manage policy alongside granular policies
--   6. CLEANUP: blocks FKs lack ON DELETE CASCADE
--   7. PERFORMANCE: Missing indexes on reports.reporter_id, analytics_events
--
-- All statements are idempotent (safe to re-run).
-- ================================================================


-- ================================================================
-- 1. FIX: blocks.blocker_id needs DEFAULT auth.uid()
-- ================================================================
-- Without this, every insert from the client fails with a NOT NULL
-- constraint violation because BlockService only sends blocked_id.

ALTER TABLE blocks ALTER COLUMN blocker_id SET DEFAULT auth.uid();


-- ================================================================
-- 2. FIX: reports.reporter_id needs DEFAULT auth.uid()
-- ================================================================
-- Same issue — ReportView only sends content_id, reason, detail.

ALTER TABLE reports ALTER COLUMN reporter_id SET DEFAULT auth.uid();


-- ================================================================
-- 3. FIX: Drop the dead second get_nearby_content overload
-- ================================================================
-- migration.sql defines get_nearby_content twice with different
-- parameter signatures. PostgreSQL treats them as two separate
-- overloaded functions (not a replacement). The second one
-- (p_lat, p_lng, p_radius, p_limit, p_offset) is never called
-- by any client code and causes PostgREST ambiguity risk.
--
-- Drop it, then update the first (active) function to also
-- exclude banned users (which the second version had).

DROP FUNCTION IF EXISTS get_nearby_content(
    double precision, double precision, double precision, int, int
);

-- Update the active function to also filter banned users
CREATE OR REPLACE FUNCTION get_nearby_content(
    viewer_lat DOUBLE PRECISION,
    viewer_lng DOUBLE PRECISION,
    radius_meters DOUBLE PRECISION DEFAULT 10.0,
    viewer_user_id UUID DEFAULT NULL,
    page_size INTEGER DEFAULT 20,
    page_offset INTEGER DEFAULT 0
)
RETURNS TABLE (
    content_id UUID,
    user_id UUID,
    username TEXT,
    content_type TEXT,
    duration_ms INTEGER,
    media_path TEXT,
    distance_meters DOUBLE PRECISION,
    created_at TIMESTAMPTZ
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    SELECT
        c.id AS content_id,
        c.user_id,
        u.username,
        c.content_type,
        c.duration_ms,
        COALESCE(c.compressed_path, c.original_path) AS media_path,
        ST_Distance(
            c.capture_point,
            ST_SetSRID(ST_MakePoint(viewer_lng, viewer_lat), 4326)::geography
        ) AS distance_meters,
        c.created_at
    FROM content c
    JOIN users u ON c.user_id = u.id
    WHERE c.is_deleted = false
        AND u.is_deleted = false
        AND u.is_banned = false
        AND ST_DWithin(
            c.capture_point,
            ST_SetSRID(ST_MakePoint(viewer_lng, viewer_lat), 4326)::geography,
            radius_meters
        )
        AND (viewer_user_id IS NULL OR c.user_id NOT IN (
            SELECT blocked_id FROM blocks WHERE blocker_id = viewer_user_id
        ))
    ORDER BY c.created_at DESC
    LIMIT page_size
    OFFSET page_offset;
$$;


-- ================================================================
-- 4. CLEANUP: Drop redundant reports columns
-- ================================================================
-- The v1 schema had resolved/resolved_at/resolved_by.
-- The v2 schema added status/reviewed_at/reviewed_by.
-- Both sets exist on the live table. Standardize on v2.

ALTER TABLE reports DROP COLUMN IF EXISTS resolved;
ALTER TABLE reports DROP COLUMN IF EXISTS resolved_at;
ALTER TABLE reports DROP COLUMN IF EXISTS resolved_by;

-- Drop the old index that referenced 'resolved'
DROP INDEX IF EXISTS idx_reports_unresolved;


-- ================================================================
-- 5. CLEANUP: Drop redundant blocks_manage policy
-- ================================================================
-- The v1 schema created blocks_manage (FOR ALL).
-- The v2 schema added granular insert/read/delete policies.
-- Both coexist. Remove the overly broad one.

DROP POLICY IF EXISTS blocks_manage ON blocks;


-- ================================================================
-- 6. FIX: Add ON DELETE CASCADE to blocks FKs
-- ================================================================
-- Without CASCADE, deleting a user row from the Supabase dashboard
-- (or via auth.users cascade) would leave orphaned blocks rows
-- and fail on FK constraints.

DO $$
BEGIN
    -- Drop and recreate blocker_id FK with CASCADE
    IF EXISTS (
        SELECT 1 FROM information_schema.table_constraints
        WHERE table_name = 'blocks' AND constraint_name = 'blocks_blocker_id_fkey'
    ) THEN
        ALTER TABLE blocks DROP CONSTRAINT blocks_blocker_id_fkey;
    END IF;
    ALTER TABLE blocks ADD CONSTRAINT blocks_blocker_id_fkey
        FOREIGN KEY (blocker_id) REFERENCES users(id) ON DELETE CASCADE;

    -- Drop and recreate blocked_id FK with CASCADE
    IF EXISTS (
        SELECT 1 FROM information_schema.table_constraints
        WHERE table_name = 'blocks' AND constraint_name = 'blocks_blocked_id_fkey'
    ) THEN
        ALTER TABLE blocks DROP CONSTRAINT blocks_blocked_id_fkey;
    END IF;
    ALTER TABLE blocks ADD CONSTRAINT blocks_blocked_id_fkey
        FOREIGN KEY (blocked_id) REFERENCES users(id) ON DELETE CASCADE;
END;
$$;


-- ================================================================
-- 7. PERFORMANCE: Missing indexes
-- ================================================================

-- reports.reporter_id — used by reports_read_own RLS policy on every SELECT
CREATE INDEX IF NOT EXISTS idx_reports_reporter ON reports (reporter_id);

-- analytics_events(user_id, event_type) — used by verify-attestation challenge lookup
CREATE INDEX IF NOT EXISTS idx_analytics_user_event
    ON analytics_events (user_id, event_type, created_at DESC);
