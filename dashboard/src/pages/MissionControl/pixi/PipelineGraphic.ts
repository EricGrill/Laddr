// pixi/PipelineGraphic.ts — Route lines with animated flow dots
import { Container, Graphics } from 'pixi.js';
import { STATION_POSITIONS } from './StationGraphic';
import { bezierPoint, type BezierPath } from './AnimationManager';

const LINE_COLOR = 0x3b4656;
const DOT_COLOR = 0x63d7e6;
const DOT_RADIUS = 4;
const DOTS_PER_PIPE = 4;

// Pipeline connections (from -> to)
const PIPELINE_CONNECTIONS: Array<[string, string]> = [
  ['intake', 'dispatcher'],
  ['dispatcher', 'llm'],
  ['dispatcher', 'code'],
  ['dispatcher', 'output'],
  ['dispatcher', 'supervisor'],
  ['llm', 'tool'],
  ['code', 'error'],
  ['supervisor', 'command-oversight'],
];

function computeBezier(fromId: string, toId: string): BezierPath | null {
  const from = STATION_POSITIONS[fromId];
  const to = STATION_POSITIONS[toId];
  if (!from || !to) return null;

  const dx = to.x - from.x;
  const dy = to.y - from.y;

  return {
    x0: from.x,
    y0: from.y,
    cx0: from.x + dx * 0.4,
    cy0: from.y + dy * 0.1,
    cx1: from.x + dx * 0.6,
    cy1: from.y + dy * 0.9,
    x1: to.x,
    y1: to.y,
  };
}

// Pre-compute all paths
const PIPELINE_PATHS: Array<{ from: string; to: string; path: BezierPath }> = [];
for (const [from, to] of PIPELINE_CONNECTIONS) {
  const path = computeBezier(from, to);
  if (path) {
    PIPELINE_PATHS.push({ from, to, path });
  }
}

interface PipelineRefs {
  dotsGfx: Graphics;
  dotOffset: number;
}

const PIPELINE_REFS = new WeakMap<Container, PipelineRefs>();

export function createPipelines(): Container {
  const container = new Container();

  // Static pipeline curves
  const linesGfx = new Graphics();
  for (const { path } of PIPELINE_PATHS) {
    linesGfx.moveTo(path.x0, path.y0);
    linesGfx.bezierCurveTo(path.cx0, path.cy0, path.cx1, path.cy1, path.x1, path.y1);
  }
  linesGfx.stroke({ color: LINE_COLOR, width: 2.5, alpha: 0.4 });
  container.addChild(linesGfx);

  // Animated flow dots
  const dotsGfx = new Graphics();
  container.addChild(dotsGfx);

  PIPELINE_REFS.set(container, { dotsGfx, dotOffset: 0 });

  return container;
}

export function updatePipelineFlow(container: Container, dt: number): void {
  const refs = PIPELINE_REFS.get(container);
  if (!refs) return;

  refs.dotOffset = (refs.dotOffset + dt * 0.3) % 1;

  refs.dotsGfx.clear();
  for (const { path } of PIPELINE_PATHS) {
    for (let i = 0; i < DOTS_PER_PIPE; i++) {
      const t = (refs.dotOffset + i / DOTS_PER_PIPE) % 1;
      const pt = bezierPoint(path, t);
      refs.dotsGfx.circle(pt.x, pt.y, DOT_RADIUS);
      refs.dotsGfx.fill({ color: DOT_COLOR, alpha: 0.6 });
    }
  }
}
