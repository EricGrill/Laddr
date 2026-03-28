import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';
import api from '../api';
import { canWrite } from '../auth';

export interface Batch {
  batch_id: string;
  agent_name: string;
  status: 'running' | 'completed' | 'failed' | 'submitted';
  task_count: number;
  job_ids: string[];  // List of job_ids for individual tasks in this batch
  task_ids: string[];
  inputs?: Record<string, any>;
  outputs?: Record<string, any>;
  created_at?: string;
  completed_at?: string;
}

export const useBatches = (limit = 50) => {
  return useQuery({
    queryKey: ['batches', limit],
    queryFn: async () => {
      const { data } = await api.get<{ batches: Batch[]; limit: number }>(
        `/api/batches?limit=${limit}`
      );
      return data.batches;
    },
    staleTime: 5000,
    refetchOnWindowFocus: true,
  });
};

export const useBatch = (batchId: string) => {
  return useQuery({
    queryKey: ['batches', batchId],
    queryFn: async () => {
      const { data } = await api.get<Batch>(`/api/batches/${batchId}`);
      return data;
    },
    enabled: !!batchId,
    staleTime: 3000,
    refetchOnWindowFocus: true,
  });
};

export const useAddTasksToBatch = () => {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: async ({
      batchId,
      agentName,
      tasks,
      wait = false,
    }: {
      batchId: string;
      agentName: string;
      tasks: Array<Record<string, any>>;
      wait?: boolean;
    }) => {
      if (!canWrite()) {
        throw new Error("Read-only users cannot add tasks to a batch.");
      }
      const { data } = await api.post(`/api/batches/${batchId}/add-tasks`, {
        agent_name: agentName,
        tasks,
        wait,
      });
      return data;
    },
    onSuccess: (_, variables) => {
      queryClient.invalidateQueries({ queryKey: ['batches', variables.batchId] });
      queryClient.invalidateQueries({ queryKey: ['batches'] });
    },
  });
};

