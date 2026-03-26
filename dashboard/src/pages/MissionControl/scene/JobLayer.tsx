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
const MAX_TRAILS = 200;
const TRAIL_SEGMENTS = 4;
const MAX_TRAIL_JOBS = 50; // 50 jobs * 4 segments = 200
const HISTORY_LENGTH = 6;
const dummy = new Object3D();
const color = new Color();

interface PosEntry {
  x: number;
  y: number;
  z: number;
}

interface JobTrailHistory {
  /** Ring buffer of positions, newest at index (writeIdx - 1 + len) % len */
  positions: PosEntry[];
  writeIdx: number;
  count: number;
  /** Frame number when last moved */
  lastMovedFrame: number;
}

export function JobLayer() {
  const meshRef = useRef<InstancedMesh>(null);
  const trailRef = useRef<InstancedMesh>(null);
  const jobs = useEntityStore((s) => s.jobs);
  const getJobPosition = useSceneStore((s) => s.getJobPosition);
  const filters = useUIStore((s) => s.filters);

  const jobList = useMemo(() => Object.values(jobs), [jobs]);

  // Persistent trail history keyed by job ID
  const trailHistoryRef = useRef<Map<string, JobTrailHistory>>(new Map());
  const frameCountRef = useRef(0);

  useFrame((state) => {
    if (!meshRef.current) return;
    const time = state.clock.elapsedTime;
    const frame = frameCountRef.current++;
    const trailHistory = trailHistoryRef.current;

    let idx = 0;
    for (const job of jobList) {
      if (idx >= MAX_JOBS) break;

      const pos = getJobPosition(job.currentStationId, job.state);
      const isFiltered =
        filters.jobStates.size > 0 && !filters.jobStates.has(job.state);

      // Spread queued jobs slightly
      const spread = job.state === "queued" ? idx * 0.15 : 0;

      const jx = pos.x + spread;
      const jy = pos.y + Math.sin(time * 2 + idx) * 0.05;
      const jz = pos.z;

      dummy.position.set(jx, jy, jz);

      // Pulse scale for higher priority
      const pulseScale = job.priority === "critical" ? 1.3 + Math.sin(time * 4) * 0.2
        : job.priority === "high" ? 1.1 + Math.sin(time * 3) * 0.1
        : 1.0;
      dummy.scale.setScalar(isFiltered ? 0.1 : pulseScale * 0.15);
      dummy.updateMatrix();
      meshRef.current.setMatrixAt(idx, dummy.matrix);

      color.set(PRIORITY_COLORS[job.priority] ?? "#3498db");
      meshRef.current.setColorAt(idx, color);

      // --- Update trail history ---
      if (!isFiltered) {
        let hist = trailHistory.get(job.id);
        if (!hist) {
          hist = {
            positions: Array.from({ length: HISTORY_LENGTH }, () => ({ x: jx, y: jy, z: jz })),
            writeIdx: 1,
            count: 1,
            lastMovedFrame: frame,
          };
          trailHistory.set(job.id, hist);
        } else {
          // Check if position actually changed (beyond float noise)
          const prevIdx = (hist.writeIdx - 1 + HISTORY_LENGTH) % HISTORY_LENGTH;
          const prev = hist.positions[prevIdx];
          const dx = jx - prev.x;
          const dy = jy - prev.y;
          const dz = jz - prev.z;
          const distSq = dx * dx + dy * dy + dz * dz;
          // Only record a new trail point if moved significantly (> 0.01 units)
          if (distSq > 0.0001) {
            hist.positions[hist.writeIdx] = { x: jx, y: jy, z: jz };
            hist.writeIdx = (hist.writeIdx + 1) % HISTORY_LENGTH;
            hist.count = Math.min(hist.count + 1, HISTORY_LENGTH);
            hist.lastMovedFrame = frame;
          }
        }
      }

      idx++;
    }

    // Hide unused job instances
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

    // --- Render trail particles ---
    if (!trailRef.current) return;

    // Collect jobs that have moved recently, sorted by recency
    const movedJobs: { jobId: string; hist: JobTrailHistory; priority: string }[] = [];
    for (const job of jobList) {
      const hist = trailHistory.get(job.id);
      if (hist && hist.count >= 2) {
        movedJobs.push({ jobId: job.id, hist, priority: job.priority });
      }
    }
    // Sort by most recently moved first
    movedJobs.sort((a, b) => b.hist.lastMovedFrame - a.hist.lastMovedFrame);

    let trailIdx = 0;
    const topMovers = movedJobs.slice(0, MAX_TRAIL_JOBS);

    for (const { hist, priority } of topMovers) {
      // Walk backwards from the most recent position in the ring buffer
      // Skip index 0 (that's the current position, already shown by main mesh)
      // Render up to TRAIL_SEGMENTS older positions
      const newestIdx = (hist.writeIdx - 1 + HISTORY_LENGTH) % HISTORY_LENGTH;
      const available = Math.min(hist.count - 1, TRAIL_SEGMENTS);

      for (let seg = 0; seg < available; seg++) {
        if (trailIdx >= MAX_TRAILS) break;

        const ringIdx = (newestIdx - 1 - seg + HISTORY_LENGTH) % HISTORY_LENGTH;
        const p = hist.positions[ringIdx];

        // Age factor: 0 = newest trail, 1 = oldest trail
        const ageFactor = (seg + 1) / (TRAIL_SEGMENTS + 1);
        const scale = 0.12 * (1.0 - ageFactor * 0.7); // shrinks with age

        dummy.position.set(p.x, p.y, p.z);
        dummy.scale.setScalar(scale);
        dummy.updateMatrix();
        trailRef.current.setMatrixAt(trailIdx, dummy.matrix);

        color.set(PRIORITY_COLORS[priority] ?? "#3498db");
        trailRef.current.setColorAt(trailIdx, color);

        trailIdx++;
      }
      if (trailIdx >= MAX_TRAILS) break;
    }

    // Hide unused trail instances
    for (let i = trailIdx; i < MAX_TRAILS; i++) {
      dummy.position.set(0, -100, 0);
      dummy.scale.setScalar(0);
      dummy.updateMatrix();
      trailRef.current.setMatrixAt(i, dummy.matrix);
    }

    trailRef.current.instanceMatrix.needsUpdate = true;
    if (trailRef.current.instanceColor) {
      trailRef.current.instanceColor.needsUpdate = true;
    }
  });

  return (
    <>
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

      <instancedMesh ref={trailRef} args={[undefined, undefined, MAX_TRAILS]}>
        <sphereGeometry args={[1, 4, 4]} />
        <meshStandardMaterial
          emissive="#3498db"
          emissiveIntensity={0.4}
          transparent
          opacity={0.4}
          metalness={0.5}
          roughness={0.3}
          toneMapped={false}
        />
      </instancedMesh>
    </>
  );
}
