import { useRef, useState, useMemo, useCallback } from "react";
import { useFrame, useLoader } from "@react-three/fiber";
import { Html } from "@react-three/drei";
import { Mesh, MeshStandardMaterial, TextureLoader, Color, DoubleSide } from "three";
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
  const cubeRefs = useRef<(Mesh | null)[]>([]);
  const setRef = useCallback(
    (index: number) => (el: Mesh | null) => { cubeRefs.current[index] = el; },
    [],
  );

  useFrame((state) => {
    const t = state.clock.elapsedTime;
    for (let i = 0; i < count; i++) {
      const mesh = cubeRefs.current[i];
      if (!mesh) continue;
      mesh.position.y = 0.15 + Math.sin(t * 2 + i * 0.5) * 0.05;
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
      {Array.from({ length: count }, (_, i) => (
        <mesh key={i} ref={setRef(i)} position={[0, 0.15, -(i * 0.35 + 1.8)]}>
          <boxGeometry args={[0.2, 0.2, 0.2]} />
          <meshStandardMaterial color={color} emissive={color} emissiveIntensity={0.6} transparent opacity={0.7} />
        </mesh>
      ))}
    </>
  );
}

/* ------------------------------------------------------------------ */
/*  Station config                                                     */
/* ------------------------------------------------------------------ */

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

const STATION_TEXTURES: Record<string, string> = {
  intake: "/textures/station-intake.png",
  dispatcher: "/textures/station-dispatcher.png",
  llm: "/textures/station-llm.png",
  tool: "/textures/station-tool.png",
  code: "/textures/station-code.png",
  supervisor: "/textures/station-supervisor.png",
  error: "/textures/station-error.png",
  output: "/textures/station-output.png",
};

/* ------------------------------------------------------------------ */
/*  StationBillboard – floating textured panel                         */
/* ------------------------------------------------------------------ */

function StationBillboard({
  textureUrl,
  color,
  isSelected,
  hovered,
  isFiltered,
}: {
  textureUrl: string;
  color: string;
  isSelected: boolean;
  hovered: boolean;
  isFiltered: boolean;
}) {
  const texture = useLoader(TextureLoader, textureUrl);
  const meshRef = useRef<Mesh>(null);

  useFrame((state) => {
    if (!meshRef.current) return;
    // Gentle hover float
    meshRef.current.position.y = 2.0 + Math.sin(state.clock.elapsedTime * 0.8) * 0.1;
  });

  const emissiveIntensity = isSelected ? 1.5 : hovered ? 1.0 : 0.5;

  return (
    <mesh ref={meshRef} position={[0, 2.0, 0]}>
      <planeGeometry args={[3, 3]} />
      <meshStandardMaterial
        map={texture}
        emissive={new Color(color)}
        emissiveIntensity={emissiveIntensity}
        transparent
        opacity={isFiltered ? 0.1 : 0.95}
        side={DoubleSide}
        toneMapped={false}
      />
    </mesh>
  );
}

/* ------------------------------------------------------------------ */
/*  StationMesh                                                        */
/* ------------------------------------------------------------------ */

interface StationMeshProps {
  station: MCStation;
  position: Vec3;
}

export function StationMesh({ station, position }: StationMeshProps) {
  const groupRef = useRef<any>(null);
  const ringRef = useRef<any>(null);
  const baseRef = useRef<Mesh>(null);
  const [hovered, setHovered] = useState(false);
  const selectEntity = useUIStore((s) => s.selectEntity);
  const selectedEntity = useUIStore((s) => s.selectedEntity);
  const isSelected =
    selectedEntity?.id === station.id && selectedEntity?.type === "station";
  const isFiltered = useUIStore((s) => s.isFiltered("station", station.state));

  const color = STATION_COLORS[station.type] ?? "#888888";
  const textureUrl = STATION_TEXTURES[station.type] ?? STATION_TEXTURES.code;

  useFrame((state, delta) => {
    if (!groupRef.current) return;

    // Dispatcher spins continuously
    if (station.type === "dispatcher") {
      groupRef.current.rotation.y += delta * 0.3;
    }

    // Active stations bob
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

    // Pulse base platform
    if (baseRef.current) {
      const basePulse = 0.3 + Math.sin(state.clock.elapsedTime * 1.5 + position.z) * 0.15;
      (baseRef.current.material as any).emissiveIntensity =
        isSelected ? 0.8 : basePulse;
    }
  });

  return (
    <group position={[position.x, position.y, position.z]}>
      {/* Clickable base platform */}
      <mesh
        ref={baseRef}
        position={[0, 0.15, 0]}
        onClick={() => selectEntity({ id: station.id, type: "station" })}
        onPointerEnter={() => setHovered(true)}
        onPointerLeave={() => setHovered(false)}
      >
        <cylinderGeometry args={[1.8, 2.0, 0.3, 6]} />
        <meshStandardMaterial
          color={new Color(color).multiplyScalar(0.3)}
          emissive={new Color(color)}
          emissiveIntensity={0.3}
          metalness={0.8}
          roughness={0.3}
          transparent={isFiltered}
          opacity={isFiltered ? 0.1 : 0.9}
        />
      </mesh>

      {/* Billboard with generated texture */}
      <group ref={groupRef}>
        <StationBillboard
          textureUrl={textureUrl}
          color={color}
          isSelected={isSelected}
          hovered={hovered}
          isFiltered={isFiltered}
        />
      </group>

      {/* Glow ring under station */}
      <mesh ref={ringRef} rotation={[-Math.PI / 2, 0, 0]} position={[0, 0.05, 0]}>
        <ringGeometry args={[1.8, 2.3, 32]} />
        <meshStandardMaterial
          color={color}
          emissive={color}
          emissiveIntensity={isSelected ? 1.5 : hovered ? 1.0 : 0.4}
          transparent
          opacity={isFiltered ? 0.05 : 0.6}
          side={DoubleSide}
        />
      </mesh>

      {/* Label */}
      <Html position={[0, 4.2, 0]} center distanceFactor={15}>
        <div
          style={{
            color: hovered || isSelected ? "#ffffff" : color,
            fontSize: "12px",
            fontWeight: 700,
            textAlign: "center",
            whiteSpace: "nowrap",
            textShadow: `0 0 10px ${color}, 0 0 4px rgba(0,0,0,0.9)`,
            pointerEvents: "none",
            userSelect: "none",
            letterSpacing: "1px",
            textTransform: "uppercase",
          }}
        >
          {station.label}
        </div>
      </Html>

      {/* Holographic stats panel */}
      {!isFiltered && (
        <Html position={[0, 5.0, 0]} center distanceFactor={15}>
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
            <div style={{ display: "flex", alignItems: "center", gap: "4px", marginBottom: "4px" }}>
              <span
                style={{
                  display: "inline-block", width: "6px", height: "6px", borderRadius: "50%",
                  background: station.state === "active" ? "#2ecc71" : station.state === "saturated" ? "#f1c40f" : station.state === "errored" ? "#e74c3c" : "#888888",
                  boxShadow: station.state === "active" ? "0 0 4px #2ecc71" : station.state === "saturated" ? "0 0 4px #f1c40f" : station.state === "errored" ? "0 0 4px #e74c3c" : "none",
                }}
              />
              <span style={{ textTransform: "uppercase", letterSpacing: "0.5px" }}>{station.state}</span>
            </div>
            <div style={{ marginBottom: "3px" }}>
              <div style={{ display: "flex", justifyContent: "space-between", marginBottom: "2px" }}>
                <span>queue</span><span>{station.queueDepth}</span>
              </div>
              <div style={{ height: "3px", borderRadius: "1.5px", background: "rgba(255,255,255,0.06)", overflow: "hidden" }}>
                <div style={{ height: "100%", width: `${Math.min((station.queueDepth / Math.max(station.capacity, 1)) * 100, 100)}%`, background: `linear-gradient(90deg, ${color}, transparent)`, borderRadius: "1.5px" }} />
              </div>
            </div>
            <div style={{ display: "flex", justifyContent: "space-between" }}>
              <span>jobs</span><span>{station.activeJobIds.length}</span>
            </div>
          </div>
        </Html>
      )}

      {!isFiltered && station.queueDepth > 0 && (
        <QueueLine queueDepth={station.queueDepth} color={color} />
      )}
    </group>
  );
}
