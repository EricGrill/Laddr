import { useState } from "react";
import { useEntityStore } from "../stores/entityStore";
import { useTransportStore } from "../stores/transportStore";
import { useUIStore } from "../stores/uiStore";
import { ConfirmDialog } from "./ConfirmDialog";

export function StationInspector({ stationId }: { stationId: string }) {
  const station = useEntityStore((s) => s.stations[stationId]);
  const send = useTransportStore((s) => s.send);
  const selectEntity = useUIStore((s) => s.selectEntity);
  const [confirmDrain, setConfirmDrain] = useState(false);

  if (!station) return <div className="text-gray-500 text-xs">Station not found</div>;

  return (
    <div className="space-y-3">
      <div>
        <div className="text-[10px] text-gray-500 uppercase">Label</div>
        <div className="text-sm">{station.label}</div>
      </div>
      <div className="flex gap-4">
        <div>
          <div className="text-[10px] text-gray-500 uppercase">Type</div>
          <div className="text-sm">{station.type}</div>
        </div>
        <div>
          <div className="text-[10px] text-gray-500 uppercase">State</div>
          <div className="text-sm">{station.state}</div>
        </div>
      </div>
      <div>
        <div className="text-[10px] text-gray-500 uppercase">Queue Depth</div>
        <div className="w-full bg-gray-800 rounded h-2 mt-1">
          <div
            className={`h-2 rounded ${station.queueDepth > station.capacity * 0.8 ? "bg-red-500" : "bg-cyan-500"}`}
            style={{ width: `${Math.min((station.queueDepth / Math.max(station.capacity, 1)) * 100, 100)}%` }}
          />
        </div>
        <div className="text-[10px] text-gray-500 mt-0.5">{station.queueDepth} / {station.capacity}</div>
      </div>
      {station.activeJobIds.length > 0 && (
        <div>
          <div className="text-[10px] text-gray-500 uppercase mb-1">Active Jobs</div>
          <div className="space-y-0.5 max-h-24 overflow-y-auto">
            {station.activeJobIds.map((jid) => (
              <button
                key={jid}
                onClick={() => selectEntity({ id: jid, type: "job" })}
                className="block text-[10px] text-cyan-400 hover:underline font-mono"
              >
                {jid}
              </button>
            ))}
          </div>
        </div>
      )}

      {/* Actions */}
      {station.workerId && (
        <div className="pt-2 border-t border-[#2a3050]">
          <div className="text-[10px] text-gray-500 uppercase mb-2">Actions</div>
          <div className="flex gap-1.5">
            {station.state !== "blocked" ? (
              <button onClick={() => setConfirmDrain(true)} className="px-2 py-1 text-[10px] bg-yellow-600/20 text-yellow-400 rounded border border-yellow-600/30 hover:bg-yellow-600/30">
                Drain
              </button>
            ) : (
              <button
                onClick={() => send({ type: "command", action: "resume_station", stationId })}
                className="px-2 py-1 text-[10px] bg-green-600/20 text-green-400 rounded border border-green-600/30 hover:bg-green-600/30"
              >
                Resume
              </button>
            )}
          </div>
        </div>
      )}

      {confirmDrain && (
        <ConfirmDialog
          title="Drain Station"
          message={`Stop station "${station.label}" from accepting new jobs?`}
          confirmLabel="Drain"
          onConfirm={() => { send({ type: "command", action: "drain_station", stationId }); setConfirmDrain(false); }}
          onCancel={() => setConfirmDrain(false)}
        />
      )}
    </div>
  );
}
