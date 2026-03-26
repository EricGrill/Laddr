// dashboard/src/pages/MissionControl/scene/StationMesh.tsx
import { useRef, useState } from "react";
import { useFrame } from "@react-three/fiber";
import { Html } from "@react-three/drei";
import type { Mesh } from "three";
import type { MCStation, Vec3 } from "../types";
import { useUIStore } from "../stores/uiStore";

const STATION_COLORS: Record<string, string> = {
  intake: "#2ecc71",
  dispatcher: "#3498db",
  llm: "#9b59b6",
  tool: "#e67e22",
  code: "#e74c3c",
  supervisor: "#f1c40f",
  error: "#c0392b",
  output: "#1abc9c",
};

const STATION_GEOMETRY: Record<string, { type: string; args: number[] }> = {
  intake: { type: "box", args: [2, 1.5, 2] },
  dispatcher: { type: "cylinder", args: [1.5, 1.5, 1.5, 16] },
  llm: { type: "box", args: [2.2, 2, 2.2] },
  tool: { type: "box", args: [2, 1.8, 2] },
  code: { type: "box", args: [2, 1.8, 2] },
  supervisor: { type: "box", args: [2.5, 1, 2.5] },
  error: { type: "box", args: [2, 1.5, 2] },
  output: { type: "box", args: [2, 1.5, 2] },
};

interface StationMeshProps {
  station: MCStation;
  position: Vec3;
}

export function StationMesh({ station, position }: StationMeshProps) {
  const meshRef = useRef<Mesh>(null);
  const [hovered, setHovered] = useState(false);
  const selectEntity = useUIStore((s) => s.selectEntity);
  const selectedEntity = useUIStore((s) => s.selectedEntity);
  const isSelected = selectedEntity?.id === station.id && selectedEntity?.type === "station";
  const isFiltered = useUIStore((s) => s.isFiltered("station", station.state));

  const color = STATION_COLORS[station.type] ?? "#888888";
  const geo = STATION_GEOMETRY[station.type] ?? { type: "box", args: [2, 1.5, 2] };

  // Subtle rotation for dispatcher
  useFrame((_, delta) => {
    if (station.type === "dispatcher" && meshRef.current) {
      meshRef.current.rotation.y += delta * 0.3;
    }
  });

  const emissiveIntensity = station.state === "active" || station.state === "saturated"
    ? 0.6
    : station.state === "errored"
    ? 0.8
    : 0.2;

  return (
    <group
      position={[position.x, position.y + (geo.args[1] ?? 1.5) / 2, position.z]}
    >
      <mesh
        ref={meshRef}
        onClick={() => selectEntity({ id: station.id, type: "station" })}
        onPointerEnter={() => setHovered(true)}
        onPointerLeave={() => setHovered(false)}
      >
        {geo.type === "cylinder" ? (
          <cylinderGeometry args={geo.args as [number, number, number, number]} />
        ) : (
          <boxGeometry args={geo.args as [number, number, number]} />
        )}
        <meshStandardMaterial
          color={color}
          emissive={station.state === "errored" ? "#ff0000" : color}
          emissiveIntensity={isSelected ? 1.0 : hovered ? 0.8 : emissiveIntensity}
          metalness={0.7}
          roughness={0.3}
          transparent={isFiltered}
          opacity={isFiltered ? 0.1 : 1}
        />
      </mesh>

      {/* Label */}
      <Html position={[0, (geo.args[1] ?? 1.5) / 2 + 0.5, 0]} center distanceFactor={15}>
        <div
          style={{
            color: hovered || isSelected ? "#ffffff" : color,
            fontSize: "11px",
            fontWeight: 600,
            textAlign: "center",
            whiteSpace: "nowrap",
            textShadow: "0 0 6px rgba(0,0,0,0.8)",
            pointerEvents: "none",
            userSelect: "none",
          }}
        >
          {station.label}
          {station.queueDepth > 0 && (
            <div style={{ fontSize: "9px", opacity: 0.7 }}>
              Queue: {station.queueDepth}
            </div>
          )}
        </div>
      </Html>
    </group>
  );
}
