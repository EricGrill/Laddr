import React, { useMemo } from 'react';
import { useJobs } from '../lib/queries/jobs';
import type { Job } from '../lib/types';

const STATUS_COLUMNS: { key: Job['status']; label: string }[] = [
  { key: 'pending', label: 'Queued' },
  { key: 'running', label: 'In Progress' },
  { key: 'completed', label: 'Completed' },
  { key: 'failed', label: 'Failed' },
];

export default function JobBoardPage() {
  const { data: jobs = [], isLoading, error } = useJobs();

  const lanes = useMemo(() => {
    const byPipeline = new Map<string, Job[]>();
    for (const job of jobs) {
      const laneKey = job.pipeline_name || 'Unknown';
      if (!byPipeline.has(laneKey)) byPipeline.set(laneKey, []);
      byPipeline.get(laneKey)!.push(job);
    }
    return Array.from(byPipeline.entries()).map(([pipeline, pipelineJobs]) => ({
      pipeline,
      jobs: pipelineJobs,
    }));
  }, [jobs]);

  if (isLoading) {
    return <div className="text-gray-400">Loading jobs…</div>;
  }

  if (error) {
    return <div className="text-red-400">Failed to load jobs.</div>;
  }

  return (
    <div className="flex flex-col h-full">
      <div className="mb-4 flex gap-6 text-sm">
        {STATUS_COLUMNS.map((col) => {
          const count = jobs.filter((j) => j.status === col.key).length;
          return (
            <div key={col.key}>
              <div className="font-medium text-gray-100">{col.label}</div>
              <div className="text-gray-500">{count} jobs</div>
            </div>
          );
        })}
      </div>

      <div className="overflow-auto border border-[#1F2121] rounded-lg bg-[#111111]">
        <div
          className="grid"
          style={{
            gridTemplateColumns: `220px repeat(${STATUS_COLUMNS.length}, minmax(220px, 1fr))`,
          }}
        >
          <div className="p-2 font-semibold bg-[#191A1A] border-b border-r border-[#1F2121] text-gray-200">
            Pipeline
          </div>
          {STATUS_COLUMNS.map((col) => (
            <div
              key={col.key}
              className="p-2 font-semibold bg-[#191A1A] border-b border-r border-[#1F2121] text-gray-200"
            >
              {col.label}
            </div>
          ))}

          {lanes.map((lane) => (
            <React.Fragment key={lane.pipeline}>
              <div className="p-2 border-t border-r border-[#1F2121] bg-[#151515] text-sm font-medium text-gray-100">
                {lane.pipeline}
              </div>
              {STATUS_COLUMNS.map((col) => {
                const cellJobs = lane.jobs.filter((j) => j.status === col.key);
                return (
                  <div
                    key={col.key}
                    className="p-2 border-t border-r border-[#1F2121] align-top min-h-[80px]"
                  >
                    <div className="flex flex-col gap-2">
                      {cellJobs.map((job) => (
                        <div
                          key={job.job_id}
                          className="rounded-md border border-[#2A2C2C] bg-[#191A1A] px-2 py-1.5 text-xs text-gray-100 shadow-sm"
                        >
                          <div className="font-medium truncate">
                            {job.job_id}
                          </div>
                          <div className="text-[11px] text-gray-500">
                            status: {job.status}
                          </div>
                          {job.agent && (
                            <div className="text-[11px] text-gray-500">
                              agent: {job.agent}
                            </div>
                          )}
                        </div>
                      ))}
                    </div>
                  </div>
                );
              })}
            </React.Fragment>
          ))}
        </div>
      </div>
    </div>
  );
}

