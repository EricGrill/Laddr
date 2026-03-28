import { useQuery } from "@tanstack/react-query";
import { listAdminSessions } from "../lib/api";

const formatDateTime = (value: string | null) => {
  if (!value) {
    return "Active";
  }
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) {
    return value;
  }
  return date.toLocaleString();
};

const formatDuration = (durationMs: number | null) => {
  if (durationMs === null || durationMs === undefined) {
    return "-";
  }
  const totalSeconds = Math.floor(durationMs / 1000);
  const hours = Math.floor(totalSeconds / 3600);
  const minutes = Math.floor((totalSeconds % 3600) / 60);
  const seconds = totalSeconds % 60;
  if (hours > 0) {
    return `${hours}h ${minutes}m ${seconds}s`;
  }
  if (minutes > 0) {
    return `${minutes}m ${seconds}s`;
  }
  return `${seconds}s`;
};

export default function UserSessions() {
  const { data, isLoading, error, refetch, isFetching } = useQuery({
    queryKey: ["admin-user-sessions"],
    queryFn: () => listAdminSessions(200),
    refetchInterval: 15000,
  });

  return (
    <div className="space-y-6">
      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-2xl font-semibold text-white">User Sessions</h1>
          <p className="text-sm text-gray-400 mt-1">
            Track login/logout activity and session durations.
          </p>
        </div>
        <button
          type="button"
          onClick={() => refetch()}
          className="px-3 py-2 rounded-lg border border-[#2A2C2C] text-sm text-gray-300 hover:text-white hover:bg-[#1F2121]"
          disabled={isFetching}
        >
          {isFetching ? "Refreshing..." : "Refresh"}
        </button>
      </div>

      {isLoading && <div className="text-gray-400">Loading sessions...</div>}
      {error && <div className="text-red-400">Failed to load sessions.</div>}

      {!isLoading && !error && (
        <div className="overflow-x-auto border border-[#2A2C2C] rounded-lg">
          <table className="min-w-full text-sm">
            <thead className="bg-[#1F2121] text-gray-300">
              <tr>
                <th className="text-left px-4 py-3">Username</th>
                <th className="text-left px-4 py-3">Role</th>
                <th className="text-left px-4 py-3">Login At</th>
                <th className="text-left px-4 py-3">Logout At</th>
                <th className="text-left px-4 py-3">Duration</th>
                <th className="text-left px-4 py-3">Status</th>
              </tr>
            </thead>
            <tbody>
              {(data || []).map((session) => (
                <tr key={session.id} className="border-t border-[#1F2121] text-gray-200">
                  <td className="px-4 py-3">{session.username}</td>
                  <td className="px-4 py-3">{session.role}</td>
                  <td className="px-4 py-3">{formatDateTime(session.login_at)}</td>
                  <td className="px-4 py-3">{formatDateTime(session.logout_at)}</td>
                  <td className="px-4 py-3">{formatDuration(session.duration_ms)}</td>
                  <td className="px-4 py-3">
                    {session.is_active ? (
                      <span className="text-green-400">Active</span>
                    ) : (
                      <span className="text-gray-400">Ended</span>
                    )}
                  </td>
                </tr>
              ))}
              {(data || []).length === 0 && (
                <tr>
                  <td className="px-4 py-4 text-gray-500" colSpan={6}>
                    No sessions found.
                  </td>
                </tr>
              )}
            </tbody>
          </table>
        </div>
      )}
    </div>
  );
}
