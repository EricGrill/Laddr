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
      {/* Fog for depth */}
      <fog attach="fog" args={["#0a0e1a", 20, 50]} />

      {/* Lighting — richer setup */}
      <ambientLight intensity={0.1} color="#1a2a4a" />
      <directionalLight position={[10, 20, 10]} intensity={0.3} color="#ffffff" />
      <pointLight position={[0, 10, 0]} intensity={0.8} color="#3498db" distance={35} />
      <pointLight position={[-12, 4, 0]} intensity={0.4} color="#2ecc71" distance={15} />
      <pointLight position={[12, 4, 0]} intensity={0.4} color="#1abc9c" distance={15} />
      <pointLight position={[0, 4, -8]} intensity={0.3} color="#f1c40f" distance={12} />
      <pointLight position={[0, 4, 8]} intensity={0.3} color="#c0392b" distance={12} />

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
          luminanceThreshold={0.4}
          luminanceSmoothing={0.9}
          intensity={1.2}
        />
      </EffectComposer>
    </Canvas>
  );
}
