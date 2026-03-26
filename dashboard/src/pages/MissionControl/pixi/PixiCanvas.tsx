// pixi/PixiCanvas.tsx — Main PixiJS canvas component (imperative, no @pixi/react)
import { useRef, useEffect } from 'react';
import { Application, Container } from 'pixi.js';
import { createEnvironment } from './Environment';
import { createStation, updateStation, tickStation, STATION_POSITIONS, type StationConfig } from './StationGraphic';
import { createWorker, updateWorker, getRoleColor, setWorkerPosition } from './WorkerGraphic';
import { createPacket, updatePacket } from './PacketGraphic';
import { createPipelines, updatePipelineFlow } from './PipelineGraphic';
import { useEntityStore } from '../stores/entityStore';
import { useUIStore } from '../stores/uiStore';
import type { StationType, StationState, MCWorker, MCJob } from '../types';

const CANVAS_W = 1060;
const CANVAS_H = 780;
const BG_COLOR = 0x1a2230;

function workerPosition(
  stationX: number,
  stationY: number,
  index: number,
  total: number,
): { x: number; y: number } {
  const spacing = 28;
  const cols = Math.ceil(Math.sqrt(total));
  const col = index % cols;
  const row = Math.floor(index / cols);
  return {
    x: stationX - ((cols - 1) * spacing) / 2 + col * spacing,
    y: stationY + 50 + row * spacing,
  };
}

function packetPosition(
  stationX: number,
  stationY: number,
  index: number,
  state: string,
): { x: number; y: number } {
  // Grid layout around station — max 6 columns, wrap to rows
  const cols = 6;
  const col = index % cols;
  const row = Math.floor(index / cols);
  const spacingX = 18;
  const spacingY = 16;
  const offsetX = (col - (cols - 1) / 2) * spacingX;
  const offsetY = -45 - row * spacingY;

  if (state === 'queued' || state === 'created') {
    return { x: stationX + offsetX, y: stationY + offsetY };
  }
  if (state === 'processing') {
    return { x: stationX + offsetX * 0.6, y: stationY - 35 - row * 14 };
  }
  return { x: stationX + offsetX * 0.3, y: stationY - 25 };
}

function buildStationList(stations: Record<string, { id: string; type: string; label: string; state: string; queueDepth: number }>): StationConfig[] {
  const storeStations = Object.values(stations);
  if (storeStations.length > 0) {
    return storeStations.map((s) => {
      const layout = STATION_POSITIONS[s.id] ??
        STATION_POSITIONS[s.type] ?? { x: 400, y: 400, type: s.type, label: s.label };
      return {
        id: s.id,
        type: s.type as StationType,
        label: s.label || layout.label,
        state: s.state as StationState,
        x: layout.x,
        y: layout.y,
        queueDepth: s.queueDepth,
      };
    });
  }
  return Object.entries(STATION_POSITIONS).map(([id, layout]) => ({
    id,
    type: layout.type,
    label: layout.label,
    state: 'idle' as StationState,
    x: layout.x,
    y: layout.y,
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
      const stationList = buildStationList(state.stations);
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
        const layout = STATION_POSITIONS[cap] ?? STATION_POSITIONS.dispatcher;
        for (let i = 0; i < group.length; i++) {
          const w = group[i];
          if (!workerContainers.has(w.id)) {
            const roleColor = getRoleColor(w.capabilities);
            const wc = createWorker(w.id, roleColor);
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
      const currentIds = new Set(jobs.map((j) => j.id));

      // Remove old
      for (const [id, pc] of packetContainers) {
        if (!currentIds.has(id)) {
          packetLayer.removeChild(pc);
          pc.destroy({ children: true });
          packetContainers.delete(id);
        }
      }

      // Create new — only for active jobs (skip completed/cancelled/failed)
      const HIDDEN_STATES = new Set(['completed', 'cancelled', 'failed']);
      for (const j of jobs) {
        if (HIDDEN_STATES.has(j.state)) continue;
        if (!packetContainers.has(j.id)) {
          const pc = createPacket(j.type, j.priority, j.state, j.progress ?? 0);
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

      // Scale the stage so the scene fills the viewport
      function fitStage() {
        const w = app.screen.width;
        const h = app.screen.height;
        const scaleX = w / CANVAS_W;
        const scaleY = h / CANVAS_H;
        const scale = Math.min(scaleX, scaleY);
        app.stage.scale.set(scale);
        // Center the scene
        app.stage.x = (w - CANVAS_W * scale) / 2;
        app.stage.y = (h - CANVAS_H * scale) / 2;
      }
      fitStage();
      app.renderer.on('resize', fitStage);

      // Build scene
      const environmentLayer = createEnvironment(CANVAS_W, CANVAS_H);
      app.stage.addChild(environmentLayer);

      pipelineLayer = createPipelines();
      app.stage.addChild(pipelineLayer);

      app.stage.addChild(stationLayer);
      app.stage.addChild(workerLayer);
      app.stage.addChild(packetLayer);

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
          const layout = STATION_POSITIONS[cap] ?? STATION_POSITIONS.dispatcher;
          for (let i = 0; i < group.length; i++) {
            const w = group[i];
            const wc = workerContainers.get(w.id);
            if (!wc) continue;
            const pos = workerPosition(layout.x, layout.y, i, group.length);
            updateWorker(wc, pos.x, pos.y, w.status, w.activeJobs, elapsed, dt);
          }
        }

        // Tick packets
        const jobs = Object.values(state.jobs);
        const stationJobGroups: Record<string, MCJob[]> = {};
        for (const j of jobs) {
          const sid = j.currentStationId ?? 'intake';
          if (!stationJobGroups[sid]) stationJobGroups[sid] = [];
          stationJobGroups[sid].push(j);
        }
        for (const [sid, group] of Object.entries(stationJobGroups)) {
          const layout = STATION_POSITIONS[sid] ?? STATION_POSITIONS.intake;
          for (let i = 0; i < group.length; i++) {
            const j = group[i];
            const pc = packetContainers.get(j.id);
            if (!pc) continue;
            const pos = packetPosition(layout.x, layout.y, i, j.state);
            updatePacket(pc, pos.x, pos.y, j.state, j.progress ?? 0, elapsed);
          }
        }

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
