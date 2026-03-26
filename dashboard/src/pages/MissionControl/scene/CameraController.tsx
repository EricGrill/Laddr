// dashboard/src/pages/MissionControl/scene/CameraController.tsx
import { useRef } from "react";
import { OrbitControls } from "@react-three/drei";
import { useFrame, useThree } from "@react-three/fiber";
import * as THREE from "three";

const FLYTHROUGH_DURATION = 3; // seconds

// Start: near Intake Bay, low angle
const START_POS = new THREE.Vector3(-14, 5, 8);
const START_LOOK = new THREE.Vector3(-12, 0, 0);

// End: default isometric view
const END_POS = new THREE.Vector3(0, 18, 14);
const END_LOOK = new THREE.Vector3(0, 0, 0);

// Ease-out cubic
function easeOutCubic(t: number): number {
  return 1 - Math.pow(1 - t, 3);
}

export function CameraController() {
  const controlsRef = useRef<any>(null);
  const elapsedRef = useRef(0);
  const doneRef = useRef(false);
  const camera = useThree((state) => state.camera);

  // Temp vectors to avoid allocations each frame
  const tmpPos = useRef(new THREE.Vector3());
  const tmpLook = useRef(new THREE.Vector3());

  useFrame((_, delta) => {
    if (doneRef.current) return;

    elapsedRef.current += delta;
    const t = Math.min(elapsedRef.current / FLYTHROUGH_DURATION, 1);
    const eased = easeOutCubic(t);

    // Interpolate position
    tmpPos.current.lerpVectors(START_POS, END_POS, eased);
    camera.position.copy(tmpPos.current);

    // Interpolate lookAt target
    tmpLook.current.lerpVectors(START_LOOK, END_LOOK, eased);
    camera.lookAt(tmpLook.current);

    // Disable orbit controls during flythrough
    if (controlsRef.current) {
      controlsRef.current.enabled = false;
    }

    if (t >= 1) {
      doneRef.current = true;
      if (controlsRef.current) {
        controlsRef.current.target.set(0, 0, 0);
        controlsRef.current.enabled = true;
        controlsRef.current.update();
      }
    }
  });

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
