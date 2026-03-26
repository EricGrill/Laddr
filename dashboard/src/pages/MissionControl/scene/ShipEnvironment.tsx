// dashboard/src/pages/MissionControl/scene/ShipEnvironment.tsx

function Floor() {
  return (
    <mesh rotation={[-Math.PI / 2, 0, 0]} position={[0, -0.01, 0]} receiveShadow>
      <planeGeometry args={[32, 20]} />
      <meshStandardMaterial color="#0d1117" metalness={0.8} roughness={0.4} />
    </mesh>
  );
}

function GridLines() {
  // Subtle grid overlay on floor
  return (
    <gridHelper
      args={[32, 32, "#1a2744", "#0f1a2e"]}
      position={[0, 0.01, 0]}
    />
  );
}

function Walls() {
  const wallMaterial = (
    <meshStandardMaterial color="#0a0f1a" metalness={0.9} roughness={0.3} />
  );

  return (
    <group>
      {/* Back wall */}
      <mesh position={[0, 3, -10]}>
        <boxGeometry args={[32, 6, 0.2]} />
        {wallMaterial}
      </mesh>
      {/* Front wall */}
      <mesh position={[0, 3, 10]}>
        <boxGeometry args={[32, 6, 0.2]} />
        {wallMaterial}
      </mesh>
      {/* Left wall */}
      <mesh position={[-16, 3, 0]}>
        <boxGeometry args={[0.2, 6, 20]} />
        {wallMaterial}
      </mesh>
      {/* Right wall */}
      <mesh position={[16, 3, 0]}>
        <boxGeometry args={[0.2, 6, 20]} />
        {wallMaterial}
      </mesh>
    </group>
  );
}

function GlowingPipe({ start, end, color = "#3498db" }: { start: [number, number, number]; end: [number, number, number]; color?: string }) {
  const midX = (start[0] + end[0]) / 2;
  const midY = (start[1] + end[1]) / 2;
  const midZ = (start[2] + end[2]) / 2;
  const dx = end[0] - start[0];
  const dy = end[1] - start[1];
  const dz = end[2] - start[2];
  const length = Math.sqrt(dx * dx + dy * dy + dz * dz);

  return (
    <mesh position={[midX, midY, midZ]}>
      <cylinderGeometry args={[0.05, 0.05, length, 8]} />
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
      {/* Horizontal ceiling pipes */}
      <GlowingPipe start={[-14, 5.5, -9]} end={[14, 5.5, -9]} color="#1a3a5c" />
      <GlowingPipe start={[-14, 5.5, 9]} end={[14, 5.5, 9]} color="#1a3a5c" />
      {/* Cross pipes */}
      <GlowingPipe start={[-8, 5.5, -9]} end={[-8, 5.5, 9]} color="#1a2a4c" />
      <GlowingPipe start={[8, 5.5, -9]} end={[8, 5.5, 9]} color="#1a2a4c" />
    </group>
  );
}

function Catwalks() {
  return (
    <group>
      {/* Elevated catwalk along back wall */}
      <mesh position={[0, 2.5, -8.5]}>
        <boxGeometry args={[30, 0.1, 1.5]} />
        <meshStandardMaterial color="#1a1f2e" metalness={0.7} roughness={0.5} transparent opacity={0.6} />
      </mesh>
      {/* Railing */}
      <mesh position={[0, 3, -8]}>
        <boxGeometry args={[30, 0.05, 0.05]} />
        <meshStandardMaterial color="#2a3a5c" metalness={0.8} roughness={0.3} />
      </mesh>
    </group>
  );
}

export function ShipEnvironment() {
  return (
    <group>
      <Floor />
      <GridLines />
      <Walls />
      <Pipes />
      <Catwalks />
    </group>
  );
}
