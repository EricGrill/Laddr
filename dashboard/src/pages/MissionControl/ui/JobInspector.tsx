import { useState } from "react";
import { useEntityStore } from "../stores/entityStore";
import { useTransportStore } from "../stores/transportStore";
import { useUIStore } from "../stores/uiStore";
import { ConfirmDialog } from "./ConfirmDialog";

export function JobInspector({ jobId }: { jobId: string }) {
  const job = useEntityStore((s) => s.jobs[jobId]);
  const send = useTransportStore((s) => s.send);
  const selectEntity = useUIStore((s) => s.selectEntity);
  const [confirmAction, setConfirmAction] = useState<string | null>(null);

  if (!job) return <div className="text-gray-500 text-xs">Job not found</div>;

  const meta = job.metadata ?? {};
  const createdAt = job.createdAt ? new Date(job.createdAt) : null;
  const updatedAt = job.updatedAt ? new Date(job.updatedAt) : null;
  const runtimeMs =
    createdAt && updatedAt && !Number.isNaN(createdAt.getTime()) && !Number.isNaN(updatedAt.getTime())
      ? Math.max(0, updatedAt.getTime() - createdAt.getTime())
      : null;

  function formatRuntime(ms: number | null) {
    if (ms == null) return "—";
    const totalSeconds = Math.floor(ms / 1000);
    const minutes = Math.floor(totalSeconds / 60);
    const seconds = totalSeconds % 60;
    if (minutes > 0) return `${minutes}m ${seconds}s`;
    return `${seconds}s`;
  }

  function execAction(action: string) {
    send({ type: "command", action: action as any, jobId });
  }

  return (
    <div className="space-y-3">
      <div>
        <div className="text-[10px] text-gray-500 uppercase">Summary</div>
        <div className="text-sm text-white/90">{meta.summary ?? job.type}</div>
      </div>
      {meta.goal && (
        <div>
          <div className="text-[10px] text-gray-500 uppercase">Goal</div>
          <div className="text-xs text-gray-300 leading-relaxed">{meta.goal}</div>
        </div>
      )}
      <div>
        <div className="text-[10px] text-gray-500 uppercase">ID</div>
        <div className="text-sm font-mono">{job.id}</div>
      </div>
      <div className="flex gap-4 flex-wrap">
        <div>
          <div className="text-[10px] text-gray-500 uppercase">Type</div>
          <div className="text-sm">{job.type}</div>
        </div>
        <div>
          <div className="text-[10px] text-gray-500 uppercase">Priority</div>
          <div className="text-sm">{job.priority}</div>
        </div>
        {meta.workType && (
          <div>
            <div className="text-[10px] text-gray-500 uppercase">Work Type</div>
            <div className="text-sm">{meta.workType}</div>
          </div>
        )}
      </div>
      <div>
        <div className="text-[10px] text-gray-500 uppercase">State</div>
        <div className="text-sm">{job.state}</div>
      </div>
      <div className="flex gap-4 flex-wrap">
        <div>
          <div className="text-[10px] text-gray-500 uppercase">Current Step</div>
          <div className="text-sm">{meta.currentStep ?? "Queued"}</div>
        </div>
        <div>
          <div className="text-[10px] text-gray-500 uppercase">Runtime</div>
          <div className="text-sm">{formatRuntime(runtimeMs)}</div>
        </div>
        <div>
          <div className="text-[10px] text-gray-500 uppercase">Retries</div>
          <div className="text-sm">{meta.retryCount ?? 0}</div>
        </div>
      </div>
      {meta.latestActivity && (
        <div>
          <div className="text-[10px] text-gray-500 uppercase">Latest Activity</div>
          <div className="text-sm text-cyan-300">{meta.latestActivity}</div>
        </div>
      )}
      {job.assignedAgentId && (
        <div>
          <div className="text-[10px] text-gray-500 uppercase">Agent</div>
          <button
            onClick={() => selectEntity({ id: job.assignedAgentId!, type: "agent" })}
            className="text-sm text-cyan-400 hover:underline"
          >
            {job.assignedAgentId}
          </button>
        </div>
      )}
      {job.currentStationId && (
        <div>
          <div className="text-[10px] text-gray-500 uppercase">Station</div>
          <button
            onClick={() => selectEntity({ id: job.currentStationId!, type: "station" })}
            className="text-sm text-cyan-400 hover:underline"
          >
            {job.currentStationId}
          </button>
        </div>
      )}
      {job.progress != null && (
        <div>
          <div className="text-[10px] text-gray-500 uppercase">Progress</div>
          <div className="w-full bg-gray-800 rounded h-1.5 mt-1">
            <div className="bg-cyan-400 h-1.5 rounded" style={{ width: `${job.progress * 100}%` }} />
          </div>
        </div>
      )}
      {meta.toolNames && meta.toolNames.length > 0 && (
        <div>
          <div className="text-[10px] text-gray-500 uppercase mb-1">Tools</div>
          <div className="flex flex-wrap gap-1">
            {meta.toolNames.map((tool) => (
              <span key={tool} className="px-1.5 py-0.5 rounded bg-cyan-500/10 border border-cyan-500/20 text-[10px] text-cyan-200">
                {tool}
              </span>
            ))}
          </div>
        </div>
      )}
      {meta.filePaths && meta.filePaths.length > 0 && (
        <div>
          <div className="text-[10px] text-gray-500 uppercase mb-1">Files</div>
          <div className="space-y-0.5 max-h-20 overflow-y-auto">
            {meta.filePaths.slice(0, 6).map((file) => (
              <div key={file} className="text-[10px] font-mono text-gray-300">
                {file}
              </div>
            ))}
          </div>
        </div>
      )}
      {(meta.tokenCount != null || meta.costUsd != null) && (
        <div className="flex gap-4 flex-wrap">
          {meta.tokenCount != null && (
            <div>
              <div className="text-[10px] text-gray-500 uppercase">Tokens</div>
              <div className="text-sm">{meta.tokenCount}</div>
            </div>
          )}
          {meta.costUsd != null && (
            <div>
              <div className="text-[10px] text-gray-500 uppercase">Cost</div>
              <div className="text-sm">${meta.costUsd.toFixed(3)}</div>
            </div>
          )}
        </div>
      )}
      {job.history.length > 0 && (
        <div>
          <div className="text-[10px] text-gray-500 uppercase mb-1">Recent History</div>
          <div className="space-y-1 max-h-32 overflow-y-auto">
            {job.history.slice(-8).reverse().map((h, i) => (
              <div key={i} className="text-[10px] text-gray-500">
                <span className="text-gray-400">{h.event}</span>
                {h.detail && <span className="ml-1">— {h.detail}</span>}
              </div>
            ))}
          </div>
        </div>
      )}

      {/* Actions */}
      <div className="pt-2 border-t border-[#2a3050]">
        <div className="text-[10px] text-gray-500 uppercase mb-2">Actions</div>
        <div className="flex flex-wrap gap-1.5">
          {job.state === "processing" && (
            <button onClick={() => execAction("pause_job")} className="px-2 py-1 text-[10px] bg-yellow-600/20 text-yellow-400 rounded border border-yellow-600/30 hover:bg-yellow-600/30">
              Pause
            </button>
          )}
          {job.state === "paused" && (
            <button onClick={() => execAction("resume_job")} className="px-2 py-1 text-[10px] bg-green-600/20 text-green-400 rounded border border-green-600/30 hover:bg-green-600/30">
              Resume
            </button>
          )}
          {job.state === "failed" && (
            <button onClick={() => execAction("retry_job")} className="px-2 py-1 text-[10px] bg-blue-600/20 text-blue-400 rounded border border-blue-600/30 hover:bg-blue-600/30">
              Retry
            </button>
          )}
          {!["completed", "cancelled", "failed"].includes(job.state) && (
            <>
              <button onClick={() => setConfirmAction("kill_job")} className="px-2 py-1 text-[10px] bg-red-600/20 text-red-400 rounded border border-red-600/30 hover:bg-red-600/30">
                Kill
              </button>
              <button onClick={() => setConfirmAction("reassign_job")} className="px-2 py-1 text-[10px] bg-purple-600/20 text-purple-400 rounded border border-purple-600/30 hover:bg-purple-600/30">
                Reassign
              </button>
            </>
          )}
        </div>
      </div>

      {confirmAction === "kill_job" && (
        <ConfirmDialog
          title="Kill Job"
          message={`Are you sure you want to kill job ${job.id}?`}
          confirmLabel="Kill"
          onConfirm={() => { execAction("kill_job"); setConfirmAction(null); }}
          onCancel={() => setConfirmAction(null)}
        />
      )}
      {confirmAction === "reassign_job" && (
        <ConfirmDialog
          title="Reassign Job"
          message={`Reassign job ${job.id} to a different worker? This will cancel the current assignment.`}
          confirmLabel="Reassign"
          onConfirm={() => {
            // For v1, reassign sends without a specific target — backend picks next available
            send({ type: "command", action: "reassign_job", jobId: job.id });
            setConfirmAction(null);
          }}
          onCancel={() => setConfirmAction(null)}
        />
      )}
    </div>
  );
}
