import { useState } from "react";
import { RefreshCw, X, Send, Loader2, Layers } from "lucide-react";
import {
  useServices,
  useService,
  useRefreshServices,
  useSubmitServiceJob,
  type ServiceSummary,
} from "../lib/queries/services";
import { canWrite } from "../lib/auth";

const CATEGORIES = ["all", "creative", "data", "ops", "system"];

const categoryStyle: Record<string, { badge: string; text: string }> = {
  creative: { badge: "bg-purple-600", text: "text-purple-400" },
  data: { badge: "bg-cyan-600", text: "text-cyan-400" },
  ops: { badge: "bg-emerald-600", text: "text-emerald-400" },
  system: { badge: "bg-amber-600", text: "text-amber-400" },
};

function CategoryPill({
  category,
  active,
  onClick,
}: {
  category: string;
  active: boolean;
  onClick: () => void;
}) {
  const baseClasses =
    "px-3 py-1 rounded-full text-xs font-medium cursor-pointer transition-colors capitalize";
  if (active) {
    return (
      <button
        onClick={onClick}
        className={`${baseClasses} bg-cyan-500 text-black`}
      >
        {category === "all" ? "All" : category}
      </button>
    );
  }
  return (
    <button
      onClick={onClick}
      className={`${baseClasses} bg-[#2A2C2C] text-gray-400 hover:text-white hover:bg-[#333535]`}
    >
      {category === "all" ? "All" : category}
    </button>
  );
}

function AvailabilityBadge({ available }: { available: boolean }) {
  return (
    <span
      className={`inline-flex items-center gap-1 px-2 py-0.5 rounded-full text-xs font-medium ${
        available
          ? "bg-emerald-900/50 text-emerald-400 border border-emerald-700/50"
          : "bg-red-900/50 text-red-400 border border-red-700/50"
      }`}
    >
      <span
        className={`w-1.5 h-1.5 rounded-full ${available ? "bg-emerald-400" : "bg-red-400"}`}
      />
      {available ? "Available" : "Offline"}
    </span>
  );
}

function ServiceCard({
  service,
  onSubmitJob,
  onViewPlaybook,
  readOnly,
}: {
  service: ServiceSummary;
  onSubmitJob: (id: string) => void;
  onViewPlaybook: (id: string) => void;
  readOnly: boolean;
}) {
  const style = categoryStyle[service.category] ?? { badge: "bg-gray-600", text: "text-gray-400" };
  const visibleTools = service.tools.slice(0, 3);
  const extraTools = service.tools.length - 3;

  return (
    <div className="bg-[#1F2121] border border-[#2A2C2C] rounded-lg p-4 flex flex-col gap-3 hover:border-[#3A3C3C] transition-colors">
      {/* Header */}
      <div className="flex items-start justify-between gap-2">
        <div className="flex items-center gap-2 min-w-0">
          <span className="text-xl leading-none">{service.icon}</span>
          <div className="min-w-0">
            <h3 className="text-sm font-semibold text-white truncate">{service.name}</h3>
            <span
              className={`inline-block mt-0.5 px-1.5 py-0.5 rounded text-[10px] font-medium ${style.badge} text-white opacity-80`}
            >
              {service.mcp}
            </span>
          </div>
        </div>
        <AvailabilityBadge available={service.available} />
      </div>

      {/* Description */}
      <p className="text-xs text-gray-400 leading-relaxed line-clamp-2">{service.description}</p>

      {/* Tool tags */}
      <div className="flex flex-wrap gap-1">
        {visibleTools.map((tool) => (
          <span
            key={tool}
            className={`px-2 py-0.5 rounded text-[10px] font-mono bg-[#2A2C2C] ${style.text}`}
          >
            {tool}
          </span>
        ))}
        {extraTools > 0 && (
          <span className="px-2 py-0.5 rounded text-[10px] bg-[#2A2C2C] text-gray-500">
            +{extraTools} more
          </span>
        )}
      </div>

      {/* Actions */}
      <div className="flex gap-2 mt-auto pt-1">
        <button
          onClick={() => onSubmitJob(service.id)}
          disabled={!service.available || readOnly}
          className="flex-1 flex items-center justify-center gap-1.5 px-3 py-1.5 rounded-md text-xs font-medium bg-cyan-600 hover:bg-cyan-500 text-white transition-colors disabled:opacity-40 disabled:cursor-not-allowed"
        >
          <Send className="w-3 h-3" />
          Submit Job
        </button>
        <button
          onClick={() => onViewPlaybook(service.id)}
          className="flex-1 flex items-center justify-center gap-1.5 px-3 py-1.5 rounded-md text-xs font-medium bg-[#2A2C2C] hover:bg-[#333535] text-gray-300 hover:text-white transition-colors"
        >
          View Playbook
        </button>
      </div>
    </div>
  );
}

