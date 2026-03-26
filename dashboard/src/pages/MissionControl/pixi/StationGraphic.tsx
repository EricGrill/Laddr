// pixi/StationGraphic.tsx — Individual station with distinct visuals per type
import { useCallback, useState } from "react";
import { extend } from "@pixi/react";
import { Container, Graphics, Text as PixiText } from "pixi.js";
import type { StationType, StationState } from "../types";
import { useAnimationTick, pulse } from "./AnimationManager";
import { useUIStore } from "../stores/uiStore";

extend({ Container, Graphics, Text: PixiText });

// --- Station type -> accent color ---
const ACCENT_COLORS: Record<StationType, number> = {
  intake: 0x63d7e6,
  dispatcher: 0x63d7e6,
  llm: 0xa47bff,
  tool: 0x56c7b6,
  code: 0x5b8cff,
  supervisor: 0xd8b15b,
  error: 0xe35b5b,
  output: 0xf2a65a,
};

// --- State indicator colors ---
const STATE_DOT_COLORS: Record<StationState, number> = {
  active: 0x4caf50,
  idle: 0x666666,
  saturated: 0xe8d25b,
  blocked: 0xe8d25b,
  errored: 0xe35b5b,
  offline: 0x444444,
};

// --- Station layout coordinates ---
export const STATION_POSITIONS: Record<
  string,
  { x: number; y: number; type: StationType; label: string }
> = {
  intake: { x: 100, y: 200, type: "intake", label: "Incoming Orders" },
  dispatcher: {
    x: 300,
    y: 350,
    type: "dispatcher",
    label: "Routing Core",
  },
  llm: { x: 150, y: 500, type: "llm", label: "Science/Research" },
  code: { x: 450, y: 500, type: "code", label: "Systems Engineering" },
  tool: { x: 100, y: 650, type: "tool", label: "Recon/Comms" },
  output: { x: 550, y: 350, type: "output", label: "Deploy Bay" },
  supervisor: {
    x: 550,
    y: 200,
    type: "supervisor",
    label: "Review/Verification",
  },
  "command-oversight": {
    x: 700,
    y: 200,
    type: "supervisor",
    label: "Command Oversight",
  },
  error: {
    x: 450,
    y: 650,
    type: "error",
    label: "Anomaly Containment",
  },
};

interface StationGraphicProps {
  id: string;
  type: StationType;
  label: string;
  state: StationState;
  x: number;
  y: number;
  queueDepth: number;
}

export function StationGraphic({
  id,
  type,
  label,
  state,
  x,
  y,
  queueDepth,
}: StationGraphicProps) {
  const accent = ACCENT_COLORS[type];
  const isDispatcher = type === "dispatcher";
  const isActive = state === "active" || state === "saturated";
  const selectEntity = useUIStore((s) => s.selectEntity);

  // Animation state
  const [glowAlpha, setGlowAlpha] = useState(0);
  const [ringAngle, setRingAngle] = useState(0);

  useAnimationTick(
    useCallback(
      (elapsed: number) => {
        if (isActive) {
          setGlowAlpha(pulse(elapsed, 0.05, 0.15, 2));
        } else {
          setGlowAlpha(0);
        }
        if (isDispatcher) {
          setRingAngle(elapsed * 0.5); // slow spin
        }
      },
      [isActive, isDispatcher],
    ),
  );

  const platformW = isDispatcher ? 110 : 80;
  const platformH = isDispatcher ? 80 : 60;
  const halfW = platformW / 2;
  const halfH = platformH / 2;

  // Glow behind station when active
  const drawGlow = useCallback(
    (g: import("pixi.js").Graphics) => {
      g.clear();
      if (glowAlpha <= 0) return;
      const radius = isDispatcher ? 70 : 50;
      g.circle(0, 0, radius);
      g.fill({ color: accent, alpha: glowAlpha });
    },
    [glowAlpha, accent, isDispatcher],
  );

  // Spinning ring for dispatcher
  const drawRing = useCallback(
    (g: import("pixi.js").Graphics) => {
      g.clear();
      if (!isDispatcher) return;
      // Draw dashed ring by drawing arcs
      const radius = 55;
      const segments = 8;
      const arcLen = (Math.PI * 2) / segments;
      for (let i = 0; i < segments; i++) {
        const startAngle = ringAngle + i * arcLen;
        const endAngle = startAngle + arcLen * 0.6;
        g.arc(0, 0, radius, startAngle, endAngle);
        g.stroke({ color: accent, width: 1.5, alpha: 0.4 });
      }
    },
    [isDispatcher, ringAngle, accent],
  );

  // Main platform shape
  const drawPlatform = useCallback(
    (g: import("pixi.js").Graphics) => {
      g.clear();
      // Platform base
      g.roundRect(-halfW, -halfH, platformW, platformH, 8);
      g.fill({ color: accent, alpha: 0.15 });
      g.stroke({ color: accent, width: 2, alpha: 0.6 });

      // Inner icon area
      const innerW = platformW * 0.5;
      const innerH = platformH * 0.4;
      g.roundRect(-innerW / 2, -innerH / 2 - 4, innerW, innerH, 4);
      g.fill({ color: accent, alpha: 0.25 });
    },
    [accent, halfW, halfH, platformW, platformH],
  );

  // State indicator dot
  const drawStateDot = useCallback(
    (g: import("pixi.js").Graphics) => {
      g.clear();
      const dotColor = STATE_DOT_COLORS[state] ?? 0x666666;
      g.circle(halfW - 8, -halfH + 8, 4);
      g.fill({ color: dotColor });
    },
    [state, halfW, halfH],
  );

  // Queue depth badge
  const drawBadge = useCallback(
    (g: import("pixi.js").Graphics) => {
      g.clear();
      if (queueDepth <= 0) return;
      g.roundRect(-halfW - 2, -halfH - 2, 18, 14, 4);
      g.fill({ color: 0x2c313a });
      g.stroke({ color: accent, width: 1, alpha: 0.5 });
    },
    [queueDepth, halfW, halfH, accent],
  );

  const handleClick = useCallback(() => {
    selectEntity({ id, type: "station" });
  }, [selectEntity, id]);

  return (
    <pixiContainer
      x={x}
      y={y}
      eventMode="static"
      cursor="pointer"
      onPointerDown={handleClick}
    >
      {/* Glow */}
      <pixiGraphics draw={drawGlow} />

      {/* Spinning ring (dispatcher only) */}
      <pixiGraphics draw={drawRing} />

      {/* Platform */}
      <pixiGraphics draw={drawPlatform} />

      {/* State dot */}
      <pixiGraphics draw={drawStateDot} />

      {/* Queue badge */}
      <pixiGraphics draw={drawBadge} />
      {queueDepth > 0 && (
        <pixiText
          text={String(queueDepth)}
          x={-halfW + 6}
          y={-halfH}
          style={{
            fontSize: 9,
            fill: "#D9D7D1",
            fontFamily: "monospace",
          }}
        />
      )}

      {/* Label */}
      <pixiText
        text={label}
        anchor={{ x: 0.5, y: 0 }}
        x={0}
        y={halfH + 6}
        style={{
          fontSize: 11,
          fill: "#D9D7D1",
          fontFamily: "monospace",
          fontWeight: "bold",
        }}
      />
    </pixiContainer>
  );
}
