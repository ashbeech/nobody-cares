-- ================================================================
-- NOBODY CARES — v5 Thumbnails Migration
-- ================================================================
--
-- Adds thumbnail support to the content table and updates
-- get_nearby_content() to return thumbnail_path so the iOS
-- client can display thumbnails while videos buffer.
--
-- Also creates the private `thumbnails` storage bucket.
--
-- Idempotent — safe to re-run.
-- ================================================================

-- Step 1: Add thumbnail columns to content table
ALTER TABLE content ADD COLUMN IF NOT EXISTS thumbnail_path TEXT;
ALTER TABLE content ADD COLUMN IF NOT EXISTS thumbnail_generated_at TIMESTAMPTZ;

-- Step 2: Create the thumbnails storage bucket (private, like `content`)
-- Note: Run via Supabase Dashboard or SQL if INSERT doesn't work in your setup.
INSERT INTO storage.buckets (id, name, public)
VALUES ('thumbnails', 'thumbnails', false)
ON CONFLICT (id) DO NOTHING;

-- Step 3: Storage policies for thumbnails bucket
--
-- SECURITY: No broad SELECT policy. Thumbnails are accessed exclusively
-- via signed URLs. The client calls createSignedURL which is validated
-- by the restricted SELECT policy below (only for visible, non-deleted,
-- non-banned, non-blocked content).
--
-- INSERT is restricted to thumbnails for content the uploader owns.

-- SELECT: only thumbnails for content the viewer is allowed to see
-- (not deleted, user not banned, not blocked by viewer).
-- This enables signed URL generation from the client SDK.
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_policies
        WHERE tablename = 'objects'
          AND policyname = 'Users can read thumbnails for visible content'
    ) THEN
        CREATE POLICY "Users can read thumbnails for visible content"
            ON storage.objects
            FOR SELECT
            TO authenticated
            USING (
                bucket_id = 'thumbnails'
                AND EXISTS (
                    SELECT 1 FROM public.content c
                    JOIN public.users u ON c.user_id = u.id
                    WHERE c.thumbnail_path = name
                      AND c.is_deleted = false
                      AND u.is_deleted = false
                      AND u.is_banned = false
                      AND c.user_id NOT IN (
                          SELECT blocked_id FROM public.blocks
                          WHERE blocker_id = auth.uid()
                      )
                )
            );
    END IF;
END
$$;

-- INSERT: only for content the uploader owns.
-- Path convention: {content_id}.jpg — extract UUID from filename.
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_policies
        WHERE tablename = 'objects'
          AND policyname = 'Users can upload thumbnails for own content'
    ) THEN
        CREATE POLICY "Users can upload thumbnails for own content"
            ON storage.objects
            FOR INSERT
            TO authenticated
            WITH CHECK (
                bucket_id = 'thumbnails'
                AND EXISTS (
                    SELECT 1 FROM public.content
                    WHERE id = (split_part(name, '.', 1))::uuid
                      AND user_id = auth.uid()
                )
            );
    END IF;
END
$$;

-- UPDATE: allow upsert for thumbnail re-generation (same ownership check)
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_policies
        WHERE tablename = 'objects'
          AND policyname = 'Users can update own thumbnails'
    ) THEN
        CREATE POLICY "Users can update own thumbnails"
            ON storage.objects
            FOR UPDATE
            TO authenticated
            USING (
                bucket_id = 'thumbnails'
                AND EXISTS (
                    SELECT 1 FROM public.content
                    WHERE id = (split_part(name, '.', 1))::uuid
                      AND user_id = auth.uid()
                )
            );
    END IF;
END
$$;

-- Step 4: Drop and recreate get_nearby_content with thumbnail_path
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
