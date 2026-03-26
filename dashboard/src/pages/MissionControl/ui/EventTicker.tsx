import { useEffect, useRef, useState } from "react";
import { create } from "zustand";
import type { MCServerEvent } from "../types";

// --- Ticker Event Store ---

export interface TickerEvent {
  id: number;
  timestamp: string; // HH:MM:SS
  icon: string;
  message: string;
  color?: string;
}

interface TickerState {
  events: TickerEvent[];
  pushEvent: (event: MCServerEvent) => void;
}

let nextId = 0;

function formatTime(): string {
  const d = new Date();
  return [d.getHours(), d.getMinutes(), d.getSeconds()]
    .map((n) => String(n).padStart(2, "0"))
    .join(":");
}

function eventToTicker(event: MCServerEvent): TickerEvent | null {
  const ts = formatTime();

  switch (event.type) {
    case "job_created":
      return {
        id: nextId++,
        timestamp: ts,
        icon: "\u2B06",
        message: `Job ${event.job.id.slice(0, 8)} submitted`,
      };
    case "job_assigned":
      return {
        id: nextId++,
        timestamp: ts,
        icon: "\u2192",
        message: `Job ${event.jobId.slice(0, 8)} assigned to ${event.agentId}`,
      };
    case "job_completed":
      return {
        id: nextId++,
        timestamp: ts,
        icon: "\u2713",
        message: `Job ${event.jobId.slice(0, 8)} completed`,
        color: "rgba(110, 231, 183, 0.9)",
      };
    case "job_failed":
      return {
        id: nextId++,
        timestamp: ts,
        icon: "\u2717",
        message: `Job ${event.jobId.slice(0, 8)} failed`,
        color: "rgba(248, 113, 113, 0.9)",
      };
    case "worker_registered":
      return {
        id: nextId++,
        timestamp: ts,
        icon: "\u25C6",
        message: `Worker ${event.worker.id} came online`,
      };
    case "worker_deregistered":
      return {
        id: nextId++,
        timestamp: ts,
        icon: "\u25C7",
        message: `Worker ${event.workerId} went offline`,
      };
    default:
      return null;
  }
}

export const useTickerStore = create<TickerState>((set) => ({
  events: [],
  pushEvent(event: MCServerEvent) {
    const ticker = eventToTicker(event);
    if (!ticker) return;
    set((s) => ({
      events: [ticker, ...s.events].slice(0, 10),
    }));
  },
}));

// --- Ticker Component ---

export function EventTicker() {
  const events = useTickerStore((s) => s.events);
  const [visible, setVisible] = useState<TickerEvent[]>([]);
  const prevIdsRef = useRef<Set<number>>(new Set());

  // Track which events are "new" for animation
  useEffect(() => {
    setVisible(events.slice(0, 4));
  }, [events]);

  // Track seen IDs so we can animate new ones
  useEffect(() => {
    const newIds = new Set(events.map((e) => e.id));
    prevIdsRef.current = newIds;
  }, [events]);

  if (visible.length === 0) return null;

  return (
    <div
      style={{
        position: "absolute",
        bottom: 0,
        left: 0,
        right: 0,
        height: 32,
        background: "rgba(10, 14, 26, 0.9)",
        borderTop: "1px solid rgba(0, 200, 220, 0.25)",
        display: "flex",
        alignItems: "center",
        paddingLeft: 12,
        paddingRight: 12,
        gap: 24,
        overflow: "hidden",
        zIndex: 20,
        fontFamily: "monospace",
        fontSize: 10,
        color: "rgba(255, 255, 255, 0.6)",
      }}
    >
      {visible.map((ev) => (
        <span
          key={ev.id}
          style={{
            whiteSpace: "nowrap",
            color: ev.color ?? "rgba(255, 255, 255, 0.6)",
            animation: "tickerSlideIn 0.3s ease-out",
          }}
        >
          <span style={{ opacity: 0.45, marginRight: 6 }}>{ev.timestamp}</span>
          <span style={{ marginRight: 4 }}>{ev.icon}</span>
          {ev.message}
        </span>
      ))}
      <style>{`
        @keyframes tickerSlideIn {
          from { opacity: 0; transform: translateX(40px); }
          to   { opacity: 1; transform: translateX(0); }
        }
      `}</style>
    </div>
  );
}
