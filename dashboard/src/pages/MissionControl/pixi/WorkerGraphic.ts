// pixi/WorkerGraphic.ts — Worker factory, animation state machine, and update functions
import { Container, Graphics, Text, TextStyle } from 'pixi.js';
import { lerp, pulse } from './AnimationManager';
import { STATION_POSITIONS } from './StationGraphic';

// Role -> visor color
const ROLE_COLORS: Record<string, number> = {
  llm: 0xa47bff,
  code: 0x5b8cff,
  tool: 0x56c7b6,
  supervisor: 0xd8b15b,
  dispatcher: 0x63d7e6,
  default: 0x63d7e6,
};

// Job type -> chip color (matches station accents)
const JOB_TYPE_COLORS: Record<string, number> = {
  llm: 0xa47bff,
  code: 0x5b8cff,
  tool: 0x56c7b6,
  supervisor: 0xd8b15b,
  default: 0x63d7e6,
};

export function getRoleColor(capabilities: string[]): number {
  for (const cap of capabilities) {
    if (cap in ROLE_COLORS) return ROLE_COLORS[cap];
  }
  return ROLE_COLORS.default;
}

const STATUS_COLORS: Record<string, string> = {
  online: '#4caf50',
  draining: '#e8d25b',
  offline: '#666666',
};

// --- Animation Phase Types ---

export type WorkerAnimPhase =
  | 'idle'
  | 'walking_to_intake'
  | 'picking_up'
  | 'walking_to_station'
  | 'processing'
  | 'walking_to_output'
  | 'delivering'
  | 'walking_home';

export interface WorkerAnimState {
  phase: WorkerAnimPhase;
  progress: number; // 0-1 for walking phases
  fromX: number;
  fromY: number;
  toX: number;
  toY: number;
  stationId: string; // target processing station
  carriedJobType: string; // for chip color
  phaseTimer: number; // seconds spent in current phase
  phaseDuration: number; // expected duration for timed phases
  finishingCycle: boolean; // true if we should go idle after current cycle
}

interface WorkerRefs {
  bodyGfx: Graphics;
  activityGfx: Graphics;
  pathGfx: Graphics;
  chipGfx: Graphics;
  nameText: Text;
  statusText: Text;
  jobBadgeGfx: Graphics;
  jobBadgeText: Text;
  bubbleGfx: Graphics;
  bubbleText: Text;
  roleColor: number;
  posX: number;
  posY: number;
  homeX: number;
  homeY: number;
  status: string;
  activeJobs: number;
  capabilities: string[];
  anim: WorkerAnimState;
}

const WORKER_REFS = new WeakMap<Container, WorkerRefs>();

const MOVE_SPEED = 150; // pixels per second

function distanceBetween(x1: number, y1: number, x2: number, y2: number): number {
  return Math.sqrt((x2 - x1) ** 2 + (y2 - y1) ** 2);
}

function pickStation(capabilities: string[]): string {
  // Pick a processing station based on worker capabilities
  const stationCaps = ['llm', 'code', 'tool', 'supervisor'];
  for (const cap of capabilities) {
    if (stationCaps.includes(cap)) return cap;
  }
  // Fallback: random station
  return stationCaps[Math.floor(Math.random() * stationCaps.length)];
}

function getStationPos(stationId: string): { x: number; y: number } {
  const pos = STATION_POSITIONS[stationId];
  if (pos) return { x: pos.x, y: pos.y };
  return { x: 650, y: 400 }; // dispatcher fallback
}

function getPhaseLabel(phase: WorkerAnimPhase): string {
  switch (phase) {
    case 'idle': return 'idle';
    case 'walking_to_intake': return '\u2192 Intake';
    case 'picking_up': return 'picking up';
    case 'walking_to_station': return '\u2192 Station';
    case 'processing': return 'processing';
    case 'walking_to_output': return '\u2192 Output';
    case 'delivering': return 'delivering';
    case 'walking_home': return '\u2192 Home';
  }
}

function initAnimState(): WorkerAnimState {
  return {
    phase: 'idle',
    progress: 0,
    fromX: 0,
    fromY: 0,
    toX: 0,
    toY: 0,
    stationId: '',
    carriedJobType: '',
    phaseTimer: 0,
    phaseDuration: 0,
    finishingCycle: false,
  };
}

