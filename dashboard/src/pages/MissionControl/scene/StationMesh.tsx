import { useRef, useState, useMemo } from "react";
import { useFrame } from "@react-three/fiber";
import { Html, useGLTF } from "@react-three/drei";
import { Mesh, MeshStandardMaterial, Color } from "three";
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

const STATION_MODELS: Record<string, string> = {
  intake: "/models/station-intake.glb",
  dispatcher: "/models/station-dispatcher.glb",
  llm: "/models/station-llm.glb",
  tool: "/models/station-tool.glb",
  code: "/models/station-code.glb",
  supervisor: "/models/station-supervisor.glb",
  error: "/models/station-error.glb",
  output: "/models/station-output.glb",
};

const STATION_SCALES: Record<string, number> = {
  intake: 2.5,
  dispatcher: 3.0,
  llm: 3.0,
  tool: 2.5,
  code: 2.5,
  supervisor: 2.5,
  error: 2.0,
  output: 2.5,
};

interface StationMeshProps {
  station: MCStation;
  position: Vec3;
}

// Preload all station models
Object.values(STATION_MODELS).forEach((url) => {
  useGLTF.preload(url);
});

export function StationMesh({ station, position }: StationMeshProps) {
  const groupRef = useRef<any>(null);
  const [hovered, setHovered] = useState(false);
  const selectEntity = useUIStore((s) => s.selectEntity);
  const selectedEntity = useUIStore((s) => s.selectedEntity);
  const isSelected =
    selectedEntity?.id === station.id && selectedEntity?.type === "station";
  const isFiltered = useUIStore((s) => s.isFiltered("station", station.state));

  const color = STATION_COLORS[station.type] ?? "#888888";
  const modelUrl = STATION_MODELS[station.type] ?? STATION_MODELS.code;
  const scale = STATION_SCALES[station.type] ?? 2.5;

  const { scene } = useGLTF(modelUrl);

  // Clone the scene and apply our custom material with emissive coloring
  const clonedScene = useMemo(() => {
    const clone = scene.clone(true);
    const emissiveIntensity =
      station.state === "active" || station.state === "saturated"
        ? 0.6
        : station.state === "errored"
        ? 0.8
        : 0.3;

    clone.traverse((child) => {
      if ((child as Mesh).isMesh) {
        const mesh = child as Mesh;
        const mat = new MeshStandardMaterial({
          color: new Color(color).multiplyScalar(0.6),
          emissive: new Color(
            station.state === "errored" ? "#ff0000" : color
          ),
          emissiveIntensity: isSelected ? 1.2 : hovered ? 0.9 : emissiveIntensity,
          metalness: 0.8,
          roughness: 0.2,
          transparent: isFiltered,
          opacity: isFiltered ? 0.1 : 1,
        });
        mesh.material = mat;
      }
    });
    return clone;
  }, [scene, color, station.state, isSelected, hovered, isFiltered]);

  const ringRef = useRef<any>(null);

  useFrame((state, delta) => {
    if (!groupRef.current) return;

    // Dispatcher spins continuously
    if (station.type === "dispatcher") {
      groupRef.current.rotation.y += delta * 0.3;
    }

    // Active stations bob gently
    if (station.state === "active" || station.state === "saturated") {
      groupRef.current.position.y = Math.sin(state.clock.elapsedTime * 1.5) * 0.05;
    }

    // Errored stations twitch
    if (station.state === "errored") {
      groupRef.current.position.x = Math.sin(state.clock.elapsedTime * 12) * 0.02;
    }

    // Pulse the glow ring
    if (ringRef.current) {
      const pulse = 0.4 + Math.sin(state.clock.elapsedTime * 2 + position.x) * 0.2;
      (ringRef.current.material as any).emissiveIntensity =
        isSelected ? 1.5 : hovered ? 1.0 : pulse;
      ringRef.current.rotation.z = state.clock.elapsedTime * 0.2;
    }
  });

  return (
    <group position={[position.x, position.y, position.z]}>
      <group
        ref={groupRef}
        scale={[scale, scale, scale]}
        onClick={() => selectEntity({ id: station.id, type: "station" })}
        onPointerEnter={() => setHovered(true)}
        onPointerLeave={() => setHovered(false)}
      >
        <primitive object={clonedScene} />
      </group>

      {/* Glow ring under station */}
      <mesh ref={ringRef} rotation={[-Math.PI / 2, 0, 0]} position={[0, 0.05, 0]}>
        <ringGeometry args={[1.2, 1.6, 32]} />
        <meshStandardMaterial
          color={color}
          emissive={color}
          emissiveIntensity={isSelected ? 1.5 : hovered ? 1.0 : 0.4}
          transparent
          opacity={isFiltered ? 0.05 : 0.6}
          side={2}
        />
      </mesh>

      {/* Label */}
      <Html position={[0, 3.5, 0]} center distanceFactor={15}>
        <div
          style={{
            color: hovered || isSelected ? "#ffffff" : color,
            fontSize: "11px",
            fontWeight: 600,
            textAlign: "center",
            whiteSpace: "nowrap",
            textShadow: `0 0 8px ${color}80, 0 0 4px rgba(0,0,0,0.9)`,
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
