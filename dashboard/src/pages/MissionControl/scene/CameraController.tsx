// dashboard/src/pages/MissionControl/scene/CameraController.tsx
import { useRef } from "react";
import { OrbitControls } from "@react-three/drei";

export function CameraController() {
  const controlsRef = useRef<any>(null);

  return (
    <OrbitControls
      ref={controlsRef}
      enableDamping
      dampingFactor={0.1}
      minDistance={5}
      maxDistance={40}
      maxPolarAngle={Math.PI / 2.2}
      minPolarAngle={0.3}
    />
  );
}
