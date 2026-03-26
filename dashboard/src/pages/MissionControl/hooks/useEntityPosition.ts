// dashboard/src/pages/MissionControl/hooks/useEntityPosition.ts
import { useSceneStore } from "../stores/sceneStore";
import type { Vec3 } from "../types";

export function useAgentPosition(stationId: string | undefined): Vec3 {
  return useSceneStore((s) => s.getAgentPosition(stationId));
}

export function useJobPosition(stationId: string | undefined, state: string): Vec3 {
  return useSceneStore((s) => s.getJobPosition(stationId, state));
}
