import { useRef, useState, useMemo, useCallback } from "react";
import { useFrame } from "@react-three/fiber";
import { Html, useGLTF } from "@react-three/drei";
import { Mesh, MeshStandardMaterial, Color } from "three";
import type { MCStation, Vec3 } from "../types";
import { useUIStore } from "../stores/uiStore";

/* ------------------------------------------------------------------ */
/*  QueueLine – small glowing cubes lined up behind a busy station    */
/* ------------------------------------------------------------------ */

interface QueueLineProps {
  queueDepth: number;
  color: string;
}

function QueueLine({ queueDepth, color }: QueueLineProps) {
  const count = Math.min(queueDepth, 8);
  const hasOverflow = queueDepth > 8;

  // One ref per cube (max 8)
  const cubeRefs = useRef<(Mesh | null)[]>([]);
  const setRef = useCallback(
    (index: number) => (el: Mesh | null) => {
      cubeRefs.current[index] = el;
    },
    [],
  );

  useFrame((state) => {
    const t = state.clock.elapsedTime;
    for (let i = 0; i < count; i++) {
      const mesh = cubeRefs.current[i];
      if (!mesh) continue;
      // gentle bob with phase offset per cube
      mesh.position.y = 0.15 + Math.sin(t * 2 + i * 0.5) * 0.05;

      // overflow indicator: last cube pulses more intensely
      if (hasOverflow && i === count - 1) {
        const pulse = 0.8 + Math.sin(t * 4) * 0.4;
        (mesh.material as MeshStandardMaterial).emissiveIntensity = pulse;
        const s = 1 + Math.sin(t * 4) * 0.15;
        mesh.scale.set(s, s, s);
      }
    }
  });

  if (count === 0) return null;

  return (
    <>
      {Array.from({ length: count }, (_, i) => {
        const isOverflow = hasOverflow && i === count - 1;
        const cubeSize = isOverflow ? 0.25 : 0.2;
        return (
          <mesh
            key={i}
            ref={setRef(i)}
            position={[0, 0.15, -(i * 0.35 + 1.8)]}
          >
            <boxGeometry args={[cubeSize, cubeSize, cubeSize]} />
            <meshStandardMaterial
              color={color}
              emissive={color}
              emissiveIntensity={0.6}
              transparent
              opacity={0.7}
            />
          </mesh>
        );
      })}
    </>
  );
}

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

      {/* Holographic stats panel */}
      {!isFiltered && (
        <Html position={[0, 4.5, 0]} center distanceFactor={15}>
          <div
            style={{
              background: "rgba(10, 14, 26, 0.85)",
              backdropFilter: "blur(4px)",
              border: `1px solid ${color}4D`,
              borderRadius: "6px",
              padding: "6px 10px",
              fontFamily: "monospace",
              fontSize: "9px",
              color: `${color}CC`,
              boxShadow: `0 0 12px ${color}26`,
              width: "100px",
              pointerEvents: "none",
              userSelect: "none",
            }}
          >
            {/* State badge */}
            <div style={{ display: "flex", alignItems: "center", gap: "4px", marginBottom: "4px" }}>
              <span
                style={{
                  display: "inline-block",
                  width: "6px",
                  height: "6px",
                  borderRadius: "50%",
                  background:
                    station.state === "active"
                      ? "#2ecc71"
                      : station.state === "saturated"
                      ? "#f1c40f"
                      : station.state === "errored"
                      ? "#e74c3c"
                      : "#888888",
                  boxShadow:
                    station.state === "active"
                      ? "0 0 4px #2ecc71"
                      : station.state === "saturated"
                      ? "0 0 4px #f1c40f"
                      : station.state === "errored"
                      ? "0 0 4px #e74c3c"
                      : "none",
                }}
              />
              <span style={{ textTransform: "uppercase", letterSpacing: "0.5px" }}>
                {station.state}
              </span>
            </div>

            {/* Queue depth bar */}
            <div style={{ marginBottom: "3px" }}>
              <div
                style={{
                  display: "flex",
                  justifyContent: "space-between",
                  marginBottom: "2px",
                }}
              >
                <span>queue</span>
                <span>{station.queueDepth}</span>
              </div>
              <div
                style={{
                  height: "3px",
                  borderRadius: "1.5px",
                  background: "rgba(255,255,255,0.06)",
                  overflow: "hidden",
                }}
              >
                <div
                  style={{
                    height: "100%",
                    width: `${Math.min((station.queueDepth / Math.max(station.capacity, 1)) * 100, 100)}%`,
                    background: `linear-gradient(90deg, ${color}, transparent)`,
                    borderRadius: "1.5px",
                  }}
                />
              </div>
            </div>

            {/* Active jobs */}
            <div style={{ display: "flex", justifyContent: "space-between" }}>
              <span>jobs</span>
              <span>{station.activeJobIds.length}</span>
            </div>
          </div>
        </Html>
      )}

      {/* Queue line – visible cubes behind station when jobs are waiting */}
      {!isFiltered && station.queueDepth > 0 && (
        <QueueLine queueDepth={station.queueDepth} color={color} />
      )}
    </group>
  );
}