export function createWorker(id: string, roleColor: number, capabilities?: string[]): Container {
  const container = new Container();
  container.label = id;

  // Path line (drawn behind everything)
  const pathGfx = new Graphics();
  container.addChild(pathGfx);

  const activityGfx = new Graphics();
  container.addChild(activityGfx);

  const bodyGfx = new Graphics();
  container.addChild(bodyGfx);

  // Carried job chip (above worker)
  const chipGfx = new Graphics();
  container.addChild(chipGfx);

  // Worker name label
  const shortId = id.length > 10 ? id.slice(0, 10) : id;
  const nameText = new Text({
    text: `${shortId} \u2022 idle`,
    style: new TextStyle({
      fontSize: 11,
      fill: '#cccccc',
      fontFamily: 'Arial, Helvetica, sans-serif',
    }),
  });
  nameText.anchor.set(0.5, 0);
  nameText.x = 0;
  nameText.y = 11;
  container.addChild(nameText);

  // Status text
  const statusText = new Text({
    text: 'online',
    style: new TextStyle({
      fontSize: 10,
      fill: '#4caf50',
      fontFamily: 'Arial, Helvetica, sans-serif',
    }),
  });
  statusText.anchor.set(0.5, 0);
  statusText.x = 0;
  statusText.y = 22;
  container.addChild(statusText);

  // Job count badge
  const jobBadgeGfx = new Graphics();
  jobBadgeGfx.visible = false;
  container.addChild(jobBadgeGfx);

  const jobBadgeText = new Text({
    text: '',
    style: new TextStyle({
      fontSize: 10,
      fill: '#ffffff',
      fontFamily: 'Arial, Helvetica, sans-serif',
      fontWeight: 'bold',
    }),
  });
  jobBadgeText.anchor.set(0.5, 0.5);
  jobBadgeText.x = 12;
  jobBadgeText.y = -8;
  jobBadgeText.visible = false;
  container.addChild(jobBadgeText);

  const bubbleGfx = new Graphics();
  bubbleGfx.visible = false;
  container.addChild(bubbleGfx);

  const bubbleText = new Text({
    text: '',
    style: new TextStyle({
      fontSize: 10,
      fill: '#0d1220',
      fontFamily: 'Arial, Helvetica, sans-serif',
      fontWeight: 'bold',
    }),
  });
  bubbleText.anchor.set(0.5, 0.5);
  bubbleText.y = -34;
  bubbleText.visible = false;
  container.addChild(bubbleText);

  const refs: WorkerRefs = {
    bodyGfx,
    activityGfx,
    pathGfx,
    chipGfx,
    nameText,
    statusText,
    jobBadgeGfx,
    jobBadgeText,
    bubbleGfx,
    bubbleText,
    roleColor,
    posX: 0,
    posY: 0,
    homeX: 0,
    homeY: 0,
    status: 'online',
    activeJobs: 0,
    capabilities: capabilities ?? [],
    anim: initAnimState(),
  };
  WORKER_REFS.set(container, refs);

  return container;
}

/** Transition to a new animation phase */
function startPhase(refs: WorkerRefs, phase: WorkerAnimPhase): void {
  const anim = refs.anim;
  anim.phase = phase;
  anim.progress = 0;
  anim.phaseTimer = 0;

  switch (phase) {
    case 'walking_to_intake': {
      const intake = getStationPos('intake');
      anim.fromX = refs.posX;
      anim.fromY = refs.posY;
      anim.toX = intake.x + (Math.random() - 0.5) * 40;
      anim.toY = intake.y + 60 + Math.random() * 20;
      anim.phaseDuration = distanceBetween(anim.fromX, anim.fromY, anim.toX, anim.toY) / MOVE_SPEED;
      // Pick a station for this work cycle
      anim.stationId = pickStation(refs.capabilities);
      anim.carriedJobType = anim.stationId;
      break;
    }
    case 'picking_up': {
      anim.phaseDuration = 0.5;
      break;
    }
    case 'walking_to_station': {
      const station = getStationPos(anim.stationId);
      anim.fromX = refs.posX;
      anim.fromY = refs.posY;
      anim.toX = station.x + (Math.random() - 0.5) * 50;
      anim.toY = station.y + 60 + Math.random() * 20;
      anim.phaseDuration = distanceBetween(anim.fromX, anim.fromY, anim.toX, anim.toY) / MOVE_SPEED;
      break;
    }
    case 'processing': {
      anim.phaseDuration = 2 + Math.random() * 2; // 2-4s
      break;
    }
    case 'walking_to_output': {
      const output = getStationPos('output');
      anim.fromX = refs.posX;
      anim.fromY = refs.posY;
      anim.toX = output.x + (Math.random() - 0.5) * 40;
      anim.toY = output.y + 60 + Math.random() * 20;
      anim.phaseDuration = distanceBetween(anim.fromX, anim.fromY, anim.toX, anim.toY) / MOVE_SPEED;
      break;
    }
    case 'delivering': {
      anim.phaseDuration = 0.5;
      break;
    }
    case 'walking_home': {
      anim.fromX = refs.posX;
      anim.fromY = refs.posY;
      anim.toX = refs.homeX;
      anim.toY = refs.homeY;
      anim.phaseDuration = distanceBetween(anim.fromX, anim.fromY, anim.toX, anim.toY) / MOVE_SPEED;
      break;
    }
    case 'idle': {
      anim.phaseDuration = 0;
      anim.finishingCycle = false;
      break;
    }
  }
}

