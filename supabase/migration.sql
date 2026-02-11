-- ================================================================
-- NOBODY CARES — v1 Database Migration
-- ================================================================
--
-- PREREQUISITES (do these in the Supabase Dashboard BEFORE running):
--
--   1. Create a new Supabase project at https://supabase.com/dashboard
--
--   2. Enable Anonymous Sign-Ins:
--      Dashboard → Authentication → Providers → Anonymous Sign-Ins → Enable
--
--   3. Create Storage bucket:
--      Dashboard → Storage → New Bucket
--        Name: "content"
--        Public: OFF (we use signed URLs)
--        File size limit: 50MB
--        Allowed MIME types: image/heic, image/heif, image/jpeg, video/quicktime
--
--   4. Run this entire SQL file in the SQL Editor:
--      Dashboard → SQL Editor → New Query → Paste → Run
--
--   5. After running, create Storage policies in Dashboard → Storage → content → Policies:
--      INSERT: allow authenticated users (bucket_id = 'content')
--      SELECT: allow authenticated users (bucket_id = 'content')
--      DELETE: allow secret key only (server-side)
--
--   6. Copy your project credentials:
--      Dashboard → Settings → API Keys
--        - Project URL  → paste into Config/Secrets.swift
--        - Publishable key (sb_publishable_...) → paste into Config/Secrets.swift
--
-- ================================================================

-- Extensions
CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS pgcrypto;
-- CREATE EXTENSION IF NOT EXISTS pg_cron;  -- Enable via Dashboard → Database → Extensions

-- ================================================================
-- USERNAME GENERATION
-- ================================================================

CREATE OR REPLACE FUNCTION generate_username()
RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
    adjectives TEXT[] := ARRAY[
        'unhinged', 'feral', 'cursed', 'chaotic', 'faded', 'expired', 'stale', 'vintage',
        'dusty', 'haunted', 'soggy', 'crusty', 'musty', 'crispy', 'salty',
        'overcooked', 'unserious', 'deranged', 'delulu', 'cringe', 'based', 'mid',
        'toxic', 'lowkey', 'highkey', 'basic', 'iconic',
        'unwell', 'cooked', 'raw', 'peak', 'valid', 'dead', 'cosmic', 'void',
        'numb', 'loud', 'silent', 'broke', 'lost', 'found', 'late', 'early', 'extra',
        'minimal', 'absolute', 'questionable', 'suspicious', 'former', 'retired',
        'professional', 'certified', 'discount', 'bootleg', 'generic'
    ];
    nouns TEXT[] := ARRAY[
        'goblin', 'gremlin', 'possum', 'raccoon', 'pigeon', 'moth', 'slug', 'toad',
        'cryptid', 'ghost', 'entity', 'npc', 'villain', 'peasant', 'goon', 'menace',
        'disaster', 'trainwreck', 'dumpster', 'landfill', 'swamp', 'abyss', 'void',
        'glitch', 'error', 'bug', 'virus', 'malware', 'spam', 'static', 'pixel',
        'crumb', 'toast', 'soup', 'bean', 'potato', 'noodle', 'pickle', 'muffin',
        'waffle', 'nugget', 'biscuit', 'pretzel', 'turnip', 'radish', 'clown',
        'puppet', 'mannequin', 'scarecrow', 'gargoyle', 'gopher', 'hamster',
        'chaos', 'entropy', 'paradox', 'anomaly', 'artifact', 'relic', 'fossil'
    ];
    adj TEXT;
    noun TEXT;
    candidate TEXT;
    attempts INT := 0;
BEGIN
    LOOP
        adj := adjectives[1 + floor(random() * array_length(adjectives, 1))::int];
        noun := nouns[1 + floor(random() * array_length(nouns, 1))::int];
        candidate := adj || noun;

        IF length(candidate) <= 20
           AND NOT EXISTS (SELECT 1 FROM users WHERE username = candidate AND is_deleted = false)
        THEN
            RETURN candidate;
        END IF;

        attempts := attempts + 1;
        IF attempts >= 10 THEN
            RETURN candidate || lpad(floor(random() * 100)::text, 2, '0');
        END IF;
    END LOOP;
END;
$$;

-- ================================================================
-- TABLES
-- ================================================================

