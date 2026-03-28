// Mission Control visualization types
// These are visualization-layer types, not direct Laddr backend types.
// See spec: docs/superpowers/specs/2026-03-26-mission-control-design.md

// --- Agent (Crew Bot) ---

export type AgentBackendState =
  | "idle"
  | "claiming_job"
  | "working"
  | "blocked"
  | "errored"
  | "offline";

export type AgentAnimationState =
  | "moving_to_pickup"
  | "moving_to_station"
  | "handoff";

export type AgentState = AgentBackendState | AgentAnimationState;

export interface MCAgent {
  id: string;
  name?: string;
  role: string;
  state: AgentState;
  currentJobId?: string;
  efficiency?: number;
  recentJobIds?: string[];
}

// --- Job ---

export type JobPriority = "low" | "normal" | "high" | "critical";
export type WorkType =
  | "llm"
  | "tool"
  | "code"
  | "review"
  | "orchestration"
  | "wait"
  | "retry"
  | "mixed";

export type JobState =
  | "created"
  | "queued"
  | "assigned"
  | "in_transit"
  | "processing"
  | "handoff"
  | "completed"
  | "failed"
  | "retrying"
  | "cancelled"
  | "paused";

export interface MCJobMetadata {
  summary?: string;
  goal?: string;
  workType?: WorkType;
  currentStep?: string;
  latestActivity?: string;
  latestActivityAt?: string;
  retryCount?: number;
  toolNames?: string[];
  filePaths?: string[];
  tokenCount?: number;
  costUsd?: number;
  estimatedProgress?: number;
  blockedReason?: string;
}

export interface MCJobHistoryEvent {
  at: string;
  event: string;
  detail?: string;
  workType?: WorkType;
  stationId?: string;
  workerId?: string;
}

export interface MCJob {
  id: string;
  type: string;
  priority: JobPriority;
  state: JobState;
  assignedAgentId?: string;
  currentStationId?: string;
  path: string[];
  progress?: number;
  createdAt: string;
  updatedAt: string;
  metadata?: MCJobMetadata;
  history: MCJobHistoryEvent[];
}

// --- Station ---

export type StationType =
  | "intake"
  | "dispatcher"
  | "llm"
  | "tool"
  | "code"
  | "supervisor"
  | "error"
  | "output";

export type StationState =
  | "idle"
  | "active"
  | "saturated"
  | "blocked"
  | "errored"
  | "offline";

export interface MCStation {
  id: string;
  type: StationType;
  label: string;
  state: StationState;
  capacity: number;
  queueDepth: number;
  activeJobIds: string[];
  workerId?: string;
}

// --- Worker ---

export type WorkerStatus = "online" | "draining" | "offline";

export interface MCWorker {
  id: string;
  name?: string;
  capabilities: string[];
  activeJobs: number;
  maxJobs: number;
  status: WorkerStatus;
}

export interface MCWorkerActivity {
  workerId: string;
  stationId?: string;
  jobId?: string;
  message: string;
  kind: WorkType | "blocked" | "error";
  at: string;
  ttlMs: number;
}

export interface WorkMixMetrics {
  llm: number;
  tool: number;
  code: number;
  review: number;
  orchestration: number;
  wait: number;
  retry: number;
}

// --- Metrics ---

export interface MCMetrics {
  totalJobs: number;
  activeAgents: number;
  errorCount: number;
  retryCount: number;
  realQueueDepth?: number;
  overflowActive?: boolean;
  dailyVeniceSpend?: number;
  dailyVeniceBudget?: number;
  workMix?: WorkMixMetrics;
  dominantMode?: keyof WorkMixMetrics;
  jobsBlocked?: number;
}

// --- WebSocket Events ---

export interface MCSnapshot {
  agents: MCAgent[];
  jobs: MCJob[];
  stations: MCStation[];
  workers: MCWorker[];
  queues: Record<string, number>;
  metrics: MCMetrics;
}

export type MCServerEvent =
  | { type: "snapshot"; data: MCSnapshot }
  | { type: "agent_updated"; agent: MCAgent }
  | { type: "job_created"; job: MCJob }
  | { type: "job_updated"; job: MCJob }
  | { type: "job_activity"; jobId: string; event: MCJobHistoryEvent; patch?: Partial<MCJobMetadata> }
  | { type: "job_completed"; jobId: string; at: string }
  | { type: "job_failed"; jobId: string; reason?: string; at: string }
  | { type: "job_assigned"; jobId: string; agentId: string; stationId: string }
  | { type: "job_handoff"; jobId: string; fromStationId: string; toStationId: string }
  | { type: "station_updated"; station: MCStation }
  | { type: "worker_registered"; worker: MCWorker }
  | { type: "worker_activity"; activity: MCWorkerActivity }
  | { type: "worker_deregistered"; workerId: string }
  | { type: "metrics_updated"; metrics: MCMetrics }
  | { type: "command_ack"; action: string; success: boolean; error?: string };

export type MCCommandAction =
  | "pause_job"
  | "resume_job"
  | "retry_job"
  | "kill_job"
  | "reassign_job"
  | "drain_station"
  | "resume_station";

export interface MCCommand {
  type: "command";
  action: MCCommandAction;
  jobId?: string;
  stationId?: string;
  targetWorkerId?: string;
}

// --- Scene Positioning ---

export interface Vec3 {
  x: number;
  y: number;
  z: number;
}

export interface SceneEntity {
  entityId: string;
  entityType: "agent" | "job" | "station";
  position: Vec3;
  targetPosition?: Vec3;
}

// --- UI State ---

export type EntitySelection = {
  id: string;
  type: "agent" | "job" | "station" | "worker";
} | null;

export interface FilterState {
  jobStates: Set<JobState>;
  jobPriorities: Set<JobPriority>;
  stationStates: Set<StationState>;
  agentStates: Set<AgentBackendState>;
}
