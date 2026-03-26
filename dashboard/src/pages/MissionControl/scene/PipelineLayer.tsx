import { useRef, useMemo } from "react";
import { useFrame } from "@react-three/fiber";
import {
  Object3D,
  InstancedMesh,
  Color,
  CatmullRomCurve3,
  Vector3,
  TubeGeometry,
} from "three";
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

const TUBE_RADIUS = 0.12;
const TUBE_SEGMENTS = 32;
const TUBE_RADIAL_SEGMENTS = 8;
const ARC_HEIGHT = 0.5;

/** Build a CatmullRomCurve3 that arcs upward between two floor points */
function buildArcCurve(start: [number, number, number], end: [number, number, number]): CatmullRomCurve3 {
  const midX = (start[0] + end[0]) / 2;
  const midY = (start[1] + end[1]) / 2 + ARC_HEIGHT;
  const midZ = (start[2] + end[2]) / 2;
  return new CatmullRomCurve3([
    new Vector3(start[0], start[1], start[2]),
    new Vector3(midX, midY, midZ),
    new Vector3(end[0], end[1], end[2]),
  ]);
}

/** A single glass tube rendered from a CatmullRomCurve3 */
function GlassTube({ curve, color }: { curve: CatmullRomCurve3; color: string }) {
  const geometry = useMemo(
    () => new TubeGeometry(curve, TUBE_SEGMENTS, TUBE_RADIUS, TUBE_RADIAL_SEGMENTS, false),
    [curve],
  );

  return (
    <mesh geometry={geometry}>
      <meshPhysicalMaterial
        color={color}
        transmission={0.6}
        roughness={0.1}
        metalness={0.3}
        opacity={0.25}
        transparent
        depthWrite={false}
      />
    </mesh>
  );
}

/** Animated particles flowing along pipeline spline paths */
function FlowParticles({
  curves,
  colors,
}: {
  curves: CatmullRomCurve3[];
  colors: string[];
}) {
  const meshRef = useRef<InstancedMesh>(null);

  const particles = useMemo(() => {
    if (curves.length === 0) return [];
    const result: Array<{ lineIdx: number; phase: number; speed: number }> = [];
    const perLine = Math.max(2, Math.floor(MAX_PARTICLES / Math.max(curves.length, 1)));
    for (let i = 0; i < curves.length && result.length < MAX_PARTICLES; i++) {
      for (let j = 0; j < perLine && result.length < MAX_PARTICLES; j++) {
        result.push({
          lineIdx: i,
          phase: j / perLine,
          speed: 0.3 + Math.random() * 0.4,
        });
      }
    }
    return result;
  }, [curves.length]);

  useFrame((state) => {
    if (!meshRef.current || curves.length === 0) return;
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
      const curve = curves[p.lineIdx];
      if (!curve) continue;

      const t = (time * p.speed + p.phase) % 1;

      // Sample position along the spline curve
      const pos = curve.getPointAt(t);
      dummy.position.set(pos.x, pos.y + 0.05, pos.z);

      // Fade in/out at ends
      const fade = Math.sin(t * Math.PI);
      dummy.scale.setScalar(0.06 * fade);
      dummy.updateMatrix();
      meshRef.current.setMatrixAt(i, dummy.matrix);

      tempColor.set(colors[p.lineIdx]);
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

  // Build spline curves and color array from the lines data
  const { curves, colors } = useMemo(() => {
    const c: CatmullRomCurve3[] = [];
    const cols: string[] = [];
    for (const line of lines) {
      c.push(buildArcCurve(line.points[0], line.points[1]));
      cols.push(line.color);
    }
    return { curves: c, colors: cols };
  }, [lines]);

  return (
    <group>
      {/* Glass tube pipelines */}
      {curves.map((curve, i) => (
        <GlassTube key={i} curve={curve} color={colors[i]} />
      ))}
      {/* Animated flow particles */}
      <FlowParticles curves={curves} colors={colors} />
    </group>
  );
}
