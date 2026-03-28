import Cookies from "js-cookie";
import axios from "axios";
import { getApiBaseUrl } from "./config";

const AUTH_COOKIE = "laddr_auth";
const AUTH_USER_KEY = "auth_user";
const AUTH_ROLE_KEY = "auth_role";
const AUTH_SESSION_KEY = "auth_session_id";

export type UserRole = "admin" | "read_only";

export interface AuthUser {
  username: string;
  role: UserRole;
  sessionId: string;
  authenticated: boolean;
}

interface DashboardCredential {
  username: string;
  password: string;
  role: UserRole;
}

interface LoginResponse {
  username: string;
  role: UserRole;
}

const parseDashUsers = (): DashboardCredential[] => {
  const dashUsers = import.meta.env.VITE_DASH_USERS || "admin:admin:admin";
  return dashUsers
    .split(",")
    .map((entry: string) => {
      const [u, p, roleRaw] = entry.split(":");
      const username = u?.trim();
      const password = p?.trim();
      if (!username || !password) {
        return null;
      }
      const role = roleRaw?.trim() === "admin" ? "admin" : "read_only";
      return { username, password, role };
    })
    .filter((credential): credential is DashboardCredential => credential !== null);
};

const generateSessionId = (): string => {
  if (typeof crypto !== "undefined" && typeof crypto.randomUUID === "function") {
    return crypto.randomUUID();
  }
  return `session-${Date.now()}-${Math.random().toString(36).slice(2, 10)}`;
};

const setAuthenticatedUser = (username: string, role: UserRole): void => {
  const sessionId = generateSessionId();
  const token = btoa(`${username}:${Date.now()}`);
  Cookies.set(AUTH_COOKIE, token, { expires: 7, sameSite: "lax", secure: false });
  localStorage.setItem("auth_token", token);
  localStorage.setItem(AUTH_USER_KEY, username);
  localStorage.setItem(AUTH_ROLE_KEY, role);
  localStorage.setItem(AUTH_SESSION_KEY, sessionId);
};

export const login = async (username: string, password: string): Promise<boolean> => {
  try {
    const { data } = await axios.post<LoginResponse>(
      `${getApiBaseUrl()}/api/auth/login`,
      { username, password },
      { headers: { "Content-Type": "application/json" } }
    );
    const role: UserRole = data.role === "admin" ? "admin" : "read_only";
    setAuthenticatedUser(data.username, role);
    return true;
  } catch {
    // Fallback for deployments still using env-only auth.
    const userPairs = parseDashUsers();
    const validUser = userPairs.find(
      (u) => u.username === username && u.password === password
    );
    if (!validUser) {
      return false;
    }
    setAuthenticatedUser(username, validUser.role);
    return true;
  }
};

export const logout = () => {
  Cookies.remove(AUTH_COOKIE);
  localStorage.removeItem("auth_token");
  localStorage.removeItem(AUTH_USER_KEY);
  localStorage.removeItem(AUTH_ROLE_KEY);
  localStorage.removeItem(AUTH_SESSION_KEY);
};

export const isAuthenticated = (): boolean => {
  return !!Cookies.get(AUTH_COOKIE) || !!localStorage.getItem("auth_token");
};

export const getCurrentUser = (): AuthUser | null => {
  const token = Cookies.get(AUTH_COOKIE) || localStorage.getItem("auth_token");
  const username = localStorage.getItem(AUTH_USER_KEY);
  const roleRaw = localStorage.getItem(AUTH_ROLE_KEY);
  const sessionId = localStorage.getItem(AUTH_SESSION_KEY);
  const role: UserRole = roleRaw === "admin" ? "admin" : "read_only";

  if (token && username && sessionId) {
    return {
      username,
      role,
      sessionId,
      authenticated: true,
    };
  }

  return null;
};

export const isAdmin = (): boolean => {
  const user = getCurrentUser();
  return user?.role === "admin";
};

export const canWrite = (): boolean => {
  return isAdmin();
};
