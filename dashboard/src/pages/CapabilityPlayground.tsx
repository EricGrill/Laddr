import { useState, useEffect, useRef } from "react";
import { Play, Loader2, Server, Cpu, Clock, Zap } from "lucide-react";
import api from "../lib/api";
import { canWrite } from "../lib/auth";

interface Worker {
  worker_id: string;
  node: string;
  status?: string;
  models?: Array<{ id: string; provider: string; loaded: boolean }>;
  mcps?: string[];
  skills?: string[];
  max_concurrent?: number;
  active_jobs?: number;
  capabilities?: {
    models?: Array<{ id: string; provider: string; loaded: boolean }>;
    mcps?: string[];
    skills?: string[];
    max_concurrent?: number;
  };
}

interface JobResult {
  job_id: string;
  worker_id?: string;
  model?: string;
  result?: any;
  completed_at?: number;
  error?: string;
}

export default function CapabilityPlayground() {
  const [systemPrompt, setSystemPrompt] = useState("You are a helpful assistant. Respond concisely.");
  const [userPrompt, setUserPrompt] = useState("");
  const [mode, setMode] = useState<"generic" | "template" | "explicit">("generic");
  const [template, setTemplate] = useState("");
  const [priority, setPriority] = useState("normal");
  const [explicitModel, setExplicitModel] = useState("");
  const [timeout, setTimeout_] = useState(120);
  
  const [workers, setWorkers] = useState<Record<string, Worker>>({});
  const [queueDepths, setQueueDepths] = useState<Record<string, number>>({});
  const [submitting, setSubmitting] = useState(false);
  const [polling, setPolling] = useState(false);
  const [currentJobId, setCurrentJobId] = useState<string | null>(null);
  const [result, setResult] = useState<JobResult | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [history, setHistory] = useState<JobResult[]>([]);
  const pollRef = useRef<ReturnType<typeof setInterval> | null>(null);
  const readOnlyUser = !canWrite();

  // Fetch workers and queue on load
  useEffect(() => {
    const fetchStatus = async () => {
      try {
        const [w, q] = await Promise.all([
          api.get("/api/workers"),
          api.get("/api/queue"),
        ]);
        setWorkers(w.data.workers || {});
        setQueueDepths(q.data.queue_depths || {});
      } catch {
        // silently fail
      }
    };
    fetchStatus();
    const interval = setInterval(fetchStatus, 10000);
    return () => clearInterval(interval);
  }, []);

  // Poll for result
  useEffect(() => {
    if (!currentJobId || !polling) return;
    
    pollRef.current = setInterval(async () => {
      try {
        // Check Redis for result
        const res = await api.get(`/api/responses/${currentJobId}/resolved`);
        if (res.data && res.data.status !== "pending") {
          setResult(res.data);
          setPolling(false);
          setHistory(prev => [res.data, ...prev].slice(0, 20));
          if (pollRef.current) clearInterval(pollRef.current);
        }
      } catch {
        // Not ready yet, keep polling
      }
    }, 2000);

    return () => {
      if (pollRef.current) clearInterval(pollRef.current);
    };
  }, [currentJobId, polling]);

  const handleSubmit = async () => {
    if (!userPrompt.trim()) return;
    if (readOnlyUser) {
      setError("Read-only users cannot submit capability jobs.");
      return;
    }
    setSubmitting(true);
    setResult(null);
    setError(null);

    const requirements: any = { mode };
    if (mode === "template") {
      requirements.template = template;
    } else if (mode === "explicit" && explicitModel) {
      requirements.models = [explicitModel];
      requirements.model_match = "any";
    }

    try {
      const res = await api.post("/api/jobs/capability", {
        system_prompt: systemPrompt,
        user_prompt: userPrompt,
        requirements,
        priority,
        timeout_seconds: timeout,
      });
      setCurrentJobId(res.data.job_id);
      setPolling(true);
    } catch (err: any) {
      setError(err.response?.data?.detail || err.message || "Failed to submit job");
    } finally {
      setSubmitting(false);
    }
  };

  const workerList = Object.values(workers);
  const allModels = Array.from(new Set(
    workerList.flatMap(w => {
      const caps = w.capabilities || w;
      return (caps.models || []).map((m: any) => m.id);
    })
  )).sort();

  const totalPending = Object.values(queueDepths).reduce((a, b) => a + b, 0);

  return (
    <div className="min-h-screen bg-gray-950 text-white p-6">
      <div className="max-w-6xl mx-auto">
        <h1 className="text-2xl font-bold mb-6 flex items-center gap-2">
          <Zap className="text-yellow-400" size={24} />
          Capability Playground
        </h1>

        <div className="grid grid-cols-1 lg:grid-cols-3 gap-6">
          {/* Left: Form */}
          <div className="lg:col-span-2 space-y-4">
            {/* System Prompt */}
            <div>
              <label className="block text-sm font-medium text-gray-400 mb-1">System Prompt</label>
              <textarea
                className="w-full bg-gray-900 border border-gray-700 rounded-lg p-3 text-sm text-white resize-none focus:border-blue-500 focus:outline-none"
                rows={3}
                value={systemPrompt}
                onChange={e => setSystemPrompt(e.target.value)}
                placeholder="You are a helpful assistant..."
              />
            </div>

            {/* User Prompt */}
            <div>
              <label className="block text-sm font-medium text-gray-400 mb-1">User Prompt</label>
              <textarea
                className="w-full bg-gray-900 border border-gray-700 rounded-lg p-3 text-sm text-white resize-none focus:border-blue-500 focus:outline-none"
                rows={5}
                value={userPrompt}
                onChange={e => setUserPrompt(e.target.value)}
                placeholder="What would you like to ask?"
              />
            </div>

            {/* Requirements */}
            <div className="grid grid-cols-2 md:grid-cols-4 gap-3">
              <div>
                <label className="block text-xs font-medium text-gray-500 mb-1">Routing</label>
                <select
                  className="w-full bg-gray-900 border border-gray-700 rounded-lg p-2 text-sm text-white focus:border-blue-500 focus:outline-none"
                  value={mode}
                  onChange={e => setMode(e.target.value as any)}
                >
                  <option value="generic">Generic (any worker)</option>
                  <option value="explicit">Explicit model</option>
                  <option value="template">Template</option>
                </select>
              </div>

              {mode === "explicit" && (
                <div>
                  <label className="block text-xs font-medium text-gray-500 mb-1">Model</label>
                  <select
                    className="w-full bg-gray-900 border border-gray-700 rounded-lg p-2 text-sm text-white focus:border-blue-500 focus:outline-none"
                    value={explicitModel}
                    onChange={e => setExplicitModel(e.target.value)}
                  >
                    <option value="">Any loaded model</option>
                    {allModels.map(m => (
                      <option key={m} value={m}>{m}</option>
                    ))}
                  </select>
                </div>
              )}

              {mode === "template" && (
                <div>
                  <label className="block text-xs font-medium text-gray-500 mb-1">Template</label>
                  <input
                    className="w-full bg-gray-900 border border-gray-700 rounded-lg p-2 text-sm text-white focus:border-blue-500 focus:outline-none"
                    value={template}
                    onChange={e => setTemplate(e.target.value)}
                    placeholder="e.g. code-review"
                  />
                </div>
              )}

              <div>
                <label className="block text-xs font-medium text-gray-500 mb-1">Priority</label>
                <select
                  className="w-full bg-gray-900 border border-gray-700 rounded-lg p-2 text-sm text-white focus:border-blue-500 focus:outline-none"
                  value={priority}
                  onChange={e => setPriority(e.target.value)}
                >
                  <option value="critical">Critical</option>
                  <option value="high">High</option>
                  <option value="normal">Normal</option>
                  <option value="low">Low</option>
                </select>
              </div>

              <div>
                <label className="block text-xs font-medium text-gray-500 mb-1">Timeout (s)</label>
                <input
                  type="number"
                  className="w-full bg-gray-900 border border-gray-700 rounded-lg p-2 text-sm text-white focus:border-blue-500 focus:outline-none"
                  value={timeout}
                  onChange={e => setTimeout_(Number(e.target.value))}
                  min={10}
                  max={600}
                />
              </div>
            </div>

            {/* Submit */}
            <button
              onClick={handleSubmit}
              disabled={submitting || polling || !userPrompt.trim() || readOnlyUser}
              className="w-full flex items-center justify-center gap-2 bg-blue-600 hover:bg-blue-500 disabled:bg-gray-700 disabled:text-gray-500 text-white font-medium py-3 px-4 rounded-lg transition-colors"
            >
              {submitting || polling ? (
                <>
                  <Loader2 className="animate-spin" size={18} />
                  {polling ? "Waiting for result..." : "Submitting..."}
                </>
              ) : (
                <>
                  <Play size={18} />
                  Run
                </>
              )}
            </button>
            {readOnlyUser && (
              <p className="text-xs text-amber-400">
                You are signed in with read-only access. Running jobs is disabled.
              </p>
            )}

            {/* Error */}
            {error && (
              <div className="bg-red-900/30 border border-red-700 rounded-lg p-4 text-red-300 text-sm">
                {error}
              </div>
            )}

            {/* Result */}
            {result && (
              <div className="bg-gray-900 border border-gray-700 rounded-lg p-4 space-y-3">
                <div className="flex items-center justify-between">
                  <h3 className="text-sm font-medium text-gray-300">Result</h3>
                  <div className="flex items-center gap-3 text-xs text-gray-500">
                    {result.worker_id && (
                      <span className="flex items-center gap-1">
                        <Server size={12} />
                        {result.worker_id}
                      </span>
                    )}
                    {result.model && (
                      <span className="flex items-center gap-1">
                        <Cpu size={12} />
                        {result.model}
                      </span>
                    )}
                  </div>
                </div>
                <pre className="text-sm text-gray-200 whitespace-pre-wrap bg-gray-950 rounded p-3 max-h-96 overflow-auto">
                  {typeof result.result === "string"
                    ? result.result
                    : JSON.stringify(result.result, null, 2)}
                </pre>
              </div>
            )}

            {/* History */}
            {history.length > 0 && (
              <div className="space-y-2">
                <h3 className="text-sm font-medium text-gray-400">Recent Jobs</h3>
                {history.map((h, i) => (
                  <div key={i} className="bg-gray-900/50 border border-gray-800 rounded-lg p-3 text-xs text-gray-400">
                    <div className="flex justify-between">
                      <span>{h.job_id?.slice(0, 8)}...</span>
                      <span className="flex items-center gap-2">
                        {h.worker_id && <span>{h.worker_id}</span>}
                        {h.model && <span className="text-gray-500">{h.model}</span>}
                      </span>
                    </div>
                  </div>
                ))}
              </div>
            )}
          </div>

          {/* Right: Fleet Status */}
          <div className="space-y-4">
            {/* Queue */}
            <div className="bg-gray-900 border border-gray-700 rounded-lg p-4">
              <h3 className="text-sm font-medium text-gray-300 mb-3 flex items-center gap-2">
                <Clock size={14} />
                Queue ({totalPending} pending)
              </h3>
              <div className="grid grid-cols-2 gap-2 text-xs">
                {Object.entries(queueDepths).map(([level, count]) => (
                  <div key={level} className="flex justify-between bg-gray-950 rounded p-2">
                    <span className="text-gray-400">{level}</span>
                    <span className={count > 0 ? "text-yellow-400 font-medium" : "text-gray-600"}>{count}</span>
                  </div>
                ))}
              </div>
            </div>

            {/* Workers */}
            <div className="bg-gray-900 border border-gray-700 rounded-lg p-4">
              <h3 className="text-sm font-medium text-gray-300 mb-3 flex items-center gap-2">
                <Server size={14} />
                Workers ({workerList.length})
              </h3>
              {workerList.length === 0 ? (
                <p className="text-xs text-gray-500">No workers registered</p>
              ) : (
                <div className="space-y-3">
                  {workerList.map(w => {
                    const caps = w.capabilities || w;
                    const models = caps.models || [];
                    const loadedCount = models.filter((m: any) => m.loaded).length;
                    return (
                      <div key={w.worker_id} className="bg-gray-950 rounded-lg p-3 text-xs">
                        <div className="flex justify-between items-center mb-1">
                          <span className="font-medium text-white">{w.node || w.worker_id}</span>
                          <span className={`px-2 py-0.5 rounded-full text-[10px] font-medium ${
                            w.active_jobs === 0 
                              ? "bg-green-900/50 text-green-400" 
                              : "bg-yellow-900/50 text-yellow-400"
                          }`}>
                            {w.active_jobs === 0 ? "idle" : `${w.active_jobs} active`}
                          </span>
                        </div>
                        <div className="text-gray-500 space-y-0.5">
                          <div className="flex items-center gap-1">
                            <Cpu size={10} />
                            {loadedCount} models loaded
                          </div>
                          {(caps.mcps || []).length > 0 && (
                            <div>MCPs: {(caps.mcps || []).join(", ")}</div>
                          )}
                          {(caps.skills || []).length > 0 && (
                            <div>Skills: {(caps.skills || []).join(", ")}</div>
                          )}
                          <div>Max concurrent: {caps.max_concurrent || 1}</div>
                        </div>
                      </div>
                    );
                  })}
                </div>
              )}
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}
