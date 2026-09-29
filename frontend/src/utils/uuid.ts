/// UUID v4 that works in non-secure contexts.
///
/// `crypto.randomUUID()` is only defined on HTTPS/localhost — the
/// same secure-context restriction that hides `navigator.clipboard`
/// and (previously) `crypto.subtle`. Plain-HTTP dev deploys (LAN
/// IPs, Tailscale magic DNS) trip a runtime `TypeError` on the
/// first call. This helper prefers the native API when available
/// and falls back to a small hand-rolled v4 built from
/// `crypto.getRandomValues` (which IS available everywhere).
export function randomUUID(): string {
  const g = globalThis.crypto as (Crypto & { randomUUID?: () => string }) | undefined;
  if (g?.randomUUID) return g.randomUUID();

  // Hand-rolled RFC 4122 v4. `getRandomValues` needs no secure
  // context — it's part of the Web Crypto baseline.
  const bytes = new Uint8Array(16);
  (g ?? crypto).getRandomValues(bytes);
  // Version (4) and variant (10xx) bits per RFC 4122 §4.4.
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  const hex = Array.from(bytes, (b) => b.toString(16).padStart(2, "0"));
  return (
    hex.slice(0, 4).join("") + "-" +
    hex.slice(4, 6).join("") + "-" +
    hex.slice(6, 8).join("") + "-" +
    hex.slice(8, 10).join("") + "-" +
    hex.slice(10, 16).join("")
  );
}
