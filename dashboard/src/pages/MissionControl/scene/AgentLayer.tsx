// dashboard/src/pages/MissionControl/scene/AgentLayer.tsx
import { useEntityStore } from "../stores/entityStore";
import { useSceneStore } from "../stores/sceneStore";
import { AgentBot } from "./AgentBot";

export function AgentLayer() {
  const agents = useEntityStore((s) => s.agents);
  const jobs = useEntityStore((s) => s.jobs);
  const getAgentPosition = useSceneStore((s) => s.getAgentPosition);

  return (
    <group>
      {Object.values(agents).map((agent) => {
        // Resolve agent's current station via their assigned job
        const currentJob = agent.currentJobId ? jobs[agent.currentJobId] : undefined;
        const stationId = currentJob?.currentStationId ?? undefined;
        return (
          <AgentBot
            key={agent.id}
            agent={agent}
            targetPosition={getAgentPosition(stationId)}
          />
        );
      })}
    </group>
  );
}
