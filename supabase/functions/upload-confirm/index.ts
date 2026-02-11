/**
 * upload-confirm Edge Function
 *
 * Called after the client successfully uploads a file to Supabase Storage.
 * Activates the content record (sets is_deleted = false) and validates
 * the file exists in Storage.
 *
 * Deploy with: supabase functions deploy upload-confirm --no-verify-jwt
 *
 * Environment variables (auto-provided):
 *   - SUPABASE_URL
 *   - SUPABASE_SERVICE_ROLE_KEY
 */

import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

interface ConfirmRequest {
  content_id: string;
  storage_path: string;
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

    // Authenticate
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

    const body: ConfirmRequest = await req.json();

    if (!body.content_id || !body.storage_path) {
      return jsonResponse({ error: "Missing required fields" }, 400);
    }

    // Verify the content record exists and belongs to this user
    const { data: content, error: fetchError } = await supabase
      .from("content")
      .select("id, user_id, original_path, is_deleted")
      .eq("id", body.content_id)
      .single();

    if (fetchError || !content) {
      return jsonResponse({ error: "Content not found" }, 404);
    }

    if (content.user_id !== user.id) {
      return jsonResponse({ error: "Unauthorized" }, 403);
    }

    if (content.original_path !== body.storage_path) {
      return jsonResponse({ error: "Path mismatch" }, 400);
    }

    // Verify the file exists in Storage
    const { data: fileList, error: listError } = await supabase.storage
      .from("content")
      .list(body.storage_path.split("/").slice(0, -1).join("/"), {
        search: body.storage_path.split("/").pop(),
      });

    if (listError || !fileList?.length) {
      return jsonResponse({ error: "File not found in storage" }, 404);
    }

    // Activate the content (set is_deleted = false)
    const { error: updateError } = await supabase
      .from("content")
      .update({ is_deleted: false })
      .eq("id", body.content_id)
      .eq("user_id", user.id);

    if (updateError) {
      console.error("Update error:", updateError);
      return jsonResponse({ error: "Failed to activate content" }, 500);
    }

    // Log analytics event
    await supabase.from("analytics_events").insert({
      event_type: "content_created",
      user_id: user.id,
      metadata: {
        content_id: body.content_id,
        content_type: content.content_type,
      },
    });

    return jsonResponse({
      confirmed: true,
      content_id: body.content_id,
    });
  } catch (err) {
    console.error("Upload confirm error:", err);
    return jsonResponse({ error: "Internal error" }, 500);
  }
});

function jsonResponse(body: Record<string, unknown>, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}
