import { useRef, useMemo } from "react";
import { useFrame } from "@react-three/fiber";
import { Line } from "@react-three/drei";
import { Object3D, InstancedMesh, Color } from "three";
import { useSceneStore } from "../stores/sceneStore";
import { useEntityStore } from "../stores/entityStore";

const FIXED_CONNECTIONS: Array<[string, string, string]> = [
  ["intake", "dispatcher", "#2ecc71"],
  ["dispatcher", "output-dock", "#1abc9c"],
  ["dispatcher", "supervisor", "#f1c40f"],
  ["dispatcher", "error-chamber", "#c0392b"],
];

const MAX_PARTICLES = 100;
const dummy = new Object3D();
const tempColor = new Color();

/** Animated particles flowing along pipeline paths */
function FlowParticles({
  lines,
}: {
  lines: Array<{ points: [number, number, number][]; color: string }>;
}) {
  const meshRef = useRef<InstancedMesh>(null);

  // Create particle assignments — each particle belongs to a line and has a phase offset
  const particles = useMemo(() => {
    if (lines.length === 0) return [];
    const result: Array<{ lineIdx: number; phase: number; speed: number }> = [];
    const perLine = Math.max(2, Math.floor(MAX_PARTICLES / Math.max(lines.length, 1)));
    for (let i = 0; i < lines.length && result.length < MAX_PARTICLES; i++) {
      for (let j = 0; j < perLine && result.length < MAX_PARTICLES; j++) {
        result.push({
          lineIdx: i,
          phase: j / perLine,
          speed: 0.3 + Math.random() * 0.4,
        });
      }
    }
    return result;
  }, [lines.length]);

  useFrame((state) => {
    if (!meshRef.current || lines.length === 0) return;
    const time = state.clock.elapsedTime;

    for (let i = 0; i < MAX_PARTICLES; i++) {
      if (i >= particles.length) {
        dummy.position.set(0, -100, 0);
        dummy.scale.setScalar(0);
        dummy.updateMatrix();
        meshRef.current.setMatrixAt(i, dummy.matrix);
        continue;
      }

      const p = particles[i];
      const line = lines[p.lineIdx];
      if (!line) continue;

      const [start, end] = line.points;
      const t = ((time * p.speed + p.phase) % 1);

      // Lerp position along line
      const x = start[0] + (end[0] - start[0]) * t;
      const y = start[1] + (end[1] - start[1]) * t + 0.15;
      const z = start[2] + (end[2] - start[2]) * t;

      dummy.position.set(x, y, z);
      // Fade in/out at ends
      const fade = Math.sin(t * Math.PI);
      dummy.scale.setScalar(0.06 * fade);
      dummy.updateMatrix();
      meshRef.current.setMatrixAt(i, dummy.matrix);

      tempColor.set(line.color);
      meshRef.current.setColorAt(i, tempColor);
    }

    meshRef.current.instanceMatrix.needsUpdate = true;
    if (meshRef.current.instanceColor) {
      meshRef.current.instanceColor.needsUpdate = true;
    }
  });

  return (
    <instancedMesh ref={meshRef} args={[undefined, undefined, MAX_PARTICLES]}>
      <sphereGeometry args={[1, 6, 6]} />
      <meshStandardMaterial
        emissive="#ffffff"
        emissiveIntensity={2}
        toneMapped={false}
        transparent
        opacity={0.8}
      />
    </instancedMesh>
  );
}

export function PipelineLayer() {
  const stations = useEntityStore((s) => s.stations);
  const getPos = useSceneStore((s) => s.getStationPosition);

  const lines = useMemo(() => {
    const result: Array<{ points: [number, number, number][]; color: string }> = [];

    for (const [fromType, toId, color] of FIXED_CONNECTIONS) {
      const from = getPos(fromType);
      const to = getPos(toId);
      result.push({
        points: [
          [from.x, 0.1, from.z],
          [to.x, 0.1, to.z],
        ],
        color,
      });
    }

    for (const station of Object.values(stations)) {
      if (station.workerId) {
        const from = getPos("dispatcher");
        const to = getPos(station.id);
        result.push({
          points: [
            [from.x, 0.1, from.z],
            [to.x, 0.1, to.z],
          ],
          color: "#3498db",
        });
        const out = getPos("output-dock");
        result.push({
          points: [
            [to.x, 0.1, to.z],
            [out.x, 0.1, out.z],
          ],
          color: "#1abc9c",
        });
      }
    }

    return result;
  }, [stations, getPos]);

  return (
    <group>
      {/* Static pipeline lines */}
      {lines.map((line, i) => (
        <Line
          key={i}
          points={line.points}
          color={line.color}
          lineWidth={1.5}
          transparent
          opacity={0.3}
        />
      ))}
      {/* Animated flow particles */}
      <FlowParticles lines={lines} />
    </group>
  );
}