function JobModal({
  serviceId,
  onClose,
}: {
  serviceId: string;
  onClose: () => void;
}) {
  const { data: service } = useService(serviceId);
  const submitJob = useSubmitServiceJob();
  const [prompt, setPrompt] = useState("");
  const [priority, setPriority] = useState("normal");
  const [successJobId, setSuccessJobId] = useState<string | null>(null);

  const handleSubmit = async () => {
    if (!prompt.trim()) return;
    try {
      const result = await submitJob.mutateAsync({
        services: [serviceId],
        prompt: prompt.trim(),
        priority,
      });
      setSuccessJobId(result?.job_id ?? result?.id ?? "submitted");
    } catch {
      // error shown via submitJob.error
    }
  };

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center">
      {/* Backdrop */}
      <div
        className="absolute inset-0 bg-black/60 backdrop-blur-sm"
        onClick={onClose}
      />

      {/* Modal */}
      <div className="relative z-10 bg-[#1F2121] border border-[#2A2C2C] rounded-xl shadow-2xl w-full max-w-lg mx-4 p-6 flex flex-col gap-4">
        {/* Header */}
        <div className="flex items-start justify-between gap-3">
          <div>
            {service ? (
              <>
                <div className="flex items-center gap-2">
                  <span className="text-lg">{service.icon}</span>
                  <h2 className="text-base font-semibold text-white">{service.name}</h2>
                </div>
                <p className="text-xs text-gray-400 mt-1">{service.description}</p>
              </>
            ) : (
              <h2 className="text-base font-semibold text-white">Submit Job</h2>
            )}
          </div>
          <button
            onClick={onClose}
            className="text-gray-500 hover:text-white transition-colors shrink-0"
          >
            <X className="w-5 h-5" />
          </button>
        </div>

        {successJobId ? (
          <div className="flex flex-col gap-3">
            <div className="bg-emerald-900/30 border border-emerald-700/50 rounded-lg p-4">
              <p className="text-emerald-400 text-sm font-medium">Job submitted successfully</p>
              <p className="text-gray-400 text-xs mt-1">
                Job ID: <span className="font-mono text-cyan-400">{successJobId}</span>
              </p>
            </div>
            <button
              onClick={onClose}
              className="px-4 py-2 rounded-lg bg-[#2A2C2C] text-gray-300 hover:text-white text-sm transition-colors"
            >
              Close
            </button>
          </div>
        ) : (
          <>
            {/* Prompt */}
            <div className="flex flex-col gap-1.5">
              <label className="text-xs font-medium text-gray-400">Instructions / Prompt</label>
              <textarea
                value={prompt}
                onChange={(e) => setPrompt(e.target.value)}
                placeholder="Describe the task for this service..."
                rows={5}
                className="w-full bg-[#2A2C2C] border border-[#3A3C3C] rounded-lg px-3 py-2.5 text-sm text-white placeholder-gray-600 resize-none focus:outline-none focus:border-cyan-600 transition-colors"
              />
            </div>

            {/* Priority */}
            <div className="flex flex-col gap-1.5">
              <label className="text-xs font-medium text-gray-400">Priority</label>
              <select
                value={priority}
                onChange={(e) => setPriority(e.target.value)}
                className="w-full bg-[#2A2C2C] border border-[#3A3C3C] rounded-lg px-3 py-2 text-sm text-white focus:outline-none focus:border-cyan-600 transition-colors"
              >
                <option value="low">Low</option>
                <option value="normal">Normal</option>
                <option value="high">High</option>
                <option value="critical">Critical</option>
              </select>
            </div>

            {/* Error */}
            {submitJob.isError && (
              <div className="bg-red-900/30 border border-red-700/50 rounded-lg p-3">
                <p className="text-red-400 text-xs">
                  {submitJob.error instanceof Error
                    ? submitJob.error.message
                    : "Failed to submit job"}
                </p>
              </div>
            )}

            {/* Actions */}
            <div className="flex gap-2 justify-end">
              <button
                onClick={onClose}
                className="px-4 py-2 rounded-lg bg-[#2A2C2C] text-gray-300 hover:text-white text-sm transition-colors"
              >
                Cancel
              </button>
              <button
                onClick={handleSubmit}
                disabled={!prompt.trim() || submitJob.isPending}
                className="flex items-center gap-2 px-4 py-2 rounded-lg bg-cyan-600 hover:bg-cyan-500 text-white text-sm font-medium transition-colors disabled:opacity-40 disabled:cursor-not-allowed"
              >
                {submitJob.isPending ? (
                  <Loader2 className="w-4 h-4 animate-spin" />
                ) : (
                  <Send className="w-4 h-4" />
                )}
                Submit
              </button>
            </div>
          </>
        )}
      </div>
    </div>
  );
}

