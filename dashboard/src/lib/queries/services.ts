import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';
import api from '../api';

export interface ServiceSummary {
  id: string;
  name: string;
  category: string;
  icon: string;
  description: string;
  mcp: string;
  tools: string[];
  available: boolean;
}

export interface ServiceDetail extends ServiceSummary {
  playbook: string;
  tool_schemas: Record<string, any>;
}

export interface ServicesResponse {
  services: ServiceSummary[];
  summary: {
    total: number;
    available: number;
    unavailable: number;
    last_discovered: string | null;
  };
}

export const useServices = () => {
  return useQuery({
    queryKey: ['services'],
    queryFn: async () => {
      const { data } = await api.get<ServicesResponse>('/api/services');
      return data;
    },
    staleTime: 30_000,
    refetchInterval: 60_000,
  });
};

export const useService = (serviceId: string) => {
  return useQuery({
    queryKey: ['services', serviceId],
    queryFn: async () => {
      const { data } = await api.get<ServiceDetail>(`/api/services/${serviceId}`);
      return data;
    },
    enabled: !!serviceId,
  });
};

export const useRefreshServices = () => {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: async () => {
      const { data } = await api.post('/api/services/refresh');
      return data;
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['services'] });
    },
  });
};

export const useSubmitServiceJob = () => {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: async ({
      services, prompt, priority, timeout,
    }: {
      services: string[];
      prompt: string;
      priority: string;
      timeout?: number;
    }) => {
      const { data } = await api.post('/api/jobs/capability', {
        system_prompt: prompt,
        user_prompt: '',
        services,
        priority,
        timeout_seconds: timeout || 300,
      });
      return data;
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['prompts'] });
    },
  });
};
