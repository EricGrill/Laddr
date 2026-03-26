// pixi/Environment.ts — Floor, grid, lane highlights, and vignette
import { Container, Graphics } from 'pixi.js';

const FLOOR_COLOR = 0x23262b;
const GRID_COLOR = 0x2c313a;
const LANE_COLOR = 0x3b4656;
const GRID_SPACING = 40;
const VIGNETTE_COLOR = 0x0e1218;

export function createEnvironment(width: number, height: number): Container {
  const container = new Container();

  // --- Floor ---
  const floor = new Graphics();
  floor.rect(0, 0, width, height);
  floor.fill({ color: FLOOR_COLOR });

  // Subtle grid lines
  for (let x = 0; x <= width; x += GRID_SPACING) {
    floor.moveTo(x, 0);
    floor.lineTo(x, height);
  }
  for (let y = 0; y <= height; y += GRID_SPACING) {
    floor.moveTo(0, y);
    floor.lineTo(width, y);
  }
  floor.stroke({ color: GRID_COLOR, width: 1, alpha: 0.3 });
  container.addChild(floor);

  // --- Lane highlights ---
  const lanes = new Graphics();
  const laneData = [
    { x1: 140, y1: 230, x2: 300, y2: 350 },
    { x1: 300, y1: 380, x2: 190, y2: 500 },
    { x1: 340, y1: 380, x2: 450, y2: 500 },
    { x1: 380, y1: 350, x2: 550, y2: 350 },
    { x1: 380, y1: 330, x2: 550, y2: 200 },
    { x1: 190, y1: 530, x2: 140, y2: 650 },
    { x1: 450, y1: 530, x2: 450, y2: 650 },
    { x1: 590, y1: 200, x2: 700, y2: 200 },
  ];
  for (const lane of laneData) {
    lanes.moveTo(lane.x1, lane.y1);
    lanes.lineTo(lane.x2, lane.y2);
  }
  lanes.stroke({ color: LANE_COLOR, width: 3, alpha: 0.15 });
  container.addChild(lanes);

  // --- Vignette ---
  const vignette = new Graphics();
  vignette.rect(0, 0, width, 60);
  vignette.fill({ color: VIGNETTE_COLOR, alpha: 0.5 });
  vignette.rect(0, height - 60, width, 60);
  vignette.fill({ color: VIGNETTE_COLOR, alpha: 0.5 });
  vignette.rect(0, 0, 40, height);
  vignette.fill({ color: VIGNETTE_COLOR, alpha: 0.4 });
  vignette.rect(width - 40, 0, 40, height);
  vignette.fill({ color: VIGNETTE_COLOR, alpha: 0.4 });
  container.addChild(vignette);

  return container;
}
