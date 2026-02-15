import {
  ActivityIndicator,
  FlatList,
  Modal,
  Pressable,
  StyleSheet,
  Text,
  View,
} from "react-native";
import { Ionicons } from "@expo/vector-icons";

export interface DeviceOption {
  uid: string;
  name: string;
}

interface DevicePickerModalProps {
  visible: boolean;
  title: string;
  options: DeviceOption[];
  selectedUid: string | null;
  onSelect: (uid: string) => void;
  onClose: () => void;
  loading?: boolean;
}

export function DevicePickerModal({
  visible,
  title,
  options,
  selectedUid,
  onSelect,
  onClose,
  loading,
}: DevicePickerModalProps) {
  return (
    <Modal visible={visible} transparent animationType="slide" onRequestClose={onClose}>
      <Pressable style={styles.backdrop} onPress={onClose}>
        <View style={styles.sheet} onStartShouldSetResponder={() => true}>
          <Text style={styles.title}>{title}</Text>
          {loading ? (
            <ActivityIndicator color="#9ca3af" style={styles.loader} />
          ) : (
            <FlatList
              data={options}
              keyExtractor={(item) => item.uid}
              renderItem={({ item }) => (
                <Pressable
                  style={({ pressed }) => [styles.row, pressed && styles.rowPressed]}
                  onPress={() => {
                    onSelect(item.uid);
                    onClose();
                  }}
                >
                  <Text style={styles.optionName}>{item.name}</Text>
                  {item.uid === selectedUid && (
                    <Ionicons name="checkmark" size={20} color="#2563eb" />
                  )}
                </Pressable>
              )}
            />
          )}
          <Pressable
            style={({ pressed }) => [styles.cancelButton, pressed && styles.rowPressed]}
            onPress={onClose}
          >
            <Text style={styles.cancelText}>Cancel</Text>
          </Pressable>
        </View>
      </Pressable>
    </Modal>
  );
}

const styles = StyleSheet.create({
  backdrop: {
    flex: 1,
    justifyContent: "flex-end",
    backgroundColor: "rgba(0, 0, 0, 0.5)",
  },
  sheet: {
    backgroundColor: "#111827",
    borderTopLeftRadius: 16,
    borderTopRightRadius: 16,
    paddingBottom: 34,
    paddingTop: 16,
  },
  title: {
    color: "#e5e7eb",
    fontSize: 16,
    fontWeight: "600",
    paddingHorizontal: 20,
    marginBottom: 12,
  },
  loader: {
    marginVertical: 24,
  },
  row: {
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "space-between",
    paddingVertical: 14,
    paddingHorizontal: 20,
    borderTopWidth: StyleSheet.hairlineWidth,
    borderTopColor: "#1f2937",
  },
  rowPressed: {
    backgroundColor: "#1f2937",
  },
  optionName: {
    color: "#e5e7eb",
    fontSize: 15,
  },
  cancelButton: {
    alignItems: "center",
    paddingVertical: 14,
    marginTop: 4,
    borderTopWidth: StyleSheet.hairlineWidth,
    borderTopColor: "#1f2937",
  },
  cancelText: {
    color: "#9ca3af",
    fontSize: 15,
  },
});
