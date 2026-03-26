// pixi/PipelineGraphic.tsx — Route lines with animated flow dots
import { useCallback, useState } from "react";
import { extend } from "@pixi/react";
import { Container, Graphics } from "pixi.js";
import { STATION_POSITIONS } from "./StationGraphic";
import { useAnimationTick, bezierPoint, type BezierPath } from "./AnimationManager";

extend({ Container, Graphics });

const LINE_COLOR = 0x3b4656;
const DOT_COLOR = 0x63d7e6;
const DOT_RADIUS = 2;
const DOTS_PER_PIPE = 4;

// Define the pipeline connections (from -> to)
const PIPELINE_CONNECTIONS: Array<[string, string]> = [
  ["intake", "dispatcher"],
  ["dispatcher", "llm"],
  ["dispatcher", "code"],
  ["dispatcher", "output"],
  ["dispatcher", "supervisor"],
  ["llm", "tool"],
  ["code", "error"],
  ["supervisor", "command-oversight"],
];

// Compute bezier control points for a connection
function computeBezier(
  fromId: string,
  toId: string,
): BezierPath | null {
  const from = STATION_POSITIONS[fromId];
  const to = STATION_POSITIONS[toId];
  if (!from || !to) return null;

  const dx = to.x - from.x;
  const dy = to.y - from.y;

  // Control points create a smooth curve
  // Bias the control points perpendicular to the line for a natural curve
  const cx0 = from.x + dx * 0.4;
  const cy0 = from.y + dy * 0.1;
  const cx1 = from.x + dx * 0.6;
  const cy1 = from.y + dy * 0.9;

  return {
    x0: from.x,
    y0: from.y,
    cx0,
    cy0,
    cx1,
    cy1,
    x1: to.x,
    y1: to.y,
  };
}

// Pre-compute all paths
const PIPELINE_PATHS: Array<{
  from: string;
  to: string;
  path: BezierPath;
}> = [];

for (const [from, to] of PIPELINE_CONNECTIONS) {
  const path = computeBezier(from, to);
  if (path) {
    PIPELINE_PATHS.push({ from, to, path });
  }
}

export function PipelineGraphic() {
  const [dotOffset, setDotOffset] = useState(0);

  useAnimationTick(
    useCallback((_elapsed: number, dt: number) => {
      // Cycle dots along path
      setDotOffset((prev) => (prev + dt * 0.3) % 1);
    }, []),
  );

  // Draw all pipeline curves
  const drawPipelines = useCallback(
    (g: import("pixi.js").Graphics) => {
      g.clear();

      for (const { path } of PIPELINE_PATHS) {
        g.moveTo(path.x0, path.y0);
        g.bezierCurveTo(
          path.cx0,
          path.cy0,
          path.cx1,
          path.cy1,
          path.x1,
          path.y1,
        );
      }
      g.stroke({ color: LINE_COLOR, width: 1.5, alpha: 0.4 });
    },
    [],
  );

  // Draw animated flow dots
  const drawDots = useCallback(
    (g: import("pixi.js").Graphics) => {
      g.clear();

      for (const { path } of PIPELINE_PATHS) {
        for (let i = 0; i < DOTS_PER_PIPE; i++) {
          const t = (dotOffset + i / DOTS_PER_PIPE) % 1;
          const pt = bezierPoint(path, t);
          g.circle(pt.x, pt.y, DOT_RADIUS);
          g.fill({ color: DOT_COLOR, alpha: 0.6 });
        }
      }
    },
    [dotOffset],
  );

  return (
    <pixiContainer>
      <pixiGraphics draw={drawPipelines} />
      <pixiGraphics draw={drawDots} />
    </pixiContainer>
  );
}
