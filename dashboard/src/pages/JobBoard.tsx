import { useMemo, useState } from 'react';
import { useQuery } from '@tanstack/react-query';
import api from '../lib/api';

interface PromptJob {
  prompt_id: string;
  prompt_name: string;
  status: string;
  created_at: string;
  completed_at: string | null;
}

interface PromptListResponse {
  prompts: PromptJob[];
  total: number;
  limit: number;
  offset: number;
}

interface PromptDetail {
  prompt_id: string;
  prompt_name: string;
  status: string;
  inputs: Record<string, unknown> | null;
  outputs: Record<string, unknown> | null;
  error: string | null;
  created_at: string;
  completed_at: string | null;
  token_usage: Record<string, number> | null;
}

interface CouncilEval {
  score: number | null;
  assessment: string | null;
  strengths: string[];
  concerns: string[];
  verdict: 'BUILD' | 'MAYBE' | 'SKIP' | null;
  raw: string;
  parsed: boolean;
}

const STATUS_COLUMNS = [
  { key: 'pending', label: 'Queued', color: 'text-cyan-400', dotColor: 'bg-cyan-400' },
  { key: 'running', label: 'In Progress', color: 'text-yellow-400', dotColor: 'bg-yellow-400' },
  { key: 'completed', label: 'Completed', color: 'text-green-400', dotColor: 'bg-green-400' },
  { key: 'failed', label: 'Failed', color: 'text-red-400', dotColor: 'bg-red-400' },
];

function computeThroughput(jobs: PromptJob[]) {
  const now = Date.now();
  const oneMin = now - 60_000;
  const oneHour = now - 3_600_000;

  let perMin = 0, perHour = 0;
  for (const j of jobs) {
    const t = new Date(j.created_at).getTime();
    if (t >= oneHour) perHour++;
    if (t >= oneMin) perMin++;
  }
  return { perMin, perHour };
}

function formatDuration(start: string, end: string | null) {
  if (!end) return '—';
  const ms = new Date(end).getTime() - new Date(start).getTime();
  if (ms < 1000) return `${ms}ms`;
  if (ms < 60_000) return `${(ms / 1000).toFixed(1)}s`;
  return `${(ms / 60_000).toFixed(1)}m`;
}

function parseCouncilEval(text: string): CouncilEval {
  const result: CouncilEval = {
    score: null,
    assessment: null,
    strengths: [],
    concerns: [],
    verdict: null,
    raw: text,
    parsed: false,
  };

  // Match both plain (SCORE: N) and markdown bold (**SCORE:** N) variants
  const scoreMatch = text.match(/(?:\*\*)?SCORE:?\*?\*?:?\s*(\d+(?:\.\d+)?)/i);
  const assessmentMatch = text.match(/(?:\*\*)?ASSESSMENT:?\*?\*?:?\s*([\s\S]*?)(?=\n\s*(?:\*\*)?(?:STRENGTHS|CONCERNS|VERDICT)|$)/i);
  const verdictMatch = text.match(/(?:\*\*)?VERDICT:?\*?\*?:?\s*(BUILD|MAYBE|SKIP)/i);

  // Extract STRENGTHS block
  const strengthsMatch = text.match(/(?:\*\*)?STRENGTHS:?\*?\*?:?\s*([\s\S]*?)(?=\n\s*(?:\*\*)?(?:CONCERNS|VERDICT|ASSESSMENT)|$)/i);
  // Extract CONCERNS block
  const concernsMatch = text.match(/(?:\*\*)?CONCERNS:?\*?\*?:?\s*([\s\S]*?)(?=\n\s*(?:\*\*)?(?:STRENGTHS|VERDICT|ASSESSMENT)|$)/i);

  if (!scoreMatch && !verdictMatch && !assessmentMatch) {
    return result; // Not a council eval
  }

  result.parsed = true;

  if (scoreMatch) {
    result.score = parseFloat(scoreMatch[1]);
  }

  if (assessmentMatch) {
    result.assessment = assessmentMatch[1].trim();
  }

  if (verdictMatch) {
    const v = verdictMatch[1].toUpperCase();
    if (v === 'BUILD' || v === 'MAYBE' || v === 'SKIP') {
      result.verdict = v;
    }
  }

  if (strengthsMatch) {
    result.strengths = strengthsMatch[1]
      .split('\n')
      .map(l => l.replace(/^[-*]\s*/, '').trim())
      .filter(l => l.length > 0);
  }

  if (concernsMatch) {
    result.concerns = concernsMatch[1]
      .split('\n')
      .map(l => l.replace(/^[-*]\s*/, '').trim())
      .filter(l => l.length > 0);
  }

  return result;
}

