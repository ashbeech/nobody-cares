-- ================================================================
-- NOBODY CARES — v4 Radar Migration
-- ================================================================
--
-- Adds capture_lat and capture_lng to get_nearby_content() return type
-- so the iOS client can compute bearing and plot content on the dev radar.
--
-- PostgreSQL cannot change a function's return type via CREATE OR REPLACE.
-- We must DROP the old function first, then CREATE the new one.
--
-- Idempotent — safe to re-run.
-- ================================================================

-- Step 1: Drop the existing function (must match the exact parameter signature)
DROP FUNCTION IF EXISTS get_nearby_content(
    DOUBLE PRECISION,
    DOUBLE PRECISION,
    DOUBLE PRECISION,
    UUID,
    INTEGER,
    INTEGER
);

-- Step 2: Recreate with capture_lat + capture_lng in the return table
CREATE FUNCTION get_nearby_content(
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
    capture_lat DOUBLE PRECISION,
    capture_lng DOUBLE PRECISION,
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
        ST_Y(c.capture_point::geometry) AS capture_lat,
        ST_X(c.capture_point::geometry) AS capture_lng,
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
