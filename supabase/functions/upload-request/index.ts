/**
 * upload-request Edge Function
 *
 * Validates the upload request, creates a content record in the DB,
 * generates a signed upload URL for Supabase Storage, and returns both.
 *
 * The client uploads directly to Storage using the signed URL,
 * then calls upload-confirm to activate the content.
 *
 * Deploy with: supabase functions deploy upload-request --no-verify-jwt
 *
 * Environment variables (auto-provided):
 *   - SUPABASE_URL
 *   - SUPABASE_SERVICE_ROLE_KEY
 */

import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

interface UploadRequest {
  content_type: "image" | "video";
  file_extension: string;
  file_size_bytes: number;
  capture_lat: number;
  capture_lng: number;
  horizontal_accuracy: number;
  duration_ms?: number;
  cell_id: string;
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

    // Check if user is banned
    const { data: banCheck } = await supabase.rpc("check_banned");
    if (banCheck === true) {
      return jsonResponse({ error: "Access revoked" }, 403);
    }

    // Check rate limit
    const { data: rateLimitResult } = await supabase.rpc("check_rate_limit", {
      p_user_id: user.id,
      p_action: "upload_request",
    });

    if (rateLimitResult === "hard_exceeded") {
      await supabase.rpc("decrease_trust_score", {
        p_user_id: user.id,
        p_amount: 5,
        p_reason: "upload_rate_limit_hard_exceeded",
      });
      return jsonResponse({ error: "Rate limit exceeded", code: "rate_limited" }, 429);
    }

    if (rateLimitResult === "soft_exceeded") {
      return jsonResponse({ error: "Captcha required", code: "captcha_required" }, 429);
    }

    // Parse request body
    const body: UploadRequest = await req.json();

    // Validate fields
    if (!body.content_type || !body.file_extension || !body.capture_lat || !body.capture_lng) {
      return jsonResponse({ error: "Missing required fields" }, 400);
    }

    if (!["image", "video"].includes(body.content_type)) {
      return jsonResponse({ error: "Invalid content type" }, 400);
    }

    if (body.file_size_bytes > 50 * 1024 * 1024) {
      return jsonResponse({ error: "File too large (max 50MB)" }, 400);
    }

    if (body.horizontal_accuracy >= 100) {
      return jsonResponse({ error: "GPS accuracy insufficient" }, 400);
    }

    // Check content creation rate limit
    const actionType = body.content_type === "video" ? "video_create" : "content_create";
    const { data: contentRateResult } = await supabase.rpc("check_rate_limit", {
      p_user_id: user.id,
      p_action: actionType,
    });

    if (contentRateResult === "hard_exceeded") {
      return jsonResponse({ error: "Content creation rate limit exceeded", code: "rate_limited" }, 429);
    }

    if (contentRateResult === "soft_exceeded") {
      return jsonResponse({ error: "Captcha required", code: "captcha_required" }, 429);
    }

    // Generate content ID and storage path
    const contentId = crypto.randomUUID();
    const now = new Date();
    const datePath = `${now.getUTCFullYear()}/${String(now.getUTCMonth() + 1).padStart(2, "0")}/${String(now.getUTCDate()).padStart(2, "0")}`;
    const storagePath = `originals/${datePath}/${contentId}.${body.file_extension}`;

    // Create content record (inactive until confirmed)
    const { error: insertError } = await supabase.from("content").insert({
      id: contentId,
      user_id: user.id,
      capture_lat: body.capture_lat,
      capture_lng: body.capture_lng,
      capture_point: `SRID=4326;POINT(${body.capture_lng} ${body.capture_lat})`,
      horizontal_accuracy: body.horizontal_accuracy,
      cell_id: body.cell_id,
      content_type: body.content_type,
      duration_ms: body.duration_ms ?? null,
      original_path: storagePath,
      file_size_bytes: body.file_size_bytes,
      is_deleted: true, // Inactive until upload-confirm
    });

    if (insertError) {
      console.error("Insert error:", insertError);
      return jsonResponse({ error: "Failed to create content record" }, 500);
    }

    // Generate signed upload URL (expires in 10 minutes)
    const { data: signedUrl, error: signError } = await supabase.storage
      .from("content")
      .createSignedUploadUrl(storagePath);

    if (signError || !signedUrl) {
      // Cleanup the content record
      await supabase.from("content").delete().eq("id", contentId);
      console.error("Sign error:", signError);
      return jsonResponse({ error: "Failed to generate upload URL" }, 500);
    }

    return jsonResponse({
      content_id: contentId,
      upload_url: signedUrl.signedUrl,
      upload_token: signedUrl.token,
      storage_path: storagePath,
      expires_in: 600, // 10 minutes
    });
  } catch (err) {
    console.error("Upload request error:", err);
    return jsonResponse({ error: "Internal error" }, 500);
  }
});

function jsonResponse(body: Record<string, unknown>, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}
