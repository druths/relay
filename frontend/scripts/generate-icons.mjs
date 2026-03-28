/**
 * Generates PWA icons (192x192, 512x512) from the iOS app icon.
 * Uses macOS `sips` — no extra packages needed.
 *
 * Run: node scripts/generate-icons.mjs
 */

import { execSync } from "child_process";
import { existsSync, mkdirSync } from "fs";
import { join, dirname } from "path";
import { fileURLToPath } from "url";

const __dir = dirname(fileURLToPath(import.meta.url));
const src = join(__dir, "../../ios-client/Relay/Assets.xcassets/AppIcon.appiconset/icon-1024.png");
const outDir = join(__dir, "../public/icons");

if (!existsSync(src)) {
  console.error(`Source icon not found: ${src}`);
  process.exit(1);
}

mkdirSync(outDir, { recursive: true });

for (const size of [192, 512, 1024]) {
  const out = join(outDir, `icon-${size}.png`);
  execSync(`sips -z ${size} ${size} "${src}" --out "${out}"`, { stdio: "pipe" });
  console.log(`✓ icon-${size}.png`);
}