function ScoreBadge({ score }: { score: number }) {
  const color =
    score >= 7 ? 'text-green-400' :
    score >= 4 ? 'text-yellow-400' :
    'text-red-400';
  return (
    <span className={`text-4xl font-bold font-mono ${color}`}>
      {score}
      <span className="text-lg text-gray-500">/10</span>
    </span>
  );
}

function VerdictBadge({ verdict }: { verdict: 'BUILD' | 'MAYBE' | 'SKIP' }) {
  const styles: Record<string, string> = {
    BUILD: 'bg-green-900/50 text-green-300 border-green-700',
    MAYBE: 'bg-yellow-900/50 text-yellow-300 border-yellow-700',
    SKIP: 'bg-red-900/50 text-red-300 border-red-700',
  };
  return (
    <span className={`inline-block px-3 py-0.5 rounded border text-xs font-bold tracking-widest uppercase ${styles[verdict]}`}>
      {verdict}
    </span>
  );
}

function FormattedOutput({ text }: { text: string }) {
  const eval_ = parseCouncilEval(text);

  if (!eval_.parsed) {
    return (
      <pre className="text-gray-300 text-xs bg-[#0A0A0A] rounded p-3 whitespace-pre-wrap break-words max-h-64 overflow-y-auto leading-relaxed">
        {text}
      </pre>
    );
  }

  return (
    <div className="space-y-4 text-sm">
      {/* Score + Verdict row */}
      <div className="flex items-center gap-6">
        {eval_.score !== null && <ScoreBadge score={eval_.score} />}
        {eval_.verdict && <VerdictBadge verdict={eval_.verdict} />}
      </div>

      {/* Assessment */}
      {eval_.assessment && (
        <div>
          <div className="text-gray-500 text-xs font-semibold uppercase tracking-wider mb-1">Assessment</div>
          <p className="text-gray-200 leading-relaxed">{eval_.assessment}</p>
        </div>
      )}

      {/* Strengths */}
      {eval_.strengths.length > 0 && (
        <div>
          <div className="text-green-500 text-xs font-semibold uppercase tracking-wider mb-1">Strengths</div>
          <ul className="space-y-1">
            {eval_.strengths.map((s, i) => (
              <li key={i} className="flex gap-2 text-gray-300">
                <span className="text-green-600 mt-0.5 shrink-0">+</span>
                <span>{s}</span>
              </li>
            ))}
          </ul>
        </div>
      )}

      {/* Concerns */}
      {eval_.concerns.length > 0 && (
        <div>
          <div className="text-red-500 text-xs font-semibold uppercase tracking-wider mb-1">Concerns</div>
          <ul className="space-y-1">
            {eval_.concerns.map((c, i) => (
              <li key={i} className="flex gap-2 text-gray-300">
                <span className="text-red-600 mt-0.5 shrink-0">-</span>
                <span>{c}</span>
              </li>
            ))}
          </ul>
        </div>
      )}
    </div>
  );
}

function OutputsSection({ outputs }: { outputs: Record<string, unknown> }) {
  const [viewMode, setViewMode] = useState<'formatted' | 'raw'>('formatted');

  const outputText: string | null = (() => {
    if (typeof outputs.output === 'string') return outputs.output;
    if (typeof outputs.result === 'string') return outputs.result;
    return null;
  })();

  return (
    <div className="px-5 py-3">
      <div className="flex items-center justify-between mb-2">
        <div className="text-gray-400 text-xs font-semibold">Outputs</div>
        <div className="flex rounded overflow-hidden border border-[#2A2C2C] text-[11px]">
          <button
            onClick={() => setViewMode('formatted')}
            className={`px-2 py-0.5 transition-colors ${
              viewMode === 'formatted'
                ? 'bg-[#2A2C2C] text-white'
                : 'text-gray-500 hover:text-gray-300'
            }`}
          >
            Formatted
          </button>
          <button
            onClick={() => setViewMode('raw')}
            className={`px-2 py-0.5 transition-colors border-l border-[#2A2C2C] ${
              viewMode === 'raw'
                ? 'bg-[#2A2C2C] text-white'
                : 'text-gray-500 hover:text-gray-300'
            }`}
          >
            Raw
          </button>
        </div>
      </div>

      {viewMode === 'formatted' && outputText ? (
        <FormattedOutput text={outputText} />
      ) : (
        <pre className="text-gray-300 text-xs bg-[#0A0A0A] rounded p-2 whitespace-pre-wrap break-words max-h-64 overflow-y-auto">
          {JSON.stringify(outputs, null, 2)}
        </pre>
      )}
    </div>
  );
}

