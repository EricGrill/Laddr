// pixi/PacketGraphic.tsx — Mission packets (jobs) as holographic cards
import { useCallback, useState } from "react";
import { extend } from "@pixi/react";
import { Container, Graphics } from "pixi.js";
import type { MCJob, JobPriority, JobState } from "../types";
import { useAnimationTick, pulse } from "./AnimationManager";

extend({ Container, Graphics });

// Priority -> visual behavior
const PRIORITY_COLORS: Record<JobPriority, number> = {
  low: 0x3b4656,
  normal: 0x63d7e6,
  high: 0xf2a65a,
  critical: 0xe35b5b,
};

// Type -> accent color
const TYPE_COLORS: Record<string, number> = {
  llm: 0xa47bff,
  code: 0x5b8cff,
  tool: 0x56c7b6,
  supervisor: 0xd8b15b,
  output: 0xf2a65a,
  default: 0x63d7e6,
};

function getTypeColor(jobType: string): number {
  return TYPE_COLORS[jobType] ?? TYPE_COLORS.default;
}

interface PacketGraphicProps {
  job: MCJob;
  x: number;
  y: number;
}

export function PacketGraphic({ job, x, y }: PacketGraphicProps) {
  const typeColor = getTypeColor(job.type);
  const priorityColor = PRIORITY_COLORS[job.priority];
  const isQueued =
    job.state === "queued" || job.state === "created";
  const isTransit =
    job.state === "in_transit" ||
    job.state === "assigned" ||
    job.state === "handoff";
  const isProcessing = job.state === "processing";
  const isCritical = job.priority === "critical";
  const isHigh = job.priority === "high";

  const [glowAlpha, setGlowAlpha] = useState(0);

  useAnimationTick(
    useCallback(
      (elapsed: number) => {
        if (isCritical) {
          setGlowAlpha(pulse(elapsed, 0.3, 0.8, 0.5));
        } else if (isHigh) {
          setGlowAlpha(pulse(elapsed, 0.2, 0.5, 1.2));
        } else {
          setGlowAlpha(0);
        }
      },
      [isCritical, isHigh],
    ),
  );

  // Queued: card shape
  const drawCard = useCallback(
    (g: import("pixi.js").Graphics) => {
      g.clear();
      if (!isQueued) return;

      const w = 16;
      const h = 12;
      // Card body
      g.roundRect(-w / 2, -h / 2, w, h, 2);
      g.fill({ color: 0x2c313a, alpha: 0.8 });
      g.stroke({ color: typeColor, width: 1, alpha: 0.6 });

      // Priority pip
      g.circle(w / 2 - 3, -h / 2 + 3, 2);
      g.fill({ color: priorityColor, alpha: 0.8 });
    },
    [isQueued, typeColor, priorityColor],
  );

  // Transit: capsule shape
  const drawCapsule = useCallback(
    (g: import("pixi.js").Graphics) => {
      g.clear();
      if (!isTransit) return;

      const w = 10;
      const h = 6;
      g.roundRect(-w / 2, -h / 2, w, h, 3);
      g.fill({ color: typeColor, alpha: 0.6 });
      g.stroke({ color: typeColor, width: 1, alpha: 0.8 });
    },
    [isTransit, typeColor],
  );

  // Processing: chip with progress bar
  const drawChip = useCallback(
    (g: import("pixi.js").Graphics) => {
      g.clear();
      if (!isProcessing) return;

      const w = 14;
      const h = 10;
      g.roundRect(-w / 2, -h / 2, w, h, 2);
      g.fill({ color: 0x2c313a, alpha: 0.9 });
      g.stroke({ color: typeColor, width: 1, alpha: 0.7 });

      // Progress bar
      const progress = job.progress ?? 0;
      const barW = (w - 4) * progress;
      if (barW > 0) {
        g.roundRect(-w / 2 + 2, h / 2 - 4, barW, 2, 1);
        g.fill({ color: typeColor, alpha: 0.8 });
      }
    },
    [isProcessing, typeColor, job.progress],
  );

  // Glow for high/critical priority
  const drawGlow = useCallback(
    (g: import("pixi.js").Graphics) => {
      g.clear();
      if (glowAlpha <= 0) return;
      const color = isCritical ? 0xe35b5b : 0xf2a65a;
      g.circle(0, 0, 10);
      g.fill({ color, alpha: glowAlpha * 0.3 });
    },
    [glowAlpha, isCritical],
  );

  // Don't render completed/cancelled/failed packets
  if (
    job.state === "completed" ||
    job.state === "cancelled" ||
    job.state === "failed"
  ) {
    return null;
  }

  return (
    <pixiContainer x={x} y={y}>
      <pixiGraphics draw={drawGlow} />
      <pixiGraphics draw={drawCard} />
      <pixiGraphics draw={drawCapsule} />
      <pixiGraphics draw={drawChip} />
    </pixiContainer>
  );
}
