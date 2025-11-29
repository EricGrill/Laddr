import { useParams, Link, useNavigate } from 'react-router-dom';
import { useBatch } from '../lib/queries/batches';
import { useBatchTraces } from '../lib/hooks/useWebSocket';
import { ArrowLeft, CheckCircle, XCircle, Loader2, Clock, Activity, Database, Zap, ChevronDown, ChevronRight, ExternalLink } from 'lucide-react';
import { format } from 'date-fns';
import { useState, useMemo } from 'react';

interface Span {
  id: number;
  name: string;
  type: 'agent' | 'tool' | 'llm' | 'reasoning' | 'event';
  start_time: string;
  agent: string;
  event_type: string;
  input?: any;
  output?: any;
  metadata: {
    duration_ms?: number;
    tokens?: number;
    cost?: number;
    [key: string]: any;
  };
  children: Span[];
}

interface SpanTreeNodeProps {
  span: Span;
  depth: number;
}

function SpanTreeNode({ span, depth }: SpanTreeNodeProps) {
  const [isExpanded, setIsExpanded] = useState(true);
  const hasChildren = span.children && span.children.length > 0;

  return (
    <>
      <SpanRow
        span={span}
        depth={depth}
        isExpanded={isExpanded}
        onToggle={() => setIsExpanded(!isExpanded)}
      />
      {hasChildren && isExpanded && (
        <>
          {span.children.map((child) => (
            <SpanTreeNode key={child.id} span={child} depth={depth + 1} />
          ))}
        </>
      )}
    </>
  );
}

interface SpanRowProps {
  span: Span;
  depth: number;
  isExpanded: boolean;
  onToggle: () => void;
}

function SpanRow({ span, depth, isExpanded, onToggle }: SpanRowProps) {
  const hasChildren = span.children && span.children.length > 0;

  const getIcon = () => {
    switch (span.type) {
      case 'agent':
        return <Activity className="w-4 h-4 text-cyan-400" />;
      case 'tool':
        return <Database className="w-4 h-4 text-purple-400" />;
      case 'llm':
        return <Database className="w-4 h-4 text-green-400" />;
      case 'reasoning':
        return <Database className="w-4 h-4 text-yellow-400" />;
      default:
        return <div className="w-4 h-4 rounded-full bg-gray-600" />;
    }
  };

  const formatDuration = (ms?: number) => {
    if (!ms) return null;
    if (ms < 1000) return `${ms}ms`;
    return `${(ms / 1000).toFixed(2)}s`;
  };

  return (
    <div className="border-b border-gray-800">
      <div
        className="flex items-center gap-3 py-3 px-4 hover:bg-[#1F2121] cursor-pointer transition-colors"
        style={{ paddingLeft: `${depth * 24 + 16}px` }}
        onClick={onToggle}
      >
        <div className="w-4 h-4 flex-shrink-0">
          {hasChildren &&
            (isExpanded ? (
              <ChevronDown className="w-4 h-4 text-gray-400" />
            ) : (
              <ChevronRight className="w-4 h-4 text-gray-400" />
            ))}
        </div>

        {getIcon()}

        <div className="flex-1 min-w-0">
          <div className="flex items-center gap-2">
            <span className="text-sm font-medium text-white truncate">
              {span.name || span.event_type}
            </span>
            <span className="text-xs text-gray-500">{span.type}</span>
          </div>
          {span.agent && (
            <div className="text-xs text-gray-400 mt-0.5">{span.agent}</div>
          )}
        </div>

        <div className="flex items-center gap-4 text-xs text-gray-400">
          {typeof span.metadata?.tokens === 'number' && (
            <div className="flex items-center gap-1">
              <Zap className="w-3.5 h-3.5" />
              <span>{span.metadata.tokens.toLocaleString()}</span>
            </div>
          )}
          {span.metadata?.duration_ms && (
            <div className="flex items-center gap-1">
              <Clock className="w-3.5 h-3.5" />
              <span>{formatDuration(span.metadata.duration_ms)}</span>
            </div>
          )}
        </div>
      </div>

      {isExpanded && (span.input || span.output || span.event_type === 'llm_usage' || span.event_type === 'autonomous_think') && (
        <div className="px-4 pb-3 bg-[#0D0E0E]" style={{ paddingLeft: `${depth * 24 + 72}px` }}>
          {span.event_type === 'llm_usage' && span.metadata && (
            <div className="mb-2">
              <div className="text-xs text-gray-500 mb-1">LLM Usage:</div>
              <div className="text-xs text-gray-300 bg-[#191A1A] p-2 rounded space-y-1">
                {span.metadata.provider && (
                  <div>
                    <span className="text-gray-500">Provider:</span>
                    <span className="ml-2 text-gray-300">{span.metadata.provider}</span>
                  </div>
                )}
                {span.metadata.model && (
                  <div>
                    <span className="text-gray-500">Model:</span>
                    <span className="ml-2 text-gray-300">{span.metadata.model}</span>
                  </div>
                )}
                {span.metadata.total_tokens != null && (
                  <div>
                    <span className="text-gray-500">Total Tokens:</span>
                    <span className="ml-2 text-cyan-400 font-semibold">
                      {Number(span.metadata.total_tokens).toLocaleString()}
                    </span>
                  </div>
                )}
              </div>
            </div>
          )}

          {span.input && (
            <div className="mb-2">
              <div className="text-xs text-gray-500 mb-1">Input:</div>
              <pre className="text-xs text-gray-300 bg-[#191A1A] p-2 rounded overflow-x-auto">
                {typeof span.input === 'string' ? span.input : JSON.stringify(span.input, null, 2)}
              </pre>
            </div>
          )}

          {span.output && (
            <div>
              <div className="text-xs text-gray-500 mb-1">Output:</div>
              <pre className="text-xs text-gray-300 bg-[#191A1A] p-2 rounded overflow-x-auto">
                {typeof span.output === 'string' ? span.output : JSON.stringify(span.output, null, 2)}
              </pre>
            </div>
          )}
        </div>
      )}
    </div>
  );
}

