import { useEffect, useRef, useCallback } from "react";
import { useMissionControl } from "./hooks/useMissionControl";
import { PixiCanvas } from "./pixi/PixiCanvas";
import { TopBar } from "./ui/TopBar";
// Sidebar removed for 2D canvas view
import { InspectorPanel } from "./ui/InspectorPanel";
import { AlertToasts } from "./ui/AlertToasts";
import { EventTicker } from "./ui/EventTicker";
import { useUIStore } from "./stores/uiStore";

export default function MissionControlPage() {
  useMissionControl();
  const containerRef = useRef<HTMLDivElement>(null);
  const fullscreen = useUIStore((s) => s.fullscreen);
  const toggleFullscreen = useUIStore((s) => s.toggleFullscreen);

  // Sync browser fullscreen API with store state
  const enterFullscreen = useCallback(() => {
    if (containerRef.current && !document.fullscreenElement) {
      containerRef.current.requestFullscreen().catch(() => {});
    }
  }, []);

  const exitFullscreen = useCallback(() => {
    if (document.fullscreenElement) {
      document.exitFullscreen().catch(() => {});
    }
  }, []);

  useEffect(() => {
    if (fullscreen) {
      enterFullscreen();
    } else {
      exitFullscreen();
    }
  }, [fullscreen, enterFullscreen, exitFullscreen]);

  // Sync store when user exits fullscreen via Escape
  useEffect(() => {
    const handler = () => {
      if (!document.fullscreenElement && fullscreen) {
        toggleFullscreen();
      }
    };
    document.addEventListener("fullscreenchange", handler);
    return () => document.removeEventListener("fullscreenchange", handler);
  }, [fullscreen, toggleFullscreen]);

  // Keyboard shortcut: F to toggle fullscreen
  useEffect(() => {
    const handler = (e: KeyboardEvent) => {
      if (e.key === "f" || e.key === "F") {
        // Don't trigger if user is typing in an input
        if (
          e.target instanceof HTMLInputElement ||
          e.target instanceof HTMLTextAreaElement
        ) {
          return;
        }
        e.preventDefault();
        toggleFullscreen();
      }
    };
    window.addEventListener("keydown", handler);
    return () => window.removeEventListener("keydown", handler);
  }, [toggleFullscreen]);

  return (
    <div
      ref={containerRef}
      className={`flex flex-col h-full w-full bg-[#1A2230] text-white overflow-hidden ${
        fullscreen ? "fixed inset-0 z-50" : ""
      }`}
    >
      <TopBar />
      <div className="flex flex-1 overflow-hidden">
        {/* Sidebar removed — the 2D canvas fills the viewport. Use inspector panel (click entities) instead. */}
        <div className="flex-1 relative">
          <PixiCanvas />
          <AlertToasts />
          <EventTicker />
        </div>
        <InspectorPanel />
      </div>
    </div>
  );
}
