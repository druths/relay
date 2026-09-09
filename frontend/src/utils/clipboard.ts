/// Copy text to the clipboard, resilient to non-secure contexts.
///
/// `navigator.clipboard` only exists on HTTPS or localhost. Dev Relay
/// accessed over plain HTTP (a LAN IP, Tailscale magic DNS, etc.)
/// silently 404s the modern API — the previous inline `.catch(() =>
/// {})` swallowed the rejection and the copy button appeared broken
/// with no user-visible feedback. Fall back to the legacy synchronous
/// `document.execCommand("copy")` in that case; it still works in
/// every current browser as long as the call is inside a user gesture
/// (which every menu-item onClick is by definition).
export async function copyToClipboard(text: string): Promise<boolean> {
  if (navigator.clipboard && window.isSecureContext) {
    try {
      await navigator.clipboard.writeText(text);
      return true;
    } catch {
      // Permission denied, focus mismatch, etc. — fall through.
    }
  }
  // Legacy fallback: attach an off-screen textarea, select, copy, remove.
  // `off-screen` (not `hidden`) matters — a `display: none` element can't
  // be selected on some browsers.
  try {
    const ta = document.createElement("textarea");
    ta.value = text;
    ta.setAttribute("readonly", "");
    ta.style.position = "fixed";
    ta.style.top = "-1000px";
    ta.style.opacity = "0";
    document.body.appendChild(ta);
    ta.select();
    const ok = document.execCommand("copy");
    document.body.removeChild(ta);
    return ok;
  } catch {
    return false;
  }
}
