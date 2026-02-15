interface StatusOrbProps {
  activeSpeaker: string;
  status: string;
  connected: boolean;
}

const SPEAKER_COLORS: Record<string, string> = {
  operator: "bg-blue-500 shadow-blue-500/50",
  system: "bg-gray-400 shadow-gray-400/50",
};

const AGENT_COLOR = "bg-emerald-500 shadow-emerald-500/50";

export function StatusOrb({ activeSpeaker, status, connected }: StatusOrbProps) {
  if (!connected) {
    return (
      <div className="flex flex-col items-center gap-2">
        <div className="w-16 h-16 rounded-full bg-gray-700 shadow-lg" />
        <span className="text-xs text-gray-500 uppercase tracking-wider">Offline</span>
      </div>
    );
  }

  const colorClass = SPEAKER_COLORS[activeSpeaker] || AGENT_COLOR;
  const isProcessing = status === "processing";

  return (
    <div className="flex flex-col items-center gap-2">
      <div
        className={`w-16 h-16 rounded-full shadow-lg transition-all duration-300 ${colorClass} ${
          isProcessing ? "animate-pulse scale-110" : ""
        }`}
      />
      <span className="text-xs text-gray-400 uppercase tracking-wider">
        {activeSpeaker} {isProcessing ? "— thinking" : ""}
      </span>
    </div>
  );
}
