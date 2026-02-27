import * as SecureStore from "expo-secure-store";

const TOKEN_KEY = "relay_token";

let _cachedToken: string | null = null;

export async function getToken(): Promise<string | null> {
  if (_cachedToken) return _cachedToken;
  _cachedToken = await SecureStore.getItemAsync(TOKEN_KEY);
  return _cachedToken;
}

export async function setToken(token: string): Promise<void> {
  _cachedToken = token;
  await SecureStore.setItemAsync(TOKEN_KEY, token);
}

export async function clearToken(): Promise<void> {
  _cachedToken = null;
  await SecureStore.deleteItemAsync(TOKEN_KEY);
}