function JobDetailPanel({ jobId, onClose }: { jobId: string; onClose: () => void }) {
  const { data, isLoading, error } = useQuery({
    queryKey: ['prompt-detail', jobId],
    queryFn: async () => {
      const { data } = await api.get<PromptDetail>(`/api/prompts/${jobId}`);
      return data;
    },
    staleTime: 5000,
  });

  if (isLoading) return <div className="text-gray-400 p-4">Loading...</div>;
  if (error || !data) return <div className="text-red-400 p-4">Failed to load job details.</div>;

  const statusCol = STATUS_COLUMNS.find(c => c.key === data.status) ?? STATUS_COLUMNS[0];

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/60" onClick={onClose}>
      <div
        className="bg-[#111111] border border-[#2A2C2C] rounded-lg shadow-2xl w-full max-w-2xl max-h-[80vh] overflow-y-auto"
        onClick={e => e.stopPropagation()}
      >
        {/* Header */}
        <div className="flex items-center justify-between px-5 py-4 border-b border-[#1F2121]">
          <div>
            <div className="text-white font-semibold text-lg">{data.prompt_name}</div>
            <div className="font-mono text-gray-500 text-xs mt-0.5">{data.prompt_id}</div>
          </div>
          <button onClick={onClose} className="text-gray-500 hover:text-white text-xl px-2">x</button>
        </div>

        {/* Status bar */}
        <div className="flex items-center gap-4 px-5 py-3 border-b border-[#1F2121] text-sm">
          <span className={`flex items-center gap-1.5 ${statusCol.color}`}>
            <span className={`w-2 h-2 rounded-full ${statusCol.dotColor}`} />
            {statusCol.label}
          </span>
          <span className="text-gray-500">Created: {new Date(data.created_at).toLocaleString()}</span>
          {data.completed_at && (
            <span className="text-gray-500">Duration: {formatDuration(data.created_at, data.completed_at)}</span>
          )}
        </div>

        {/* Token usage */}
        {data.token_usage && Object.keys(data.token_usage).length > 0 && (
          <div className="px-5 py-3 border-b border-[#1F2121]">
            <div className="text-gray-400 text-xs font-semibold mb-1">Token Usage</div>
            <div className="flex gap-4 text-sm">
              {data.token_usage.prompt_tokens != null && (
                <span className="text-gray-300">Input: <span className="text-white font-mono">{data.token_usage.prompt_tokens}</span></span>
              )}
              {data.token_usage.completion_tokens != null && (
                <span className="text-gray-300">Output: <span className="text-white font-mono">{data.token_usage.completion_tokens}</span></span>
              )}
              {data.token_usage.total_tokens != null && (
                <span className="text-gray-300">Total: <span className="text-white font-mono">{data.token_usage.total_tokens}</span></span>
              )}
            </div>
          </div>
        )}

        {/* Error */}
        {data.error && (
          <div className="px-5 py-3 border-b border-[#1F2121]">
            <div className="text-red-400 text-xs font-semibold mb-1">Error</div>
            <pre className="text-red-300 text-xs bg-red-950/30 rounded p-2 whitespace-pre-wrap break-words">{data.error}</pre>
          </div>
        )}

        {/* Inputs */}
        {data.inputs && Object.keys(data.inputs).length > 0 && (
          <div className="px-5 py-3 border-b border-[#1F2121]">
            <div className="text-gray-400 text-xs font-semibold mb-1">Inputs</div>
            <pre className="text-gray-300 text-xs bg-[#0A0A0A] rounded p-2 whitespace-pre-wrap break-words max-h-48 overflow-y-auto">
              {JSON.stringify(data.inputs, null, 2)}
            </pre>
          </div>
        )}

        {/* Outputs */}
        {data.outputs && Object.keys(data.outputs).length > 0 && (
          <OutputsSection outputs={data.outputs} />
        )}
      </div>
    </div>
  );
}

