import { useRef, useState, useMemo } from "react";
import { useFrame } from "@react-three/fiber";
import { Html, useGLTF } from "@react-three/drei";
import { Mesh, MeshStandardMaterial, Color } from "three";
import type { MCAgent, Vec3 } from "../types";
import { useUIStore } from "../stores/uiStore";
import { useAnimatedPosition } from "../hooks/useAnimatedPosition";

const STATE_COLORS: Record<string, string> = {
  idle: "#3498db",
  claiming_job: "#2ecc71",
  working: "#9b59b6",
  blocked: "#f39c12",
  errored: "#e74c3c",
  offline: "#555555",
  moving_to_pickup: "#2ecc71",
  moving_to_station: "#3498db",
  handoff: "#e67e22",
};

function nameToColor(name: string): string {
  const PALETTE = ["#e74c3c", "#3498db", "#2ecc71", "#9b59b6", "#e67e22", "#f1c40f", "#1abc9c", "#e91e63"];
  let hash = 0;
  for (let i = 0; i < name.length; i++) hash = ((hash << 5) - hash + name.charCodeAt(i)) | 0;
  return PALETTE[Math.abs(hash) % PALETTE.length];
}

function roleToScale(role: string | undefined): number {
  if (!role) return 1.5;
  const r = role.toLowerCase();
  if (r.includes("supervisor") || r.includes("coordinator")) return 2.0;
  if (r.includes("router") || r.includes("dispatcher")) return 1.8;
  return 1.5;
}

useGLTF.preload("/models/agent-bot.glb");

interface AgentBotProps {
  agent: MCAgent;
  targetPosition: Vec3;
}

export function AgentBot({ agent, targetPosition }: AgentBotProps) {
  const groupRef = useRef<any>(null);
  const ringRef = useRef<Mesh>(null);
  const [hovered, setHovered] = useState(false);
  const selectEntity = useUIStore((s) => s.selectEntity);
  const selectedEntity = useUIStore((s) => s.selectedEntity);
  const isSelected =
    selectedEntity?.id === agent.id && selectedEntity?.type === "agent";
  const isFiltered = useUIStore((s) => s.isFiltered("agent", agent.state));

  const posRef = useAnimatedPosition(targetPosition);
  const color = STATE_COLORS[agent.state] ?? "#3498db";

  const agentName = agent.name ?? agent.id;
  const accentColor = nameToColor(agentName);
  const scale = roleToScale(agent.role);

  const { scene } = useGLTF("/models/agent-bot.glb");

  const clonedScene = useMemo(() => {
    const clone = scene.clone(true);
    clone.traverse((child) => {
      if ((child as Mesh).isMesh) {
        const mesh = child as Mesh;
        mesh.material = new MeshStandardMaterial({
          color: new Color(color).multiplyScalar(0.5),
          emissive: new Color(color),
          emissiveIntensity: isSelected ? 1.2 : hovered ? 0.8 : 0.4,
          metalness: 0.7,
          roughness: 0.3,
          transparent: isFiltered,
          opacity: isFiltered ? 0.1 : 1,
        });
      }
    });
    return clone;
  }, [scene, color, isSelected, hovered, isFiltered]);

  useFrame((state) => {
    if (!groupRef.current || !posRef.current) return;
    groupRef.current.position.copy(posRef.current);

    if (agent.state === "idle") {
      groupRef.current.position.y +=
        Math.sin(state.clock.elapsedTime * 2) * 0.1;
    }
    if (agent.state === "errored") {
      groupRef.current.position.x +=
        Math.sin(state.clock.elapsedTime * 15) * 0.03;
    }

    // Rotate helmet ring
    if (ringRef.current) {
      ringRef.current.rotation.y = state.clock.elapsedTime * 1.0;
    }
  });

  const showFull = hovered || isSelected;

  return (
    <group>
      <group
        ref={groupRef}
        scale={[scale, scale, scale]}
        onClick={() => selectEntity({ id: agent.id, type: "agent" })}
        onPointerEnter={() => setHovered(true)}
        onPointerLeave={() => setHovered(false)}
      >
        <primitive object={clonedScene} />

        {/* Helmet accent ring */}
        <mesh ref={ringRef} position={[0, 0.6, 0]} rotation={[Math.PI / 2, 0, 0]}>
          <torusGeometry args={[0.25, 0.04, 8, 16]} />
          <meshStandardMaterial
            color={accentColor}
            emissive={accentColor}
            emissiveIntensity={0.8}
            transparent={isFiltered}
            opacity={isFiltered ? 0.1 : 1}
          />
        </mesh>

        <pointLight
          color={color}
          intensity={isSelected ? 2 : 0.5}
          distance={3}
        />
      </group>

      {/* Persistent name tag — always visible, brighter on hover/select */}
      <Html
        position={[
          targetPosition.x,
          targetPosition.y + 2,
          targetPosition.z,
        ]}
        center
        distanceFactor={15}
      >
        <div
          style={{
            color: showFull ? "#ffffff" : accentColor,
            fontSize: showFull ? "10px" : "8px",
            fontWeight: 600,
            opacity: showFull ? 1.0 : 0.5,
            textShadow: showFull
              ? `0 0 8px ${color}80, 0 0 4px rgba(0,0,0,0.9)`
              : `0 0 4px rgba(0,0,0,0.8)`,
            whiteSpace: "nowrap",
            pointerEvents: "none",
            textAlign: "center",
            transition: "all 0.2s ease",
          }}
        >
          <div>{agentName}</div>
          {agent.role && (
            <div
              style={{
                fontSize: showFull ? "7px" : "6px",
                fontWeight: 400,
                opacity: showFull ? 0.8 : 0.4,
              }}
            >
              {agent.role}
            </div>
          )}
        </div>
      </Html>
    </group>
  );
}
