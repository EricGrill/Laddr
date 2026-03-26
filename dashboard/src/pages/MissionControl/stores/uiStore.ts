// dashboard/src/pages/MissionControl/stores/uiStore.ts
import { create } from "zustand";
import type {
  AgentBackendState,
  EntitySelection,
  JobPriority,
  JobState,
  StationState,
} from "../types";

interface UIState {
  selectedEntity: EntitySelection;
  inspectorOpen: boolean;
  fullscreen: boolean;
  playbackSpeed: number;
  filters: {
    jobStates: Set<JobState>;
    jobPriorities: Set<JobPriority>;
    stationStates: Set<StationState>;
    agentStates: Set<AgentBackendState>;
  };
  selectEntity: (entity: EntitySelection) => void;
  clearSelection: () => void;
  toggleFullscreen: () => void;
  setPlaybackSpeed: (speed: number) => void;
  toggleJobStateFilter: (state: JobState) => void;
  toggleJobPriorityFilter: (priority: JobPriority) => void;
  toggleStationStateFilter: (state: StationState) => void;
  toggleAgentStateFilter: (state: AgentBackendState) => void;
  isFiltered: (entityType: string, state: string) => boolean;
}

export const useUIStore = create<UIState>((set, get) => ({
  selectedEntity: null,
  inspectorOpen: false,
  fullscreen: false,
  playbackSpeed: 1,
  filters: {
    jobStates: new Set<JobState>(),
    jobPriorities: new Set<JobPriority>(),
    stationStates: new Set<StationState>(),
    agentStates: new Set<AgentBackendState>(),
  },

  selectEntity(entity) {
    set({ selectedEntity: entity, inspectorOpen: entity !== null });
  },

  clearSelection() {
    set({ selectedEntity: null, inspectorOpen: false });
  },

  toggleFullscreen() {
    set((s) => ({ fullscreen: !s.fullscreen }));
  },

  setPlaybackSpeed(speed) {
    set({ playbackSpeed: speed });
  },

  toggleJobStateFilter(state) {
    set((s) => {
      const next = new Set(s.filters.jobStates);
      if (next.has(state)) next.delete(state);
      else next.add(state);
      return { filters: { ...s.filters, jobStates: next } };
    });
  },

  toggleJobPriorityFilter(priority) {
    set((s) => {
      const next = new Set(s.filters.jobPriorities);
      if (next.has(priority)) next.delete(priority);
      else next.add(priority);
      return { filters: { ...s.filters, jobPriorities: next } };
    });
  },

  toggleStationStateFilter(state) {
    set((s) => {
      const next = new Set(s.filters.stationStates);
      if (next.has(state)) next.delete(state);
      else next.add(state);
      return { filters: { ...s.filters, stationStates: next } };
    });
  },

  toggleAgentStateFilter(state) {
    set((s) => {
      const next = new Set(s.filters.agentStates);
      if (next.has(state)) next.delete(state);
      else next.add(state);
      return { filters: { ...s.filters, agentStates: next } };
    });
  },

  isFiltered(entityType, state) {
    const { filters } = get();
    if (entityType === "job") {
      return filters.jobStates.size > 0 && !filters.jobStates.has(state as JobState);
    }
    if (entityType === "station") {
      return filters.stationStates.size > 0 && !filters.stationStates.has(state as StationState);
    }
    if (entityType === "agent") {
      return filters.agentStates.size > 0 && !filters.agentStates.has(state as AgentBackendState);
    }
    return false;
  },
}));
