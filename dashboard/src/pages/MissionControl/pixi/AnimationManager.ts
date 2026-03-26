// pixi/AnimationManager.ts — Central animation tick manager
import { useRef, useCallback } from "react";
import { useTick } from "@pixi/react";

// --- Easing functions ---

export function easeOutCubic(t: number): number {
  return 1 - Math.pow(1 - t, 3);
}

export function easeInOutQuad(t: number): number {
  return t < 0.5 ? 2 * t * t : 1 - Math.pow(-2 * t + 2, 2) / 2;
}

export function lerp(a: number, b: number, t: number): number {
  return a + (b - a) * t;
}

// --- Pulse / oscillation helpers ---

/** Oscillates between min and max over the given period (seconds) */
export function pulse(
  elapsed: number,
  min: number,
  max: number,
  period: number,
): number {
  const t = (Math.sin((elapsed / period) * Math.PI * 2) + 1) / 2;
  return min + t * (max - min);
}

/** Returns a 0-1 progress value cycling over the given period */
export function cycle(elapsed: number, period: number): number {
  return (elapsed % period) / period;
}

// --- Position lerping for workers/packets ---

export interface LerpPosition {
  x: number;
  y: number;
  targetX: number;
  targetY: number;
}

export function lerpPosition(
  pos: LerpPosition,
  speed: number,
  dt: number,
): { x: number; y: number } {
  const factor = Math.min(1, speed * dt);
  return {
    x: lerp(pos.x, pos.targetX, factor),
    y: lerp(pos.y, pos.targetY, factor),
  };
}

// --- Bezier path interpolation ---

export interface BezierPath {
  x0: number;
  y0: number;
  cx0: number;
  cy0: number;
  cx1: number;
  cy1: number;
  x1: number;
  y1: number;
}

export function bezierPoint(
  path: BezierPath,
  t: number,
): { x: number; y: number } {
  const u = 1 - t;
  const tt = t * t;
  const uu = u * u;
  const uuu = uu * u;
  const ttt = tt * t;

  return {
    x:
      uuu * path.x0 +
      3 * uu * t * path.cx0 +
      3 * u * tt * path.cx1 +
      ttt * path.x1,
    y:
      uuu * path.y0 +
      3 * uu * t * path.cy0 +
      3 * u * tt * path.cy1 +
      ttt * path.y1,
  };
}

// --- Hook: useElapsed ---

export function useElapsed(): { elapsed: number } {
  const ref = useRef({ elapsed: 0 });

  useTick((ticker) => {
    ref.current.elapsed += ticker.deltaMS / 1000;
  });

  return ref.current;
}

// --- Hook: useAnimationTick ---

export function useAnimationTick(
  callback: (elapsed: number, dt: number) => void,
) {
  const elapsedRef = useRef(0);
  const cb = useCallback(callback, [callback]);

  useTick((ticker) => {
    const dt = ticker.deltaMS / 1000;
    elapsedRef.current += dt;
    cb(elapsedRef.current, dt);
  });
}
