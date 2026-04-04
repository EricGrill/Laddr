// pixi/PixiCanvas.tsx — Main PixiJS canvas component (imperative, no @pixi/react)
import { useRef, useEffect } from 'react';
import { Application, Container, Text, TextStyle } from 'pixi.js';
import { createEnvironment } from './Environment';
import { createStation, updateStation, tickStation, STATION_POSITIONS, type StationConfig } from './StationGraphic';
import { createWorker, updateWorker, updateWorkerBubble, getRoleColor, setWorkerPosition } from './WorkerGraphic';
import { createPacket, updatePacket } from './PacketGraphic';
import { createPipelines, updatePipelineFlow } from './PipelineGraphic';
import { useEntityStore } from '../stores/entityStore';
import { useUIStore } from '../stores/uiStore';
import type { StationType, StationState, MCWorker, MCJob, WorkMixMetrics } from '../types';

const BG_COLOR = 0x1a2230;
const DEFAULT_WORK_MIX: WorkMixMetrics = {
  llm: 0,
  tool: 0,
  code: 0,
  review: 0,
  orchestration: 0,
  wait: 0,
  retry: 0,
};

/** Resolve a station layout position to screen coordinates */
function resolvePos(id: string, screenW: number, screenH: number): { x: number; y: number } {
  const layout = STATION_POSITIONS[id] ?? STATION_POSITIONS.dispatcher;
  return { x: layout.x * screenW, y: layout.y * screenH };
}

function workerPosition(
  stationX: number,
  stationY: number,
  index: number,
  total: number,
): { x: number; y: number } {
  const spacing = 80;
  const cols = Math.ceil(Math.sqrt(total));
  const col = index % cols;
  const row = Math.floor(index / cols);
  return {
    x: stationX - ((cols - 1) * spacing) / 2 + col * spacing,
    y: stationY + 80 + row * spacing,
  };
}

function packetPosition(
  stationX: number,
  stationY: number,
  index: number,
  state: string,
): { x: number; y: number } {
  // Simple horizontal row above station, max 5 shown
  const offsetX = (index - 2) * 40;

  if (state === 'queued' || state === 'created') {
    return { x: stationX + offsetX, y: stationY - 75 };
  }
  if (state === 'processing') {
    return { x: stationX + offsetX, y: stationY - 60 };
  }
  return { x: stationX + offsetX * 0.5, y: stationY - 50 };
}

function buildStationList(
  stations: Record<string, { id: string; type: string; label: string; state: string; queueDepth: number }>,
  screenW: number,
  screenH: number,
): StationConfig[] {
  const storeStations = Object.values(stations);
  if (storeStations.length > 0) {
    return storeStations.map((s) => {
      const layout = STATION_POSITIONS[s.id] ??
        STATION_POSITIONS[s.type] ?? { x: 0.5, y: 0.5, type: s.type, label: s.label };
      return {
        id: s.id,
        type: s.type as StationType,
        label: s.label || layout.label,
        state: s.state as StationState,
        x: layout.x * screenW,
        y: layout.y * screenH,
        queueDepth: s.queueDepth,
      };
    });
  }
  return Object.entries(STATION_POSITIONS).map(([id, layout]) => ({
    id,
    type: layout.type,
    label: layout.label,
    state: 'idle' as StationState,
    x: layout.x * screenW,
    y: layout.y * screenH,
    queueDepth: 0,
  }));
}

