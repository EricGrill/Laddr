// pixi/PacketGraphic.ts — Job packet factory and update functions
import { Container, Graphics } from 'pixi.js';
import type { JobPriority, JobState } from '../types';
import { pulse } from './AnimationManager';

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

interface PacketRefs {
  glowGfx: Graphics;
  cardGfx: Graphics;
  capsuleGfx: Graphics;
  chipGfx: Graphics;
  typeColor: number;
  priorityColor: number;
  priority: JobPriority;
  state: JobState;
  progress: number;
  jobType: string;
}

const PACKET_REFS = new WeakMap<Container, PacketRefs>();

export function createPacket(
  jobType: string,
  priority: JobPriority,
  state: JobState,
  progress: number,
): Container {
  const container = new Container();

  const glowGfx = new Graphics();
  container.addChild(glowGfx);

  const cardGfx = new Graphics();
  container.addChild(cardGfx);

  const capsuleGfx = new Graphics();
  container.addChild(capsuleGfx);

  const chipGfx = new Graphics();
  container.addChild(chipGfx);

  const refs: PacketRefs = {
    glowGfx,
    cardGfx,
    capsuleGfx,
    chipGfx,
    typeColor: getTypeColor(jobType),
    priorityColor: PRIORITY_COLORS[priority],
    priority,
    state,
    progress,
    jobType,
  };
  PACKET_REFS.set(container, refs);

  // Initial draw
  redrawPacket(refs);

  return container;
}

export function updatePacket(
  container: Container,
  x: number,
  y: number,
  state: JobState,
  progress: number,
  elapsed: number,
): void {
  const refs = PACKET_REFS.get(container);
  if (!refs) return;

  container.x = x;
  container.y = y;

  const stateChanged = state !== refs.state;
  const progressChanged = progress !== refs.progress;

  refs.state = state;
  refs.progress = progress;

  // Hide completed/cancelled/failed
  if (state === 'completed' || state === 'cancelled' || state === 'failed') {
    container.visible = false;
    return;
  }
  container.visible = true;

  if (stateChanged || progressChanged) {
    redrawPacket(refs);
  }

  // Animate glow
  const isCritical = refs.priority === 'critical';
  const isHigh = refs.priority === 'high';
  refs.glowGfx.clear();
  if (isCritical) {
    const alpha = pulse(elapsed, 0.3, 0.8, 0.5);
    refs.glowGfx.circle(0, 0, 10);
    refs.glowGfx.fill({ color: 0xe35b5b, alpha: alpha * 0.3 });
  } else if (isHigh) {
    const alpha = pulse(elapsed, 0.2, 0.5, 1.2);
    refs.glowGfx.circle(0, 0, 10);
    refs.glowGfx.fill({ color: 0xf2a65a, alpha: alpha * 0.3 });
  }
}

function redrawPacket(refs: PacketRefs) {
  const { state, typeColor, priorityColor, progress } = refs;
  const isQueued = state === 'queued' || state === 'created';
  const isTransit = state === 'in_transit' || state === 'assigned' || state === 'handoff';
  const isProcessing = state === 'processing';

  // Card (queued)
  refs.cardGfx.clear();
  if (isQueued) {
    const w = 16, h = 12;
    refs.cardGfx.roundRect(-w / 2, -h / 2, w, h, 2);
    refs.cardGfx.fill({ color: 0x2c313a, alpha: 0.8 });
    refs.cardGfx.stroke({ color: typeColor, width: 1, alpha: 0.6 });
    refs.cardGfx.circle(w / 2 - 3, -h / 2 + 3, 2);
    refs.cardGfx.fill({ color: priorityColor, alpha: 0.8 });
  }

  // Capsule (transit)
  refs.capsuleGfx.clear();
  if (isTransit) {
    const w = 10, h = 6;
    refs.capsuleGfx.roundRect(-w / 2, -h / 2, w, h, 3);
    refs.capsuleGfx.fill({ color: typeColor, alpha: 0.6 });
    refs.capsuleGfx.stroke({ color: typeColor, width: 1, alpha: 0.8 });
  }

  // Chip (processing)
  refs.chipGfx.clear();
  if (isProcessing) {
    const w = 14, h = 10;
    refs.chipGfx.roundRect(-w / 2, -h / 2, w, h, 2);
    refs.chipGfx.fill({ color: 0x2c313a, alpha: 0.9 });
    refs.chipGfx.stroke({ color: typeColor, width: 1, alpha: 0.7 });
    const barW = (w - 4) * (progress ?? 0);
    if (barW > 0) {
      refs.chipGfx.roundRect(-w / 2 + 2, h / 2 - 4, barW, 2, 1);
      refs.chipGfx.fill({ color: typeColor, alpha: 0.8 });
    }
  }
}
