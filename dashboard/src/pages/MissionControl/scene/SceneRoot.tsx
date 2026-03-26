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
      style={{ background: "#0c1225" }}
    >
      {/* Fog — pushed back so scene is more visible */}
      <fog attach="fog" args={["#0c1225", 35, 60]} />

      {/* Lighting — much brighter */}
      <ambientLight intensity={0.4} color="#4a6fa5" />
      <directionalLight position={[10, 25, 10]} intensity={0.8} color="#ffffff" />
      <hemisphereLight args={["#4a6fa5", "#1a1a2e", 0.3]} />

      {/* Station zone lights — brighter and wider */}
      <pointLight position={[0, 12, 0]} intensity={1.5} color="#3498db" distance={40} />
      <pointLight position={[-12, 6, 0]} intensity={1.0} color="#2ecc71" distance={20} />
      <pointLight position={[12, 6, 0]} intensity={1.0} color="#1abc9c" distance={20} />
      <pointLight position={[0, 6, -8]} intensity={0.8} color="#f1c40f" distance={16} />
      <pointLight position={[0, 6, 8]} intensity={0.8} color="#c0392b" distance={16} />
      {/* Fill lights for the middle zone */}
      <pointLight position={[3, 6, 0]} intensity={0.6} color="#9b59b6" distance={18} />
      <pointLight position={[-3, 6, 0]} intensity={0.6} color="#e67e22" distance={18} />

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

      {/* Post-processing — slightly toned down bloom so it doesn't wash out */}
      <EffectComposer>
        <Bloom
          luminanceThreshold={0.5}
          luminanceSmoothing={0.9}
          intensity={0.8}
        />
      </EffectComposer>
    </Canvas>
  );
}
