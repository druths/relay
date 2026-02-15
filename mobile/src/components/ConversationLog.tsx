import { useEffect, useRef } from "react";
import { FlatList, StyleSheet, Text, View } from "react-native";
import type { Message } from "../types";
import { MessageBubble } from "./MessageBubble";

interface ConversationLogProps {
  lobbyMessages: Message[];
  sessionMessages: Message[];
  activeSessionId: string | null;
  activeAgentName: string | null;
}

export function ConversationLog({
  lobbyMessages,
  sessionMessages,
  activeSessionId,
  activeAgentName,
}: ConversationLogProps) {
  const listRef = useRef<FlatList>(null);
  const messages = activeSessionId ? sessionMessages : lobbyMessages;

  useEffect(() => {
    if (messages.length > 0) {
      // Small delay to let the FlatList render the new item
      setTimeout(() => {
        listRef.current?.scrollToEnd({ animated: true });
      }, 100);
    }
  }, [messages.length, messages[messages.length - 1]?.text_content]);

  if (messages.length === 0) {
    return (
      <View style={styles.emptyContainer}>
        <Text style={styles.emptyText}>
          {activeSessionId
            ? `In session with ${activeAgentName ?? "agent"}. Loading...`
            : "Connect to start a conversation."}
        </Text>
      </View>
    );
  }

  return (
    <View style={styles.container}>
      {activeSessionId && (
        <View style={styles.sessionHeader}>
          <Text style={styles.sessionHeaderText}>
            Session with {activeAgentName}
          </Text>
        </View>
      )}
      <FlatList
        ref={listRef}
        data={messages}
        keyExtractor={(_, index) => String(index)}
        renderItem={({ item }) => <MessageBubble message={item} />}
        contentContainerStyle={styles.listContent}
        showsVerticalScrollIndicator={false}
      />
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
  },
  emptyContainer: {
    flex: 1,
    justifyContent: "center",
    alignItems: "center",
  },
  emptyText: {
    fontSize: 14,
    color: "#4b5563",
  },
  sessionHeader: {
    borderBottomWidth: 1,
    borderBottomColor: "#1f2937",
    paddingVertical: 8,
    alignItems: "center",
  },
  sessionHeaderText: {
    fontSize: 11,
    color: "#4b5563",
  },
  listContent: {
    padding: 16,
  },
});
