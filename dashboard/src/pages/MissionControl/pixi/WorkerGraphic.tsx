// pixi/WorkerGraphic.tsx — Animated worker units
import { useCallback, useRef, useState } from "react";
import { extend } from "@pixi/react";
import { Container, Graphics } from "pixi.js";
import type { MCWorker } from "../types";
import { useAnimationTick, pulse, lerp } from "./AnimationManager";

extend({ Container, Graphics });

// Role -> visor color
const ROLE_COLORS: Record<string, number> = {
  llm: 0xa47bff,
  code: 0x5b8cff,
  tool: 0x56c7b6,
  supervisor: 0xd8b15b,
  dispatcher: 0x63d7e6,
  default: 0x63d7e6,
};

function getRoleColor(capabilities: string[]): number {
  for (const cap of capabilities) {
    if (cap in ROLE_COLORS) return ROLE_COLORS[cap];
  }
  return ROLE_COLORS.default;
}

interface WorkerGraphicProps {
  worker: MCWorker;
  targetX: number;
  targetY: number;
}

export function WorkerGraphic({
  worker,
  targetX,
  targetY,
}: WorkerGraphicProps) {
  const roleColor = getRoleColor(worker.capabilities);
  const isOnline = worker.status === "online";
  const isDraining = worker.status === "draining";
  const isOffline = worker.status === "offline";
  const isBusy = worker.activeJobs > 0;

  const posRef = useRef({ x: targetX, y: targetY });
  const [pos, setPos] = useState({ x: targetX, y: targetY });
  const [breathAlpha, setBreathAlpha] = useState(0.5);
  const [activityRing, setActivityRing] = useState(0);

  useAnimationTick(
    useCallback(
      (elapsed: number, dt: number) => {
        // Lerp position
        const speed = 3; // px/frame factor
        const factor = Math.min(1, speed * dt);
        posRef.current.x = lerp(posRef.current.x, targetX, factor);
        posRef.current.y = lerp(posRef.current.y, targetY, factor);
        setPos({ x: posRef.current.x, y: posRef.current.y });

        // Breathing glow for idle workers
        if (isOnline && !isBusy) {
          setBreathAlpha(pulse(elapsed, 0.3, 0.6, 2));
        } else if (isBusy) {
          setBreathAlpha(0.8);
          setActivityRing(elapsed * 3);
        } else {
          setBreathAlpha(0.3);
        }
      },
      [targetX, targetY, isOnline, isBusy],
    ),
  );

  const bodyW = 20;
  const bodyH = 16;

  const drawBody = useCallback(
    (g: import("pixi.js").Graphics) => {
      g.clear();

      const alpha = isOffline ? 0.3 : 1;

      // Drop shadow
      g.ellipse(0, bodyH / 2 + 2, bodyW / 2 - 2, 3);
      g.fill({ color: 0x0e1218, alpha: 0.3 * alpha });

      // Body
      g.roundRect(-bodyW / 2, -bodyH / 2, bodyW, bodyH, 3);
      g.fill({ color: 0x2c313a, alpha });

      // Visor strip (top 2px)
      g.roundRect(-bodyW / 2 + 2, -bodyH / 2 + 1, bodyW - 4, 3, 1);
      g.fill({ color: roleColor, alpha: breathAlpha * alpha });

      // Optic dot
      g.circle(0, -bodyH / 2 + 5, 2);
      g.fill({ color: roleColor, alpha: breathAlpha * alpha });

      // Draining outline
      if (isDraining) {
        g.roundRect(-bodyW / 2 - 1, -bodyH / 2 - 1, bodyW + 2, bodyH + 2, 4);
        g.stroke({ color: 0xe8d25b, width: 1, alpha: 0.6 });
      }
    },
    [roleColor, breathAlpha, isOffline, isDraining],
  );

  // Activity ring when working
  const drawActivityRing = useCallback(
    (g: import("pixi.js").Graphics) => {
      g.clear();
      if (!isBusy || isOffline) return;
      const radius = 12;
      const segments = 6;
      const arcLen = (Math.PI * 2) / segments;
      for (let i = 0; i < segments; i++) {
        const start = activityRing + i * arcLen;
        const end = start + arcLen * 0.4;
        g.arc(0, 0, radius, start, end);
        g.stroke({ color: roleColor, width: 1, alpha: 0.3 });
      }
    },
    [isBusy, isOffline, activityRing, roleColor],
  );

  return (
    <pixiContainer x={pos.x} y={pos.y}>
      <pixiGraphics draw={drawActivityRing} />
      <pixiGraphics draw={drawBody} />
    </pixiContainer>
  );
}
