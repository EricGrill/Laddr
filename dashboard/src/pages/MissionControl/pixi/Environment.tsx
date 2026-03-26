// pixi/Environment.tsx — Floor, grid, lane highlights, and vignette
import { useCallback } from "react";
import { extend } from "@pixi/react";
import { Container, Graphics } from "pixi.js";

extend({ Container, Graphics });

const FLOOR_COLOR = 0x23262b;
const GRID_COLOR = 0x2c313a;
const LANE_COLOR = 0x3b4656;
const GRID_SPACING = 40;

// Vignette edge darkness
const VIGNETTE_COLOR = 0x0e1218;

interface EnvironmentProps {
  width: number;
  height: number;
}

export function Environment({ width, height }: EnvironmentProps) {
  const drawFloor = useCallback(
    (g: import("pixi.js").Graphics) => {
      g.clear();

      // Main floor
      g.rect(0, 0, width, height);
      g.fill({ color: FLOOR_COLOR });

      // Subtle grid lines
      for (let x = 0; x <= width; x += GRID_SPACING) {
        g.moveTo(x, 0);
        g.lineTo(x, height);
      }
      for (let y = 0; y <= height; y += GRID_SPACING) {
        g.moveTo(0, y);
        g.lineTo(width, y);
      }
      g.stroke({ color: GRID_COLOR, width: 1, alpha: 0.3 });
    },
    [width, height],
  );

  const drawLaneHighlights = useCallback(
    (g: import("pixi.js").Graphics) => {
      g.clear();

      // Soft connecting lanes between major station areas
      const lanes = [
        // Intake -> Dispatcher
        { x1: 140, y1: 230, x2: 300, y2: 350 },
        // Dispatcher -> Science
        { x1: 300, y1: 380, x2: 190, y2: 500 },
        // Dispatcher -> Engineering
        { x1: 340, y1: 380, x2: 450, y2: 500 },
        // Dispatcher -> Deploy
        { x1: 380, y1: 350, x2: 550, y2: 350 },
        // Dispatcher -> Review
        { x1: 380, y1: 330, x2: 550, y2: 200 },
        // Science -> Recon
        { x1: 190, y1: 530, x2: 140, y2: 650 },
        // Engineering -> Anomaly
        { x1: 450, y1: 530, x2: 450, y2: 650 },
        // Review -> Command
        { x1: 590, y1: 200, x2: 700, y2: 200 },
      ];

      for (const lane of lanes) {
        g.moveTo(lane.x1, lane.y1);
        g.lineTo(lane.x2, lane.y2);
      }
      g.stroke({ color: LANE_COLOR, width: 3, alpha: 0.15 });
    },
    [],
  );

  const drawVignette = useCallback(
    (g: import("pixi.js").Graphics) => {
      g.clear();

      // Top edge
      g.rect(0, 0, width, 60);
      g.fill({ color: VIGNETTE_COLOR, alpha: 0.5 });

      // Bottom edge
      g.rect(0, height - 60, width, 60);
      g.fill({ color: VIGNETTE_COLOR, alpha: 0.5 });

      // Left edge
      g.rect(0, 0, 40, height);
      g.fill({ color: VIGNETTE_COLOR, alpha: 0.4 });

      // Right edge
      g.rect(width - 40, 0, 40, height);
      g.fill({ color: VIGNETTE_COLOR, alpha: 0.4 });
    },
    [width, height],
  );

  return (
    <pixiContainer>
      <pixiGraphics draw={drawFloor} />
      <pixiGraphics draw={drawLaneHighlights} />
      <pixiGraphics draw={drawVignette} />
    </pixiContainer>
  );
}
