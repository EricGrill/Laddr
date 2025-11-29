import { useBatches } from '../lib/queries/batches';
import { Clock, CheckCircle, XCircle, Loader2, ChevronRight } from 'lucide-react';
import { useNavigate } from 'react-router-dom';
import { format } from 'date-fns';

export default function Batches() {
  const { data: batches, isLoading } = useBatches(50);
  const navigate = useNavigate();

  const getStatusIcon = (status: string) => {
    switch (status) {
      case 'completed':
        return <CheckCircle className="w-5 h-5 text-green-400" />;
      case 'failed':
        return <XCircle className="w-5 h-5 text-red-400" />;
      case 'running':
      case 'submitted':
        return <Loader2 className="w-5 h-5 text-blue-400 animate-spin" />;
      default:
        return <Clock className="w-5 h-5 text-gray-400" />;
    }
  };

  const getStatusColor = (status: string) => {
    switch (status) {
      case 'completed':
        return 'text-green-400 bg-green-400/10';
      case 'failed':
        return 'text-red-400 bg-red-400/10';
      case 'running':
      case 'submitted':
        return 'text-blue-400 bg-blue-400/10';
      default:
        return 'text-gray-400 bg-gray-400/10';
    }
  };

  const calculateDuration = (createdAt?: string, completedAt?: string) => {
    if (!createdAt) return '-';
    const start = new Date(createdAt).getTime();
    const end = completedAt ? new Date(completedAt).getTime() : Date.now();
    const ms = Math.max(0, end - start);
    if (ms < 1000) return `${ms}ms`;
    if (ms < 60000) return `${(ms / 1000).toFixed(1)}s`;
    return `${(ms / 60000).toFixed(1)}m`;
  };

  if (isLoading) {
    return (
      <div className="flex items-center justify-center h-64">
        <p className="text-gray-400">Loading batches...</p>
      </div>
    );
  }

  return (
    <div className="space-y-6 bg-[#191A1A] p-6">
      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-2xl font-bold text-white">Batches</h1>
          <p className="text-sm text-gray-400 mt-1">
            View and manage batch operations
          </p>
        </div>
      </div>

      <div className="bg-[#1F2121] rounded-lg border border-gray-800 overflow-hidden">
        {!batches || batches.length === 0 ? (
          <div className="text-center py-12 text-gray-400">
            <Clock className="w-12 h-12 mx-auto mb-4 text-gray-600" />
            <p>No batches found</p>
          </div>
        ) : (
          <table className="w-full">
            <thead className="bg-[#191A1A]">
              <tr>
                <th className="px-6 py-3 text-left text-xs font-medium text-gray-400 uppercase tracking-wider">
                  Status
                </th>
                <th className="px-6 py-3 text-left text-xs font-medium text-gray-400 uppercase tracking-wider">
                  Batch ID
                </th>
                <th className="px-6 py-3 text-left text-xs font-medium text-gray-400 uppercase tracking-wider">
                  Agent
                </th>
                <th className="px-6 py-3 text-left text-xs font-medium text-gray-400 uppercase tracking-wider">
                  Tasks
                </th>
                <th className="px-6 py-3 text-left text-xs font-medium text-gray-400 uppercase tracking-wider">
                  Jobs
                </th>
                <th className="px-6 py-3 text-left text-xs font-medium text-gray-400 uppercase tracking-wider">
                  Created
                </th>
                <th className="px-6 py-3 text-left text-xs font-medium text-gray-400 uppercase tracking-wider">
                  Duration
                </th>
                <th className="px-6 py-3 text-left text-xs font-medium text-gray-400 uppercase tracking-wider">
                  Actions
                </th>
              </tr>
            </thead>
            <tbody className="divide-y divide-gray-800">
              {batches.map((batch) => {
                const duration = calculateDuration(
                  batch.created_at,
                  batch.completed_at
                );
                return (
                  <tr
                    key={batch.batch_id}
                    className="hover:bg-[#252525] transition-colors"
                  >
                    <td className="px-6 py-4">
                      <div className="flex items-center gap-2">
                        {getStatusIcon(batch.status)}
                        <span
                          className={`text-xs px-2 py-1 rounded font-medium ${getStatusColor(
                            batch.status
                          )}`}
                        >
                          {batch.status}
                        </span>
                      </div>
                    </td>
                    <td className="px-6 py-4">
                      <code className="text-sm text-gray-300 font-mono">
                        {batch.batch_id.slice(0, 8)}
                      </code>
                    </td>
                    <td className="px-6 py-4">
                      <div className="text-white font-medium">
                        {batch.agent_name}
                      </div>
                    </td>
                    <td className="px-6 py-4 text-gray-300">
                      {batch.task_count}
                    </td>
                    <td className="px-6 py-4 text-gray-300">
                      {batch.job_ids?.length || 0}
                    </td>
                    <td className="px-6 py-4 text-gray-400">
                      {batch.created_at
                        ? format(new Date(batch.created_at), 'MMM d, HH:mm:ss')
                        : '-'}
                    </td>
                    <td className="px-6 py-4 text-gray-400">{duration}</td>
                    <td className="px-6 py-4">
                      <button
                        onClick={() => navigate(`/batches/${batch.batch_id}`)}
                        className="flex items-center gap-1 text-sm text-[#1FB8CD] hover:text-cyan-300 transition-colors"
                      >
                        View Traces
                        <ChevronRight className="w-4 h-4" />
                      </button>
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        )}
      </div>
    </div>
  );
}
