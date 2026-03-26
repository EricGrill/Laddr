// pixi/WorkerGraphic.ts — Worker factory and update functions
import { Container, Graphics, Text, TextStyle } from 'pixi.js';
import { lerp, pulse } from './AnimationManager';

// Role -> visor color
const ROLE_COLORS: Record<string, number> = {
  llm: 0xa47bff,
  code: 0x5b8cff,
  tool: 0x56c7b6,
  supervisor: 0xd8b15b,
  dispatcher: 0x63d7e6,
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

interface WorkerRefs {
  bodyGfx: Graphics;
  activityGfx: Graphics;
  nameText: Text;
  statusText: Text;
  jobBadgeGfx: Graphics;
  jobBadgeText: Text;
  roleColor: number;
  posX: number;
  posY: number;
  status: string;
  activeJobs: number;
}

const WORKER_REFS = new WeakMap<Container, WorkerRefs>();

export function createWorker(id: string, roleColor: number): Container {
  const container = new Container();
  container.label = id;

  const activityGfx = new Graphics();
  container.addChild(activityGfx);

  const bodyGfx = new Graphics();
  container.addChild(bodyGfx);

  // Worker name label
  const shortId = id.length > 10 ? id.slice(0, 10) : id;
  const nameText = new Text({
    text: shortId,
    style: new TextStyle({
      fontSize: 8,
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
      fontSize: 7,
      fill: '#4caf50',
      fontFamily: 'Arial, Helvetica, sans-serif',
    }),
  });
  statusText.anchor.set(0.5, 0);
  statusText.x = 0;
  statusText.y = 20;
  container.addChild(statusText);

  // Job count badge
  const jobBadgeGfx = new Graphics();
  jobBadgeGfx.visible = false;
  container.addChild(jobBadgeGfx);

  const jobBadgeText = new Text({
    text: '',
    style: new TextStyle({
      fontSize: 7,
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

  const refs: WorkerRefs = {
    bodyGfx,
    activityGfx,
    nameText,
    statusText,
    jobBadgeGfx,
    jobBadgeText,
    roleColor,
    posX: 0,
    posY: 0,
    status: 'online',
    activeJobs: 0,
  };
  WORKER_REFS.set(container, refs);

  return container;
}

export function updateWorker(
  container: Container,
  targetX: number,
  targetY: number,
  status: string,
  activeJobs: number,
  elapsed: number,
  dt: number,
): void {
  const refs = WORKER_REFS.get(container);
  if (!refs) return;

  // Update status text if changed
  if (status !== refs.status) {
    refs.statusText.text = status;
    refs.statusText.style.fill = STATUS_COLORS[status] ?? '#888888';
  }

  // Update job badge
  if (activeJobs !== refs.activeJobs) {
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
  }

  refs.status = status;
  refs.activeJobs = activeJobs;

  // Lerp position
  const speed = 3;
  const factor = Math.min(1, speed * dt);
  refs.posX = lerp(refs.posX, targetX, factor);
  refs.posY = lerp(refs.posY, targetY, factor);
  container.x = refs.posX;
  container.y = refs.posY;

  const isOnline = status === 'online';
  const isOffline = status === 'offline';
  const isDraining = status === 'draining';
  const isBusy = activeJobs > 0;

  // Breathing alpha
  let breathAlpha: number;
  if (isOnline && !isBusy) {
    breathAlpha = pulse(elapsed, 0.3, 0.6, 2);
  } else if (isBusy) {
    breathAlpha = 0.8;
  } else {
    breathAlpha = 0.3;
  }

  const bodyW = 20;
  const bodyH = 16;
  const alpha = isOffline ? 0.3 : 1;

  // Draw body
  const g = refs.bodyGfx;
  g.clear();
  g.ellipse(0, bodyH / 2 + 2, bodyW / 2 - 2, 3);
  g.fill({ color: 0x0e1218, alpha: 0.3 * alpha });
  g.roundRect(-bodyW / 2, -bodyH / 2, bodyW, bodyH, 3);
  g.fill({ color: 0x2c313a, alpha });
  g.roundRect(-bodyW / 2 + 2, -bodyH / 2 + 1, bodyW - 4, 3, 1);
  g.fill({ color: refs.roleColor, alpha: breathAlpha * alpha });
  g.circle(0, -bodyH / 2 + 5, 2);
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
}

/** Set initial position without lerping */
export function setWorkerPosition(container: Container, x: number, y: number): void {
  const refs = WORKER_REFS.get(container);
  if (!refs) return;
  refs.posX = x;
  refs.posY = y;
  container.x = x;
  container.y = y;
}
