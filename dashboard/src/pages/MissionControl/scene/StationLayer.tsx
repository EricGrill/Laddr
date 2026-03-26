// dashboard/src/pages/MissionControl/scene/StationLayer.tsx
import { useEffect } from "react";
import { useEntityStore } from "../stores/entityStore";
import { useSceneStore } from "../stores/sceneStore";
import { StationMesh } from "./StationMesh";

export function StationLayer() {
  const stations = useEntityStore((s) => s.stations);
  const setStationPositions = useSceneStore((s) => s.setStationPositions);
  const getStationPosition = useSceneStore((s) => s.getStationPosition);

  const stationList = Object.values(stations);

  // Update scene layout when stations change
  useEffect(() => {
    if (stationList.length > 0) {
      setStationPositions(stationList.map((s) => ({ id: s.id, type: s.type })));
    }
  }, [stationList.length, setStationPositions]);

  return (
    <group>
      {stationList.map((station) => (
        <StationMesh
          key={station.id}
          station={station}
          position={getStationPosition(station.id)}
        />
      ))}
    </group>
  );
}
