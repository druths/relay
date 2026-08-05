import { useEffect, useRef, useState } from "react";

interface Option {
  /** Value the parent stores in state. */
  value: string;
  /** Label shown to the user. */
  label: string;
}

interface Props {
  /** Prefix shown before the value ("Project", "Label"). Kept as
   *  its own prop so the button reads "Project: All" / "Label: foo"
   *  consistently across filters. */
  title: string;
  options: Option[];
  /** Currently-selected value, or null for "no filter." */
  value: string | null;
  onChange: (next: string | null) => void;
  /** Show a search field inside the popover once the option list
   *  exceeds this count. Small lists don't need one. */
  searchThreshold?: number;
}

/// Compact single-select filter. Renders as a chip-like button that
/// shows "Title: All" when unset or "Title: <value>" (with an inline
/// clear ×) when set. Clicking opens a popover with the option list;
/// long lists get a search input at the top. Meant for filtering
/// the session list by project / label — both share this component so
/// the two filters look and behave identically.
export function FilterMenu({
  title, options, value, onChange, searchThreshold = 8,
}: Props) {
  const [open, setOpen] = useState(false);
  const [query, setQuery] = useState("");
  const rootRef = useRef<HTMLDivElement>(null);

  // Close on outside click / Escape.
  useEffect(() => {
    if (!open) return;
    const onDown = (e: MouseEvent) => {
      if (!rootRef.current) return;
      if (!rootRef.current.contains(e.target as Node)) setOpen(false);
    };
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") setOpen(false);
    };
    document.addEventListener("mousedown", onDown);
    document.addEventListener("keydown", onKey);
    return () => {
      document.removeEventListener("mousedown", onDown);
      document.removeEventListener("keydown", onKey);
    };
  }, [open]);

  useEffect(() => { if (!open) setQuery(""); }, [open]);

  const selected = value != null
    ? options.find((o) => o.value === value)
    : null;

  const showSearch = options.length > searchThreshold;
  const q = query.trim().toLowerCase();
  const filtered = q
    ? options.filter((o) => o.label.toLowerCase().includes(q))
    : options;

  return (
    <div ref={rootRef} className="relative">
      <button
        type="button"
        onClick={() => setOpen((v) => !v)}
        className="flex items-center gap-1.5 px-2 py-0.5 rounded-full text-xs
                   border border-gray-700 hover:border-gray-500 transition-colors label-chip"
        style={selected
          ? { backgroundColor: "var(--primary)", color: "var(--bg)", borderColor: "transparent" }
          : { backgroundColor: "var(--elevated)", color: "var(--text-tertiary)" }
        }
        title={selected ? `${title}: ${selected.label}` : `${title}: All`}
      >
        <span className="opacity-70">{title}:</span>
        <span className="max-w-[120px] truncate">
          {selected ? selected.label : "All"}
        </span>
        {selected ? (
          <span
            role="button"
            tabIndex={-1}
            onClick={(e) => {
              e.stopPropagation();
              onChange(null);
              setOpen(false);
            }}
            className="opacity-70 hover:opacity-100"
          >
            ×
          </span>
        ) : (
          <span className="opacity-50">▾</span>
        )}
      </button>

      {open && (
        <div className="absolute left-0 top-full mt-1 z-30 w-48
                        bg-gray-900 border border-gray-700 rounded-md shadow-xl">
          {showSearch && (
            <div className="p-1.5 border-b border-gray-800">
              <input
                autoFocus
                type="text"
                value={query}
                onChange={(e) => setQuery(e.target.value)}
                placeholder="Search…"
                className="w-full px-2 py-1 text-xs bg-gray-800 border border-gray-700
                           rounded outline-none focus:border-blue-500 text-gray-200"
              />
            </div>
          )}
          <div className="max-h-56 overflow-y-auto py-0.5">
            <button
              type="button"
              onClick={() => { onChange(null); setOpen(false); }}
              className={`w-full text-left px-3 py-1 text-xs transition-colors ${
                value == null
                  ? "bg-gray-800 text-gray-100"
                  : "text-gray-300 hover:bg-gray-800/70"
              }`}
            >
              All
            </button>
            {filtered.length === 0 && q && (
              <div className="px-3 py-1.5 text-xs text-gray-500 italic">No matches.</div>
            )}
            {filtered.map((o) => (
              <button
                key={o.value}
                type="button"
                onClick={() => { onChange(o.value); setOpen(false); }}
                className={`w-full text-left px-3 py-1 text-xs transition-colors truncate ${
                  o.value === value
                    ? "bg-gray-800 text-gray-100"
                    : "text-gray-300 hover:bg-gray-800/70"
                }`}
                title={o.label}
              >
                {o.label}
              </button>
            ))}
          </div>
        </div>
      )}
    </div>
  );
}
