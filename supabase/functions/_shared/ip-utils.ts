/**
 * Shared IP extraction and IP-level rate limiting for Edge Functions.
 *
 * User-level rate limits stop a single account from going wild.
 * IP-level rate limits stop bot farms that create many throwaway
 * anonymous accounts across different user IDs but share the same
 * IP or IP range.
 *
 * The SQL side lives in migration_v2_security.sql (ip_rate_limits
 * table + check_ip_rate_limit function).
 */

import { SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";

/**
 * Extract the real client IP from proxy/CDN headers.
 * Priority: Cloudflare → X-Real-IP → X-Forwarded-For → "unknown".
 */
export function getClientIP(req: Request): string {
  // Cloudflare (Supabase runs behind Cloudflare by default)
  const cfIP = req.headers.get("cf-connecting-ip");
  if (cfIP) return cfIP.trim();

  // Nginx / generic reverse proxy
  const realIP = req.headers.get("x-real-ip");
  if (realIP) return realIP.trim();

  // Standard multi-hop header — first entry is the client
  const xff = req.headers.get("x-forwarded-for");
  if (xff) {
    const first = xff.split(",")[0];
    if (first) return first.trim();
  }

  return "unknown";
}

/**
 * Check IP-level rate limit via the check_ip_rate_limit() SQL function.
 * Returns "ok" | "soft_exceeded" | "hard_exceeded".
 *
 * Fails open: if the check errors, the request is allowed.
 */
export async function checkIPRateLimit(
  supabase: SupabaseClient,
  clientIP: string,
  action: string
): Promise<string> {
  if (clientIP === "unknown") return "ok";

  try {
    const { data, error } = await supabase.rpc("check_ip_rate_limit", {
      p_ip: clientIP,
      p_action: action,
    });

    if (error) {
      console.error("[ip-utils] check_ip_rate_limit error:", error.message);
      return "ok"; // fail open
    }

    return data ?? "ok";
  } catch (err) {
    console.error("[ip-utils] unexpected error:", err);
    return "ok";
  }
}
