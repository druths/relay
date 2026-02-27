import { useState } from "react";
import { isAuthenticated, clearToken } from "./hooks/useAuth";
import { LoginPage } from "./components/LoginPage";
import { useRelay } from "./hooks/useRelay";
import { StatusOrb } from "./components/StatusOrb";
import { ConversationLog } from "./components/ConversationLog";
import { TextInput } from "./components/TextInput";
import { AgentSelector } from "./components/AgentSelector";
import { AgentManagement } from "./components/AgentManagement";

function App() {
  const [authed, setAuthed] = useState(isAuthenticated());

  if (!authed) {
    return <LoginPage onLogin={() => setAuthed(true)} />;
  }

  return <RelayApp onLogout={() => { clearToken(); setAuthed(false); }} />;
}

function RelayApp({ onLogout }: { onLogout: () => void }) {
  const relay = useRelay();
  const [showSettings, setShowSettings] = useState(false);

  const handleAgentSelect = (agentName: string) => {
    relay.sendMessage(`connect me to ${agentName}`);
  };

  const inSession = relay.activeSessionId !== null;

  return (
    <div className="h-screen flex">
      {/* Sidebar */}
      <aside className="w-64 border-r border-gray-800 flex flex-col gap-6 p-4 bg-gray-900/50 overflow-y-auto">
        <div className="flex items-center justify-between">
          <div>
            <h1 className="text-lg font-bold tracking-tight">Relay</h1>
            <p className="text-xs text-gray-500">
              {inSession ? `Session with ${relay.activeAgentName}` : "Lobby"}
            </p>
          </div>
          <button
            onClick={() => setShowSettings(true)}
            className="text-gray-500 hover:text-gray-300 transition-colors p-1"
            title="Agent Management"
          >
            <svg xmlns="http://www.w3.org/2000/svg" className="w-5 h-5" viewBox="0 0 20 20" fill="currentColor">
              <path fillRule="evenodd" d="M11.49 3.17c-.38-1.56-2.6-1.56-2.98 0a1.532 1.532 0 01-2.286.948c-1.372-.836-2.942.734-2.106 2.106.54.886.061 2.042-.947 2.287-1.561.379-1.561 2.6 0 2.978a1.532 1.532 0 01.947 2.287c-.836 1.372.734 2.942 2.106 2.106a1.532 1.532 0 012.287.947c.379 1.561 2.6 1.561 2.978 0a1.533 1.533 0 012.287-.947c1.372.836 2.942-.734 2.106-2.106a1.533 1.533 0 01.947-2.287c1.561-.379 1.561-2.6 0-2.978a1.532 1.532 0 01-.947-2.287c.836-1.372-.734-2.942-2.106-2.106a1.532 1.532 0 01-2.287-.947zM10 13a3 3 0 100-6 3 3 0 000 6z" clipRule="evenodd" />
            </svg>
          </button>
        </div>

        <StatusOrb
          activeSpeaker={relay.activeSpeaker}
          status={relay.status}
          connected={relay.connected}
        />

        {relay.connected && (
          <div className="flex flex-col gap-2">
            {inSession && (
              <button
                onClick={() => relay.leaveSession()}
                className="bg-amber-700 hover:bg-amber-600 rounded-lg px-4 py-2 text-sm
                           font-medium transition-colors"
              >
                Back to Lobby
              </button>
            )}
          </div>
        )}

        {/* Agent selector — only show in lobby */}
        {relay.connected && !inSession && (
          <AgentSelector
            agents={relay.agents}
            activeSpeaker={relay.activeSpeaker}
            onSelect={handleAgentSelect}
            disabled={false}
          />
        )}

        {/* Session list — show in lobby when sessions exist */}
        {relay.connected && !inSession && relay.sessions.length > 0 && (
          <div className="space-y-2">
            <h3 className="text-xs font-semibold text-gray-500 uppercase tracking-wider px-1">
              Sessions
            </h3>
            <div className="space-y-1">
              {relay.sessions.map((s) => (
                <button
                  key={s.session_id}
                  onClick={() => relay.resumeSession(s.session_id)}
                  className="w-full text-left px-3 py-2 rounded-lg text-sm
                             hover:bg-gray-800 text-gray-300 transition-colors"
                >
                  <div className="font-medium">{s.name || s.agent_name}</div>
                  <div className="text-xs text-gray-500">
                    {s.agent_name} &middot; {s.status}
                  </div>
                  {s.summary && (
                    <div className="text-xs text-gray-600 mt-0.5 line-clamp-2">
                      {s.summary}
                    </div>
                  )}
                </button>
              ))}
            </div>
          </div>
        )}

        {/* Logout */}
        <button
          onClick={onLogout}
          className="text-gray-600 hover:text-gray-400 text-xs mt-auto transition-colors"
        >
          Logout
        </button>
      </aside>

      {/* Main conversation area */}
      <main className="flex-1 flex flex-col">
        <ConversationLog
          lobbyMessages={relay.lobbyMessages}
          sessionMessages={relay.sessionMessages}
          activeSessionId={relay.activeSessionId}
          activeAgentName={relay.activeAgentName}
        />
        <TextInput
          onSend={relay.sendMessage}
          onSendAudio={relay.sendAudio}
          onStopAudio={relay.stopAudio}
          disabled={!relay.connected}
          muted={relay.muted}
          onToggleMute={relay.toggleMute}
          sttAvailable={relay.sttAvailable}
        />
      </main>

      {/* Agent Management modal */}
      {showSettings && (
        <AgentManagement
          agents={relay.agents}
          onClose={() => setShowSettings(false)}
          onAgentsChanged={relay.refreshAgents}
        />
      )}
    </div>
  );
}

export default App;