function PlaybookDrawer({
  serviceId,
  onClose,
}: {
  serviceId: string;
  onClose: () => void;
}) {
  const { data: service, isLoading } = useService(serviceId);

  return (
    <div className="fixed inset-0 z-50 flex justify-end">
      {/* Backdrop */}
      <div
        className="absolute inset-0 bg-black/50 backdrop-blur-sm"
        onClick={onClose}
      />

      {/* Drawer */}
      <div className="relative z-10 bg-[#1F2121] border-l border-[#2A2C2C] w-full max-w-xl h-full flex flex-col shadow-2xl">
        {/* Header */}
        <div className="flex items-center justify-between px-6 py-4 border-b border-[#2A2C2C] shrink-0">
          <div className="flex items-center gap-2">
            {service && <span className="text-lg">{service.icon}</span>}
            <h2 className="text-base font-semibold text-white">
              {service ? service.name : "Playbook"}
            </h2>
          </div>
          <button
            onClick={onClose}
            className="text-gray-500 hover:text-white transition-colors"
          >
            <X className="w-5 h-5" />
          </button>
        </div>

        {/* Content */}
        <div className="flex-1 overflow-y-auto px-6 py-4">
          {isLoading ? (
            <div className="flex items-center justify-center h-32 text-gray-500">
              <Loader2 className="w-5 h-5 animate-spin" />
            </div>
          ) : service?.playbook ? (
            <pre className="text-xs text-gray-300 leading-relaxed whitespace-pre-wrap font-mono">
              {service.playbook}
            </pre>
          ) : (
            <p className="text-gray-500 text-sm">No playbook available for this service.</p>
          )}
        </div>
      </div>
    </div>
  );
}

export default function Services() {
  const { data, isLoading, isError } = useServices();
  const refreshServices = useRefreshServices();
  const readOnly = !canWrite();

  const [selectedCategory, setSelectedCategory] = useState<string>("all");
  const [jobModalServiceId, setJobModalServiceId] = useState<string | null>(null);
  const [playbookServiceId, setPlaybookServiceId] = useState<string | null>(null);

  const services = data?.services ?? [];
  const summary = data?.summary;

  const filteredServices =
    selectedCategory === "all"
      ? services
      : services.filter((s) => s.category === selectedCategory);

  return (
    <div className="h-full flex flex-col bg-[#191A1A]">
      {/* Top bar */}
      <div className="px-6 py-4 border-b border-[#2A2C2C] shrink-0">
        <div className="flex items-center justify-between gap-4">
          <div>
            <div className="flex items-center gap-2">
              <Layers className="w-5 h-5 text-cyan-400" />
              <h1 className="text-lg font-semibold text-white">Platform Services</h1>
            </div>
            {summary && (
              <p className="text-xs text-gray-500 mt-0.5">
                {summary.total} services &mdash;{" "}
                <span className="text-emerald-400">{summary.available} available</span>
                {summary.unavailable > 0 && (
                  <span className="text-red-400">, {summary.unavailable} offline</span>
                )}
                {summary.last_discovered && (
                  <span>
                    {" "}
                    &mdash; last discovered{" "}
                    {new Date(summary.last_discovered).toLocaleString()}
                  </span>
                )}
              </p>
            )}
          </div>

          <button
            onClick={() => refreshServices.mutate()}
            disabled={refreshServices.isPending}
            className="flex items-center gap-2 px-3 py-1.5 rounded-lg bg-[#2A2C2C] hover:bg-[#333535] text-gray-300 hover:text-white text-sm transition-colors disabled:opacity-50"
          >
            <RefreshCw
              className={`w-4 h-4 ${refreshServices.isPending ? "animate-spin" : ""}`}
            />
            Refresh
          </button>
        </div>

        {/* Category filter pills */}
        <div className="flex gap-2 mt-3 flex-wrap">
          {CATEGORIES.map((cat) => (
            <CategoryPill
              key={cat}
              category={cat}
              active={selectedCategory === cat}
              onClick={() => setSelectedCategory(cat)}
            />
          ))}
        </div>
      </div>

      {/* Content */}
      <div className="flex-1 overflow-y-auto px-6 py-4">
        {isLoading ? (
          <div className="flex items-center justify-center h-48 text-gray-500">
            <Loader2 className="w-6 h-6 animate-spin mr-2" />
            <span className="text-sm">Loading services...</span>
          </div>
        ) : isError ? (
          <div className="flex items-center justify-center h-48">
            <p className="text-red-400 text-sm">Failed to load services. Check API connection.</p>
          </div>
        ) : filteredServices.length === 0 ? (
          <div className="flex items-center justify-center h-48">
            <p className="text-gray-500 text-sm">
              {selectedCategory === "all"
                ? "No services discovered yet. Click Refresh to scan."
                : `No ${selectedCategory} services found.`}
            </p>
          </div>
        ) : (
          <div className="grid grid-cols-1 lg:grid-cols-2 gap-4">
            {filteredServices.map((service) => (
              <ServiceCard
                key={service.id}
                service={service}
                onSubmitJob={setJobModalServiceId}
                onViewPlaybook={setPlaybookServiceId}
                readOnly={readOnly}
              />
            ))}
          </div>
        )}
      </div>

      {/* Job submission modal */}
      {jobModalServiceId && (
        <JobModal
          serviceId={jobModalServiceId}
          onClose={() => setJobModalServiceId(null)}
        />
      )}

      {/* Playbook drawer */}
      {playbookServiceId && (
        <PlaybookDrawer
          serviceId={playbookServiceId}
          onClose={() => setPlaybookServiceId(null)}
        />
      )}
    </div>
  );
}
