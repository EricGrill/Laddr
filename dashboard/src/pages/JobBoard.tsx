import React, { useMemo } from 'react';
import { useQuery } from '@tanstack/react-query';
import api from '../lib/api';

interface PromptJob {
  prompt_id: string;
  prompt_name: string;
  status: string;
  created_at: string;
  completed_at: string | null;
}

const STATUS_COLUMNS = [
  { key: 'pending', label: 'Queued', color: 'text-cyan-400' },
  { key: 'running', label: 'In Progress', color: 'text-yellow-400' },
  { key: 'completed', label: 'Completed', color: 'text-green-400' },
  { key: 'failed', label: 'Failed', color: 'text-red-400' },
];

export default function JobBoardPage() {
  const { data: jobs = [], isLoading, error } = useQuery({
    queryKey: ['prompts-board'],
    queryFn: async () => {
      const { data } = await api.get<{ prompts: PromptJob[] }>('/api/prompts?limit=200');
      return data.prompts;
    },
    refetchInterval: 3000, // Poll every 3 seconds
    staleTime: 2000,
  });

  const byStatus = useMemo(() => {
    const map: Record<string, PromptJob[]> = {};
    for (const col of STATUS_COLUMNS) map[col.key] = [];
    for (const j of jobs) {
      const bucket = map[j.status] ?? map['pending'];
      if (bucket) bucket.push(j);
    }
    return map;
  }, [jobs]);

  if (isLoading) {
    return <div className="text-gray-400 p-6">Loading jobs...</div>;
  }

  if (error) {
    return <div className="text-red-400 p-6">Failed to load jobs.</div>;
  }

  return (
    <div className="flex flex-col h-full p-4 gap-4">
      {/* Summary counters */}
      <div className="flex gap-8 text-sm">
        {STATUS_COLUMNS.map((col) => (
          <div key={col.key}>
            <div className={`font-semibold ${col.color}`}>{col.label}</div>
            <div className="text-2xl font-bold text-white">{byStatus[col.key]?.length ?? 0}</div>
          </div>
        ))}
        <div className="ml-auto text-gray-500 text-xs self-end">
          {jobs.length} total &middot; auto-refreshing
        </div>
      </div>

      {/* Kanban columns */}
      <div className="flex-1 grid grid-cols-4 gap-3 overflow-hidden">
        {STATUS_COLUMNS.map((col) => (
          <div key={col.key} className="flex flex-col bg-[#111111] rounded-lg border border-[#1F2121] overflow-hidden">
            <div className={`px-3 py-2 text-sm font-semibold border-b border-[#1F2121] ${col.color}`}>
              {col.label} ({byStatus[col.key]?.length ?? 0})
            </div>
            <div className="flex-1 overflow-y-auto p-2 space-y-2">
              {(byStatus[col.key] ?? []).map((job) => (
                <div
                  key={job.prompt_id}
                  className="rounded-md border border-[#2A2C2C] bg-[#191A1A] px-3 py-2 text-xs shadow-sm hover:border-[#3A3C3C] transition-colors"
                >
                  <div className="font-mono text-gray-300 truncate text-[11px]">
                    {job.prompt_id.slice(0, 8)}...
                  </div>
                  <div className="text-gray-100 mt-1 truncate" title={job.prompt_name}>
                    {job.prompt_name.length > 50
                      ? job.prompt_name.slice(0, 50) + '...'
                      : job.prompt_name}
                  </div>
                  <div className="text-gray-500 mt-1 text-[10px]">
                    {new Date(job.created_at).toLocaleTimeString()}
                  </div>
                </div>
              ))}
              {(byStatus[col.key] ?? []).length === 0 && (
                <div className="text-gray-600 text-xs text-center py-8">No jobs</div>
              )}
            </div>
          </div>
        ))}
      </div>
    </div>
  );
}
