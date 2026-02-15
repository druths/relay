import { useRelay } from "./hooks/useRelay";
import { StatusOrb } from "./components/StatusOrb";
import { ConversationLog } from "./components/ConversationLog";
import { TextInput } from "./components/TextInput";
import { AgentSelector } from "./components/AgentSelector";
import { VoiceSettings } from "./components/VoiceSettings";

function App() {
  const relay = useRelay();

  const handleAgentSelect = (agentName: string) => {
    relay.sendMessage(`connect me to ${agentName}`);
  };

  const inSession = relay.activeSessionId !== null;

  return (
    <div className="h-screen flex">
      {/* Sidebar */}
      <aside className="w-64 border-r border-gray-800 flex flex-col gap-6 p-4 bg-gray-900/50 overflow-y-auto">
        <div>
          <h1 className="text-lg font-bold tracking-tight">Relay</h1>
          <p className="text-xs text-gray-500">
            {inSession ? `Session with ${relay.activeAgentName}` : "Lobby"}
          </p>
        </div>

        <StatusOrb
          activeSpeaker={relay.activeSpeaker}
          status={relay.status}
          connected={relay.connected}
        />

        {!relay.connected ? (
          <button
            onClick={() => relay.connect()}
            className="bg-blue-600 hover:bg-blue-500 rounded-lg px-4 py-2 text-sm
                       font-medium transition-colors"
          >
            Connect
          </button>
        ) : (
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
            <button
              onClick={() => relay.disconnect()}
              className="bg-gray-700 hover:bg-gray-600 rounded-lg px-4 py-2 text-sm
                         font-medium transition-colors"
            >
              Disconnect
            </button>
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

        <VoiceSettings agents={relay.agents} onUpdate={relay.updateAgentConfig} />
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
    </div>
  );
}

export default App;