/** Advance the animation state machine by dt seconds */
function tickAnim(refs: WorkerRefs, dt: number): void {
  const anim = refs.anim;

  if (anim.phase === 'idle') {
    // If worker has active jobs, start a work cycle
    if (refs.activeJobs > 0 && refs.status === 'online') {
      startPhase(refs, 'walking_to_intake');
    }
    return;
  }

  anim.phaseTimer += dt;

  // For walking phases, advance progress based on time
  const isWalking = anim.phase === 'walking_to_intake'
    || anim.phase === 'walking_to_station'
    || anim.phase === 'walking_to_output'
    || anim.phase === 'walking_home';

  if (isWalking && anim.phaseDuration > 0) {
    anim.progress = Math.min(1, anim.phaseTimer / anim.phaseDuration);
  }

  // Check for phase completion
  const isComplete = isWalking
    ? anim.progress >= 1
    : anim.phaseTimer >= anim.phaseDuration;

  if (!isComplete) return;

  // Transition to next phase
  switch (anim.phase) {
    case 'walking_to_intake':
      startPhase(refs, 'picking_up');
      break;
    case 'picking_up':
      startPhase(refs, 'walking_to_station');
      break;
    case 'walking_to_station':
      startPhase(refs, 'processing');
      break;
    case 'processing':
      startPhase(refs, 'walking_to_output');
      break;
    case 'walking_to_output':
      startPhase(refs, 'delivering');
      break;
    case 'delivering':
      // If still has active jobs and not finishing, start another cycle
      if (refs.activeJobs > 0 && !anim.finishingCycle) {
        startPhase(refs, 'walking_to_intake');
      } else {
        startPhase(refs, 'walking_home');
      }
      break;
    case 'walking_home':
      startPhase(refs, 'idle');
      break;
  }
}

/** Get the current target position based on animation state */
function getAnimTargetPos(refs: WorkerRefs): { x: number; y: number } {
  const anim = refs.anim;

  switch (anim.phase) {
    case 'idle':
      return { x: refs.homeX, y: refs.homeY };

    case 'walking_to_intake':
    case 'walking_to_station':
    case 'walking_to_output':
    case 'walking_home': {
      // Smooth eased interpolation along path
      const t = easeInOutQuad(anim.progress);
      return {
        x: lerp(anim.fromX, anim.toX, t),
        y: lerp(anim.fromY, anim.toY, t),
      };
    }

    case 'picking_up':
    case 'processing':
    case 'delivering':
      // Stay at current position during timed phases
      return { x: refs.posX, y: refs.posY };
  }
}

function easeInOutQuad(t: number): number {
  return t < 0.5 ? 2 * t * t : 1 - Math.pow(-2 * t + 2, 2) / 2;
}

