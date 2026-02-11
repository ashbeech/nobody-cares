/**
 * upload-confirm Edge Function
 *
 * Called after the client successfully uploads a file to Supabase Storage.
 * Validates the uploaded file's real metadata (size, MIME type) against
 * what was declared, then activates the content record.
 *
 * Security layers:
 *   1. JWT authentication
 *   2. Device assertion verification
 *   3. Ownership + path verification
 *   4. Post-upload file validation (size, MIME type, type cross-check)
 *   5. Reject + delete on any validation failure
 *
 * Deploy with: supabase functions deploy upload-confirm --no-verify-jwt
 *
 * Environment variables (auto-provided):
 *   - SUPABASE_URL
 *   - SUPABASE_SERVICE_ROLE_KEY
 */

import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { verifyAssertion } from "../_shared/verify-assertion.ts";

interface ConfirmRequest {
  content_id: string;
  storage_path: string;
}

// MIME types the Storage bucket should accept (mirrors Dashboard config)
const ALLOWED_MIME_TYPES: Record<string, string[]> = {
  image: ["image/heic", "image/heif", "image/jpeg", "image/jpg"],
  video: ["video/quicktime", "video/mp4"],
};

const MAX_FILE_SIZE = 50 * 1024 * 1024; // 50 MB

serve(async (req) => {
  try {
    if (req.method !== "POST") {
      return jsonResponse({ error: "Method not allowed" }, 405);
    }

    const supabase = createClient(
      Deno.env.get("SUPABASE_URL") ?? "",
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "",
    );

    // ── 1. Authenticate ─────────────────────────────────────────
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

    // ── 2. Device assertion ─────────────────────────────────────
    const assertionResult = await verifyAssertion(supabase, req, user.id);
    if (!assertionResult.valid) {
      return jsonResponse(
        {
          error: "Assertion failed",
          detail: assertionResult.error,
          code: "assertion_failed",
        },
        403,
      );
    }

    // ── 3. Parse body & verify ownership ────────────────────────
    const body: ConfirmRequest = await req.json();

    if (!body.content_id || !body.storage_path) {
      return jsonResponse({ error: "Missing required fields" }, 400);
    }

    const { data: content, error: fetchError } = await supabase
      .from("content")
      .select(
        "id, user_id, original_path, is_deleted, content_type, file_size_bytes",
      )
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

    if (!content.is_deleted) {
      // Already confirmed — idempotent success
      return jsonResponse({ confirmed: true, content_id: body.content_id });
    }

    // ── 4. Verify file exists in Storage and read metadata ──────
    const dirPath = body.storage_path.split("/").slice(0, -1).join("/");
    const fileName = body.storage_path.split("/").pop();

    const { data: fileList, error: listError } = await supabase.storage
      .from("content")
      .list(dirPath, { search: fileName });

    if (listError || !fileList?.length) {
      return jsonResponse({ error: "File not found in storage" }, 404);
    }

    const file = fileList[0];

    // ── 5. Post-upload validation ───────────────────────────────
    // 5a. File size — must be > 0 and within hard cap
    const actualSize: number | undefined = file.metadata?.size;
    if (typeof actualSize === "number") {
      if (actualSize <= 0) {
        await rejectUpload(
          supabase,
          body.content_id,
          body.storage_path,
          "Empty file",
        );
        return jsonResponse(
          { error: "Uploaded file is empty", code: "validation_failed" },
          400,
        );
      }
      if (actualSize > MAX_FILE_SIZE) {
        await rejectUpload(
          supabase,
          body.content_id,
          body.storage_path,
          "Exceeds 50MB",
        );
        return jsonResponse(
          { error: "File exceeds maximum size", code: "validation_failed" },
          400,
        );
      }
    }

    // 5b. MIME type — must be in the allowed list for the declared content type
    const actualMime: string | undefined = file.metadata?.mimetype;
    if (actualMime) {
      const allowed = ALLOWED_MIME_TYPES[content.content_type] ?? [];
      if (!allowed.includes(actualMime.toLowerCase())) {
        await rejectUpload(
          supabase,
          body.content_id,
          body.storage_path,
          `MIME ${actualMime} not allowed for ${content.content_type}`,
        );
        return jsonResponse(
          { error: "Invalid file type", code: "validation_failed" },
          400,
        );
      }

      // 5c. Cross-check: declared type (image/video) must match actual MIME prefix
      const isImage = actualMime.toLowerCase().startsWith("image/");
      const isVideo = actualMime.toLowerCase().startsWith("video/");
      if (
        (content.content_type === "image" && !isImage) ||
        (content.content_type === "video" && !isVideo)
      ) {
        await rejectUpload(
          supabase,
          body.content_id,
          body.storage_path,
          `Declared ${content.content_type} but uploaded ${actualMime}`,
        );
        return jsonResponse(
          { error: "Content type mismatch", code: "validation_failed" },
          400,
        );
      }
    }

    // ── 6. Activate the content ─────────────────────────────────
    // Also update file_size_bytes to the real value if we have it
    const updateFields: Record<string, unknown> = { is_deleted: false };
    if (typeof actualSize === "number") {
      updateFields.file_size_bytes = actualSize;
    }

    const { error: updateError } = await supabase
      .from("content")
      .update(updateFields)
      .eq("id", body.content_id)
      .eq("user_id", user.id);

    if (updateError) {
      console.error("Update error:", updateError);
      return jsonResponse({ error: "Failed to activate content" }, 500);
    }

    // ── 7. Analytics ────────────────────────────────────────────
    await supabase.from("analytics_events").insert({
      event_type: "content_created",
      user_id: user.id,
      metadata: {
        content_id: body.content_id,
        content_type: content.content_type,
        file_size_bytes: actualSize ?? content.file_size_bytes,
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

// ── Helpers ───────────────────────────────────────────────────────

/**
 * Reject a failed upload: delete the Storage object and the
 * content DB record so they don't leak as orphans.
 */
async function rejectUpload(
  supabase: ReturnType<typeof createClient>,
  contentId: string,
  storagePath: string,
  reason: string,
) {
  console.warn(`[upload-confirm] Rejecting upload ${contentId}: ${reason}`);

  // Delete the file from Storage
  const { error: removeErr } = await supabase.storage
    .from("content")
    .remove([storagePath]);
  if (removeErr) {
    console.error("Failed to remove rejected file:", removeErr);
  }

  // Hard-delete the inactive content record
  const { error: deleteErr } = await supabase
    .from("content")
    .delete()
    .eq("id", contentId);
  if (deleteErr) {
    console.error("Failed to delete rejected content record:", deleteErr);
  }
}

function jsonResponse(body: Record<string, unknown>, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}
