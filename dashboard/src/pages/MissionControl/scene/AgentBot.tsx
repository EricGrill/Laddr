// dashboard/src/pages/MissionControl/scene/AgentBot.tsx
import { useRef, useState } from "react";
import { useFrame } from "@react-three/fiber";
import { Html } from "@react-three/drei";
import type { Mesh } from "three";
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

interface AgentBotProps {
  agent: MCAgent;
  targetPosition: Vec3;
}

export function AgentBot({ agent, targetPosition }: AgentBotProps) {
  const meshRef = useRef<Mesh>(null);
  const [hovered, setHovered] = useState(false);
  const selectEntity = useUIStore((s) => s.selectEntity);
  const selectedEntity = useUIStore((s) => s.selectedEntity);
  const isSelected = selectedEntity?.id === agent.id && selectedEntity?.type === "agent";
  const isFiltered = useUIStore((s) => s.isFiltered("agent", agent.state));

  const posRef = useAnimatedPosition(targetPosition);
  const color = STATE_COLORS[agent.state] ?? "#3498db";

  // Bob animation for idle
  useFrame((state) => {
    if (!meshRef.current || !posRef.current) return;
    meshRef.current.position.copy(posRef.current);

    if (agent.state === "idle") {
      meshRef.current.position.y += Math.sin(state.clock.elapsedTime * 2) * 0.1;
    }
    if (agent.state === "errored") {
      meshRef.current.position.x += Math.sin(state.clock.elapsedTime * 15) * 0.03;
    }
  });

  return (
    <group>
      <mesh
        ref={meshRef}
        onClick={() => selectEntity({ id: agent.id, type: "agent" })}
        onPointerEnter={() => setHovered(true)}
        onPointerLeave={() => setHovered(false)}
      >
        {/* Bot body - capsule shape */}
        <capsuleGeometry args={[0.25, 0.5, 4, 8]} />
        <meshStandardMaterial
          color={color}
          emissive={color}
          emissiveIntensity={isSelected ? 1.2 : hovered ? 0.8 : 0.4}
          metalness={0.6}
          roughness={0.3}
          transparent={isFiltered}
          opacity={isFiltered ? 0.1 : 1}
        />
      </mesh>

      {/* Name label on hover/select */}
      {(hovered || isSelected) && (
        <Html position={[targetPosition.x, targetPosition.y + 1.2, targetPosition.z]} center distanceFactor={15}>
          <div style={{
            color: "#ffffff",
            fontSize: "10px",
            fontWeight: 600,
            textShadow: "0 0 6px rgba(0,0,0,0.8)",
            whiteSpace: "nowrap",
            pointerEvents: "none",
          }}>
            {agent.name ?? agent.id}
          </div>
        </Html>
      )}
    </group>
  );
}
