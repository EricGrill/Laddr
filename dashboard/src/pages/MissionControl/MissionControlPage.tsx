import { useMissionControl } from "./hooks/useMissionControl";
import { SceneRoot } from "./scene/SceneRoot";
import { TopBar } from "./ui/TopBar";
import { MCSidebar } from "./ui/Sidebar";

export default function MissionControlPage() {
  useMissionControl();

  return (
    <div className="flex flex-col h-full w-full bg-[#0a0e1a] text-white overflow-hidden">
      <TopBar />
      <div className="flex flex-1 overflow-hidden">
        <MCSidebar />
        <div className="flex-1 relative">
          <SceneRoot />
        </div>
        {/* Inspector panel — Task 9 */}
      </div>
    </div>
  );
}
