-- ================================================================
-- NOBODY CARES — v6 Ephemeral Content Migration
-- ================================================================
--
-- Run AFTER migration_v5_thumbnails.sql. Implements:
--
--   1. 20-MINUTE VISIBILITY DELAY (anti-stalking)
--      Posts appear immediately for the author but are hidden from
--      all other users for 20 minutes. This eliminates the ability
--      to stalk someone's real-time location by watching what they
--      post in the vicinity (e.g. sitting across a café).
--
--   2. 24-HOUR AUTO-EXPIRATION
--      All content is ephemeral — automatically hard-deleted
--      (DB records + CDN/Storage files) after 24 hours.
--      Meaning is captured in the moment, in the place it was taken.
--      Others may experience it, but it's scarce and precious —
--      and completely throwaway.
--
-- FUTURE-PROOFING (likes):
--   When a likes system is added, the design should ensure:
--     • A user's total_likes_received (or equivalent aggregate)
--       is NEVER decremented when content expires.
--     • Individual like rows referencing content can be deleted.
--     • The aggregate metric survives content expiration as part
--       of the user's permanent, anonymous story.
--   Pattern: likes are recorded → aggregate incremented → content
--   expires and is deleted → aggregate stays. The retention is
--   in the anonymous metric, not the content.
--
-- Idempotent — safe to re-run.
--
-- After running, schedule the cleanup:
--   Option A (pg_cron only — deletes DB rows, storage files remain orphaned):
--     SELECT cron.schedule('cleanup-expired-content', '*/15 * * * *',
--            'SELECT cleanup_expired_content()');
--
--   Option B (recommended — pg_cron + pg_net → Edge Function for full cleanup):
--     SELECT cron.schedule(
--       'invoke-cleanup-expired-content',
--       '*/15 * * * *',
--       $$
--       SELECT net.http_post(
--         url := '<SUPABASE_URL>/functions/v1/cleanup-expired-content',
--         headers := jsonb_build_object(
--           'Authorization', 'Bearer <SERVICE_ROLE_KEY>',
--           'Content-Type', 'application/json'
--         ),
--         body := '{}'::jsonb
--       );
--       $$
--     );
--
-- ================================================================


-- ================================================================
-- 1. UPDATE get_nearby_content()
--    Adds: 20-minute visibility delay + 24-hour expiry window
-- ================================================================

-- Must DROP first because PostgreSQL cannot alter return types via
-- CREATE OR REPLACE. Match the exact v5 parameter signature.
DROP FUNCTION IF EXISTS get_nearby_content(
    DOUBLE PRECISION,
    DOUBLE PRECISION,
    DOUBLE PRECISION,
    UUID,
    INTEGER,
    INTEGER
);

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
    thumbnail_path TEXT,
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
        c.thumbnail_path,
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
        -- ── Ephemeral: only show content less than 24 hours old ──
        AND c.created_at > now() - INTERVAL '24 hours'
        -- ── Anti-stalking: author sees own content immediately;
        --    everyone else sees it after a 20-minute delay ──
        AND (
            c.user_id = viewer_user_id
            OR c.created_at <= now() - INTERVAL '20 minutes'
        )
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
-- 2. EXPIRED CONTENT CLEANUP FUNCTION
-- ================================================================
-- Hard-deletes content older than 24 hours and returns storage
-- paths grouped by bucket so the calling Edge Function can purge
-- files from Supabase Storage.
--
-- FUTURE-PROOFING (likes):
--   When a `likes` table is added, this function should:
--     1. DELETE individual like rows (they reference content via FK)
--     2. NOT decrement any aggregate like count on the user profile
--        (e.g. users.total_likes_received should be left untouched)
--   Add the DELETE FROM likes ... statement here, BEFORE the
--   content DELETE, in the same dependency-order pattern.

CREATE OR REPLACE FUNCTION cleanup_expired_content()
RETURNS TABLE (bucket TEXT, storage_path TEXT)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    -- 1. Collect storage paths BEFORE deleting rows.
    --    Returns bucket name + path so the caller knows which
    --    Storage bucket to delete from.
    RETURN QUERY
        -- Original media files
        SELECT 'content'::TEXT AS bucket,
               c.original_path AS storage_path
        FROM content c
        WHERE c.created_at < now() - INTERVAL '24 hours'
        UNION ALL
        -- Compressed variants (if any)
        SELECT 'content'::TEXT AS bucket,
               c.compressed_path AS storage_path
        FROM content c
        WHERE c.created_at < now() - INTERVAL '24 hours'
          AND c.compressed_path IS NOT NULL
        UNION ALL
        -- Thumbnails (if any)
        SELECT 'thumbnails'::TEXT AS bucket,
               c.thumbnail_path AS storage_path
        FROM content c
        WHERE c.created_at < now() - INTERVAL '24 hours'
          AND c.thumbnail_path IS NOT NULL;

    -- 2. Delete dependent rows (children → parents)
    --    FUTURE: Add  DELETE FROM likes WHERE content_id IN (...)  here.
    DELETE FROM views
    WHERE content_id IN (
        SELECT id FROM content
        WHERE created_at < now() - INTERVAL '24 hours'
    );

    DELETE FROM reports
    WHERE content_id IN (
        SELECT id FROM content
        WHERE created_at < now() - INTERVAL '24 hours'
    );

    -- 3. Hard-delete the expired content records
    DELETE FROM content
    WHERE created_at < now() - INTERVAL '24 hours';
END;
$$;


-- ================================================================
-- 3. INDEX for efficient expiry queries
-- ================================================================
-- Accelerates both:
--   • The 24-hour window filter in get_nearby_content()
--   • The cleanup_expired_content() batch deletes
-- Partial index: only non-deleted content matters for these queries.

CREATE INDEX IF NOT EXISTS idx_content_expiry
    ON content (created_at)
    WHERE is_deleted = false;
