/**
 * Provider schemas are now fetched from the backend. This file holds the
 * TypeScript shapes and a small React hook that loads + caches them.
 *
 * To add a new provider, edit `backend/app/services/{llm,tts,stt}/__init__.py`
 * — no client changes needed.
 */

import { useEffect, useState } from "react";
import { apiFetch } from "./api";

export interface ProviderFieldOption {
  value: string;
  label: string;
}

export interface ProviderField {
  key: string;
  label: string;
  type: "text" | "password" | "select";
  placeholder?: string;
  required?: boolean;
  /** For `type === "select"` fields: the choices to render. */
  options?: ProviderFieldOption[];
  /** Storage key in PlatformSetting when the user sets a platform-wide default. */
  platform_key?: string;
  /** Whether a platform-wide default is currently set for this field. */
  platform_default_set?: boolean;
}

export interface ProviderSchemaEntry {
  id: string;
  label: string;
  fields: ProviderField[];
  /** STT only: `apple` is on-device, no server-side provider. */
  client_only?: boolean;
}

export interface ProviderDefaultsField {
  platform_key: string;
  label: string;
  type: "text" | "password";
  placeholder?: string;
  value: string | null;
}

export interface ProviderDefaultsProvider {
  id: string;
  label: string;
  fields: ProviderDefaultsField[];
}

export interface ProviderDefaultsGroup {
  category: string;
  label: string;
  providers: ProviderDefaultsProvider[];
}

export interface ProviderSchemas {
  llm: ProviderSchemaEntry[];
  tts: ProviderSchemaEntry[];
  stt: ProviderSchemaEntry[];
}

/** Process-wide cache so repeated mounts don't re-fetch. */
let _cache: ProviderSchemas | null = null;
let _inflight: Promise<ProviderSchemas> | null = null;
let _subscribers: Set<(s: ProviderSchemas) => void> = new Set();

/** Invalidate the cache so the next `useProviderSchemas` (or `load()`) call
 * re-fetches. Notify any mounted subscribers so they pick up the fresh data
 * immediately. Call after the user saves provider defaults. */
export function invalidateProviderSchemas(): void {
  _cache = null;
  _inflight = null;
  load().then((s) => {
    for (const cb of _subscribers) cb(s);
  });
}

async function load(): Promise<ProviderSchemas> {
  if (_cache) return _cache;
  if (_inflight) return _inflight;
  _inflight = (async () => {
    const [llm, tts, stt] = await Promise.all([
      apiFetch("/v1/agents/llm/providers").then((r) => r.json()),
      apiFetch("/v1/agents/tts/providers").then((r) => r.json()),
      apiFetch("/v1/agents/stt/providers").then((r) => r.json()),
    ]);
    _cache = { llm, tts, stt };
    _inflight = null;
    return _cache;
  })();
  return _inflight;
}

/** Hook: returns `null` until the schemas have loaded. Subscribes for cache
 * invalidations so the component re-renders when defaults change. */
export function useProviderSchemas(): ProviderSchemas | null {
  const [schemas, setSchemas] = useState<ProviderSchemas | null>(_cache);
  useEffect(() => {
    if (!_cache) {
      load().then(setSchemas).catch((err) => {
        console.error("Failed to load provider schemas", err);
      });
    }
    _subscribers.add(setSchemas);
    return () => {
      _subscribers.delete(setSchemas);
    };
  }, []);
  return schemas;
}

/** Lookup helpers — return undefined until schemas load. */
export function findSchema(
  schemas: ProviderSchemaEntry[] | undefined,
  id: string,
): ProviderSchemaEntry | undefined {
  return schemas?.find((s) => s.id === id);
}
