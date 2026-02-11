/**
 * Shared assertion verification for Edge Functions.
 *
 * Every sensitive Edge Function imports this and calls verifyAssertion()
 * immediately after JWT authentication. This ensures ongoing requests
 * are bound to the original attested device — a stolen JWT alone is
 * not enough to act as the user.
 *
 * Expected request headers from the iOS client:
 *   X-App-Assertion : base64-encoded CBOR assertion from DCAppAttestService
 *   X-App-KeyId     : the attested key identifier stored in Keychain
 *
 * v1: Validates that the key exists, belongs to the user, is not
 *     blacklisted, and the assertion payload is structurally valid.
 * v2 TODO: Full CBOR decode → signature verification → counter check.
 */

import { SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";

export interface AssertionResult {
  valid: boolean;
  error?: string;
  keyId?: string;
}

export async function verifyAssertion(
  supabase: SupabaseClient,
  req: Request,
  userId: string
): Promise<AssertionResult> {
  const assertion = req.headers.get("X-App-Assertion");
  const keyId = req.headers.get("X-App-KeyId");

  // ── Development bypass ──────────────────────────────────────────
  // When ENVIRONMENT is "development" (set in Supabase Dashboard →
  // Edge Functions → Secrets), missing assertion headers are allowed
  // so the simulator and debug builds can function.
  if (!assertion || !keyId) {
    const env = Deno.env.get("ENVIRONMENT") ?? "production";
    if (env === "development") {
      return { valid: true, keyId: "dev-bypass" };
    }
    return { valid: false, error: "Missing attestation headers (X-App-Assertion, X-App-KeyId)" };
  }

  // ── Look up attestation record ──────────────────────────────────
  const { data: attestation, error: lookupError } = await supabase
    .from("device_attestations")
    .select("id, key_id, user_id, is_valid, is_blacklisted")
    .eq("key_id", keyId)
    .eq("user_id", userId)
    .single();

  if (lookupError || !attestation) {
    return { valid: false, error: "No attestation record for this key/user pair" };
  }

  if (!attestation.is_valid) {
    return { valid: false, error: "Attestation has been invalidated" };
  }

  if (attestation.is_blacklisted) {
    return { valid: false, error: "Device has been blacklisted" };
  }

  // ── Structural validation of the assertion blob ─────────────────
  try {
    const bytes = Uint8Array.from(atob(assertion), (c) => c.charCodeAt(0));
    if (bytes.length < 50) {
      return { valid: false, error: "Assertion payload too short" };
    }
  } catch {
    return { valid: false, error: "Assertion is not valid base64" };
  }

  // ── Update last-used timestamp ──────────────────────────────────
  // (non-blocking — don't fail the request if this update errors)
  supabase
    .from("device_attestations")
    .update({ last_used_at: new Date().toISOString() })
    .eq("key_id", keyId)
    .then(() => {});

  return { valid: true, keyId };
}
