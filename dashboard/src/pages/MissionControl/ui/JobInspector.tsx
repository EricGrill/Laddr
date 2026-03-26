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

  function execAction(action: string) {
    send({ type: "command", action: action as any, jobId });
  }

  return (
    <div className="space-y-3">
      <div>
        <div className="text-[10px] text-gray-500 uppercase">ID</div>
        <div className="text-sm font-mono">{job.id}</div>
      </div>
      <div className="flex gap-4">
        <div>
          <div className="text-[10px] text-gray-500 uppercase">Type</div>
          <div className="text-sm">{job.type}</div>
        </div>
        <div>
          <div className="text-[10px] text-gray-500 uppercase">Priority</div>
          <div className="text-sm">{job.priority}</div>
        </div>
      </div>
      <div>
        <div className="text-[10px] text-gray-500 uppercase">State</div>
        <div className="text-sm">{job.state}</div>
      </div>
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
      {job.progress != null && (
        <div>
          <div className="text-[10px] text-gray-500 uppercase">Progress</div>
          <div className="w-full bg-gray-800 rounded h-1.5 mt-1">
            <div className="bg-cyan-400 h-1.5 rounded" style={{ width: `${job.progress * 100}%` }} />
          </div>
        </div>
      )}
      {job.history.length > 0 && (
        <div>
          <div className="text-[10px] text-gray-500 uppercase mb-1">History</div>
          <div className="space-y-1 max-h-32 overflow-y-auto">
            {job.history.map((h, i) => (
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