export function updateWorker(
  container: Container,
  homeX: number,
  homeY: number,
  status: string,
  activeJobs: number,
  elapsed: number,
  dt: number,
): void {
  const refs = WORKER_REFS.get(container);
  if (!refs) return;

  // Update home position
  refs.homeX = homeX;
  refs.homeY = homeY;

  // Update status text if changed
  if (status !== refs.status) {
    refs.statusText.text = status;
    refs.statusText.style.fill = STATUS_COLORS[status] ?? '#888888';
  }

  // Detect job count changes
  const jobsChanged = activeJobs !== refs.activeJobs;

  // Update job badge
  if (jobsChanged) {
    if (activeJobs > 0) {
      refs.jobBadgeGfx.clear();
      refs.jobBadgeGfx.circle(12, -8, 6);
      refs.jobBadgeGfx.fill({ color: 0xe35b5b, alpha: 0.9 });
      refs.jobBadgeGfx.visible = true;
      refs.jobBadgeText.text = String(activeJobs);
      refs.jobBadgeText.visible = true;
    } else {
      refs.jobBadgeGfx.visible = false;
      refs.jobBadgeText.visible = false;
    }

    // If jobs dropped to 0 while animating, let current cycle finish
    if (activeJobs === 0 && refs.anim.phase !== 'idle') {
      refs.anim.finishingCycle = true;
    }
  }

  refs.status = status;
  refs.activeJobs = activeJobs;

  // Tick the animation state machine
  tickAnim(refs, dt);

  // Get target position from animation
  const target = getAnimTargetPos(refs);

  // Smooth lerp to target
  const speed = 5;
  const factor = Math.min(1, speed * dt);
  refs.posX = lerp(refs.posX, target.x, factor);
  refs.posY = lerp(refs.posY, target.y, factor);
  container.x = refs.posX;
  container.y = refs.posY;

  const isOnline = status === 'online';
  const isOffline = status === 'offline';
  const isDraining = status === 'draining';
  const isBusy = refs.anim.phase !== 'idle';

  // Update name label with phase info
  const shortId = container.label!.length > 10 ? container.label!.slice(0, 10) : container.label!;
  const phaseLabel = getPhaseLabel(refs.anim.phase);
  refs.nameText.text = `${shortId} \u2022 ${phaseLabel}`;

  // Breathing alpha
  let breathAlpha: number;
  if (isOnline && !isBusy) {
    breathAlpha = pulse(elapsed, 0.3, 0.6, 2);
  } else if (isBusy) {
    breathAlpha = 0.8;
  } else {
    breathAlpha = 0.3;
  }

  const bodyW = 40;
  const bodyH = 30;
  const alpha = isOffline ? 0.3 : 1;

  // Draw body
  const g = refs.bodyGfx;
  g.clear();
  g.ellipse(0, bodyH / 2 + 2, bodyW / 2 - 2, 3);
  g.fill({ color: 0x0e1218, alpha: 0.3 * alpha });
  g.roundRect(-bodyW / 2, -bodyH / 2, bodyW, bodyH, 3);
  g.fill({ color: 0x2c313a, alpha });
  g.roundRect(-bodyW / 2 + 3, -bodyH / 2 + 2, bodyW - 6, 5, 2);
  g.fill({ color: refs.roleColor, alpha: breathAlpha * alpha });
  g.circle(0, -bodyH / 2 + 9, 4);
  g.fill({ color: refs.roleColor, alpha: breathAlpha * alpha });
  if (isDraining) {
    g.roundRect(-bodyW / 2 - 1, -bodyH / 2 - 1, bodyW + 2, bodyH + 2, 4);
    g.stroke({ color: 0xe8d25b, width: 1, alpha: 0.6 });
  }

  // Activity ring
  const ag = refs.activityGfx;
  ag.clear();
  if (isBusy && !isOffline) {
    const activityRing = elapsed * 3;
    const radius = 12;
    const segments = 6;
    const arcLen = (Math.PI * 2) / segments;
    for (let i = 0; i < segments; i++) {
      const start = activityRing + i * arcLen;
      const end = start + arcLen * 0.4;
      ag.arc(0, 0, radius, start, end);
      ag.stroke({ color: refs.roleColor, width: 1, alpha: 0.3 });
    }
  }

  // Processing indicator — spinning/pulsing at station
  if (refs.anim.phase === 'processing' && !isOffline) {
    const procAlpha = pulse(elapsed, 0.3, 0.8, 0.6);
    const procAngle = elapsed * 5;
    const procRadius = 15;
    ag.arc(0, 0, procRadius, procAngle, procAngle + Math.PI * 0.8);
    ag.stroke({ color: refs.roleColor, width: 2, alpha: procAlpha });
    ag.arc(0, 0, procRadius, procAngle + Math.PI, procAngle + Math.PI * 1.8);
    ag.stroke({ color: refs.roleColor, width: 2, alpha: procAlpha });
  }

  // Carried job chip
  const cg = refs.chipGfx;
  cg.clear();
  const isCarrying = refs.anim.phase === 'walking_to_station'
    || refs.anim.phase === 'walking_to_output'
    || refs.anim.phase === 'processing';
  if (isCarrying && !isOffline) {
    const chipColor = JOB_TYPE_COLORS[refs.anim.carriedJobType] ?? JOB_TYPE_COLORS.default;
    const chipW = 22;
    const chipH = 14;
    // Bob animation
    const bob = Math.sin(elapsed * 4) * 2;
    const chipY = -bodyH / 2 - 8 + bob;
    cg.roundRect(-chipW / 2, chipY - chipH / 2, chipW, chipH, 2);
    cg.fill({ color: chipColor, alpha: 0.85 });
    cg.stroke({ color: chipColor, width: 1, alpha: 1 });
  }

  // Path line to target (when walking)
  const pg = refs.pathGfx;
  pg.clear();
  const isWalkingPhase = refs.anim.phase === 'walking_to_intake'
    || refs.anim.phase === 'walking_to_station'
    || refs.anim.phase === 'walking_to_output'
    || refs.anim.phase === 'walking_home';
  if (isWalkingPhase && !isOffline) {
    // Path line is drawn in local coordinates (0,0 is the worker's current position)
    // Target is relative to current position
    const dx = refs.anim.toX - refs.posX;
    const dy = refs.anim.toY - refs.posY;
    const dist = Math.sqrt(dx * dx + dy * dy);
    if (dist > 5) {
      // Draw dashed line
      const dashLen = 6;
      const gapLen = 4;
      const totalLen = dashLen + gapLen;
      const steps = Math.floor(dist / totalLen);
      const nx = dx / dist;
      const ny = dy / dist;
      for (let i = 0; i < steps; i++) {
        const startT = (i * totalLen) / dist;
        const endT = Math.min((i * totalLen + dashLen) / dist, 1);
        pg.moveTo(nx * startT * dist, ny * startT * dist);
        pg.lineTo(nx * endT * dist, ny * endT * dist);
      }
      pg.stroke({ color: refs.roleColor, width: 1, alpha: 0.2 });
    }
  }
}

