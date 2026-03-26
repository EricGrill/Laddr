// dashboard/src/pages/MissionControl/scene/SceneRoot.tsx
import { Canvas } from "@react-three/fiber";
import { EffectComposer, Bloom } from "@react-three/postprocessing";
import { ShipEnvironment } from "./ShipEnvironment";
import { CameraController } from "./CameraController";
import { StationLayer } from "./StationLayer";
import { PipelineLayer } from "./PipelineLayer";
import { AgentLayer } from "./AgentLayer";
import { JobLayer } from "./JobLayer";
import { EffectsLayer } from "./EffectsLayer";

export function SceneRoot() {
  return (
    <Canvas
      camera={{ position: [0, 18, 14], fov: 50 }}
      gl={{ antialias: true, alpha: false }}
      style={{ background: "#0a0e1a" }}
    >
      {/* Lighting */}
      <ambientLight intensity={0.15} color="#4a6fa5" />
      <directionalLight position={[10, 20, 10]} intensity={0.4} color="#ffffff" />
      <pointLight position={[0, 8, 0]} intensity={0.6} color="#3498db" distance={30} />

      {/* Environment */}
      <ShipEnvironment />
      <PipelineLayer />

      {/* Entities */}
      <StationLayer />
      <AgentLayer />
      <JobLayer />

      {/* Camera */}
      <CameraController />

      {/* Effects */}
      <EffectsLayer />

      {/* Post-processing */}
      <EffectComposer>
        <Bloom
          luminanceThreshold={0.6}
          luminanceSmoothing={0.9}
          intensity={0.8}
        />
      </EffectComposer>
    </Canvas>
  );
}
