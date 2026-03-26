// dashboard/src/pages/MissionControl/hooks/useAnimatedPosition.ts
import { useRef } from "react";
import { useFrame } from "@react-three/fiber";
import { Vector3 } from "three";
import type { Vec3 } from "../types";

const LERP_SPEED = 3;

export function useAnimatedPosition(target: Vec3): React.RefObject<Vector3 | null> {
  const current = useRef<Vector3>(new Vector3(target.x, target.y, target.z));

  useFrame((_, delta) => {
    if (!current.current) return;
    const speed = Math.min(delta * LERP_SPEED, 1);
    current.current.lerp(new Vector3(target.x, target.y, target.z), speed);
  });

  return current as React.RefObject<Vector3 | null>;
}
