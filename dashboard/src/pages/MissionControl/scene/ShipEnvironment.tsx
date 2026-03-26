import { useRef, useMemo } from "react";
import { useFrame } from "@react-three/fiber";
import { Color } from "three";
import type { Mesh, PointLight, MeshStandardMaterial } from "three";
import { useEntityStore } from "../stores/entityStore";
import { useSceneStore } from "../stores/sceneStore";
import type { MCStation } from "../types";

function Floor() {
  return (
    <mesh rotation={[-Math.PI / 2, 0, 0]} position={[0, -0.01, 0]} receiveShadow>
      <planeGeometry args={[32, 20]} />
      <meshStandardMaterial color="#1a2030" metalness={0.6} roughness={0.5} />
    </mesh>
  );
}

function GridLines() {
  return (
    <gridHelper args={[32, 32, "#2a3a5c", "#1a2a4a"]} position={[0, 0.01, 0]} />
  );
}

function Walls() {
  return (
    <group>
      <mesh position={[0, 3, -10]}>
        <boxGeometry args={[32, 6, 0.2]} />
        <meshStandardMaterial color="#151d2e" metalness={0.7} roughness={0.4} />
      </mesh>
      <mesh position={[0, 3, 10]}>
        <boxGeometry args={[32, 6, 0.2]} />
        <meshStandardMaterial color="#151d2e" metalness={0.7} roughness={0.4} />
      </mesh>
      <mesh position={[-16, 3, 0]}>
        <boxGeometry args={[0.2, 6, 20]} />
        <meshStandardMaterial color="#151d2e" metalness={0.7} roughness={0.4} />
      </mesh>
      <mesh position={[16, 3, 0]}>
        <boxGeometry args={[0.2, 6, 20]} />
        <meshStandardMaterial color="#151d2e" metalness={0.7} roughness={0.4} />
      </mesh>
    </group>
  );
}

/** Pulsing ceiling pipe with animated glow */
function GlowingPipe({
  start,
  end,
  color = "#3498db",
  pulseSpeed = 1,
}: {
  start: [number, number, number];
  end: [number, number, number];
  color?: string;
  pulseSpeed?: number;
}) {
  const meshRef = useRef<Mesh>(null);
  const midX = (start[0] + end[0]) / 2;
  const midY = (start[1] + end[1]) / 2;
  const midZ = (start[2] + end[2]) / 2;
  const dx = end[0] - start[0];
  const dz = end[2] - start[2];
  const length = Math.sqrt(dx * dx + dz * dz);
  const angle = Math.atan2(dx, dz);

  useFrame((state) => {
    if (!meshRef.current) return;
    const mat = meshRef.current.material as any;
    if (mat.emissiveIntensity !== undefined) {
      mat.emissiveIntensity = 0.3 + Math.sin(state.clock.elapsedTime * pulseSpeed) * 0.2;
    }
  });

  return (
    <mesh
      ref={meshRef}
      position={[midX, midY, midZ]}
      rotation={[0, angle, Math.PI / 2]}
    >
      <cylinderGeometry args={[0.06, 0.06, length, 8]} />
      <meshStandardMaterial
        color={color}
        emissive={color}
        emissiveIntensity={0.5}
        metalness={0.9}
        roughness={0.2}
      />
    </mesh>
  );
}

function Pipes() {
  return (
    <group>
      <GlowingPipe start={[-14, 5.5, -9]} end={[14, 5.5, -9]} color="#1a3a5c" pulseSpeed={0.8} />
      <GlowingPipe start={[-14, 5.5, 9]} end={[14, 5.5, 9]} color="#1a3a5c" pulseSpeed={1.2} />
      <GlowingPipe start={[-8, 5.5, -9]} end={[-8, 5.5, 9]} color="#1a2a4c" pulseSpeed={0.6} />
      <GlowingPipe start={[8, 5.5, -9]} end={[8, 5.5, 9]} color="#1a2a4c" pulseSpeed={1.0} />
      {/* Extra detail pipes */}
      <GlowingPipe start={[-14, 4.5, -9.5]} end={[14, 4.5, -9.5]} color="#0d1a2c" pulseSpeed={1.5} />
      <GlowingPipe start={[-14, 4.5, 9.5]} end={[14, 4.5, 9.5]} color="#0d1a2c" pulseSpeed={0.9} />
    </group>
  );
}

function Catwalks() {
  return (
    <group>
      <mesh position={[0, 2.5, -8.5]}>
        <boxGeometry args={[30, 0.1, 1.5]} />
        <meshStandardMaterial color="#1a1f2e" metalness={0.7} roughness={0.5} transparent opacity={0.6} />
      </mesh>
      <mesh position={[0, 3, -8]}>
        <boxGeometry args={[30, 0.05, 0.05]} />
        <meshStandardMaterial color="#2a3a5c" metalness={0.8} roughness={0.3} />
      </mesh>
      {/* Second catwalk on front wall */}
      <mesh position={[0, 2.5, 8.5]}>
        <boxGeometry args={[30, 0.1, 1.5]} />
        <meshStandardMaterial color="#1a1f2e" metalness={0.7} roughness={0.5} transparent opacity={0.6} />
      </mesh>
    </group>
  );
}

