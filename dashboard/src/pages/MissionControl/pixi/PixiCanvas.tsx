// pixi/PixiCanvas.tsx — Main PixiJS canvas component
import { useRef, useMemo } from "react";
import { Application, extend } from "@pixi/react";
import { Container, Graphics, Text as PixiText } from "pixi.js";
import { Environment } from "./Environment";
import { StationGraphic, STATION_POSITIONS } from "./StationGraphic";
import { WorkerGraphic } from "./WorkerGraphic";
import { PacketGraphic } from "./PacketGraphic";
import { PipelineGraphic } from "./PipelineGraphic";
import { useEntityStore } from "../stores/entityStore";
import type { StationType, StationState } from "../types";

extend({ Container, Graphics, Text: PixiText });

const CANVAS_W = 840;
const CANVAS_H = 780;
const BG_COLOR = 0x1a2230;

// Compute worker positions around their associated station
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

// Compute job/packet positions near a station
function packetPosition(
  stationX: number,
  stationY: number,
  index: number,
  state: string,
): { x: number; y: number } {
  if (state === "queued" || state === "created") {
    // Fan out above the station
    const offset = (index - 2) * 20;
    return { x: stationX + offset, y: stationY - 50 };
  }
  if (state === "processing") {
    // Chip above station
    return { x: stationX + (index - 1) * 18, y: stationY - 35 };
  }
  // Transit: between stations
  return { x: stationX, y: stationY - 20 };
}

export function PixiCanvas() {
  const containerRef = useRef<HTMLDivElement>(null);

  const stations = useEntityStore((s) => s.stations);
  const workers = useEntityStore((s) => s.workers);
  const jobs = useEntityStore((s) => s.jobs);

  // Build station list from store, falling back to layout defaults
  const stationList = useMemo(() => {
    const storeStations = Object.values(stations);
    if (storeStations.length > 0) {
      return storeStations.map((s) => {
        const layout = STATION_POSITIONS[s.id] ??
          STATION_POSITIONS[s.type] ?? {
            x: 400,
            y: 400,
            type: s.type,
            label: s.label,
          };
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
    // Default layout when no data from backend
    return Object.entries(STATION_POSITIONS).map(([id, layout]) => ({
      id,
      type: layout.type,
      label: layout.label,
      state: "idle" as StationState,
      x: layout.x,
      y: layout.y,
      queueDepth: 0,
    }));
  }, [stations]);

  // Build worker list with positions
  const workerList = useMemo(() => {
    const ws = Object.values(workers);
    // Group workers by their primary capability to place near stations
    const stationWorkers: Record<string, typeof ws> = {};
    for (const w of ws) {
      const cap = w.capabilities[0] ?? "dispatcher";
      if (!stationWorkers[cap]) stationWorkers[cap] = [];
      stationWorkers[cap].push(w);
    }

    const result: Array<{
      worker: (typeof ws)[0];
      x: number;
      y: number;
    }> = [];

    for (const [cap, group] of Object.entries(stationWorkers)) {
      const layout = STATION_POSITIONS[cap] ?? STATION_POSITIONS.dispatcher;
      for (let i = 0; i < group.length; i++) {
        const pos = workerPosition(layout.x, layout.y, i, group.length);
        result.push({ worker: group[i], x: pos.x, y: pos.y });
      }
    }
    return result;
  }, [workers]);

  // Build job/packet list with positions
  const jobList = useMemo(() => {
    const js = Object.values(jobs);
    // Group by current station for positioning
    const stationJobs: Record<string, typeof js> = {};
    for (const j of js) {
      const sid = j.currentStationId ?? "intake";
      if (!stationJobs[sid]) stationJobs[sid] = [];
      stationJobs[sid].push(j);
    }

    const result: Array<{
      job: (typeof js)[0];
      x: number;
      y: number;
    }> = [];

    for (const [sid, group] of Object.entries(stationJobs)) {
      const layout =
        STATION_POSITIONS[sid] ?? STATION_POSITIONS.intake;
      for (let i = 0; i < group.length; i++) {
        const pos = packetPosition(layout.x, layout.y, i, group[i].state);
        result.push({ job: group[i], x: pos.x, y: pos.y });
      }
    }
    return result;
  }, [jobs]);

  return (
    <div
      ref={containerRef}
      style={{ width: "100%", height: "100%", position: "relative" }}
    >
      <Application
        resizeTo={containerRef as React.RefObject<HTMLElement>}
        background={BG_COLOR}
        antialias
        autoDensity
        resolution={window.devicePixelRatio || 1}
      >
        {/* Environment: floor, grid, vignette */}
        <pixiContainer>
          <Environment width={CANVAS_W} height={CANVAS_H} />
        </pixiContainer>

        {/* Pipeline routes */}
        <pixiContainer>
          <PipelineGraphic />
        </pixiContainer>

        {/* Stations */}
        <pixiContainer>
          {stationList.map((s) => (
            <StationGraphic
              key={s.id}
              id={s.id}
              type={s.type}
              label={s.label}
              state={s.state}
              x={s.x}
              y={s.y}
              queueDepth={s.queueDepth}
            />
          ))}
        </pixiContainer>

        {/* Workers */}
        <pixiContainer>
          {workerList.map((w) => (
            <WorkerGraphic
              key={w.worker.id}
              worker={w.worker}
              targetX={w.x}
              targetY={w.y}
            />
          ))}
        </pixiContainer>

        {/* Packets (jobs) */}
        <pixiContainer>
          {jobList.map((j) => (
            <PacketGraphic
              key={j.job.id}
              job={j.job}
              x={j.x}
              y={j.y}
            />
          ))}
        </pixiContainer>
      </Application>
    </div>
  );
}
