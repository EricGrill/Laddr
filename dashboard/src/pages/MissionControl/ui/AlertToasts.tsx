import { useEffect, useRef, useState } from "react";
import { useEntityStore } from "../stores/entityStore";

interface Toast {
  id: string;
  message: string;
  type: "error" | "success";
  at: number;
}

export function AlertToasts() {
  const [toasts, setToasts] = useState<Toast[]>([]);
  const jobs = useEntityStore((s) => s.jobs);
  const seenFailedRef = useRef<Set<string>>(new Set());

  // Watch for newly failed jobs
  useEffect(() => {
    for (const job of Object.values(jobs)) {
      if (job.state === "failed" && !seenFailedRef.current.has(job.id)) {
        seenFailedRef.current.add(job.id);
        setToasts((prev) => [
          ...prev.slice(-4), // keep max 5 toasts
          {
            id: `${job.id}-${Date.now()}`,
            message: `Job ${job.id.slice(0, 8)}... failed`,
            type: "error",
            at: Date.now(),
          },
        ]);
      }
    }
  }, [jobs]);

  // Auto-dismiss after 5 seconds
  useEffect(() => {
    if (toasts.length === 0) return;
    const timer = setTimeout(() => {
      setToasts((prev) => prev.slice(1));
    }, 5000);
    return () => clearTimeout(timer);
  }, [toasts]);

  if (toasts.length === 0) return null;

  return (
    <div className="absolute bottom-4 right-4 z-50 space-y-2">
      {toasts.map((toast) => (
        <div
          key={toast.id}
          className={`px-3 py-2 rounded text-xs border ${
            toast.type === "error"
              ? "bg-red-900/80 border-red-700 text-red-200"
              : "bg-green-900/80 border-green-700 text-green-200"
          }`}
        >
          {toast.message}
        </div>
      ))}
    </div>
  );
}