/** Spinning holographic ring — decorative element */
function HoloRing({ position, color, speed, size }: {
  position: [number, number, number];
  color: string;
  speed: number;
  size: number;
}) {
  const ref = useRef<Mesh>(null);
  useFrame((state) => {
    if (!ref.current) return;
    ref.current.rotation.y = state.clock.elapsedTime * speed;
    ref.current.rotation.x = Math.sin(state.clock.elapsedTime * speed * 0.5) * 0.3;
  });

  return (
    <mesh ref={ref} position={position}>
      <torusGeometry args={[size, 0.03, 8, 32]} />
      <meshStandardMaterial
        color={color}
        emissive={color}
        emissiveIntensity={0.8}
        transparent
        opacity={0.5}
      />
    </mesh>
  );
}

/** Pulsing ceiling light */
function CeilingLight({ position, color }: {
  position: [number, number, number];
  color: string;
}) {
  const lightRef = useRef<PointLight>(null);
  const meshRef = useRef<Mesh>(null);

  useFrame((state) => {
    const pulse = 0.5 + Math.sin(state.clock.elapsedTime * 1.5 + position[0]) * 0.3;
    if (lightRef.current) lightRef.current.intensity = pulse;
    if (meshRef.current) {
      (meshRef.current.material as any).emissiveIntensity = pulse;
    }
  });

  return (
    <group position={position}>
      <pointLight ref={lightRef} color={color} intensity={0.5} distance={8} />
      <mesh ref={meshRef}>
        <sphereGeometry args={[0.15, 8, 8]} />
        <meshStandardMaterial color={color} emissive={color} emissiveIntensity={0.5} />
      </mesh>
    </group>
  );
}

/** Compute heat color and emissive intensity for a station based on its state and load */
function getHeatProps(station: MCStation): { color: string; emissiveIntensity: number; pulseSpeed: number } {
  if (station.state === "errored") {
    return { color: "#c0392b", emissiveIntensity: 1.0, pulseSpeed: 4.0 };
  }
  if (station.state === "saturated") {
    return { color: "#e74c3c", emissiveIntensity: 0.8, pulseSpeed: 1.5 };
  }
  if (station.state === "active") {
    const threshold = station.capacity * 0.5;
    if (station.queueDepth >= threshold) {
      return { color: "#e67e22", emissiveIntensity: 0.6, pulseSpeed: 1.2 };
    }
    return { color: "#2980b9", emissiveIntensity: 0.4, pulseSpeed: 1.0 };
  }
  // idle, offline, blocked
  return { color: "#1a2a4a", emissiveIntensity: 0.2, pulseSpeed: 0.6 };
}

/** A single heat spot on the floor under a station */
function HeatSpot({ station }: { station: MCStation }) {
  const meshRef = useRef<Mesh>(null);
  const pos = useSceneStore((s) => s.getStationPosition(station.id));
  const { color, emissiveIntensity, pulseSpeed } = getHeatProps(station);
  const threeColor = useMemo(() => new Color(color), [color]);

  useFrame((state) => {
    if (!meshRef.current) return;
    const mat = meshRef.current.material as MeshStandardMaterial;
    const oscillation = Math.sin(state.clock.elapsedTime * pulseSpeed) * 0.1;
    mat.emissiveIntensity = emissiveIntensity + oscillation;
  });

  return (
    <mesh
      ref={meshRef}
      rotation={[-Math.PI / 2, 0, 0]}
      position={[pos.x, 0.02, pos.z]}
    >
      <circleGeometry args={[2.5, 32]} />
      <meshStandardMaterial
        color={threeColor}
        emissive={threeColor}
        emissiveIntensity={emissiveIntensity}
        transparent
        opacity={0.4}
        depthWrite={false}
      />
    </mesh>
  );
}

/** Heat map floor overlay: renders a glow under each station based on load */
function HeatMapFloor() {
  const stations = useEntityStore((s) => s.stations);
  const stationList = useMemo(() => Object.values(stations), [stations]);

  return (
    <group>
      {stationList.map((station) => (
        <HeatSpot key={station.id} station={station} />
      ))}
    </group>
  );
}

export function ShipEnvironment() {
  return (
    <group>
      <Floor />
      <GridLines />
      <HeatMapFloor />
      <Walls />
      <Pipes />
      <Catwalks />

      {/* Holographic rings — decorative spinning elements */}
      <HoloRing position={[-6, 3.5, 0]} color="#3498db" speed={1.5} size={0.8} />
      <HoloRing position={[-6, 3.8, 0]} color="#3498db" speed={-1.0} size={0.5} />
      <HoloRing position={[0, 3.5, -8]} color="#f1c40f" speed={0.8} size={0.6} />
      <HoloRing position={[12, 3.0, 0]} color="#1abc9c" speed={1.2} size={0.7} />

      {/* Pulsing ceiling lights */}
      <CeilingLight position={[-10, 5.8, 0]} color="#3498db" />
      <CeilingLight position={[-3, 5.8, 0]} color="#9b59b6" />
      <CeilingLight position={[3, 5.8, 0]} color="#e67e22" />
      <CeilingLight position={[10, 5.8, 0]} color="#1abc9c" />
      <CeilingLight position={[0, 5.8, -5]} color="#f1c40f" />
      <CeilingLight position={[0, 5.8, 5]} color="#c0392b" />
    </group>
  );
}