export function PixiCanvas() {
  const containerRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (!containerRef.current) return;

    const app = new Application();
    let destroyed = false;

    // Scene object maps
    const stationContainers = new Map<string, Container>();
    const workerContainers = new Map<string, Container>();
    const packetContainers = new Map<string, Container>();

    // Layers
    const stationLayer = new Container();
    const workerLayer = new Container();
    const packetLayer = new Container();
    let pipelineLayer: Container;
    let elapsed = 0;
    let unsubStore: (() => void) | undefined;

    const selectEntity = useUIStore.getState().selectEntity;

    // --- Sync functions ---

    function syncStations() {
      const state = useEntityStore.getState();
      const stationList = buildStationList(state.stations, app.screen.width, app.screen.height);
      const currentIds = new Set(stationList.map((s) => s.id));

      // Remove old
      for (const [id, sc] of stationContainers) {
        if (!currentIds.has(id)) {
          stationLayer.removeChild(sc);
          sc.destroy({ children: true });
          stationContainers.delete(id);
        }
      }

      // Create or update
      for (const s of stationList) {
        let sc = stationContainers.get(s.id);
        if (!sc) {
          sc = createStation(s, (id) => selectEntity({ id, type: 'station' }));
          stationContainers.set(s.id, sc);
          stationLayer.addChild(sc);
        } else {
          updateStation(sc, s.state, s.queueDepth);
        }
      }
    }

    function syncWorkers() {
      const state = useEntityStore.getState();
      const workers = Object.values(state.workers);
      const currentIds = new Set(workers.map((w) => w.id));

      // Remove old
      for (const [id, wc] of workerContainers) {
        if (!currentIds.has(id)) {
          workerLayer.removeChild(wc);
          wc.destroy({ children: true });
          workerContainers.delete(id);
        }
      }

      // Create new workers
      const stationWorkerGroups: Record<string, MCWorker[]> = {};
      for (const w of workers) {
        const cap = w.capabilities[0] ?? 'dispatcher';
        if (!stationWorkerGroups[cap]) stationWorkerGroups[cap] = [];
        stationWorkerGroups[cap].push(w);
      }

      for (const [cap, group] of Object.entries(stationWorkerGroups)) {
        const layout = resolvePos(cap, app.screen.width, app.screen.height);
        for (let i = 0; i < group.length; i++) {
          const w = group[i];
          if (!workerContainers.has(w.id)) {
            const roleColor = getRoleColor(w.capabilities);
            const wc = createWorker(w.id, roleColor, w.capabilities);
            const pos = workerPosition(layout.x, layout.y, i, group.length);
            setWorkerPosition(wc, pos.x, pos.y);
            workerContainers.set(w.id, wc);
            workerLayer.addChild(wc);
          }
        }
      }
    }

    function syncPackets() {
      const state = useEntityStore.getState();
      const jobs = Object.values(state.jobs);

      // Only active jobs, max 5 per station to keep it clean
      const HIDDEN_STATES = new Set(['completed', 'cancelled', 'failed', 'paused']);
      const activeJobs = jobs.filter((j) => !HIDDEN_STATES.has(j.state));

      // Group by station and limit to 5 per station
      const byStation: Record<string, typeof activeJobs> = {};
      for (const j of activeJobs) {
        const sid = j.currentStationId ?? 'intake';
        if (!byStation[sid]) byStation[sid] = [];
        if (byStation[sid].length < 5) byStation[sid].push(j);
      }
      const visibleJobs = Object.values(byStation).flat();
      const visibleIds = new Set(visibleJobs.map((j) => j.id));

      // Remove packets that are no longer visible
      for (const [id, pc] of packetContainers) {
        if (!visibleIds.has(id)) {
          packetLayer.removeChild(pc);
          pc.destroy({ children: true });
          packetContainers.delete(id);
        }
      }

      for (const j of visibleJobs) {
        if (!packetContainers.has(j.id)) {
          const jobName = j.id.length > 12 ? j.id.slice(0, 12) : j.id;
          const pc = createPacket(j.type, j.priority, j.state, j.progress ?? 0, jobName);
          packetContainers.set(j.id, pc);
          packetLayer.addChild(pc);
        }
      }
    }

    // --- Init ---

    const initPromise = app.init({
      background: BG_COLOR,
      resizeTo: containerRef.current!,
      antialias: true,
      autoDensity: true,
      resolution: window.devicePixelRatio || 1,
    }).then(() => {
      if (destroyed) {
        app.destroy(true);
        return;
      }

      containerRef.current!.appendChild(app.canvas);

      // No scaling — scene coordinates = screen coordinates
      // Station positions are defined as fractions in STATION_POSITIONS
      // and get multiplied by actual screen size in syncStations
      app.stage.scale.set(1);
      app.stage.x = 0;
      app.stage.y = 0;

      // Build scene — use actual screen dimensions
      const environmentLayer = createEnvironment(app.screen.width, app.screen.height);
      app.stage.addChild(environmentLayer);

      pipelineLayer = createPipelines();
      app.stage.addChild(pipelineLayer);

      app.stage.addChild(stationLayer);
      app.stage.addChild(workerLayer);
      app.stage.addChild(packetLayer);

      // --- Summary text overlay ---
      const overlayContainer = new Container();
      app.stage.addChild(overlayContainer);

      const activeJobsText = new Text({
        text: 'ACTIVE JOBS: 0',
        style: new TextStyle({
          fontSize: 28,
          fill: '#63d7e6',
          fontFamily: 'Arial, Helvetica, sans-serif',
          fontWeight: 'bold',
        }),
      });
      activeJobsText.x = 24;
      activeJobsText.y = 16;
      overlayContainer.addChild(activeJobsText);

      const workersText = new Text({
        text: 'WORKERS: 0 online',
        style: new TextStyle({
          fontSize: 20,
          fill: '#cccccc',
          fontFamily: 'Arial, Helvetica, sans-serif',
        }),
      });
      workersText.x = 24;
      workersText.y = 46;
      overlayContainer.addChild(workersText);

      const queueDepthText = new Text({
        text: 'QUEUE DEPTH: 0',
        style: new TextStyle({
          fontSize: 20,
          fill: '#cccccc',
          fontFamily: 'Arial, Helvetica, sans-serif',
        }),
      });
      queueDepthText.x = 24;
      queueDepthText.y = 70;
      overlayContainer.addChild(queueDepthText);

      const workMixText = new Text({
        text: 'WORK MIX: orchestration',
        style: new TextStyle({
          fontSize: 20,
          fill: '#cccccc',
          fontFamily: 'Arial, Helvetica, sans-serif',
        }),
      });
      workMixText.x = 24;
      workMixText.y = 94;
      overlayContainer.addChild(workMixText);

      const blockedText = new Text({
        text: 'BLOCKED: 0',
        style: new TextStyle({
          fontSize: 20,
          fill: '#cccccc',
          fontFamily: 'Arial, Helvetica, sans-serif',
        }),
      });
      blockedText.x = 24;
      blockedText.y = 118;
      overlayContainer.addChild(blockedText);

      // Initial sync
      syncStations();
      syncWorkers();
      syncPackets();

      // Subscribe to store changes
      unsubStore = useEntityStore.subscribe(() => {
        if (destroyed) return;
        syncStations();
        syncWorkers();
        syncPackets();
      });

      // Animation ticker
      app.ticker.add((ticker) => {
        const dt = ticker.deltaMS / 1000;
        elapsed += dt;

        // Tick station animations
        for (const sc of stationContainers.values()) {
          tickStation(sc, elapsed);
        }

        // Tick workers (position lerp + visuals)
        const state = useEntityStore.getState();
        const workers = Object.values(state.workers);
        const stationWorkerGroups: Record<string, MCWorker[]> = {};
        for (const w of workers) {
          const cap = w.capabilities[0] ?? 'dispatcher';
          if (!stationWorkerGroups[cap]) stationWorkerGroups[cap] = [];
          stationWorkerGroups[cap].push(w);
        }
        for (const [cap, group] of Object.entries(stationWorkerGroups)) {
          const layout = resolvePos(cap, app.screen.width, app.screen.height);
          const stationKey = Object.keys(STATION_POSITIONS).includes(cap) ? cap : `station-${cap}`;
          const stationJobs = Object.values(state.jobs).filter((j) => {
            if (j.state === 'completed' || j.state === 'cancelled' || j.state === 'failed') return false;
            const workType = j.metadata?.workType;
            return j.currentStationId === stationKey || workType === cap;
          });
          const primaryJob = stationJobs[0];
          const rawActivity = primaryJob?.metadata?.latestActivity;
          const rawStep = primaryJob?.metadata?.currentStep;
          const activityStr = typeof rawActivity === 'string' ? rawActivity : null;
          const stepStr = typeof rawStep === 'string' ? rawStep : null;
          const bubbleMessage = activityStr
            ?? stepStr
            ?? (group.some((w) => w.activeJobs > 0) ? `Working ${String(cap)}` : null);
          const bubbleKind = String(primaryJob?.metadata?.workType ?? cap);
          for (let i = 0; i < group.length; i++) {
            const w = group[i];
            const wc = workerContainers.get(w.id);
            if (!wc) continue;
            const pos = workerPosition(layout.x, layout.y, i, group.length);
            updateWorker(wc, pos.x, pos.y, w.status, w.activeJobs, elapsed, dt);
            updateWorkerBubble(wc, w.activeJobs > 0 ? bubbleMessage : null, bubbleKind);
          }
        }

        // Tick packets — only visible ones (max 5 per station)
        const allJobs = Object.values(state.jobs);
        const HIDDEN = new Set(['completed', 'cancelled', 'failed', 'paused']);
        const activeJobs = allJobs.filter((j) => !HIDDEN.has(j.state));

        const stationJobGroups: Record<string, MCJob[]> = {};
        for (const j of activeJobs) {
          const sid = j.currentStationId ?? 'intake';
          if (!stationJobGroups[sid]) stationJobGroups[sid] = [];
          stationJobGroups[sid].push(j);
        }

        // Update station queue badges with real counts
        for (const [sid, sc] of stationContainers) {
          const count = stationJobGroups[sid]?.length ?? 0;
          const stationData = state.stations[sid];
          if (stationData) {
            updateStation(sc, stationData.state as StationState, count);
          }
        }

        for (const [sid, group] of Object.entries(stationJobGroups)) {
          const layout = resolvePos(sid, app.screen.width, app.screen.height);
          const visible = group.slice(0, 5); // only 5 rendered per station
          for (let i = 0; i < visible.length; i++) {
            const j = visible[i];
            const pc = packetContainers.get(j.id);
            if (!pc) continue;
            const pos = packetPosition(layout.x, layout.y, i, j.state);
            updatePacket(pc, pos.x, pos.y, j.state, j.progress ?? 0, elapsed);
          }
        }

        // Update summary overlay
        const onlineWorkers = workers.filter((w) => w.status !== 'offline').length;
        const totalActiveJobs = allJobs.filter((j) => !HIDDEN.has(j.state)).length;
        const totalQueueDepth = allJobs.filter((j) => j.state === 'queued' || j.state === 'created').length;
        activeJobsText.text = `ACTIVE JOBS: ${totalActiveJobs}`;
        workersText.text = `WORKERS: ${onlineWorkers} online`;
        queueDepthText.text = `QUEUE DEPTH: ${totalQueueDepth}`;
        const workMix = state.metrics.workMix ?? DEFAULT_WORK_MIX;
        const workMixSummary = Object.entries(workMix)
          .filter(([, value]) => value > 0)
          .sort((a, b) => b[1] - a[1])
          .slice(0, 3)
          .map(([key, value]) => `${key}:${value}`)
          .join('  ');
        workMixText.text = `WORK MIX: ${(state.metrics.dominantMode ?? 'orchestration').toUpperCase()}${workMixSummary ? `  ${workMixSummary}` : ''}`;
        blockedText.text = `BLOCKED: ${state.metrics.jobsBlocked ?? 0}`;

        // Tick pipeline flow dots
        updatePipelineFlow(pipelineLayer, dt);
      });
    });

    return () => {
      destroyed = true;
      unsubStore?.();
      initPromise.then(() => {
        app.destroy(true);
      });
    };
  }, []);

  return (
    <div
      ref={containerRef}
      style={{ width: '100%', height: '100%', position: 'relative' }}
    />
  );
}
