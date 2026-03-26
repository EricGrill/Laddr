import { useUIStore } from "../stores/uiStore";
import { AgentInspector } from "./AgentInspector";
import { JobInspector } from "./JobInspector";
import { StationInspector } from "./StationInspector";

export function InspectorPanel() {
  const selectedEntity = useUIStore((s) => s.selectedEntity);
  const inspectorOpen = useUIStore((s) => s.inspectorOpen);
  const clearSelection = useUIStore((s) => s.clearSelection);

  if (!inspectorOpen || !selectedEntity) return null;

  return (
    <div className="w-64 border-l border-[#1a2040] bg-[#0d1220] p-4 flex-shrink-0 overflow-y-auto">
      <div className="flex items-center justify-between mb-3">
        <h3 className="text-[10px] uppercase tracking-wider text-cyan-400">
          {selectedEntity.type} Inspector
        </h3>
        <button onClick={clearSelection} className="text-gray-600 hover:text-white text-xs">
          ✕
        </button>
      </div>

      {selectedEntity.type === "agent" && <AgentInspector agentId={selectedEntity.id} />}
      {selectedEntity.type === "job" && <JobInspector jobId={selectedEntity.id} />}
      {selectedEntity.type === "station" && <StationInspector stationId={selectedEntity.id} />}
    </div>
  );
}
