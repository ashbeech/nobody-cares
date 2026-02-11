-- ================================================================
-- NOBODY CARES — v2 Security Hardening Migration
-- ================================================================
--
-- Run AFTER migration.sql. Adds:
--   1. IP-based rate limiting (complement to per-user limits)
--   2. Server-side account deletion (hard delete from DB + storage paths)
--   3. Assertion counter tracking on device attestations (anti-replay)
--   4. Stale upload cleanup function
--
-- Run in: Dashboard → SQL Editor → New Query → Paste → Run
--
-- After running:
--   1. Schedule stale upload cleanup via pg_cron:
--      SELECT cron.schedule('cleanup-stale-uploads', '*/30 * * * *', $$SELECT cleanup_stale_uploads()$$);
--   2. Schedule IP rate limit cleanup:
--      SELECT cron.schedule('cleanup-ip-rate-limits', '0 */6 * * *', $$SELECT cleanup_ip_rate_limits()$$);
--
-- ================================================================


-- ================================================================
-- 1. IP-BASED RATE LIMITING
-- ================================================================
-- Tracks request counts per IP per action in sliding windows.
-- Prevents bot farms from creating many anonymous accounts across IPs.

CREATE TABLE IF NOT EXISTS ip_rate_limits (
    ip_address    INET NOT NULL,
    action        TEXT NOT NULL,
    window_start  TIMESTAMPTZ NOT NULL,
    request_count INTEGER NOT NULL DEFAULT 1,
    PRIMARY KEY (ip_address, action, window_start)
);

CREATE INDEX IF NOT EXISTS idx_ip_rate_limits_cleanup
    ON ip_rate_limits (window_start);

ALTER TABLE ip_rate_limits ENABLE ROW LEVEL SECURITY;
-- No direct user access — all access via SECURITY DEFINER functions

-- Add IP-specific rate limit configurations
INSERT INTO rate_limit_config (action, window_seconds, max_requests, soft_pct) VALUES
    ('ip_registration',   3600,    5, 0.6),   -- 5 new accounts/hour per IP (soft at 3)
    ('ip_upload',         3600,   50, 0.8),   -- 50 uploads/hour per IP
    ('ip_global',           60,  120, 0.8)    -- 120 requests/minute per IP (burst cap)
ON CONFLICT (action) DO NOTHING;

-- Check IP rate limit (mirrors check_rate_limit but keyed on IP)
CREATE OR REPLACE FUNCTION check_ip_rate_limit(
    p_ip_address INET,
    p_action TEXT
)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_window_seconds INTEGER;
    v_max_requests INTEGER;
    v_soft_pct DOUBLE PRECISION;
    v_window_start TIMESTAMPTZ;
    v_current_count INTEGER;
    v_soft_limit INTEGER;
BEGIN
    SELECT window_seconds, max_requests, soft_pct
    INTO v_window_seconds, v_max_requests, v_soft_pct
    FROM rate_limit_config
    WHERE action = p_action;

    IF NOT FOUND THEN
        RETURN 'ok';
    END IF;

    v_window_start := date_trunc('second',
        to_timestamp(
            floor(extract(epoch FROM now()) / v_window_seconds) * v_window_seconds
        )
    );

    v_soft_limit := floor(v_max_requests * v_soft_pct)::INTEGER;

    INSERT INTO ip_rate_limits (ip_address, action, window_start, request_count)
    VALUES (p_ip_address, p_action, v_window_start, 1)
    ON CONFLICT (ip_address, action, window_start)
    DO UPDATE SET request_count = ip_rate_limits.request_count + 1
    RETURNING request_count INTO v_current_count;

    IF v_current_count > v_max_requests THEN
        RETURN 'hard_exceeded';
    ELSIF v_current_count > v_soft_limit THEN
        RETURN 'soft_exceeded';
    ELSE
        RETURN 'ok';
    END IF;
END;
$$;

-- Cleanup old IP rate limit windows
CREATE OR REPLACE FUNCTION cleanup_ip_rate_limits()
RETURNS void
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
    DELETE FROM ip_rate_limits
    WHERE window_start < now() - INTERVAL '2 days';
$$;


-- ================================================================
-- 2. ASSERTION COUNTER (anti-replay for App Attest)
-- ================================================================
-- Each assertion must have a strictly increasing counter.
-- If an assertion arrives with a counter <= last seen, it's a replay.

ALTER TABLE device_attestations
    ADD COLUMN IF NOT EXISTS assertion_counter BIGINT NOT NULL DEFAULT 0;


-- ================================================================
-- 3. SERVER-SIDE ACCOUNT DELETION
-- ================================================================
-- Hard-deletes all user data from the database.
-- Returns storage paths so the calling Edge Function can delete files from Storage.
-- Called only from the delete-account Edge Function (service role key).

CREATE OR REPLACE FUNCTION delete_user_account(p_user_id UUID)
RETURNS TABLE (storage_path TEXT)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    -- Return all storage paths that need to be deleted from Storage.
    -- The Edge Function will delete these files after this function returns.
    RETURN QUERY
        SELECT c.original_path AS storage_path
        FROM content c
        WHERE c.user_id = p_user_id AND c.original_path IS NOT NULL
        UNION ALL
        SELECT c.compressed_path AS storage_path
        FROM content c
        WHERE c.user_id = p_user_id AND c.compressed_path IS NOT NULL;

    -- Delete in dependency order (children first)

    -- Views on this user's content
    DELETE FROM views
    WHERE content_id IN (SELECT id FROM content WHERE user_id = p_user_id);

    -- Views by this user
    DELETE FROM views WHERE viewer_id = p_user_id;

    -- Reports on this user's content
    DELETE FROM reports
    WHERE content_id IN (SELECT id FROM content WHERE user_id = p_user_id);

    -- Reports by this user
    DELETE FROM reports WHERE reporter_id = p_user_id;

    -- Blocks (both directions)
    DELETE FROM blocks WHERE blocker_id = p_user_id OR blocked_id = p_user_id;

    -- Analytics events
    DELETE FROM analytics_events WHERE user_id = p_user_id;

    -- Rate limits
    DELETE FROM rate_limits WHERE user_id = p_user_id;

    -- Device attestations
    DELETE FROM device_attestations WHERE user_id = p_user_id;

    -- Content (the actual posts)
    DELETE FROM content WHERE user_id = p_user_id;

    -- User row
    DELETE FROM users WHERE id = p_user_id;
END;
$$;


-- ================================================================
-- 4. STALE UPLOAD CLEANUP
-- ================================================================
-- Content records created by upload-request but never confirmed
-- (is_deleted = true, older than 1 hour) are orphans. Clean them up.
-- Storage files for these are cleaned up by the Edge Function or a separate job.

CREATE OR REPLACE FUNCTION cleanup_stale_uploads()
RETURNS TABLE (orphan_path TEXT)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    -- Return paths of orphaned uploads for storage cleanup
    RETURN QUERY
        SELECT c.original_path AS orphan_path
        FROM content c
        WHERE c.is_deleted = true
          AND c.created_at < now() - INTERVAL '1 hour';

    -- Delete the orphaned content records
    DELETE FROM content
    WHERE is_deleted = true
      AND created_at < now() - INTERVAL '1 hour';
END;
$$;


-- ================================================================
-- DONE — v2 Security Hardening
-- ================================================================
