import axios from "axios";
import { getApiBaseUrl } from "./config";
import { canWrite, getCurrentUser } from "./auth";

const API_BASE_URL = getApiBaseUrl();

export const api = axios.create({
  baseURL: API_BASE_URL,
  headers: {
    "Content-Type": "application/json",
  },
});

api.interceptors.request.use((requestConfig) => {
  const user = getCurrentUser();
  if (user) {
    requestConfig.headers["X-Dashboard-User"] = user.username;
    requestConfig.headers["X-Dashboard-Role"] = user.role;
    requestConfig.headers["X-Dashboard-Session-Id"] = user.sessionId;
  }

  const method = (requestConfig.method || "get").toLowerCase();
  const isWriteMethod = method === "post" || method === "put" || method === "patch" || method === "delete";
  const sessionEndpoint = requestConfig.url?.startsWith("/api/auth/sessions/");
  if (isWriteMethod && !sessionEndpoint && !canWrite()) {
    return Promise.reject(new Error("Read-only users cannot perform write actions."));
  }

  return requestConfig;
});

// Response interceptor for error handling (no redirect on 401)
api.interceptors.response.use(
  (response) => response,
  (error) => Promise.reject(error)
);

export const startSessionTracking = async () => {
  await api.post("/api/auth/sessions/start");
};

export const endSessionTracking = async () => {
  await api.post("/api/auth/sessions/end");
};

export interface UserSessionRecord {
  id: number;
  session_id: string;
  username: string;
  role: string;
  login_at: string;
  logout_at: string | null;
  duration_ms: number | null;
  is_active: boolean;
  ip: string | null;
  user_agent: string | null;
}

export const listAdminSessions = async (limit = 100): Promise<UserSessionRecord[]> => {
  const { data } = await api.get<{ sessions: UserSessionRecord[] }>(`/api/admin/sessions?limit=${limit}`);
  return data.sessions;
};

export interface DashboardUserRecord {
  id: number;
  username: string;
  role: "admin" | "read_only";
  created_at: string;
  updated_at: string;
}

export const listAdminUsers = async (): Promise<DashboardUserRecord[]> => {
  const { data } = await api.get<{ users: DashboardUserRecord[] }>("/api/admin/users");
  return data.users;
};

export const createAdminUser = async (
  username: string,
  password: string,
  role: "admin" | "read_only"
): Promise<DashboardUserRecord> => {
  const { data } = await api.post<DashboardUserRecord>("/api/admin/users", {
    username,
    password,
    role,
  });
  return data;
};

export const deleteAdminUser = async (username: string): Promise<void> => {
  await api.delete(`/api/admin/users/${encodeURIComponent(username)}`);
};

export default api;
