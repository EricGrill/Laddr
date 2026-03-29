import { useTransportStore } from "../stores/transportStore";
import { useEntityStore } from "../stores/entityStore";
import { useUIStore } from "../stores/uiStore";

export function TopBar() {
  const isConnected = useTransportStore((s) => s.isConnected);
  const metrics = useEntityStore((s) => s.metrics);
  const fullscreen = useUIStore((s) => s.fullscreen);
  const toggleFullscreen = useUIStore((s) => s.toggleFullscreen);
  const dominantMode = metrics.dominantMode ?? "orchestration";
  const blockedJobs = metrics.jobsBlocked ?? 0;

  return (
    <div className="h-14 bg-[#0d1220] border-b border-[#1a2040] flex items-center px-6 gap-8 text-sm flex-shrink-0">
      <span className="text-cyan-400 font-semibold tracking-wider uppercase">
        Mission Control
      </span>
      <span className={isConnected ? "text-green-400" : "text-red-400"}>
        {isConnected ? "ONLINE" : "OFFLINE"}
      </span>
      <div className="flex gap-4 ml-auto text-gray-400 items-center">
        <span>Jobs: <span className="text-white">{metrics.totalJobs}</span></span>
        <span>Agents: <span className="text-white">{metrics.activeAgents}</span></span>
        <span>Errors: <span className={metrics.errorCount > 0 ? "text-red-400" : "text-white"}>{metrics.errorCount}</span></span>
        <span>Mode: <span className="text-cyan-300 uppercase">{dominantMode}</span></span>
        <span>Blocked: <span className={blockedJobs > 0 ? "text-yellow-300" : "text-white"}>{blockedJobs}</span></span>
        <button
          onClick={toggleFullscreen}
          className="ml-2 px-2 py-1 rounded border border-[#2a3050] text-gray-400 hover:text-white hover:border-cyan-400/50 transition-colors"
          title={fullscreen ? "Exit fullscreen (F)" : "Fullscreen (F)"}
        >
          {fullscreen ? "EXIT FS" : "FULLSCREEN"}
        </button>
      </div>
    </div>
  );
}
