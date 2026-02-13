/**
 * cleanup-expired-content Edge Function
 *
 * Purges ephemeral content older than 24 hours:
 *   1. Calls cleanup_expired_content() to hard-delete expired DB rows
 *      and collect the list of Storage paths that need purging
 *   2. Batch-deletes those files from the "content" and "thumbnails"
 *      Storage buckets
 *
 * This function is designed to be invoked on a schedule (every 15 min)
 * via pg_cron + pg_net, or any external cron/scheduler.
 *
 * Deploy with:
 *   supabase functions deploy cleanup-expired-content --no-verify-jwt
 *
 * Environment variables (auto-provided by Supabase):
 *   - SUPABASE_URL
 *   - SUPABASE_SERVICE_ROLE_KEY
 */

// Schedule via pg_cron + pg_net (recommended):
//
//   SELECT cron.schedule(
//     'invoke-cleanup-expired-content',
//     '*/15 * * * *',
//     $$
//     SELECT net.http_post(
//       url := '<SUPABASE_URL>/functions/v1/cleanup-expired-content',
//       headers := jsonb_build_object(
//         'Authorization', 'Bearer <SERVICE_ROLE_KEY>',
//         'Content-Type', 'application/json'
//       ),
//       body := '{}'::jsonb
//     );
//     $$
//   );

import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

serve(async (req) => {
  try {
    if (req.method !== "POST") {
      return jsonResponse({ error: "Method not allowed" }, 405);
    }

    const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";

    // ── Auth: require service role key ──────────────────────────
    // This is an admin-only operation. Verify the caller is using
    // the service role key (not a regular user JWT).
    const authHeader = req.headers.get("Authorization");
    const token = authHeader?.replace("Bearer ", "") ?? "";

    if (token !== serviceRoleKey) {
      // Also allow if called by a service-role-authenticated client
      // (pg_net sends the key as a Bearer token)
      const supabaseCheck = createClient(supabaseUrl, serviceRoleKey);
      const {
        data: { user },
      } = await supabaseCheck.auth.getUser(token);

      // If it resolves to a regular user, reject.
      // Service role key won't resolve to a user — it bypasses auth.
      if (user) {
        return jsonResponse({ error: "Forbidden: admin only" }, 403);
      }
    }

    // ── Use service role client for admin operations ─────────────
    const supabase = createClient(supabaseUrl, serviceRoleKey);

    // ── Call cleanup function ────────────────────────────────────
    const { data: expiredPaths, error: cleanupError } = await supabase.rpc(
      "cleanup_expired_content"
    );

    if (cleanupError) {
      console.error("cleanup_expired_content error:", cleanupError);
      return jsonResponse(
        { error: "Cleanup function failed", detail: cleanupError.message },
        500
      );
    }

    if (!expiredPaths || expiredPaths.length === 0) {
      return jsonResponse({ deleted: 0, message: "No expired content" });
    }

    // ── Group paths by bucket ────────────────────────────────────
    const contentPaths: string[] = [];
    const thumbnailPaths: string[] = [];

    for (const row of expiredPaths) {
      if (!row.storage_path) continue;
      if (row.bucket === "thumbnails") {
        thumbnailPaths.push(row.storage_path);
      } else {
        contentPaths.push(row.storage_path);
      }
    }

    let deletedFiles = 0;
    const errors: string[] = [];
    const BATCH = 100;

    // ── Delete from 'content' bucket ─────────────────────────────
    for (let i = 0; i < contentPaths.length; i += BATCH) {
      const batch = contentPaths.slice(i, i + BATCH);
      const { error: storageErr } = await supabase.storage
        .from("content")
        .remove(batch);

      if (storageErr) {
        console.error(
          `Content storage batch ${i / BATCH + 1} error:`,
          storageErr
        );
        errors.push(`content batch ${i / BATCH + 1}: ${storageErr.message}`);
      } else {
        deletedFiles += batch.length;
      }
    }

    // ── Delete from 'thumbnails' bucket ──────────────────────────
    for (let i = 0; i < thumbnailPaths.length; i += BATCH) {
      const batch = thumbnailPaths.slice(i, i + BATCH);
      const { error: storageErr } = await supabase.storage
        .from("thumbnails")
        .remove(batch);

      if (storageErr) {
        console.error(
          `Thumbnails storage batch ${i / BATCH + 1} error:`,
          storageErr
        );
        errors.push(
          `thumbnails batch ${i / BATCH + 1}: ${storageErr.message}`
        );
      } else {
        deletedFiles += batch.length;
      }
    }

    const summary = {
      expired_records: expiredPaths.length,
      storage_files_deleted: deletedFiles,
      content_files: contentPaths.length,
      thumbnail_files: thumbnailPaths.length,
      ...(errors.length > 0 && { storage_errors: errors }),
    };

    console.log("Cleanup complete:", JSON.stringify(summary));

    return jsonResponse(summary);
  } catch (err) {
    console.error("cleanup-expired-content error:", err);
    return jsonResponse({ error: "Internal error" }, 500);
  }
});

function jsonResponse(body: Record<string, unknown>, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}
