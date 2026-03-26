import { useEntityStore } from "../stores/entityStore";
import { useUIStore } from "../stores/uiStore";

export function AgentInspector({ agentId }: { agentId: string }) {
  const agent = useEntityStore((s) => s.agents[agentId]);
  const selectEntity = useUIStore((s) => s.selectEntity);

  if (!agent) return <div className="text-gray-500 text-xs">Agent not found</div>;

  return (
    <div className="space-y-3">
      <div>
        <div className="text-[10px] text-gray-500 uppercase">Name</div>
        <div className="text-sm">{agent.name ?? agent.id}</div>
      </div>
      <div>
        <div className="text-[10px] text-gray-500 uppercase">Role</div>
        <div className="text-sm">{agent.role}</div>
      </div>
      <div>
        <div className="text-[10px] text-gray-500 uppercase">State</div>
        <div className="text-sm">{agent.state}</div>
      </div>
      {agent.currentJobId && (
        <div>
          <div className="text-[10px] text-gray-500 uppercase">Current Job</div>
          <button
            onClick={() => selectEntity({ id: agent.currentJobId!, type: "job" })}
            className="text-sm text-cyan-400 hover:underline"
          >
            {agent.currentJobId}
          </button>
        </div>
      )}
      {agent.efficiency != null && (
        <div>
          <div className="text-[10px] text-gray-500 uppercase">Efficiency</div>
          <div className="text-sm">{(agent.efficiency * 100).toFixed(0)}%</div>
        </div>
      )}
    </div>
  );
}
