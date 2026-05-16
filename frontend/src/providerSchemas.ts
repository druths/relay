/**
 * Provider schemas are now fetched from the backend. This file holds the
 * TypeScript shapes and a small React hook that loads + caches them.
 *
 * To add a new provider, edit `backend/app/services/{llm,tts,stt}/__init__.py`
 * — no client changes needed.
 */

import { useEffect, useState } from "react";
import { apiFetch } from "./api";

export interface ProviderField {
  key: string;
  label: string;
  type: "text" | "password" | "select";
  placeholder?: string;
  required?: boolean;
}

export interface ProviderSchemaEntry {
  id: string;
  label: string;
  fields: ProviderField[];
  /** STT only: `apple` is on-device, no server-side provider. */
  client_only?: boolean;
}

export interface ProviderSchemas {
  llm: ProviderSchemaEntry[];
  tts: ProviderSchemaEntry[];
  stt: ProviderSchemaEntry[];
}

/** Process-wide cache so repeated mounts don't re-fetch. */
let _cache: ProviderSchemas | null = null;
let _inflight: Promise<ProviderSchemas> | null = null;

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

/** Hook: returns `null` until the schemas have loaded. */
export function useProviderSchemas(): ProviderSchemas | null {
  const [schemas, setSchemas] = useState<ProviderSchemas | null>(_cache);
  useEffect(() => {
    if (_cache) return;
    load().then(setSchemas).catch((err) => {
      console.error("Failed to load provider schemas", err);
    });
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
