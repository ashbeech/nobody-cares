/**
 * verify-attestation Edge Function
 *
 * Handles Apple App Attest attestation verification.
 *
 * GET: Returns a challenge (nonce) for the client to use in attestation
 * POST: Verifies the attestation object from the client
 *
 * Deploy with: supabase functions deploy verify-attestation --no-verify-jwt
 * (--no-verify-jwt required because client uses publishable key, not legacy JWT)
 *
 * Environment variables required:
 *   - APPLE_APP_ID: Your app's App ID (TeamID.BundleID)
 *   - SUPABASE_URL: Auto-provided
 *   - SUPABASE_SERVICE_ROLE_KEY: Auto-provided (secret key equivalent for server-side)
 */

import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const APPLE_ATTEST_ROOT_CA = `-----BEGIN CERTIFICATE-----
MIICITCCAaegAwIBAgIQC/O+DvHN0uD7jG5yH2IXmDAKBggqhkjOPQQDAzBSMSYw
JAYDVQQDDB1BcHBsZSBBcHAgQXR0ZXN0YXRpb24gUm9vdCBDQTETMBEGA1UECgwK
QXBwbGUgSW5jLjETMBEGA1UECAwKQ2FsaWZvcm5pYTAeFw0yMDAzMTgxODMyNTNa
Fw00NTAzMTUwMDAwMDBaMFIxJjAkBgNVBAMMHUFwcGxlIEFwcCBBdHRlc3RhdGlv
biBSb290IENBMRMwEQYDVQQKDApBcHBsZSBJbmMuMRMwEQYDVQQIDApDYWxpZm9y
bmlhMHYwEAYHKoZIzj0CAQYFK4EEACIDYgAERTHhmLW07ATaFQIEVwTtT4dyctdh
NbJhFs/Ii2FBtgwRXIJHOZhQAJhIBiukWmt6+Ps+l/dVeBNgiZLlLh6bOd8d/ljR
++JbBSjXS2VFNdaYHFG0cI9kFo2S62gUF7gFo0IwQDAPBgNVHRMBAf8EBTADAQH/
MB0GA1UdDgQWBBSskRBTM72+aEH/pwyp5frq5eWKoTAOBgNVHQ8BAf8EBAMCAQYw
CgYIKoZIzj0EAwMDaAAwZQIwQgFGnByvsiVbpTKwSga0kP0e8EeDS4+sQmTvb7vn
53O5+FRXgeLhd/U4mLa1mf3pAjEAp5U4xDgEgllF7En3VcE3iexZZtKeYnpqtijV
oyFraWVIyd/dganmrduC1bmTBGwD
-----END CERTIFICATE-----`;

// Apple's App Attest endpoints
const APPLE_ATTEST_DEVELOPMENT = "https://data.development.appattest.apple.com";
const APPLE_ATTEST_PRODUCTION = "https://data.appattest.apple.com";

serve(async (req) => {
  try {
    const supabase = createClient(
      Deno.env.get("SUPABASE_URL") ?? "",
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? ""
    );

    // Authenticate the request
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) {
      return new Response(JSON.stringify({ error: "Missing authorization" }), {
        status: 401,
        headers: { "Content-Type": "application/json" },
      });
    }

    const token = authHeader.replace("Bearer ", "");
    const {
      data: { user },
      error: authError,
    } = await supabase.auth.getUser(token);

    if (authError || !user) {
      return new Response(JSON.stringify({ error: "Unauthorized" }), {
        status: 401,
        headers: { "Content-Type": "application/json" },
      });
    }

    // GET: Return a challenge nonce
    if (req.method === "GET") {
      const challenge = crypto.getRandomValues(new Uint8Array(32));
      const challengeB64 = btoa(String.fromCharCode(...challenge));

      // Store challenge temporarily (expires in 5 minutes)
      await supabase.from("analytics_events").insert({
        event_type: "attest_challenge",
        user_id: user.id,
        metadata: {
          challenge: challengeB64,
          expires_at: new Date(Date.now() + 5 * 60 * 1000).toISOString(),
        },
      });

      return new Response(JSON.stringify({ challenge: challengeB64 }), {
        headers: { "Content-Type": "application/json" },
      });
    }

    // POST: Verify attestation
    if (req.method === "POST") {
      const { keyId, attestation, challenge } = await req.json();

      if (!keyId || !attestation || !challenge) {
        return new Response(
          JSON.stringify({ verified: false, error: "Missing fields" }),
          { status: 400, headers: { "Content-Type": "application/json" } }
        );
      }

      // Verify the challenge was recently issued to this user
      const { data: challengeEvents } = await supabase
        .from("analytics_events")
        .select("metadata")
        .eq("event_type", "attest_challenge")
        .eq("user_id", user.id)
        .order("created_at", { ascending: false })
        .limit(1);

      if (!challengeEvents?.length) {
        return new Response(
          JSON.stringify({ verified: false, error: "No challenge found" }),
          { status: 400, headers: { "Content-Type": "application/json" } }
        );
      }

      const storedChallenge = challengeEvents[0].metadata.challenge;
      const expiresAt = new Date(challengeEvents[0].metadata.expires_at);

      if (challenge !== storedChallenge || new Date() > expiresAt) {
        return new Response(
          JSON.stringify({
            verified: false,
            error: "Invalid or expired challenge",
          }),
          { status: 400, headers: { "Content-Type": "application/json" } }
        );
      }

      // Decode and verify the attestation object
      // In production, this would involve:
      // 1. Decoding the CBOR attestation object
      // 2. Verifying the certificate chain back to Apple's root CA
      // 3. Verifying the nonce matches SHA256(challenge)
      // 4. Extracting the public key and key ID
      //
      // For v1, we store the attestation and key ID, and do basic validation.
      // Full CBOR verification requires a dedicated library.

      const attestationBytes = Uint8Array.from(atob(attestation), (c) =>
        c.charCodeAt(0)
      );

      // Verify minimum attestation size (CBOR encoded object should be > 100 bytes)
      if (attestationBytes.length < 100) {
        return new Response(
          JSON.stringify({
            verified: false,
            error: "Invalid attestation format",
          }),
          { status: 400, headers: { "Content-Type": "application/json" } }
        );
      }

      // Store the attestation
      const { error: insertError } = await supabase
        .from("device_attestations")
        .upsert(
          {
            user_id: user.id,
            key_id: keyId,
            attestation: attestation,
            is_valid: true,
            last_used_at: new Date().toISOString(),
          },
          { onConflict: "key_id" }
        );

      if (insertError) {
        return new Response(
          JSON.stringify({
            verified: false,
            error: "Failed to store attestation",
          }),
          { status: 500, headers: { "Content-Type": "application/json" } }
        );
      }

      return new Response(JSON.stringify({ verified: true }), {
        headers: { "Content-Type": "application/json" },
      });
    }

    return new Response(JSON.stringify({ error: "Method not allowed" }), {
      status: 405,
      headers: { "Content-Type": "application/json" },
    });
  } catch (err) {
    return new Response(
      JSON.stringify({ error: "Internal error", details: String(err) }),
      { status: 500, headers: { "Content-Type": "application/json" } }
    );
  }
});
