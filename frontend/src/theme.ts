/** Theme system — manages appearance switching and localStorage persistence. */

export type ThemeName = "default" | "light" | "tva" | "tva_mono";

const STORAGE_KEY = "relay_appearance_theme";

const VALID_THEMES: ThemeName[] = ["default", "light", "tva", "tva_mono"];

export function getStoredTheme(): ThemeName {
  const stored = localStorage.getItem(STORAGE_KEY);
  return VALID_THEMES.includes(stored as ThemeName) ? (stored as ThemeName) : "default";
}

export function setStoredTheme(name: ThemeName): void {
  localStorage.setItem(STORAGE_KEY, name);
}

export function applyTheme(name: ThemeName): void {
  document.documentElement.setAttribute("data-theme", name);
  setStoredTheme(name);
}

// Apply on load
applyTheme(getStoredTheme());
