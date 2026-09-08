import { useRef, useState, useEffect, type KeyboardEvent } from "react";
import { uploadFiles } from "../api";
import type { FileAttachment } from "../types";

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
  return t === "tva" || t === "tva_mono" || t === "retro_green";
}

interface TextInputProps {
  onSend: (text: string) => void;
  disabled: boolean;
  sessionId?: string | null;
  onAttachment?: (attachment: FileAttachment) => void;
  /** True while an agent turn is in flight on this session. When set,
   *  the trailing Send button is replaced by a Stop button that fires
   *  `onStop`. Textarea stays editable so the user can start typing
   *  the next prompt while the current turn winds down. */
  busy?: boolean;
  onStop?: () => void;
}

export function TextInput({
  onSend, disabled, sessionId, onAttachment, busy, onStop,
}: TextInputProps) {
  const [value, setValue] = useState("");
  const [uploading, setUploading] = useState(false);
  const textareaRef = useRef<HTMLTextAreaElement>(null);
  const fileInputRef = useRef<HTMLInputElement>(null);
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

  const handleFiles = async (files: FileList | null) => {
    if (!files || files.length === 0 || !onAttachment) return;
    setUploading(true);
    try {
      await uploadFiles(files, sessionId, onAttachment);
    } finally {
      setUploading(false);
      if (fileInputRef.current) fileInputRef.current.value = "";
    }
  };

  const placeholder = disabled ? "Connect to start…" : "Type a message…";

  return (
    <div className="flex gap-2 p-4 border-t border-gray-800 input-bar items-end">
      {onAttachment && (
        <>
          <input
            ref={fileInputRef}
            type="file"
            multiple
            className="hidden"
            onChange={(e) => handleFiles(e.target.files)}
          />
          <button
            type="button"
            onClick={() => fileInputRef.current?.click()}
            disabled={disabled || uploading}
            title="Attach file"
            className="bg-gray-800 hover:bg-gray-700 disabled:opacity-50 rounded-lg
                       h-9 px-3 text-gray-300 transition-colors
                       flex items-center justify-center"
          >
            <svg viewBox="0 0 16 16" width="16" height="16" fill="currentColor">
              <path d="M10.5 1a2.5 2.5 0 0 0-2.5 2.5V11a1.5 1.5 0 0 0 3 0V4a.5.5 0 0 0-1 0v7a.5.5 0 0 1-1 0V3.5a1.5 1.5 0 0 1 3 0V11a2.5 2.5 0 0 1-5 0V3.5a.5.5 0 0 0-1 0V11a3.5 3.5 0 0 0 7 0V3.5A2.5 2.5 0 0 0 10.5 1Z"/>
            </svg>
          </button>
        </>
      )}
      <textarea
        ref={textareaRef}
        data-message-input
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
      {busy && onStop ? (
        <button
          onClick={onStop}
          title="Stop generating"
          className="stop-btn bg-red-700 hover:bg-red-600 rounded-lg px-4 py-2
                     text-sm font-medium text-white transition-colors
                     flex items-center justify-center gap-1.5"
        >
          <span className="inline-block w-2.5 h-2.5 bg-white rounded-sm" aria-hidden />
          Stop
        </button>
      ) : (
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
      )}
    </div>
  );
}
