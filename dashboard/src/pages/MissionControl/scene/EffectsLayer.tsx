import { useRef } from "react";
import { useFrame } from "@react-three/fiber";
import { Sparkles } from "@react-three/drei";
import type { Mesh } from "three";

/** Slowly rotating scanner beam at the dispatcher hub */
function ScannerBeam() {
  const ref = useRef<Mesh>(null);
  useFrame((state) => {
    if (!ref.current) return;
    ref.current.rotation.y = state.clock.elapsedTime * 0.5;
  });

  return (
    <mesh ref={ref} position={[-6, 0.1, 0]} rotation={[-Math.PI / 2, 0, 0]}>
      <coneGeometry args={[6, 0.02, 1]} />
      <meshStandardMaterial
        color="#3498db"
        emissive="#3498db"
        emissiveIntensity={0.6}
        transparent
        opacity={0.15}
        side={2}
      />
    </mesh>
  );
}

/** Pulsing vertical beam at a position — like a data uplink */
function DataBeam({ position, color }: { position: [number, number, number]; color: string }) {
  const ref = useRef<Mesh>(null);
  useFrame((state) => {
    if (!ref.current) return;
    const scale = 0.8 + Math.sin(state.clock.elapsedTime * 3 + position[0]) * 0.2;
    ref.current.scale.set(scale, 1, scale);
    (ref.current.material as any).opacity =
      0.1 + Math.sin(state.clock.elapsedTime * 2 + position[2]) * 0.05;
  });

  return (
    <mesh ref={ref} position={position}>
      <cylinderGeometry args={[0.02, 0.15, 5, 8, 1, true]} />
      <meshStandardMaterial
        color={color}
        emissive={color}
        emissiveIntensity={1.5}
        transparent
        opacity={0.1}
        side={2}
      />
    </mesh>
  );
}

/** Orbiting ring around a point */
function OrbitRing({ center, color, radius, speed, tilt }: {
  center: [number, number, number];
  color: string;
  radius: number;
  speed: number;
  tilt: number;
}) {
  const ref = useRef<Mesh>(null);
  useFrame((state) => {
    if (!ref.current) return;
    ref.current.rotation.y = state.clock.elapsedTime * speed;
  });

  return (
    <group position={center} rotation={[tilt, 0, 0]}>
      <mesh ref={ref}>
        <torusGeometry args={[radius, 0.015, 8, 48]} />
        <meshStandardMaterial
          color={color}
          emissive={color}
          emissiveIntensity={1.0}
          transparent
          opacity={0.4}
        />
      </mesh>
    </group>
  );
}

export function EffectsLayer() {
  return (
    <group>
      {/* Ambient sparkles */}
      <Sparkles
        count={60}
        scale={[30, 6, 18]}
        size={1.5}
        speed={0.4}
        opacity={0.25}
        color="#3498db"
      />
      <Sparkles
        count={30}
        scale={[10, 3, 10]}
        position={[0, 1, 0]}
        size={2}
        speed={0.6}
        opacity={0.2}
        color="#9b59b6"
      />
      {/* Extra sparkles near error chamber */}
      <Sparkles
        count={15}
        scale={[4, 2, 4]}
        position={[0, 1, 8]}
        size={1.8}
        speed={1.0}
        opacity={0.3}
        color="#e74c3c"
      />

      {/* Scanner beam at dispatcher */}
      <ScannerBeam />

      {/* Data uplink beams at key stations */}
      <DataBeam position={[-12, 2.5, 0]} color="#2ecc71" />
      <DataBeam position={[12, 2.5, 0]} color="#1abc9c" />
      <DataBeam position={[0, 2.5, -8]} color="#f1c40f" />

      {/* Orbiting rings at dispatcher */}
      <OrbitRing center={[-6, 2, 0]} color="#3498db" radius={2.2} speed={0.8} tilt={0.3} />
      <OrbitRing center={[-6, 2, 0]} color="#2980b9" radius={1.8} speed={-0.5} tilt={-0.5} />
    </group>
  );
}
