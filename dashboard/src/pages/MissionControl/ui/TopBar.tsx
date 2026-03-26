// dashboard/src/pages/MissionControl/ui/TopBar.tsx
import { useTransportStore } from "../stores/transportStore";
import { useEntityStore } from "../stores/entityStore";

export function TopBar() {
  const isConnected = useTransportStore((s) => s.isConnected);
  const metrics = useEntityStore((s) => s.metrics);

  return (
    <div className="h-10 bg-[#0d1220] border-b border-[#1a2040] flex items-center px-4 gap-6 text-xs flex-shrink-0">
      <span className="text-cyan-400 font-semibold tracking-wider uppercase">
        Mission Control
      </span>
      <span className={isConnected ? "text-green-400" : "text-red-400"}>
        {isConnected ? "ONLINE" : "OFFLINE"}
      </span>
      <div className="flex gap-4 ml-auto text-gray-400">
        <span>Jobs: <span className="text-white">{metrics.totalJobs}</span></span>
        <span>Agents: <span className="text-white">{metrics.activeAgents}</span></span>
        <span>Errors: <span className={metrics.errorCount > 0 ? "text-red-400" : "text-white"}>{metrics.errorCount}</span></span>
      </div>
    </div>
  );
}