export default function JobBoardPage() {
  const [selectedJobId, setSelectedJobId] = useState<string | null>(null);

  const { data: queryResult, isLoading, error } = useQuery({
    queryKey: ['prompts-board'],
    queryFn: async () => {
      const { data } = await api.get<PromptListResponse>('/api/prompts?limit=500&since_hours=24');
      return data;
    },
    refetchInterval: 3000,
    staleTime: 2000,
  });

  const jobs: PromptJob[] = queryResult?.prompts ?? [];
  const apiTotal: number | null = queryResult?.total ?? null;

  const byStatus = useMemo(() => {
    const map: Record<string, PromptJob[]> = {};
    for (const col of STATUS_COLUMNS) map[col.key] = [];
    for (const j of jobs) {
      const bucket = map[j.status] ?? map['pending'];
      if (bucket) bucket.push(j);
    }
    return map;
  }, [jobs]);

  const throughput = useMemo(() => computeThroughput(jobs), [jobs]);

  if (isLoading) {
    return <div className="text-gray-400 p-6">Loading jobs...</div>;
  }

  if (error) {
    return <div className="text-red-400 p-6">Failed to load jobs.</div>;
  }

  // If the API returned a total that exceeds what's displayed, show both.
  const showTruncationNote = apiTotal !== null && apiTotal > jobs.length;

  return (
    <div className="flex flex-col h-full p-4 gap-4">
      {/* Throughput + Summary */}
      <div className="flex items-end gap-6">
        {/* Throughput */}
        <div className="flex gap-6 text-sm">
          <div>
            <div className="text-gray-500 text-xs">Jobs / min</div>
            <div className="text-2xl font-bold text-cyan-400 font-mono">{throughput.perMin}</div>
          </div>
          <div>
            <div className="text-gray-500 text-xs">Jobs / hr</div>
            <div className="text-2xl font-bold text-cyan-400 font-mono">{throughput.perHour}</div>
          </div>
        </div>

        {/* Divider */}
        <div className="w-px h-10 bg-[#2A2C2C]" />

        {/* Status counters */}
        {STATUS_COLUMNS.map((col) => (
          <div key={col.key}>
            <div className={`text-xs ${col.color}`}>{col.label}</div>
            <div className="text-xl font-bold text-white font-mono">{byStatus[col.key]?.length ?? 0}</div>
          </div>
        ))}

        <div className="ml-auto text-gray-500 text-xs self-end text-right">
          {apiTotal !== null ? (
            <>
              <span className="text-gray-300">{apiTotal.toLocaleString()}</span> in last 24h
              {showTruncationNote && (
                <span className="block text-gray-600">showing {jobs.length.toLocaleString()}</span>
              )}
            </>
          ) : (
            <>{jobs.length} total</>
          )}
          <span className="block text-gray-600">auto-refreshing</span>
        </div>
      </div>

      {/* Kanban columns */}
      <div className="flex-1 grid grid-cols-4 gap-3 overflow-hidden">
        {STATUS_COLUMNS.map((col) => {
          const isCompleted = col.key === 'completed';
          const displayedCount = byStatus[col.key]?.length ?? 0;

          // For the completed column header: show API total if available and larger
          const headerCount = isCompleted && apiTotal !== null && apiTotal > displayedCount
            ? apiTotal
            : displayedCount;

          const showParens = isCompleted && apiTotal !== null && apiTotal > displayedCount;

          return (
            <div key={col.key} className="flex flex-col bg-[#111111] rounded-lg border border-[#1F2121] overflow-hidden">
              <div className={`px-3 py-2 text-sm font-semibold border-b border-[#1F2121] ${col.color}`}>
                <span>{col.label}</span>
                {showParens ? (
                  <span className="font-normal text-xs ml-1">
                    ({headerCount.toLocaleString()}
                    <span className="text-gray-600 ml-1">showing {displayedCount.toLocaleString()}</span>)
                  </span>
                ) : (
                  <span className="font-normal text-xs ml-1">({displayedCount})</span>
                )}
              </div>
              <div className="flex-1 overflow-y-auto p-2 space-y-2">
                {(byStatus[col.key] ?? []).map((job) => (
                  <div
                    key={job.prompt_id}
                    onClick={() => setSelectedJobId(job.prompt_id)}
                    className="rounded-md border border-[#2A2C2C] bg-[#191A1A] px-3 py-2 text-xs shadow-sm hover:border-cyan-800 hover:bg-[#1A1D1D] cursor-pointer transition-colors"
                  >
                    <div className="font-mono text-gray-400 truncate text-[11px]">
                      {job.prompt_id.slice(0, 8)}
                    </div>
                    <div className="text-gray-100 mt-1 truncate" title={job.prompt_name}>
                      {job.prompt_name.length > 50
                        ? job.prompt_name.slice(0, 50) + '...'
                        : job.prompt_name}
                    </div>
                    <div className="flex justify-between items-center mt-1">
                      <div className="text-gray-500 text-[10px]">
                        {new Date(job.created_at).toLocaleTimeString()}
                      </div>
                      {job.completed_at && (
                        <div className="text-gray-600 text-[10px]">
                          {formatDuration(job.created_at, job.completed_at)}
                        </div>
                      )}
                    </div>
                  </div>
                ))}
                {(byStatus[col.key] ?? []).length === 0 && (
                  <div className="text-gray-600 text-xs text-center py-8">No jobs</div>
                )}
              </div>
            </div>
          );
        })}
      </div>

      {/* Detail modal */}
      {selectedJobId && (
        <JobDetailPanel jobId={selectedJobId} onClose={() => setSelectedJobId(null)} />
      )}
    </div>
  );
}
