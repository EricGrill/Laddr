// dashboard/src/pages/MissionControl/stores/entityStore.ts
import { create } from "zustand";
import type {
  MCAgent,
  MCJob,
  MCMetrics,
  MCServerEvent,
  MCStation,
  MCWorkerActivity,
  MCWorker,
} from "../types";

interface EntityState {
  agents: Record<string, MCAgent>;
  jobs: Record<string, MCJob>;
  stations: Record<string, MCStation>;
  workers: Record<string, MCWorker>;
  workerActivity: Record<string, MCWorkerActivity>;
  queues: Record<string, number>;
  metrics: MCMetrics;
  handleEvent: (event: MCServerEvent) => void;
}

const EMPTY_METRICS: MCMetrics = {
  totalJobs: 0,
  activeAgents: 0,
  errorCount: 0,
  retryCount: 0,
};

function toRecord<T extends { id: string }>(arr: T[]): Record<string, T> {
  const map: Record<string, T> = {};
  for (const item of arr) {
    map[item.id] = item;
  }
  return map;
}

export const useEntityStore = create<EntityState>((set) => ({
  agents: {},
  jobs: {},
  stations: {},
  workers: {},
  workerActivity: {},
  queues: {},
  metrics: EMPTY_METRICS,

  handleEvent(event: MCServerEvent) {
    switch (event.type) {
      case "snapshot":
        set({
          agents: toRecord(event.data.agents),
          jobs: toRecord(event.data.jobs),
          stations: toRecord(event.data.stations),
          workers: toRecord(event.data.workers),
          workerActivity: {},
          queues: event.data.queues,
          metrics: event.data.metrics,
        });
        break;

      case "agent_updated":
        set((s) => ({
          agents: { ...s.agents, [event.agent.id]: event.agent },
        }));
        break;

      case "job_created":
        set((s) => ({
          jobs: { ...s.jobs, [event.job.id]: event.job },
        }));
        break;

      case "job_updated":
        set((s) => ({
          jobs: { ...s.jobs, [event.job.id]: event.job },
        }));
        break;

      case "job_activity":
        set((s) => {
          const existing = s.jobs[event.jobId];
          if (!existing) return s;
          return {
            jobs: {
              ...s.jobs,
              [event.jobId]: {
                ...existing,
                metadata: { ...existing.metadata, ...event.patch },
                history: [...existing.history, event.event].slice(-20),
              },
            },
          };
        });
        break;

      case "job_completed": {
        set((s) => {
          const existing = s.jobs[event.jobId];
          if (!existing) return s;
          return {
            jobs: {
              ...s.jobs,
              [event.jobId]: { ...existing, state: "completed" as const, updatedAt: event.at },
            },
          };
        });
        break;
      }

      case "job_failed": {
        set((s) => {
          const existing = s.jobs[event.jobId];
          if (!existing) return s;
          return {
            jobs: {
              ...s.jobs,
              [event.jobId]: { ...existing, state: "failed" as const, updatedAt: event.at },
            },
          };
        });
        break;
      }

      case "job_assigned": {
        set((s) => {
          const existing = s.jobs[event.jobId];
          if (!existing) return s;
          return {
            jobs: {
              ...s.jobs,
              [event.jobId]: {
                ...existing,
                state: "assigned" as const,
                assignedAgentId: event.agentId,
                currentStationId: event.stationId,
              },
            },
          };
        });
        break;
      }

      case "job_handoff": {
        set((s) => {
          const existing = s.jobs[event.jobId];
          if (!existing) return s;
          return {
            jobs: {
              ...s.jobs,
              [event.jobId]: {
                ...existing,
                currentStationId: event.toStationId,
                path: [...existing.path, event.toStationId],
              },
            },
          };
        });
        break;
      }

      case "station_updated":
        set((s) => ({
          stations: { ...s.stations, [event.station.id]: event.station },
        }));
        break;

      case "worker_registered":
        set((s) => ({
          workers: { ...s.workers, [event.worker.id]: event.worker },
        }));
        break;

      case "worker_activity":
        set((s) => ({
          workerActivity: {
            ...s.workerActivity,
            [event.activity.workerId]: event.activity,
          },
        }));
        break;

      case "worker_deregistered": {
        set((s) => {
          const { [event.workerId]: _worker, ...restWorkers } = s.workers;
          const { [event.workerId]: _activity, ...restActivity } = s.workerActivity;
          return { workers: restWorkers, workerActivity: restActivity };
        });
        break;
      }

      case "metrics_updated":
        set({ metrics: event.metrics });
        break;

      case "command_ack":
        // Handled by UI toast system — no entity state change
        break;
    }
  },
}));
