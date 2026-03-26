import axios from "axios";
import { getApiBaseUrl } from "./config";

const API_BASE_URL = getApiBaseUrl();

export const api = axios.create({
  baseURL: API_BASE_URL,
  headers: {
    "Content-Type": "application/json",
  },
});

// Response interceptor for error handling (no redirect on 401)
api.interceptors.response.use(
  (response) => response,
  (error) => Promise.reject(error)
);

export default api;
