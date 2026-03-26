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

const PRIORITY_SCALE: Record<string, { base: number; pulse: number }> = {
  critical: { base: 0.25, pulse: 0.08 },
  high: { base: 0.20, pulse: 0.05 },
  normal: { base: 0.15, pulse: 0.02 },
  low: { base: 0.10, pulse: 0.01 },
};

const DEFAULT_SCALE = PRIORITY_SCALE.normal;

const LLM_PATTERNS = ["llm", "chat", "completion", "prompt"];
const TOOL_PATTERNS = ["tool", "mcp", "skill"];

function classifyJob(jobType: string | undefined): "llm" | "tool" | "other" {
  const t = (jobType ?? "").toLowerCase();
  if (LLM_PATTERNS.some((p) => t.includes(p))) return "llm";
  if (TOOL_PATTERNS.some((p) => t.includes(p))) return "tool";
  return "other";
}

const MAX_PER_SHAPE = 200;
const MAX_TRAILS = 200;
const TRAIL_SEGMENTS = 4;
const MAX_TRAIL_JOBS = 50;
const HISTORY_LENGTH = 6;
const dummy = new Object3D();
const color = new Color();

interface PosEntry {
  x: number;
  y: number;
  z: number;
}

interface JobTrailHistory {
  positions: PosEntry[];
  writeIdx: number;
  count: number;
  lastMovedFrame: number;
}

function hideUnused(mesh: InstancedMesh, startIdx: number, max: number) {
  for (let i = startIdx; i < max; i++) {
    dummy.position.set(0, -100, 0);
    dummy.scale.setScalar(0);
    dummy.updateMatrix();
    mesh.setMatrixAt(i, dummy.matrix);
  }
}

