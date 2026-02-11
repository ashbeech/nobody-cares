-- ================================================================
-- NOBODY CARES — v2 Security Migration
-- ================================================================
--
-- Run AFTER migration.sql. Adds:
--   1. IP-level rate limiting  (bot-farm defense)
--   2. Server-side account deletion  (GDPR hard delete + storage)
--   3. Abandoned upload cleanup
--
-- All statements are idempotent (safe to re-run).
--
-- After running, schedule the new cron jobs:
--   SELECT cron.schedule('cleanup-ip-rate-limits', '0 */6 * * *',
--          'SELECT cleanup_ip_rate_limits()');
--   SELECT cron.schedule('cleanup-abandoned-uploads', '*/30 * * * *',
--          'SELECT cleanup_abandoned_uploads()');
-- ================================================================


-- ================================================================
-- 1. IP-LEVEL RATE LIMITING
-- ================================================================

CREATE TABLE IF NOT EXISTS ip_rate_limits (
    ip_address    TEXT NOT NULL,
    action        TEXT NOT NULL,
    window_start  TIMESTAMPTZ NOT NULL,
    request_count INTEGER NOT NULL DEFAULT 1,
    PRIMARY KEY (ip_address, action, window_start)
);

CREATE INDEX IF NOT EXISTS idx_ip_rate_limits_cleanup
    ON ip_rate_limits (window_start);

ALTER TABLE ip_rate_limits ENABLE ROW LEVEL SECURITY;
-- No direct user access — all access via SECURITY DEFINER functions.

-- Default IP-level limits.
-- Uses the existing rate_limit_config table (same schema).
INSERT INTO rate_limit_config (action, window_seconds, max_requests, soft_pct) VALUES
    ('ip_registration',   3600,   10,  0.7),  -- 10 new accounts/hour per IP
    ('ip_upload',         3600,   50,  0.8),  -- 50 uploads/hour per IP
    ('ip_global',           60,  120,  0.8)   -- 120 requests/minute per IP
ON CONFLICT (action) DO NOTHING;

-- Check IP rate limit — same algorithm as check_rate_limit but keyed on IP.
CREATE OR REPLACE FUNCTION check_ip_rate_limit(
    p_ip   TEXT,
    p_action TEXT
)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_window_seconds INTEGER;
    v_max_requests   INTEGER;
    v_soft_pct       DOUBLE PRECISION;
    v_window_start   TIMESTAMPTZ;
    v_current_count  INTEGER;
    v_soft_limit     INTEGER;
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
    VALUES (p_ip, p_action, v_window_start, 1)
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

-- Cleanup old IP windows (run via pg_cron every 6 hours)
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
-- 2. SERVER-SIDE ACCOUNT DELETION (hard delete)
-- ================================================================
-- Returns the storage paths the calling Edge Function must remove
-- from the Storage bucket, then cascade-deletes every DB row.

CREATE OR REPLACE FUNCTION delete_user_account(p_user_id UUID)
RETURNS TABLE (storage_path TEXT)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    -- 1. Collect storage paths BEFORE deleting rows
    RETURN QUERY
        SELECT c.original_path AS storage_path
        FROM content c WHERE c.user_id = p_user_id
        UNION ALL
        SELECT c.compressed_path AS storage_path
        FROM content c WHERE c.user_id = p_user_id
            AND c.compressed_path IS NOT NULL;

    -- 2. Delete in dependency order (children → parents)
    DELETE FROM views
        WHERE content_id IN (SELECT id FROM content WHERE user_id = p_user_id);

    DELETE FROM reports
        WHERE content_id IN (SELECT id FROM content WHERE user_id = p_user_id);

    DELETE FROM analytics_events WHERE user_id = p_user_id;
    DELETE FROM rate_limits       WHERE user_id = p_user_id;
    DELETE FROM views             WHERE viewer_id = p_user_id;
    DELETE FROM reports           WHERE reporter_id = p_user_id;
    DELETE FROM blocks            WHERE blocker_id = p_user_id
                                     OR blocked_id = p_user_id;
    DELETE FROM device_attestations WHERE user_id = p_user_id;
    DELETE FROM content           WHERE user_id = p_user_id;
    DELETE FROM users             WHERE id = p_user_id;
END;
$$;


-- ================================================================
-- 3. ABANDONED UPLOAD CLEANUP
-- ================================================================
-- Content records created by upload-request but never confirmed
-- (is_deleted = true, older than 1 hour) are garbage.  The calling
-- Edge Function or cron wrapper should also delete the returned
-- storage paths from the bucket.

CREATE OR REPLACE FUNCTION cleanup_abandoned_uploads()
RETURNS TABLE (storage_path TEXT)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    -- Return paths so the caller can purge Storage
    RETURN QUERY
        SELECT c.original_path AS storage_path
        FROM content c
        WHERE c.is_deleted = true
          AND c.created_at < now() - INTERVAL '1 hour';

    -- Hard-delete the orphaned records
    DELETE FROM content
    WHERE is_deleted = true
      AND created_at < now() - INTERVAL '1 hour';
END;
$$;
