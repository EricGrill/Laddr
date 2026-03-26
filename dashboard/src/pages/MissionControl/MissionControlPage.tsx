import { useMissionControl } from "./hooks/useMissionControl";
import { SceneRoot } from "./scene/SceneRoot";

export default function MissionControlPage() {
  const { isConnected, error } = useMissionControl();

  return (
    <div className="flex h-full w-full bg-[#0a0e1a] text-white overflow-hidden">
      {/* Left sidebar - filters & metrics */}
      <div className="w-56 border-r border-[#1a2040] p-4 flex-shrink-0 overflow-y-auto">
        <h3 className="text-xs uppercase tracking-wider text-cyan-400 mb-3">
          Mission Control
        </h3>
        <div className="text-xs text-gray-500">
          {isConnected ? (
            <span className="text-green-400">Connected</span>
          ) : error ? (
            <span className="text-red-400">{error}</span>
          ) : (
            <span className="text-yellow-400">Connecting...</span>
          )}
        </div>
      </div>

      {/* 3D Scene viewport */}
      <div className="flex-1 relative">
        <SceneRoot />
      </div>

      {/* Right inspector panel - conditionally shown */}
      {/* Added in Task 9 */}
    </div>
  );
}