-- Users (linked to Supabase Auth anonymous users)
CREATE TABLE IF NOT EXISTS users (
    id              UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
    device_token_hash TEXT UNIQUE,
    username        TEXT NOT NULL UNIQUE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    creation_lat    DOUBLE PRECISION,
    creation_lng    DOUBLE PRECISION,
    creation_point  GEOGRAPHY(POINT, 4326),
    trust_score     INTEGER NOT NULL DEFAULT 100 CHECK (trust_score BETWEEN 0 AND 100),
    is_deleted      BOOLEAN NOT NULL DEFAULT false,
    deleted_at      TIMESTAMPTZ,
    last_active_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_users_device_hash ON users (device_token_hash) WHERE device_token_hash IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_users_creation_point ON users USING GIST (creation_point);

-- Content (geo-locked)
-- NOTE: original_path and compressed_path store Storage object keys,
-- NOT signed URLs. Signed URLs are generated at request time.
CREATE TABLE IF NOT EXISTS content (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id             UUID NOT NULL REFERENCES users(id),
    capture_lat         DOUBLE PRECISION NOT NULL,
    capture_lng         DOUBLE PRECISION NOT NULL,
    capture_point       GEOGRAPHY(POINT, 4326) NOT NULL,
    horizontal_accuracy DOUBLE PRECISION NOT NULL,
    cell_id             TEXT NOT NULL,
    content_type        TEXT NOT NULL CHECK (content_type IN ('image', 'video')),
    duration_ms         INTEGER CHECK (duration_ms IS NULL OR duration_ms <= 6000),
    original_path       TEXT NOT NULL,
    compressed_path     TEXT,
    is_compressed       BOOLEAN NOT NULL DEFAULT false,
    file_size_bytes     BIGINT NOT NULL CHECK (file_size_bytes <= 52428800), -- 50MB
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_viewed_at      TIMESTAMPTZ,
    views_count         INTEGER NOT NULL DEFAULT 0,
    is_deleted          BOOLEAN NOT NULL DEFAULT false,
    deleted_at          TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_content_capture_point ON content USING GIST (capture_point);
CREATE INDEX IF NOT EXISTS idx_content_cell_id ON content (cell_id);
CREATE INDEX IF NOT EXISTS idx_content_user_id ON content (user_id);
CREATE INDEX IF NOT EXISTS idx_content_created_at ON content (created_at DESC);
CREATE INDEX IF NOT EXISTS idx_content_compression ON content (is_compressed, last_viewed_at)
    WHERE is_deleted = false;

-- Views
CREATE TABLE IF NOT EXISTS views (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    content_id      UUID NOT NULL REFERENCES content(id),
    viewer_id       UUID NOT NULL REFERENCES users(id),
    viewed_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    viewer_lat      DOUBLE PRECISION NOT NULL,
    viewer_lng      DOUBLE PRECISION NOT NULL,
    distance_meters DOUBLE PRECISION NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_views_content ON views (content_id);
CREATE INDEX IF NOT EXISTS idx_views_viewer ON views (viewer_id);
CREATE INDEX IF NOT EXISTS idx_views_viewed_at ON views (viewed_at DESC);

-- Reports
CREATE TABLE IF NOT EXISTS reports (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    content_id  UUID NOT NULL REFERENCES content(id) ON DELETE CASCADE,
    reporter_id UUID NOT NULL DEFAULT auth.uid() REFERENCES users(id) ON DELETE CASCADE,
    reason      TEXT NOT NULL CHECK (reason IN ('inappropriate', 'illegal', 'other')),
    detail      TEXT,
    status      TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'reviewed', 'actioned', 'dismissed')),
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    reviewed_at TIMESTAMPTZ,
    reviewed_by UUID
);

CREATE INDEX IF NOT EXISTS idx_reports_status ON reports (status) WHERE status = 'pending';
CREATE INDEX IF NOT EXISTS idx_reports_reporter ON reports (reporter_id);

-- Blocks
CREATE TABLE IF NOT EXISTS blocks (
    blocker_id  UUID NOT NULL DEFAULT auth.uid() REFERENCES users(id) ON DELETE CASCADE,
    blocked_id  UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (blocker_id, blocked_id)
);

CREATE INDEX IF NOT EXISTS idx_blocks_blocker ON blocks (blocker_id);

-- Analytics Events
CREATE TABLE IF NOT EXISTS analytics_events (
    id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    event_type TEXT NOT NULL,
    user_id    UUID REFERENCES users(id),
    metadata   JSONB NOT NULL DEFAULT '{}',
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_analytics_type ON analytics_events (event_type, created_at DESC);

-- ================================================================
-- ROW LEVEL SECURITY
-- ================================================================

-- Users: read and update own row only
ALTER TABLE users ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS users_self_read ON users;
CREATE POLICY users_self_read ON users FOR SELECT USING (id = auth.uid());
DROP POLICY IF EXISTS users_self_update ON users;
CREATE POLICY users_self_update ON users FOR UPDATE USING (id = auth.uid());

-- Content: anyone authenticated can read non-deleted content
-- (proximity check is done in the get_nearby_content function)
-- Insert only via own user_id
ALTER TABLE content ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS content_read ON content;
CREATE POLICY content_read ON content FOR SELECT USING (is_deleted = false);
DROP POLICY IF EXISTS content_insert ON content;
CREATE POLICY content_insert ON content FOR INSERT WITH CHECK (user_id = auth.uid());

-- Views: insert own views, read own views
ALTER TABLE views ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS views_insert ON views;
CREATE POLICY views_insert ON views FOR INSERT WITH CHECK (viewer_id = auth.uid());
DROP POLICY IF EXISTS views_read_own ON views;
CREATE POLICY views_read_own ON views FOR SELECT USING (viewer_id = auth.uid());

-- Reports: insert only
ALTER TABLE reports ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS reports_insert ON reports;
CREATE POLICY reports_insert ON reports FOR INSERT WITH CHECK (reporter_id = auth.uid());

-- Blocks: full CRUD on own blocks
ALTER TABLE blocks ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS blocks_manage ON blocks;
CREATE POLICY blocks_manage ON blocks FOR ALL USING (blocker_id = auth.uid());

-- Analytics: insert only
ALTER TABLE analytics_events ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS analytics_insert ON analytics_events;
CREATE POLICY analytics_insert ON analytics_events FOR INSERT WITH CHECK (
    user_id = auth.uid() OR user_id IS NULL
);

-- ================================================================
-- SERVER FUNCTIONS
-- ================================================================

-- Register a new user (called after anonymous sign-in)
-- Idempotent: returns existing username if user already registered
CREATE OR REPLACE FUNCTION register_user(
    lat DOUBLE PRECISION DEFAULT NULL,
    lng DOUBLE PRECISION DEFAULT NULL
)
RETURNS TABLE (out_username TEXT)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    existing_username TEXT;
    new_username TEXT;
BEGIN
    -- Return existing user if already registered
    SELECT u.username INTO existing_username
    FROM users u WHERE u.id = auth.uid();

    IF existing_username IS NOT NULL THEN
        UPDATE users SET last_active_at = now() WHERE id = auth.uid();
        RETURN QUERY SELECT existing_username;
        RETURN;
    END IF;

    -- Generate unique username
    new_username := generate_username();

    -- Create user row
    INSERT INTO users (id, username, creation_lat, creation_lng, creation_point)
    VALUES (
        auth.uid(),
        new_username,
        lat,
        lng,
        CASE
            WHEN lat IS NOT NULL AND lng IS NOT NULL
            THEN ST_SetSRID(ST_MakePoint(lng, lat), 4326)::geography
            ELSE NULL
        END
    );

    RETURN QUERY SELECT new_username;
END;
$$;

-- Regenerate username
CREATE OR REPLACE FUNCTION regenerate_username()
RETURNS TABLE (out_username TEXT)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    new_username TEXT;
BEGIN
    new_username := generate_username();
    UPDATE users SET username = new_username WHERE id = auth.uid();
    RETURN QUERY SELECT new_username;
END;
$$;

-- Get nearby content (core proximity query)
-- Returns storage object paths (NOT signed URLs)
-- Client generates short-lived signed URLs from these paths
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
-- RATE LIMITING (Postgres-backed)
-- ================================================================
-- Tracks request counts per user per action in sliding windows.
-- Thresholds: soft = warn, hard = reject + penalize trust.

-- Rate limits table
CREATE TABLE IF NOT EXISTS rate_limits (
    user_id       UUID NOT NULL REFERENCES users(id),
    action        TEXT NOT NULL,
    window_start  TIMESTAMPTZ NOT NULL,
    request_count INTEGER NOT NULL DEFAULT 1,
    PRIMARY KEY (user_id, action, window_start)
);

CREATE INDEX IF NOT EXISTS idx_rate_limits_cleanup ON rate_limits (window_start);

-- Rate limit policies (only the system/functions touch this table)
ALTER TABLE rate_limits ENABLE ROW LEVEL SECURITY;
-- No direct user access — all access is via SECURITY DEFINER functions

-- Rate limit configuration table (editable by admins)
CREATE TABLE IF NOT EXISTS rate_limit_config (
    action          TEXT PRIMARY KEY,
    window_seconds  INTEGER NOT NULL,
    max_requests    INTEGER NOT NULL,
    soft_pct        DOUBLE PRECISION NOT NULL DEFAULT 0.8  -- 80% = soft threshold
);

-- Populate default limits per spec
INSERT INTO rate_limit_config (action, window_seconds, max_requests, soft_pct) VALUES
    ('content_create',      86400, 1000, 0.8),   -- 1000/day
    ('video_create',         3600,   10, 0.8),   -- 10/hour
    ('upload_request',         60,    5, 0.8),   -- 5/minute
    ('feed_query',             60,   60, 0.8),   -- 60/minute
    ('report_submit',        3600,   10, 0.8),   -- 10/hour
    ('location_update',        60,   60, 0.8),   -- 60/minute
    ('device_registration',  3600,    3, 0.67)   -- 3/hour (soft at 2)
ON CONFLICT (action) DO NOTHING;

-- Check rate limit function
-- Returns: 'ok', 'soft_exceeded', or 'hard_exceeded'
CREATE OR REPLACE FUNCTION check_rate_limit(
    p_user_id UUID,
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
    -- Get config for this action
    SELECT window_seconds, max_requests, soft_pct
    INTO v_window_seconds, v_max_requests, v_soft_pct
    FROM rate_limit_config
    WHERE action = p_action;

    IF NOT FOUND THEN
        -- Unknown action, allow by default
        RETURN 'ok';
    END IF;

    -- Calculate window start (floor to window boundary)
    v_window_start := date_trunc('second',
        to_timestamp(
            floor(extract(epoch FROM now()) / v_window_seconds) * v_window_seconds
        )
    );

    v_soft_limit := floor(v_max_requests * v_soft_pct)::INTEGER;

    -- Upsert request count and get current value
    INSERT INTO rate_limits (user_id, action, window_start, request_count)
    VALUES (p_user_id, p_action, v_window_start, 1)
    ON CONFLICT (user_id, action, window_start)
    DO UPDATE SET request_count = rate_limits.request_count + 1
    RETURNING request_count INTO v_current_count;

    -- Check thresholds
    IF v_current_count > v_max_requests THEN
        RETURN 'hard_exceeded';
    ELSIF v_current_count > v_soft_limit THEN
        RETURN 'soft_exceeded';
    ELSE
        RETURN 'ok';
    END IF;
END;
$$;

-- Cleanup old rate limit windows (run periodically via pg_cron or Edge Function)
CREATE OR REPLACE FUNCTION cleanup_rate_limits()
RETURNS void
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
    DELETE FROM rate_limits
    WHERE window_start < now() - INTERVAL '2 days';
$$;

-- ================================================================
-- BANNING SYSTEM
-- ================================================================

-- Add ban columns to users table
ALTER TABLE users ADD COLUMN IF NOT EXISTS is_banned BOOLEAN NOT NULL DEFAULT false;
ALTER TABLE users ADD COLUMN IF NOT EXISTS banned_at TIMESTAMPTZ;

-- Update RLS policies to enforce bans
-- Drop and recreate content_read to check for banned users
DROP POLICY IF EXISTS content_read ON content;
CREATE POLICY content_read ON content FOR SELECT USING (
    is_deleted = false
    AND NOT EXISTS (
        SELECT 1 FROM users WHERE users.id = auth.uid() AND users.is_banned = true
    )
);

-- Ban check function (called at the start of every sensitive operation)
CREATE OR REPLACE FUNCTION check_banned()
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    SELECT COALESCE(
        (SELECT is_banned FROM users WHERE id = auth.uid()),
        false
    );
$$;

-- Ban a user (admin or system function)
CREATE OR REPLACE FUNCTION ban_user(p_user_id UUID)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    -- Mark user as banned
    UPDATE users
    SET is_banned = true, banned_at = now(), trust_score = 0
    WHERE id = p_user_id;

    -- Soft-delete all their content
    UPDATE content
    SET is_deleted = true, deleted_at = now()
    WHERE user_id = p_user_id;
END;
$$;

-- ================================================================
-- TRUST SCORE MANAGEMENT
-- ================================================================

-- Decrease trust score and auto-ban at 0
CREATE OR REPLACE FUNCTION decrease_trust_score(
    p_user_id UUID,
    p_amount INTEGER,
    p_reason TEXT DEFAULT NULL
)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_new_score INTEGER;
BEGIN
    UPDATE users
    SET trust_score = GREATEST(0, trust_score - p_amount)
    WHERE id = p_user_id
    RETURNING trust_score INTO v_new_score;

    -- Log the event
    INSERT INTO analytics_events (event_type, user_id, metadata)
    VALUES ('trust_score_decrease', p_user_id, jsonb_build_object(
        'amount', p_amount,
        'new_score', v_new_score,
        'reason', COALESCE(p_reason, 'unspecified')
    ));

    -- Auto-ban at 0
    IF v_new_score = 0 THEN
        PERFORM ban_user(p_user_id);
    END IF;

    RETURN v_new_score;
END;
$$;

-- Increase trust score (daily recovery)
CREATE OR REPLACE FUNCTION recover_trust_scores()
RETURNS void
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
    UPDATE users
    SET trust_score = LEAST(100, trust_score + 1)
    WHERE is_banned = false
      AND is_deleted = false
      AND trust_score < 100
      AND last_active_at >= now() - INTERVAL '24 hours';
$$;

-- ================================================================
-- DEVICE ATTESTATION (for Apple App Attest)
-- ================================================================

CREATE TABLE IF NOT EXISTS device_attestations (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id         UUID NOT NULL REFERENCES users(id),
    key_id          TEXT NOT NULL UNIQUE,
    attestation     BYTEA,               -- raw attestation object from Apple
    is_valid        BOOLEAN NOT NULL DEFAULT true,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_used_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    is_blacklisted  BOOLEAN NOT NULL DEFAULT false
);

CREATE INDEX IF NOT EXISTS idx_device_attestations_user ON device_attestations (user_id);
CREATE INDEX IF NOT EXISTS idx_device_attestations_key ON device_attestations (key_id) WHERE is_valid = true;

ALTER TABLE device_attestations ENABLE ROW LEVEL SECURITY;
-- No direct user access — all access is via Edge Functions with secret key

-- ================================================================
-- PHASE 5: Additional policies + indexes
-- ================================================================
-- The reports, blocks, and analytics_events tables are already
-- created above. This section adds the granular RLS policies
-- and any missing indexes.

-- Reports: additional indexes and policies
CREATE INDEX IF NOT EXISTS idx_reports_content ON reports (content_id);
CREATE INDEX IF NOT EXISTS idx_reports_reporter ON reports (reporter_id);

DROP POLICY IF EXISTS "reports_read_own" ON reports;
CREATE POLICY "reports_read_own" ON reports
    FOR SELECT TO authenticated
    USING (reporter_id = auth.uid());

-- Blocks: additional index and granular policies
CREATE INDEX IF NOT EXISTS idx_blocks_blocked ON blocks (blocked_id);

DROP POLICY IF EXISTS blocks_manage ON blocks;  -- remove overly broad v1 policy
DROP POLICY IF EXISTS "blocks_insert" ON blocks;
CREATE POLICY "blocks_insert" ON blocks
    FOR INSERT TO authenticated
    WITH CHECK (blocker_id = auth.uid());

DROP POLICY IF EXISTS "blocks_read_own" ON blocks;
CREATE POLICY "blocks_read_own" ON blocks
    FOR SELECT TO authenticated
    USING (blocker_id = auth.uid());

DROP POLICY IF EXISTS "blocks_delete_own" ON blocks;
CREATE POLICY "blocks_delete_own" ON blocks
    FOR DELETE TO authenticated
    USING (blocker_id = auth.uid());

-- Analytics: ensure metadata column exists (for DBs upgraded from earlier schema)
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT FROM information_schema.columns
        WHERE table_name = 'analytics_events' AND column_name = 'metadata'
    ) THEN
        ALTER TABLE analytics_events ADD COLUMN metadata JSONB DEFAULT '{}';
    END IF;
END;
$$;

-- Analytics: performance index for attestation challenge lookups
CREATE INDEX IF NOT EXISTS idx_analytics_user_event
    ON analytics_events (user_id, event_type, created_at DESC);

-- ================================================================
-- DONE
-- ================================================================
-- After running this migration, proceed to set up the iOS app:
--   1. Copy Project URL and publishable key from Dashboard → Settings → API Keys
--   2. Paste into Nobody Cares/Config/Secrets.swift
--   3. Build and run the app
--
-- For anti-abuse setup:
--   4. Enable pg_cron extension and schedule: SELECT cron.schedule('cleanup-rate-limits', '0 */6 * * *', 'SELECT cleanup_rate_limits()');
--   5. Schedule trust recovery: SELECT cron.schedule('recover-trust', '0 0 * * *', 'SELECT recover_trust_scores()');
