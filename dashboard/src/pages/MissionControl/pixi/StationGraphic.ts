// pixi/StationGraphic.ts — Station factory and update functions
import { Container, Graphics, Text, TextStyle } from 'pixi.js';
import type { StationType, StationState } from '../types';
import { pulse } from './AnimationManager';

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
  intake: { x: 120, y: 180, type: 'intake', label: 'Incoming Orders' },
  dispatcher: { x: 440, y: 320, type: 'dispatcher', label: 'Routing Core' },
  llm: { x: 220, y: 480, type: 'llm', label: 'Science/Research' },
  code: { x: 660, y: 480, type: 'code', label: 'Systems Engineering' },
  tool: { x: 120, y: 600, type: 'tool', label: 'Recon/Comms' },
  output: { x: 780, y: 320, type: 'output', label: 'Deploy Bay' },
  supervisor: { x: 660, y: 140, type: 'supervisor', label: 'Review/Verification' },
  'command-oversight': { x: 900, y: 140, type: 'supervisor', label: 'Command Oversight' },
  error: { x: 660, y: 620, type: 'error', label: 'Anomaly Containment' },
};

export interface StationConfig {
  id: string;
  type: StationType;
  label: string;
  state: StationState;
  x: number;
  y: number;
  queueDepth: number;
}

// --- State label text ---
const STATE_LABELS: Record<StationState, string> = {
  active: 'ACTIVE',
  idle: 'IDLE',
  saturated: 'SATURATED',
  blocked: 'BLOCKED',
  errored: 'ERRORED',
  offline: 'OFFLINE',
};

const STATE_LABEL_COLORS: Record<StationState, string> = {
  active: '#4caf50',
  idle: '#888888',
  saturated: '#e8d25b',
  blocked: '#e8d25b',
  errored: '#e35b5b',
  offline: '#555555',
};

/** Internal references stored on the container for updates */
interface StationRefs {
  glowGfx: Graphics;
  ringGfx: Graphics;
  platformGfx: Graphics;
  stateDotGfx: Graphics;
  badgeGfx: Graphics;
  badgeText: Text;
  labelText: Text;
  queueCountText: Text;
  stateText: Text;
  accent: number;
  isDispatcher: boolean;
  platformW: number;
  platformH: number;
  state: StationState;
  queueDepth: number;
}

const STATION_REFS = new WeakMap<Container, StationRefs>();

export function createStation(config: StationConfig, onClick?: (id: string) => void): Container {
  const accent = ACCENT_COLORS[config.type];
  const isDispatcher = config.type === 'dispatcher';
  const platformW = isDispatcher ? 120 : 100;
  const platformH = isDispatcher ? 90 : 70;
  const halfW = platformW / 2;
  const halfH = platformH / 2;

  const container = new Container();
  container.x = config.x;
  container.y = config.y;
  container.eventMode = 'static';
  container.cursor = 'pointer';

  if (onClick) {
    container.on('pointerdown', () => onClick(config.id));
  }

  // Glow
  const glowGfx = new Graphics();
  container.addChild(glowGfx);

  // Spinning ring (dispatcher only)
  const ringGfx = new Graphics();
  container.addChild(ringGfx);

  // Platform
  const platformGfx = new Graphics();
  drawPlatform(platformGfx, accent, halfW, halfH, platformW, platformH);
  container.addChild(platformGfx);

  // State dot
  const stateDotGfx = new Graphics();
  drawStateDot(stateDotGfx, config.state, halfW, halfH);
  container.addChild(stateDotGfx);

  // Badge background
  const badgeGfx = new Graphics();
  container.addChild(badgeGfx);

  // Badge text
  const badgeText = new Text({
    text: '',
    style: new TextStyle({ fontSize: 9, fill: '#D9D7D1', fontFamily: 'Arial, Helvetica, sans-serif' }),
  });
  badgeText.visible = false;
  container.addChild(badgeText);

  // Queue count — large centered number inside the platform
  const queueCountText = new Text({
    text: config.queueDepth > 0 ? String(config.queueDepth) : '',
    style: new TextStyle({
      fontSize: 18,
      fill: '#ffffff',
      fontFamily: 'Arial, Helvetica, sans-serif',
      fontWeight: 'bold',
    }),
  });
  queueCountText.anchor.set(0.5, 0.5);
  queueCountText.x = 0;
  queueCountText.y = -2;
  container.addChild(queueCountText);

  // Label
  const labelText = new Text({
    text: config.label,
    style: new TextStyle({
      fontSize: 13,
      fill: '#D9D7D1',
      fontFamily: 'Arial, Helvetica, sans-serif',
      fontWeight: 'bold',
    }),
  });
  labelText.anchor.set(0.5, 0);
  labelText.x = 0;
  labelText.y = halfH + 6;
  container.addChild(labelText);

  // State text — below label, colored by state
  const stateText = new Text({
    text: STATE_LABELS[config.state] ?? 'IDLE',
    style: new TextStyle({
      fontSize: 9,
      fill: STATE_LABEL_COLORS[config.state] ?? '#888888',
      fontFamily: 'Arial, Helvetica, sans-serif',
    }),
  });
  stateText.anchor.set(0.5, 0);
  stateText.x = 0;
  stateText.y = halfH + 22;
  container.addChild(stateText);

  // Update badge
  updateBadge(badgeGfx, badgeText, config.queueDepth, halfW, halfH, accent);

  const refs: StationRefs = {
    glowGfx,
    ringGfx,
    platformGfx,
    stateDotGfx,
    badgeGfx,
    badgeText,
    labelText,
    queueCountText,
    stateText,
    accent,
    isDispatcher,
    platformW,
    platformH,
    state: config.state,
    queueDepth: config.queueDepth,
  };
  STATION_REFS.set(container, refs);

  return container;
}

