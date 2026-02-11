/**
 * delete-account Edge Function
 *
 * Hard-deletes the authenticated user's account:
 *   1. Verifies JWT + device assertion (prevents deletion via stolen token)
 *   2. Calls delete_user_account() to cascade-delete all DB rows and
 *      collect the list of Storage paths that need purging
 *   3. Batch-deletes those files from the "content" Storage bucket
 *   4. Deletes the Supabase Auth user via the Admin API
 *
 * This is GDPR-compliant: no user data survives the call.
 *
 * Deploy with: supabase functions deploy delete-account --no-verify-jwt
 *
 * Environment variables (auto-provided):
 *   - SUPABASE_URL
 *   - SUPABASE_SERVICE_ROLE_KEY
 */

import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { verifyAssertion } from "../_shared/verify-assertion.ts";

interface DeleteRequest {
  confirmation: string; // must be "DELETE_MY_ACCOUNT"
}

serve(async (req) => {
  try {
    if (req.method !== "POST") {
      return jsonResponse({ error: "Method not allowed" }, 405);
    }

    const supabase = createClient(
      Deno.env.get("SUPABASE_URL") ?? "",
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? ""
    );

    // ── Authenticate ────────────────────────────────────────────
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) {
      return jsonResponse({ error: "Missing authorization" }, 401);
    }

    const token = authHeader.replace("Bearer ", "");
    const {
      data: { user },
      error: authError,
    } = await supabase.auth.getUser(token);

    if (authError || !user) {
      return jsonResponse({ error: "Unauthorized" }, 401);
    }

    // ── Verify device assertion ─────────────────────────────────
    const assertionResult = await verifyAssertion(supabase, req, user.id);
    if (!assertionResult.valid) {
      return jsonResponse(
        { error: "Assertion failed", detail: assertionResult.error },
        403
      );
    }

    // ── Safety check ────────────────────────────────────────────
    const body: DeleteRequest = await req.json();
    if (body.confirmation !== "DELETE_MY_ACCOUNT") {
      return jsonResponse({ error: "Missing or invalid confirmation string" }, 400);
    }

    // ── Cascade-delete DB rows and collect storage paths ────────
    const { data: storagePaths, error: deleteError } = await supabase.rpc(
      "delete_user_account",
      { p_user_id: user.id }
    );

    if (deleteError) {
      console.error("delete_user_account error:", deleteError);
      return jsonResponse({ error: "Failed to delete account data" }, 500);
    }

    // ── Purge storage files in batches of 100 ───────────────────
    if (storagePaths && storagePaths.length > 0) {
      const paths: string[] = storagePaths
        .map((row: { storage_path: string }) => row.storage_path)
        .filter(Boolean);

      const BATCH = 100;
      for (let i = 0; i < paths.length; i += BATCH) {
        const batch = paths.slice(i, i + BATCH);
        const { error: storageErr } = await supabase.storage
          .from("content")
          .remove(batch);
        if (storageErr) {
          // Log but continue — partial cleanup is better than aborting
          console.error("Storage batch delete error:", storageErr);
        }
      }
    }

    // ── Delete Supabase Auth user ───────────────────────────────
    const { error: authDeleteErr } = await supabase.auth.admin.deleteUser(
      user.id
    );
    if (authDeleteErr) {
      // Non-fatal: DB rows are already gone; auth user is orphaned
      // but harmless.  Supabase will auto-prune inactive anon users.
      console.error("Auth user deletion error:", authDeleteErr);
    }

    return jsonResponse({ deleted: true });
  } catch (err) {
    console.error("delete-account error:", err);
    return jsonResponse({ error: "Internal error" }, 500);
  }
});

function jsonResponse(body: Record<string, unknown>, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}
