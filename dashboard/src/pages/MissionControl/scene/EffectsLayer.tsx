import { Sparkles } from "@react-three/drei";

export function EffectsLayer() {
  return (
    <group>
      <Sparkles
        count={50}
        scale={[30, 6, 18]}
        size={1.5}
        speed={0.3}
        opacity={0.2}
        color="#3498db"
      />
      <Sparkles
        count={20}
        scale={[10, 3, 10]}
        position={[0, 1, 0]}
        size={2}
        speed={0.5}
        opacity={0.15}
        color="#9b59b6"
      />
    </group>
  );
}