export function updateStation(
  container: Container,
  state: StationState,
  queueDepth: number,
): void {
  const refs = STATION_REFS.get(container);
  if (!refs) return;

  const halfW = refs.platformW / 2;
  const halfH = refs.platformH / 2;

  if (state !== refs.state) {
    refs.state = state;
    drawStateDot(refs.stateDotGfx, state, halfW, halfH);
    refs.stateText.text = STATE_LABELS[state] ?? 'IDLE';
    refs.stateText.style.fill = STATE_LABEL_COLORS[state] ?? '#888888';
  }

  if (queueDepth !== refs.queueDepth) {
    refs.queueDepth = queueDepth;
    updateBadge(refs.badgeGfx, refs.badgeText, queueDepth, halfW, halfH, refs.accent);
    refs.queueCountText.text = queueDepth > 0 ? String(queueDepth) : '';
  }
}

/** Called each tick to animate glow and ring */
export function tickStation(container: Container, elapsed: number): void {
  const refs = STATION_REFS.get(container);
  if (!refs) return;

  const isActive = refs.state === 'active' || refs.state === 'saturated';
  const halfW = refs.platformW / 2;
  const halfH = refs.platformH / 2;

  // Glow
  refs.glowGfx.clear();
  if (isActive) {
    const glowAlpha = pulse(elapsed, 0.05, 0.15, 2);
    const radius = refs.isDispatcher ? 70 : 50;
    refs.glowGfx.circle(0, 0, radius);
    refs.glowGfx.fill({ color: refs.accent, alpha: glowAlpha });
  }

  // Ring (dispatcher only)
  if (refs.isDispatcher) {
    refs.ringGfx.clear();
    const ringAngle = elapsed * 0.5;
    const radius = 55;
    const segments = 8;
    const arcLen = (Math.PI * 2) / segments;
    for (let i = 0; i < segments; i++) {
      const startAngle = ringAngle + i * arcLen;
      const endAngle = startAngle + arcLen * 0.6;
      refs.ringGfx.arc(0, 0, radius, startAngle, endAngle);
      refs.ringGfx.stroke({ color: refs.accent, width: 1.5, alpha: 0.4 });
    }
  }
}

// --- Internal draw helpers ---

function drawPlatform(
  g: Graphics,
  accent: number,
  halfW: number,
  halfH: number,
  platformW: number,
  platformH: number,
) {
  g.clear();
  g.roundRect(-halfW, -halfH, platformW, platformH, 8);
  g.fill({ color: accent, alpha: 0.15 });
  g.stroke({ color: accent, width: 2, alpha: 0.6 });

  const innerW = platformW * 0.5;
  const innerH = platformH * 0.4;
  g.roundRect(-innerW / 2, -innerH / 2 - 4, innerW, innerH, 4);
  g.fill({ color: accent, alpha: 0.25 });
}

function drawStateDot(g: Graphics, state: StationState, halfW: number, halfH: number) {
  g.clear();
  const dotColor = STATE_DOT_COLORS[state] ?? 0x666666;
  g.circle(halfW - 8, -halfH + 8, 4);
  g.fill({ color: dotColor });
}

function updateBadge(
  badgeGfx: Graphics,
  badgeText: Text,
  queueDepth: number,
  halfW: number,
  halfH: number,
  accent: number,
) {
  badgeGfx.clear();
  if (queueDepth > 0) {
    badgeGfx.roundRect(-halfW - 2, -halfH - 2, 18, 14, 4);
    badgeGfx.fill({ color: 0x2c313a });
    badgeGfx.stroke({ color: accent, width: 1, alpha: 0.5 });
    badgeText.text = String(queueDepth);
    badgeText.x = -halfW + 6;
    badgeText.y = -halfH;
    badgeText.visible = true;
  } else {
    badgeText.visible = false;
  }
}
