// dashboard/src/pages/MissionControl/scene/JobLayer.tsx
import { useRef, useMemo } from "react";
import { useFrame } from "@react-three/fiber";
import { InstancedMesh, Object3D, Color } from "three";
import { useEntityStore } from "../stores/entityStore";
import { useSceneStore } from "../stores/sceneStore";
import { useUIStore } from "../stores/uiStore";

const PRIORITY_COLORS: Record<string, string> = {
  low: "#2ecc71",
  normal: "#3498db",
  high: "#e67e22",
  critical: "#e74c3c",
};

const MAX_JOBS = 500;
const dummy = new Object3D();
const color = new Color();

export function JobLayer() {
  const meshRef = useRef<InstancedMesh>(null);
  const jobs = useEntityStore((s) => s.jobs);
  const getJobPosition = useSceneStore((s) => s.getJobPosition);
  const filters = useUIStore((s) => s.filters);

  const jobList = useMemo(() => Object.values(jobs), [jobs]);

  useFrame((state) => {
    if (!meshRef.current) return;
    const time = state.clock.elapsedTime;

    let idx = 0;
    for (const job of jobList) {
      if (idx >= MAX_JOBS) break;

      const pos = getJobPosition(job.currentStationId, job.state);
      const isFiltered =
        filters.jobStates.size > 0 && !filters.jobStates.has(job.state);

      // Spread queued jobs slightly
      const spread = job.state === "queued" ? idx * 0.15 : 0;

      dummy.position.set(pos.x + spread, pos.y + Math.sin(time * 2 + idx) * 0.05, pos.z);

      // Pulse scale for higher priority
      const pulseScale = job.priority === "critical" ? 1.3 + Math.sin(time * 4) * 0.2
        : job.priority === "high" ? 1.1 + Math.sin(time * 3) * 0.1
        : 1.0;
      dummy.scale.setScalar(isFiltered ? 0.1 : pulseScale * 0.15);
      dummy.updateMatrix();
      meshRef.current.setMatrixAt(idx, dummy.matrix);

      color.set(PRIORITY_COLORS[job.priority] ?? "#3498db");
      meshRef.current.setColorAt(idx, color);

      idx++;
    }

    // Hide unused instances
    for (let i = idx; i < MAX_JOBS; i++) {
      dummy.position.set(0, -100, 0);
      dummy.scale.setScalar(0);
      dummy.updateMatrix();
      meshRef.current.setMatrixAt(i, dummy.matrix);
    }

    meshRef.current.instanceMatrix.needsUpdate = true;
    if (meshRef.current.instanceColor) {
      meshRef.current.instanceColor.needsUpdate = true;
    }
  });

  return (
    <instancedMesh ref={meshRef} args={[undefined, undefined, MAX_JOBS]}>
      <boxGeometry args={[1, 1, 1]} />
      <meshStandardMaterial
        emissive="#3498db"
        emissiveIntensity={0.8}
        metalness={0.5}
        roughness={0.3}
        toneMapped={false}
      />
    </instancedMesh>
  );
}
