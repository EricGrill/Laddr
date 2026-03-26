// dashboard/src/pages/MissionControl/stores/sceneStore.ts
import { create } from "zustand";
import type { StationType, Vec3 } from "../types";

// Fixed station positions (world coordinates, x = left-right, z = depth)
const FIXED_POSITIONS: Record<string, Vec3> = {
  intake: { x: -12, y: 0, z: 0 },
  dispatcher: { x: -6, y: 0, z: 0 },
  supervisor: { x: 0, y: 0, z: -8 },
  error: { x: 0, y: 0, z: 8 },
  output: { x: 12, y: 0, z: 0 },
};

// Dynamic stations are positioned in the middle zone between dispatcher and output
const DYNAMIC_ZONE = { xMin: -1, xMax: 7, zMin: -6, zMax: 6 };

interface SceneState {
  stationPositions: Record<string, Vec3>;
  setStationPositions: (stations: Array<{ id: string; type: StationType }>) => void;
  getStationPosition: (stationId: string) => Vec3;
  getAgentPosition: (stationId: string | undefined) => Vec3;
  getJobPosition: (stationId: string | undefined, state: string) => Vec3;
}

export const useSceneStore = create<SceneState>((set, get) => ({
  stationPositions: { ...FIXED_POSITIONS },

  setStationPositions(stations) {
    const positions: Record<string, Vec3> = { ...FIXED_POSITIONS };
    const dynamicStations = stations.filter(
      (s) => !FIXED_POSITIONS[s.type] && !positions[s.id]
    );

    // Lay out dynamic stations in a grid in the middle zone
    const cols = Math.ceil(Math.sqrt(dynamicStations.length));
    dynamicStations.forEach((station, i) => {
      const col = i % cols;
      const row = Math.floor(i / cols);
      const totalRows = Math.ceil(dynamicStations.length / cols);
      const x =
        DYNAMIC_ZONE.xMin +
        ((col + 0.5) / cols) * (DYNAMIC_ZONE.xMax - DYNAMIC_ZONE.xMin);
      const z =
        DYNAMIC_ZONE.zMin +
        ((row + 0.5) / totalRows) * (DYNAMIC_ZONE.zMax - DYNAMIC_ZONE.zMin);
      positions[station.id] = { x, y: 0, z };
    });

    // Also map type-based lookups for fixed stations
    for (const station of stations) {
      if (FIXED_POSITIONS[station.type] && !positions[station.id]) {
        positions[station.id] = FIXED_POSITIONS[station.type];
      }
    }

    set({ stationPositions: positions });
  },

  getStationPosition(stationId) {
    return get().stationPositions[stationId] ?? { x: 0, y: 0, z: 0 };
  },

  getAgentPosition(stationId) {
    if (!stationId) return { x: -8, y: 0.5, z: 0 }; // idle position near dispatcher
    const base = get().getStationPosition(stationId);
    return { x: base.x, y: 0.5, z: base.z + 1.5 }; // offset slightly from station
  },

  getJobPosition(stationId, state) {
    if (state === "queued" || !stationId) {
      return FIXED_POSITIONS.intake;
    }
    if (state === "completed") {
      return FIXED_POSITIONS.output;
    }
    if (state === "failed") {
      return FIXED_POSITIONS.error;
    }
    const base = get().getStationPosition(stationId);
    return { x: base.x, y: 0.3, z: base.z - 1 }; // offset below station
  },
}));