export function updateWorkerBubble(
  container: Container,
  message: string | null,
  kind: string = 'orchestration',
): void {
  const refs = WORKER_REFS.get(container);
  if (!refs) return;

  if (!message) {
    refs.bubbleGfx.visible = false;
    refs.bubbleText.visible = false;
    return;
  }

  const fillColors: Record<string, number> = {
    llm: 0x8fe7ff,
    tool: 0xf2d47c,
    code: 0x91f0c2,
    review: 0xc6b8ff,
    orchestration: 0xb8c6d9,
    wait: 0xaab4c0,
    retry: 0xff9e8f,
    blocked: 0xffd166,
    error: 0xff7b7b,
  };

  const text = message.length > 32 ? `${message.slice(0, 29)}...` : message;
  refs.bubbleText.text = text;
  refs.bubbleText.visible = true;
  refs.bubbleGfx.visible = true;

  const width = Math.max(70, refs.bubbleText.width + 14);
  const height = 18;
  const x = -width / 2;
  const y = -43;
  const fillColor = fillColors[kind] ?? fillColors.orchestration;

  refs.bubbleText.x = 0;
  refs.bubbleText.y = y + height / 2;

  refs.bubbleGfx.clear();
  refs.bubbleGfx.roundRect(x, y, width, height, 8);
  refs.bubbleGfx.fill({ color: fillColor, alpha: 0.95 });
  refs.bubbleGfx.moveTo(-4, y + height);
  refs.bubbleGfx.lineTo(0, y + height + 5);
  refs.bubbleGfx.lineTo(4, y + height);
  refs.bubbleGfx.fill({ color: fillColor, alpha: 0.95 });
}

/** Set initial position without lerping */
export function setWorkerPosition(container: Container, x: number, y: number): void {
  const refs = WORKER_REFS.get(container);
  if (!refs) return;
  refs.posX = x;
  refs.posY = y;
  refs.homeX = x;
  refs.homeY = y;
  container.x = x;
  container.y = y;
}
