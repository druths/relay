import { useRef, useState, useEffect, type KeyboardEvent } from "react";

// 11x9 pixel grid for ⏎ return arrow — matches iOS PixelIcons.returnArrow
const RETURN_GRID = [
  "..........#",
  "..........#",
  "..........#",
  "..........#",
  "..#.......#",
  ".##.......#",
  "###########",
  ".##........",
  "..#........",
];

function ReturnIcon({ color }: { color: string }) {
  const rects: string[] = [];
  for (let r = 0; r < RETURN_GRID.length; r++) {
    for (let c = 0; c < RETURN_GRID[0].length; c++) {
      if (RETURN_GRID[r][c] === "#") {
        rects.push(`M${c},${r}h1v1h-1z`);
      }
    }
  }
  return (
    <svg width="22" height="18" viewBox="0 0 11 9">
      <path d={rects.join("")} fill={color} />
    </svg>
  );
}

function isTvaTheme(): boolean {
  if (typeof document === "undefined") return false;
  const t = document.documentElement.getAttribute("data-theme") ?? "";
  return t === "tva" || t === "tva_mono";
}

interface TextInputProps {
  onSend: (text: string) => void;
  disabled: boolean;
}

export function TextInput({ onSend, disabled }: TextInputProps) {
  const [value, setValue] = useState("");
  const textareaRef = useRef<HTMLTextAreaElement>(null);
  const tva = isTvaTheme();

  const handleSend = () => {
    const trimmed = value.trim();
    if (!trimmed) return;
    onSend(trimmed);
    setValue("");
  };

  const handleKey = (e: KeyboardEvent) => {
    if (e.key === "Enter" && !e.shiftKey) {
      e.preventDefault();
      handleSend();
    }
    // Shift+Enter inserts a newline (default textarea behavior)
  };

  // Auto-resize textarea to fit content, capped at 6 lines
  useEffect(() => {
    const el = textareaRef.current;
    if (!el) return;
    el.style.height = "auto";
    const maxHeight = parseInt(getComputedStyle(el).lineHeight) * 6 || 144;
    el.style.height = `${Math.min(el.scrollHeight, maxHeight)}px`;
  }, [value]);

  const placeholder = disabled ? "Connect to start…" : "Type a message…";

  return (
    <div className="flex gap-2 p-4 border-t border-gray-800 input-bar items-end">
      <textarea
        ref={textareaRef}
        value={value}
        onChange={(e) => setValue(e.target.value)}
        onKeyDown={handleKey}
        disabled={disabled}
        placeholder={placeholder}
        rows={1}
        className="flex-1 bg-gray-800 rounded-lg px-4 py-2 text-sm outline-none
                   focus:ring-2 focus:ring-blue-500 disabled:opacity-50
                   placeholder-gray-500 resize-none overflow-hidden"
      />
      <button
        onClick={handleSend}
        disabled={disabled || !value.trim()}
        className="send-btn bg-blue-600 hover:bg-blue-500 disabled:bg-gray-700
                   disabled:opacity-50 rounded-lg px-4 py-2 text-sm font-medium
                   transition-colors flex items-center justify-center"
      >
        {tva ? (
          <ReturnIcon color="var(--bg)" />
        ) : (
          "Send"
        )}
      </button>
    </div>
  );
}
