import { useEffect, useState } from "react";

interface StatusOrbProps {
  activeSpeaker: string;
  displayName?: string;
  status: string;
  connected: boolean;
}

const SPEAKER_COLORS: Record<string, string> = {
  operator: "bg-blue-500 shadow-blue-500/50",
  system: "bg-gray-400 shadow-gray-400/50",
};

const AGENT_COLOR = "bg-emerald-500 shadow-emerald-500/50";

// Pixel face frames as 13x13 grids (0=empty, 1=face fill, 2=feature/cutout)
const IDLE_FRAMES = [
  // smile
  [
    "...1111111...",
    "..111111111..",
    ".11111111111.",
    "1111111111111",
    "111221112211 ",
    "1112211122111",
    "1111111111111",
    "1111111111111",
    "1112111112111",
    "1111222221111",
    ".11111111111.",
    "..111111111..",
    "...1111111...",
  ],
  // soft smile
  [
    "...1111111...",
    "..111111111..",
    ".11111111111.",
    "1111111111111",
    "1112211122111",
    "1112211122111",
    "1111111111111",
    "1111111111111",
    "1111211121111",
    "1111122211111",
    ".11111111111.",
    "..111111111..",
    "...1111111...",
  ],
  // wink
  [
    "...1111111...",
    "..111111111..",
    ".11111111111.",
    "1111111111111",
    "1112211122111",
    "1112211111211",
    "1111111111111",
    "1111111111111",
    "1112111112111",
    "1111222221111",
    ".11111111111.",
    "..111111111..",
    "...1111111...",
  ],
  // bliss
  [
    "...1111111...",
    "..111111111..",
    ".11111111111.",
    "1111111111111",
    "1111111111111",
    "1122221222211",
    "1111111111111",
    "1111111111111",
    "1112111112111",
    "1111222221111",
    ".11111111111.",
    "..111111111..",
    "...1111111...",
  ],
];

const THINKING_FRAMES = [
  // focused
  [
    "...1111111...",
    "..111111111..",
    ".11111111111.",
    "1111111111111",
    "1112211122111",
    "1112211122111",
    "1111111111111",
    "1111111111111",
    "1111222211111",
    "1111111111111",
    ".11111111111.",
    "..111111111..",
    "...1111111...",
  ],
  // look right
  [
    "...1111111...",
    "..111111111..",
    ".11111111111.",
    "1111111111111",
    "1111221112211",
    "1111221112211",
    "1111111111111",
    "1111111111111",
    "1111122221111",
    "1111111111111",
    ".11111111111.",
    "..111111111..",
    "...1111111...",
  ],
];

const OFFLINE_FRAMES = [
  [
    "...1111111...",
    "..111111111..",
    ".11111111111.",
    "1111111111111",
    "1111111111111",
    "1122221222211",
    "1111111111111",
    "1111111111111",
    "1111222221111",
    "1111111111111",
    ".11111111111.",
    "..111111111..",
    "...1111111...",
  ],
];

function PixelFace({ frame, className }: { frame: string[]; className?: string }) {
  const pixelSize = 4;
  const rows = frame.length;
  const cols = frame[0].length;

  return (
    <svg
      width={cols * pixelSize}
      height={rows * pixelSize}
      className={className}
      style={{ display: "block" }}
    >
      {frame.map((row, y) =>
        [...row].map((ch, x) => {
          if (ch === "1") {
            return (
              <rect
                key={`${y}-${x}`}
                x={x * pixelSize}
                y={y * pixelSize}
                width={pixelSize}
                height={pixelSize}
                fill="var(--primary, #d49000)"
              />
            );
          }
          if (ch === "2") {
            return (
              <rect
                key={`${y}-${x}`}
                x={x * pixelSize}
                y={y * pixelSize}
                width={pixelSize}
                height={pixelSize}
                fill="var(--bg, #050400)"
              />
            );
          }
          return null;
        })
      )}
    </svg>
  );
}

export function StatusOrb({ activeSpeaker, displayName, status, connected }: StatusOrbProps) {
  const label = displayName ?? activeSpeaker;
  const [frame, setFrame] = useState(0);
  const isProcessing = status === "processing";
  const isTvaTheme =
    typeof document !== "undefined" &&
    ["tva", "tva_mono", "retro_green"].includes(
      document.documentElement.getAttribute("data-theme") ?? ""
    );

  useEffect(() => {
    if (!isTvaTheme) return;
    const interval = setInterval(
      () => setFrame((f) => f + 1),
      isProcessing ? 800 : 2000
    );
    return () => clearInterval(interval);
  }, [isTvaTheme, isProcessing]);

  // Reset frame on state change
  useEffect(() => setFrame(0), [connected, isProcessing]);

  if (!connected) {
    if (isTvaTheme) {
      const frames = OFFLINE_FRAMES;
      return (
        <div className="flex flex-col items-center gap-2">
          <PixelFace frame={frames[frame % frames.length]} className="status-orb-glow" />
          <span className="text-xs uppercase tracking-wider section-label" style={{ color: "var(--text-tertiary)" }}>
            Offline
          </span>
        </div>
      );
    }
    return (
      <div className="flex flex-col items-center gap-2">
        <div className="w-16 h-16 rounded-full bg-gray-700 shadow-lg status-dot" />
        <span className="text-xs text-gray-500 uppercase tracking-wider section-label">Offline</span>
      </div>
    );
  }

  if (isTvaTheme) {
    const frames = isProcessing ? THINKING_FRAMES : IDLE_FRAMES;
    return (
      <div className="flex flex-col items-center gap-2">
        <PixelFace frame={frames[frame % frames.length]} className="status-orb-glow" />
        <span className="text-xs uppercase tracking-wider section-label" style={{ color: "var(--text-tertiary)" }}>
          {label} {isProcessing ? "— thinking" : ""}
        </span>
      </div>
    );
  }

  const colorClass = SPEAKER_COLORS[activeSpeaker] || AGENT_COLOR;

  return (
    <div className="flex flex-col items-center gap-2">
      <div
        className={`w-16 h-16 rounded-full shadow-lg transition-all duration-300 status-dot status-orb-glow ${colorClass} ${
          isProcessing ? "animate-pulse scale-110" : ""
        }`}
      />
      <span className="text-xs text-gray-400 uppercase tracking-wider section-label">
        {label} {isProcessing ? "— thinking" : ""}
      </span>
    </div>
  );
}
