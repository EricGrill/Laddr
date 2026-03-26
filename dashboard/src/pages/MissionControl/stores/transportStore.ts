// dashboard/src/pages/MissionControl/stores/transportStore.ts
import { create } from "zustand";
import { getWebSocketBaseUrl } from "../../../lib/config";
import type { MCCommand, MCServerEvent } from "../types";
import { useEntityStore } from "./entityStore";
import { useTickerStore } from "../ui/EventTicker";

interface TransportState {
  isConnected: boolean;
  error: string | null;
  reconnectAttempts: number;
  connect: () => void;
  disconnect: () => void;
  send: (command: MCCommand) => void;
}

const MAX_RECONNECT_ATTEMPTS = 10;
const BASE_RECONNECT_MS = 2000;
const MAX_RECONNECT_MS = 30000;

export const useTransportStore = create<TransportState>((set, get) => {
  let ws: WebSocket | null = null;
  let reconnectTimer: ReturnType<typeof setTimeout> | null = null;
  let backoff = BASE_RECONNECT_MS;

  function cleanup() {
    if (reconnectTimer) {
      clearTimeout(reconnectTimer);
      reconnectTimer = null;
    }
    if (ws) {
      ws.onopen = null;
      ws.onclose = null;
      ws.onmessage = null;
      ws.onerror = null;
      if (ws.readyState === WebSocket.OPEN || ws.readyState === WebSocket.CONNECTING) {
        ws.close();
      }
      ws = null;
    }
  }

  function scheduleReconnect() {
    const { reconnectAttempts } = get();
    if (reconnectAttempts >= MAX_RECONNECT_ATTEMPTS) {
      set({ error: "Max reconnect attempts reached" });
      return;
    }
    reconnectTimer = setTimeout(() => {
      set({ reconnectAttempts: reconnectAttempts + 1 });
      doConnect();
    }, backoff);
    backoff = Math.min(backoff * 2, MAX_RECONNECT_MS);
  }

  function handleMessage(event: MessageEvent) {
    try {
      const data = JSON.parse(event.data) as MCServerEvent;
      useEntityStore.getState().handleEvent(data);
      useTickerStore.getState().pushEvent(data);
    } catch {
      console.error("[MissionControl] Failed to parse WebSocket message");
    }
  }

  function doConnect() {
    cleanup();
    const base = getWebSocketBaseUrl();
    const url = `${base}/ws/mission-control`;
    ws = new WebSocket(url);

    ws.onopen = () => {
      set({ isConnected: true, error: null, reconnectAttempts: 0 });
      backoff = BASE_RECONNECT_MS;
    };

    ws.onclose = () => {
      set({ isConnected: false });
      scheduleReconnect();
    };

    ws.onerror = () => {
      set({ error: "WebSocket error" });
    };

    ws.onmessage = handleMessage;
  }

  return {
    isConnected: false,
    error: null,
    reconnectAttempts: 0,

    connect() {
      set({ reconnectAttempts: 0, error: null });
      backoff = BASE_RECONNECT_MS;
      doConnect();
    },

    disconnect() {
      set({ reconnectAttempts: MAX_RECONNECT_ATTEMPTS }); // prevent reconnect
      cleanup();
      set({ isConnected: false, error: null, reconnectAttempts: 0 });
    },

    send(command: MCCommand) {
      if (ws && ws.readyState === WebSocket.OPEN) {
        ws.send(JSON.stringify(command));
      }
    },
  };
});