export default function BatchDetail() {
  const { batchId } = useParams<{ batchId: string }>();
  const { data: batch, isLoading } = useBatch(batchId!);
  const { traces, isConnected, isComplete } = useBatchTraces(batchId || null);
  const navigate = useNavigate();

  const getStatusIcon = () => {
    switch (batch?.status) {
      case 'completed':
        return <CheckCircle className="w-8 h-8 text-green-500" />;
      case 'failed':
        return <XCircle className="w-8 h-8 text-red-500" />;
      case 'running':
      case 'submitted':
        return <Loader2 className="w-8 h-8 text-blue-500 animate-spin" />;
      default:
        return <Clock className="w-8 h-8 text-gray-400" />;
    }
  };

  // Extract spans from traces
  const allSpans: Span[] = traces.length > 0 && traces[0].spans ? traces[0].spans : [];

  // Group spans by job_id from their payload
  const spansByJobId = useMemo(() => {
    const grouped: Record<string, Span[]> = {};
    
    const extractJobId = (span: Span): string | null => {
      // Try to get job_id from span metadata or payload
      if (span.metadata?.job_id) return span.metadata.job_id;
      // Check if span has a payload with job_id
      if ((span as any).payload?.job_id) return (span as any).payload.job_id;
      return null;
    };

    const processSpan = (span: Span) => {
      const jobId = extractJobId(span);
      if (jobId) {
        if (!grouped[jobId]) {
          grouped[jobId] = [];
        }
        grouped[jobId].push(span);
      }
      // Process children recursively
      if (span.children && span.children.length > 0) {
        span.children.forEach(processSpan);
      }
    };

    allSpans.forEach(processSpan);
    return grouped;
  }, [allSpans]);

  // If we can't extract job_ids from spans, try to use batch.job_ids and group by matching
  // For now, we'll show all spans together but add a job list section

  // Calculate metrics
  const calculateTotalTokens = (spanList: Span[]): number => {
    return spanList.reduce((sum, span) => {
      const spanTokens = span.metadata?.tokens || 0;
      const childTokens = calculateTotalTokens(span.children || []);
      return sum + spanTokens + childTokens;
    }, 0);
  };

  const calculateTotalDuration = (spanList: Span[]): number => {
    if (spanList.length === 0) return 0;
    try {
      const firstSpan = spanList[0];
      const firstStartTime = new Date(firstSpan.start_time).getTime();
      const lastSpan = spanList[spanList.length - 1];
      const lastStartTime = new Date(lastSpan.start_time).getTime();
      return lastStartTime - firstStartTime;
    } catch (e) {
      return 0;
    }
  };

  const totalTokens = calculateTotalTokens(allSpans);
  const totalDuration = calculateTotalDuration(allSpans);

  if (isLoading) {
    return (
      <div className="flex items-center justify-center h-64">
        <p className="text-gray-400">Loading batch...</p>
      </div>
    );
  }

  if (!batch) {
    return (
      <div className="text-center py-12">
        <p className="text-gray-400">Batch not found</p>
        <Link to="/batches" className="text-[#1FB8CD] hover:text-cyan-300 mt-4 inline-block">
          Back to batches
        </Link>
      </div>
    );
  }

  return (
    <div className="min-h-screen bg-[#191A1A] p-6 space-y-6">
      <div className="flex items-center gap-4">
        <Link to="/batches" className="p-2 hover:bg-[#1F2121] rounded-lg transition-colors">
          <ArrowLeft className="w-5 h-5 text-gray-400" />
        </Link>
        <div className="flex-1">
          <h1 className="text-2xl font-bold text-white">Batch Details</h1>
          <code className="text-gray-400 text-sm">{batch.batch_id}</code>
        </div>
      </div>

      <div className="bg-[#1F2121] rounded-lg p-6 border border-gray-800">
        <div className="flex items-center gap-4 mb-6">
          {getStatusIcon()}
          <div>
            <h2 className="text-2xl font-bold text-white capitalize">{batch.status}</h2>
            <p className="text-gray-400">Agent: {batch.agent_name}</p>
          </div>
        </div>

        <div className="grid grid-cols-2 md:grid-cols-4 gap-4">
          <div>
            <h3 className="text-sm font-medium text-gray-400 mb-1">Created</h3>
            <p className="text-white">
              {batch.created_at ? format(new Date(batch.created_at), 'MMM d, yyyy HH:mm:ss') : '-'}
            </p>
          </div>
          {batch.completed_at && (
            <div>
              <h3 className="text-sm font-medium text-gray-400 mb-1">Completed</h3>
              <p className="text-white">{format(new Date(batch.completed_at), 'MMM d, yyyy HH:mm:ss')}</p>
            </div>
          )}
          <div>
            <h3 className="text-sm font-medium text-gray-400 mb-1">Tasks</h3>
            <p className="text-white">{batch.task_count}</p>
          </div>
          <div>
            <h3 className="text-sm font-medium text-gray-400 mb-1">Jobs</h3>
            <p className="text-white">{batch.job_ids?.length || 0}</p>
          </div>
        </div>
      </div>

      {/* Job IDs List Section */}
      {batch.job_ids && batch.job_ids.length > 0 && (
        <div className="bg-[#1F2121] rounded-lg border border-gray-800">
          <div className="px-6 py-4 border-b border-gray-800">
            <h2 className="text-lg font-semibold text-white">Jobs in Batch</h2>
            <p className="text-sm text-gray-400 mt-1">
              Each job represents an individual task. Click to view its full trace.
            </p>
          </div>
          <div className="p-6">
            <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-3">
              {batch.job_ids.map((jobId: string) => (
                <Link
                  key={jobId}
                  to={`/traces?job_id=${encodeURIComponent(jobId)}`}
                  className="flex items-center justify-between p-3 bg-[#0D0E0E] border border-gray-800 rounded-lg hover:border-[#1FB8CD] transition-colors group"
                >
                  <div className="flex-1 min-w-0">
                    <div className="text-sm font-medium text-white truncate">
                      {jobId.slice(0, 8)}...
                    </div>
                    <div className="text-xs text-gray-400 mt-1">Job ID</div>
                  </div>
                  <ExternalLink className="w-4 h-4 text-gray-400 group-hover:text-[#1FB8CD] transition-colors flex-shrink-0 ml-2" />
                </Link>
              ))}
            </div>
          </div>
        </div>
      )}

      {/* Live Traces Section */}
      {(batch.status === 'running' || allSpans.length > 0) && (
        <div className="border-t-2 border-t-[#1FB8CD] bg-[#0D0E0E] rounded-lg shadow-[0_-4px_6px_-1px_rgba(0,0,0,0.3)]">
          <div className="px-6 py-3 border-b border-gray-800 bg-[#0D0E0E] flex items-center justify-between">
            <div className="flex items-center gap-3">
              <h2 className="text-sm font-semibold text-white">All Traces</h2>
              {isConnected && !isComplete && (
                <span className="flex items-center gap-1.5 text-xs text-cyan-400">
                  <span className="w-2 h-2 bg-cyan-400 rounded-full animate-pulse" />
                  Running
                </span>
              )}
              {isComplete && (
                <span className="text-xs px-2 py-1 rounded bg-green-500/20 text-green-400">
                  Completed
                </span>
              )}
            </div>

            <div className="flex items-center gap-6">
              {allSpans.length > 0 && (
                <div className="flex items-center gap-6 text-xs text-gray-400">
                  <div className="flex items-center gap-1.5">
                    <Database className="w-3.5 h-3.5" />
                    <span>{allSpans.length} spans</span>
                  </div>
                  {totalTokens > 0 && (
                    <div className="flex items-center gap-1.5">
                      <Zap className="w-3.5 h-3.5" />
                      <span>{totalTokens.toLocaleString()} tokens</span>
                    </div>
                  )}
                  {isComplete && totalDuration > 0 && (
                    <div className="flex items-center gap-1.5">
                      <Clock className="w-3.5 h-3.5" />
                      <span>{(totalDuration / 1000).toFixed(2)}s</span>
                    </div>
                  )}
                </div>
              )}
            </div>
          </div>

          <div className="h-96 overflow-y-auto bg-[#0D0E0E]">
            {allSpans.length === 0 ? (
              <div className="flex items-center justify-center h-full text-gray-500">
                <div className="text-center">
                  <Activity className="w-12 h-12 mx-auto mb-3 opacity-50" />
                  <p className="text-sm">Waiting for traces...</p>
                </div>
              </div>
            ) : (
              <div className="p-4 space-y-1">
                {allSpans.map((span, index) => (
                  <div
                    key={`${span.id}-${index}`}
                    className="opacity-0 animate-[fadeInSlide_0.3s_ease-out_forwards]"
                    style={{ animationDelay: `${index * 50}ms` }}
                  >
                    <SpanTreeNode span={span} depth={0} />
                  </div>
                ))}
              </div>
            )}
          </div>
        </div>
      )}

      {batch.outputs && (
        <div className="bg-[#1F2121] rounded-lg border border-gray-800">
          <div className="px-6 py-4 border-b border-gray-800">
            <h2 className="text-lg font-semibold text-white">Outputs</h2>
          </div>
          <div className="p-6">
            <div className="bg-[#0D0E0E] rounded-lg p-4 border border-gray-800">
              <pre className="text-sm text-gray-300 overflow-x-auto whitespace-pre-wrap">
                {typeof batch.outputs === 'string'
                  ? batch.outputs
                  : JSON.stringify(batch.outputs, null, 2)}
              </pre>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}