export function JobLayer() {
  const llmRef = useRef<InstancedMesh>(null);
  const toolRef = useRef<InstancedMesh>(null);
  const otherRef = useRef<InstancedMesh>(null);
  const trailRef = useRef<InstancedMesh>(null);
  const jobs = useEntityStore((s) => s.jobs);
  const getJobPosition = useSceneStore((s) => s.getJobPosition);
  const filters = useUIStore((s) => s.filters);

  const jobList = useMemo(() => Object.values(jobs), [jobs]);

  const trailHistoryRef = useRef<Map<string, JobTrailHistory>>(new Map());
  const frameCountRef = useRef(0);

  useFrame((state) => {
    const llmMesh = llmRef.current;
    const toolMesh = toolRef.current;
    const otherMesh = otherRef.current;
    if (!llmMesh || !toolMesh || !otherMesh) return;

    const time = state.clock.elapsedTime;
    const frame = frameCountRef.current++;
    const trailHistory = trailHistoryRef.current;

    let llmIdx = 0;
    let toolIdx = 0;
    let otherIdx = 0;

    for (let jobI = 0; jobI < jobList.length; jobI++) {
      const job = jobList[jobI];
      const category = classifyJob(job.type);

      let mesh: InstancedMesh;
      let idx: number;
      if (category === "llm") {
        if (llmIdx >= MAX_PER_SHAPE) continue;
        mesh = llmMesh;
        idx = llmIdx++;
      } else if (category === "tool") {
        if (toolIdx >= MAX_PER_SHAPE) continue;
        mesh = toolMesh;
        idx = toolIdx++;
      } else {
        if (otherIdx >= MAX_PER_SHAPE) continue;
        mesh = otherMesh;
        idx = otherIdx++;
      }

      const pos = getJobPosition(job.currentStationId, job.state);
      const isFiltered =
        filters.jobStates.size > 0 && !filters.jobStates.has(job.state);

      const spread = job.state === "queued" ? jobI * 0.15 : 0;

      const jx = pos.x + spread;
      const jy = pos.y + Math.sin(time * 2 + jobI) * 0.05;
      const jz = pos.z;

      dummy.position.set(jx, jy, jz);

      const ps = PRIORITY_SCALE[job.priority] ?? DEFAULT_SCALE;
      const pulseScale = ps.base + Math.sin(time * 3) * ps.pulse;
      dummy.scale.setScalar(isFiltered ? 0.05 : pulseScale);
      dummy.updateMatrix();
      mesh.setMatrixAt(idx, dummy.matrix);

      color.set(PRIORITY_COLORS[job.priority] ?? "#3498db");
      mesh.setColorAt(idx, color);

      // --- Update trail history ---
      if (!isFiltered) {
        let hist = trailHistory.get(job.id);
        if (!hist) {
          hist = {
            positions: Array.from({ length: HISTORY_LENGTH }, () => ({
              x: jx,
              y: jy,
              z: jz,
            })),
            writeIdx: 1,
            count: 1,
            lastMovedFrame: frame,
          };
          trailHistory.set(job.id, hist);
        } else {
          const prevIdx =
            (hist.writeIdx - 1 + HISTORY_LENGTH) % HISTORY_LENGTH;
          const prev = hist.positions[prevIdx];
          const dx = jx - prev.x;
          const dy = jy - prev.y;
          const dz = jz - prev.z;
          const distSq = dx * dx + dy * dy + dz * dz;
          if (distSq > 0.0001) {
            hist.positions[hist.writeIdx] = { x: jx, y: jy, z: jz };
            hist.writeIdx = (hist.writeIdx + 1) % HISTORY_LENGTH;
            hist.count = Math.min(hist.count + 1, HISTORY_LENGTH);
            hist.lastMovedFrame = frame;
          }
        }
      }
    }

    // Hide unused instances per shape
    hideUnused(llmMesh, llmIdx, MAX_PER_SHAPE);
    hideUnused(toolMesh, toolIdx, MAX_PER_SHAPE);
    hideUnused(otherMesh, otherIdx, MAX_PER_SHAPE);

    llmMesh.instanceMatrix.needsUpdate = true;
    toolMesh.instanceMatrix.needsUpdate = true;
    otherMesh.instanceMatrix.needsUpdate = true;
    if (llmMesh.instanceColor) llmMesh.instanceColor.needsUpdate = true;
    if (toolMesh.instanceColor) toolMesh.instanceColor.needsUpdate = true;
    if (otherMesh.instanceColor) otherMesh.instanceColor.needsUpdate = true;

    // --- Render trail particles ---
    if (!trailRef.current) return;

    const movedJobs: {
      jobId: string;
      hist: JobTrailHistory;
      priority: string;
    }[] = [];
    for (const job of jobList) {
      const hist = trailHistory.get(job.id);
      if (hist && hist.count >= 2) {
        movedJobs.push({ jobId: job.id, hist, priority: job.priority });
      }
    }
    movedJobs.sort((a, b) => b.hist.lastMovedFrame - a.hist.lastMovedFrame);

    let trailIdx = 0;
    const topMovers = movedJobs.slice(0, MAX_TRAIL_JOBS);

    for (const { hist, priority } of topMovers) {
      const newestIdx =
        (hist.writeIdx - 1 + HISTORY_LENGTH) % HISTORY_LENGTH;
      const available = Math.min(hist.count - 1, TRAIL_SEGMENTS);

      for (let seg = 0; seg < available; seg++) {
        if (trailIdx >= MAX_TRAILS) break;

        const ringIdx =
          (newestIdx - 1 - seg + HISTORY_LENGTH) % HISTORY_LENGTH;
        const p = hist.positions[ringIdx];

        const ageFactor = (seg + 1) / (TRAIL_SEGMENTS + 1);
        const scale = 0.12 * (1.0 - ageFactor * 0.7);

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
      {/* LLM jobs — icosahedron */}
      <instancedMesh
        ref={llmRef}
        args={[undefined, undefined, MAX_PER_SHAPE]}
      >
        <icosahedronGeometry args={[1, 0]} />
        <meshStandardMaterial
          emissive="#3498db"
          emissiveIntensity={0.8}
          metalness={0.5}
          roughness={0.3}
          toneMapped={false}
        />
      </instancedMesh>

      {/* Tool jobs — octahedron */}
      <instancedMesh
        ref={toolRef}
        args={[undefined, undefined, MAX_PER_SHAPE]}
      >
        <octahedronGeometry args={[1, 0]} />
        <meshStandardMaterial
          emissive="#3498db"
          emissiveIntensity={0.8}
          metalness={0.5}
          roughness={0.3}
          toneMapped={false}
        />
      </instancedMesh>

      {/* Other/script jobs — dodecahedron */}
      <instancedMesh
        ref={otherRef}
        args={[undefined, undefined, MAX_PER_SHAPE]}
      >
        <dodecahedronGeometry args={[1, 0]} />
        <meshStandardMaterial
          emissive="#3498db"
          emissiveIntensity={0.8}
          metalness={0.5}
          roughness={0.3}
          toneMapped={false}
        />
      </instancedMesh>

      {/* Trail particles — spheres */}
      <instancedMesh
        ref={trailRef}
        args={[undefined, undefined, MAX_TRAILS]}
      >
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
