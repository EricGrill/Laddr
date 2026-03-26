import { Suspense, lazy } from 'react';
import { Routes, Route, Navigate } from "react-router-dom";
import Layout from "./components/Layout";
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
import "./App.css";

function App() {
  return (
    <Routes>
      <Route
        path="/*"
        element={
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
              <Route path="/mission-control" element={
                <Suspense fallback={<div className="flex items-center justify-center h-full text-gray-500">Loading Mission Control...</div>}>
                  <MissionControl />
                </Suspense>
              } />
            </Routes>
          </Layout>
        }
      />
    </Routes>
  );
}

export default App;
