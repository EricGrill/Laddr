// dashboard/src/pages/MissionControl/ui/Sidebar.tsx
import { useEntityStore } from "../stores/entityStore";
import { useUIStore } from "../stores/uiStore";
import type { JobState, JobPriority, StationState, AgentBackendState } from "../types";

const JOB_STATES: JobState[] = ["queued", "assigned", "processing", "completed", "failed", "paused"];
const JOB_PRIORITIES: JobPriority[] = ["low", "normal", "high", "critical"];
const STATION_STATES: StationState[] = ["idle", "active", "saturated", "errored"];
const AGENT_STATES: AgentBackendState[] = ["idle", "working", "blocked", "errored"];

const STATE_COLORS: Record<string, string> = {
  idle: "bg-gray-500", active: "bg-green-500", saturated: "bg-yellow-500",
  errored: "bg-red-500", queued: "bg-blue-500", assigned: "bg-cyan-500",
  processing: "bg-purple-500", completed: "bg-green-500", failed: "bg-red-500",
  paused: "bg-yellow-500", working: "bg-purple-500", blocked: "bg-yellow-500",
  low: "bg-gray-400", normal: "bg-blue-400", high: "bg-orange-400", critical: "bg-red-400",
};

function FilterSection({
  title,
  items,
  activeSet,
  onToggle,
}: {
  title: string;
  items: string[];
  activeSet: Set<string>;
  onToggle: (item: string) => void;
}) {
  return (
    <div className="mb-4">
      <h4 className="text-[10px] uppercase tracking-wider text-gray-500 mb-2">{title}</h4>
      <div className="flex flex-wrap gap-1">
        {items.map((item) => {
          const isActive = activeSet.size === 0 || activeSet.has(item);
          return (
            <button
              key={item}
              onClick={() => onToggle(item)}
              className={`px-2 py-0.5 text-[10px] rounded border transition-all ${
                isActive
                  ? "border-gray-600 text-white"
                  : "border-gray-800 text-gray-600"
              }`}
            >
              <span className={`inline-block w-1.5 h-1.5 rounded-full mr-1 ${STATE_COLORS[item] ?? "bg-gray-500"}`} />
              {item}
            </button>
          );
        })}
      </div>
    </div>
  );
}

export function MCSidebar() {
  const workers = useEntityStore((s) => s.workers);
  const stations = useEntityStore((s) => s.stations);
  const agents = useEntityStore((s) => s.agents);
  const filters = useUIStore((s) => s.filters);
  const toggleJobState = useUIStore((s) => s.toggleJobStateFilter);
  const toggleJobPriority = useUIStore((s) => s.toggleJobPriorityFilter);
  const toggleStationState = useUIStore((s) => s.toggleStationStateFilter);
  const toggleAgentState = useUIStore((s) => s.toggleAgentStateFilter);

  const workerCount = Object.keys(workers).length;
  const stationCount = Object.keys(stations).length;
  const agentCount = Object.keys(agents).length;

  return (
    <div className="w-52 border-r border-[#1a2040] p-3 flex-shrink-0 overflow-y-auto text-xs">
      {/* Summary */}
      <div className="mb-5">
        <h3 className="text-[10px] uppercase tracking-wider text-cyan-400 mb-2">System</h3>
        <div className="space-y-1 text-gray-400">
          <div>Workers: <span className="text-white">{workerCount}</span></div>
          <div>Stations: <span className="text-white">{stationCount}</span></div>
          <div>Agents: <span className="text-white">{agentCount}</span></div>
        </div>
      </div>

      {/* Filters */}
      <h3 className="text-[10px] uppercase tracking-wider text-cyan-400 mb-3">Filters</h3>

      <FilterSection
        title="Job State"
        items={JOB_STATES}
        activeSet={filters.jobStates as Set<string>}
        onToggle={(s) => toggleJobState(s as JobState)}
      />
      <FilterSection
        title="Priority"
        items={JOB_PRIORITIES}
        activeSet={filters.jobPriorities as Set<string>}
        onToggle={(p) => toggleJobPriority(p as JobPriority)}
      />
      <FilterSection
        title="Station State"
        items={STATION_STATES}
        activeSet={filters.stationStates as Set<string>}
        onToggle={(s) => toggleStationState(s as StationState)}
      />
      <FilterSection
        title="Agent State"
        items={AGENT_STATES}
        activeSet={filters.agentStates as Set<string>}
        onToggle={(s) => toggleAgentState(s as AgentBackendState)}
      />
    </div>
  );
}
