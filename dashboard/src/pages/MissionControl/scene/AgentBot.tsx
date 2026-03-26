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

useGLTF.preload("/models/agent-bot.glb");

interface AgentBotProps {
  agent: MCAgent;
  targetPosition: Vec3;
}

export function AgentBot({ agent, targetPosition }: AgentBotProps) {
  const groupRef = useRef<any>(null);
  const [hovered, setHovered] = useState(false);
  const selectEntity = useUIStore((s) => s.selectEntity);
  const selectedEntity = useUIStore((s) => s.selectedEntity);
  const isSelected =
    selectedEntity?.id === agent.id && selectedEntity?.type === "agent";
  const isFiltered = useUIStore((s) => s.isFiltered("agent", agent.state));

  const posRef = useAnimatedPosition(targetPosition);
  const color = STATE_COLORS[agent.state] ?? "#3498db";

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
  });

  return (
    <group>
      <group
        ref={groupRef}
        scale={[1.5, 1.5, 1.5]}
        onClick={() => selectEntity({ id: agent.id, type: "agent" })}
        onPointerEnter={() => setHovered(true)}
        onPointerLeave={() => setHovered(false)}
      >
        <primitive object={clonedScene} />
        <pointLight
          color={color}
          intensity={isSelected ? 2 : 0.5}
          distance={3}
        />
      </group>

      {(hovered || isSelected) && (
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
              color: "#ffffff",
              fontSize: "10px",
              fontWeight: 600,
              textShadow: `0 0 8px ${color}80, 0 0 4px rgba(0,0,0,0.9)`,
              whiteSpace: "nowrap",
              pointerEvents: "none",
            }}
          >
            {agent.name ?? agent.id}
          </div>
        </Html>
      )}
    </group>
  );
}
