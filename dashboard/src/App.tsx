import { Suspense, lazy } from 'react';
import { Routes, Route, Navigate } from "react-router-dom";
import Layout from "./components/Layout";
import { isAuthenticated, isAdmin } from "./lib/auth";
const MissionControl = lazy(() => import('./pages/MissionControl'));
import Dashboard from "./pages/Dashboard";
import AgentsList from "./pages/Agents/List";
import AgentDetail from "./pages/Agents/Detail";
import CapabilityPlayground from "./pages/CapabilityPlayground";
import Playground from "./pages/Playground";
import PlaygroundHistory from "./pages/PlaygroundHistory";
import PlaygroundDetail from "./pages/PlaygroundDetail";
import Traces from "./pages/Traces";
import Batches from "./pages/Batches";
import BatchDetail from "./pages/BatchDetail";
import Logs from "./pages/Logs";
import Settings from "./pages/Settings";
import JobBoardPage from "./pages/JobBoard";
import Login from "./pages/Login";
import UserSessions from "./pages/UserSessions";
import UsersPage from "./pages/Users";
import Services from "./pages/Services";
import "./App.css";

function App() {
  const authenticated = isAuthenticated();

  return (
    <Routes>
      <Route
        path="/login"
        element={authenticated ? <Navigate to="/" replace /> : <Login />}
      />
      <Route
        path="/*"
        element={
          authenticated ? (
            <Layout>
              <Routes>
                <Route path="/" element={<Dashboard />} />
                <Route path="/agents" element={<AgentsList />} />
                <Route path="/agents/:agentName" element={<AgentDetail />} />
                <Route path="/playground" element={<CapabilityPlayground />} />
                <Route path="/playground-legacy" element={<Playground />} />
                <Route path="/playground-history" element={<PlaygroundHistory />} />
                <Route path="/playground-history/:promptId" element={<PlaygroundDetail />} />
                <Route path="/traces" element={<Traces />} />
                <Route path="/batches" element={<Batches />} />
                <Route path="/batches/:batchId" element={<BatchDetail />} />
                <Route path="/logs" element={<Logs />} />
                <Route path="/settings" element={<Settings />} />
                <Route path="/jobs-board" element={<JobBoardPage />} />
                <Route path="/services" element={<Services />} />
                <Route
                  path="/user-sessions"
                  element={isAdmin() ? <UserSessions /> : <Navigate to="/" replace />}
                />
                <Route
                  path="/users"
                  element={isAdmin() ? <UsersPage /> : <Navigate to="/" replace />}
                />
                <Route path="/mission-control" element={
                  <Suspense fallback={<div className="flex items-center justify-center h-full text-gray-500">Loading Mission Control...</div>}>
                    <MissionControl />
                  </Suspense>
                } />
              </Routes>
            </Layout>
          ) : (
            <Navigate to="/login" replace />
          )
        }
      />
    </Routes>
  );
}

export default App;
