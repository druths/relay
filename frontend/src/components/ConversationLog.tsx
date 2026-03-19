import { useEffect, useRef } from "react";
import type { Message } from "../types";

interface ConversationLogProps {
  lobbyMessages: Message[];
  sessionMessages: Message[];
  activeSessionId: string | null;
  activeAgentName: string | null;
}

const ROLE_STYLES: Record<string, string> = {
  user: "bg-gray-800 ml-12 text-right",
  operator: "bg-blue-900/40 mr-12",
  agent: "bg-emerald-900/40 mr-12",
};


export function ConversationLog({
  lobbyMessages,
  sessionMessages,
  activeSessionId,
  activeAgentName,
}: ConversationLogProps) {
  const endRef = useRef<HTMLDivElement>(null);
  const messages = activeSessionId ? sessionMessages : lobbyMessages;

  useEffect(() => {
    endRef.current?.scrollIntoView({ behavior: "smooth" });
  }, [messages]);

  if (messages.length === 0) {
    return (
      <div className="flex-1 flex items-center justify-center text-gray-600 text-sm">
        {activeSessionId
          ? `In session with ${activeAgentName ?? "agent"}. Loading…`
          : "Connect to start a conversation."}
      </div>
    );
  }

  return (
    <div className="flex-1 overflow-y-auto space-y-3 p-4">
      {activeSessionId && (
        <div className="text-center text-xs text-gray-600 py-2 border-b border-gray-800 mb-2">
          Session with {activeAgentName}
        </div>
      )}
      {messages.map((msg, i) => (
        <div
          key={i}
          className={`rounded-lg px-4 py-3 text-sm ${
            ROLE_STYLES[msg.role] || ROLE_STYLES.agent
          }`}
        >
          <div className="whitespace-pre-wrap">
            {msg.text_content}
            {msg.streaming && (
              <span className="inline-flex items-end gap-0.5 ml-1.5 mb-0.5">
                {[0, 1, 2].map((i) => (
                  <span
                    key={i}
                    className="block w-1.5 h-1.5 rounded-full bg-gray-400"
                    style={{
                      animation: "dotPulse 0.9s ease-in-out infinite",
                      animationDelay: `${i * 0.15}s`,
                    }}
                  />
                ))}
              </span>
            )}
          </div>
        </div>
      ))}
      <div ref={endRef} />
    </div>
  );
}
