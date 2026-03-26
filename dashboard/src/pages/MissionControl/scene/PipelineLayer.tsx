// dashboard/src/pages/MissionControl/scene/PipelineLayer.tsx
import { useMemo } from "react";
import { Line } from "@react-three/drei";
import { useSceneStore } from "../stores/sceneStore";
import { useEntityStore } from "../stores/entityStore";

// Fixed flow connections
const FIXED_CONNECTIONS: Array<[string, string, string]> = [
  ["intake", "dispatcher", "#2ecc71"],
  ["dispatcher", "output-dock", "#1abc9c"],
  ["dispatcher", "supervisor", "#f1c40f"],
  ["dispatcher", "error-chamber", "#c0392b"],
];

export function PipelineLayer() {
  const stations = useEntityStore((s) => s.stations);
  const getPos = useSceneStore((s) => s.getStationPosition);

  const lines = useMemo(() => {
    const result: Array<{ points: [number, number, number][]; color: string }> = [];

    // Fixed connections
    for (const [fromType, toId, color] of FIXED_CONNECTIONS) {
      const from = getPos(fromType);
      const to = getPos(toId);
      result.push({
        points: [
          [from.x, 0.1, from.z],
          [to.x, 0.1, to.z],
        ],
        color,
      });
    }

    // Dynamic: dispatcher → each dynamic station
    for (const station of Object.values(stations)) {
      if (station.workerId) {
        const from = getPos("dispatcher");
        const to = getPos(station.id);
        result.push({
          points: [
            [from.x, 0.1, from.z],
            [to.x, 0.1, to.z],
          ],
          color: "#3498db",
        });
        // station → output
        const out = getPos("output-dock");
        result.push({
          points: [
            [to.x, 0.1, to.z],
            [out.x, 0.1, out.z],
          ],
          color: "#1abc9c",
        });
      }
    }

    return result;
  }, [stations, getPos]);

  return (
    <group>
      {lines.map((line, i) => (
        <Line
          key={i}
          points={line.points}
          color={line.color}
          lineWidth={1.5}
          transparent
          opacity={0.4}
        />
      ))}
    </group>
  );
}
