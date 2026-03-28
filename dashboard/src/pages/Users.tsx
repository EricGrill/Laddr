import { FormEvent, useMemo, useState } from "react";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { createAdminUser, deleteAdminUser, listAdminUsers } from "../lib/api";

type NewRole = "admin" | "read_only";

export default function UsersPage() {
  const queryClient = useQueryClient();
  const [username, setUsername] = useState("");
  const [password, setPassword] = useState("");
  const [role, setRole] = useState<NewRole>("read_only");
  const [error, setError] = useState("");

  const usersQuery = useQuery({
    queryKey: ["admin-users"],
    queryFn: listAdminUsers,
    refetchInterval: 15000,
  });

  const createMutation = useMutation({
    mutationFn: () => createAdminUser(username.trim(), password, role),
    onSuccess: () => {
      setUsername("");
      setPassword("");
      setRole("read_only");
      setError("");
      queryClient.invalidateQueries({ queryKey: ["admin-users"] });
    },
    onError: (err: any) => {
      setError(err?.response?.data?.detail || err?.message || "Failed to create user");
    },
  });

  const deleteMutation = useMutation({
    mutationFn: (targetUsername: string) => deleteAdminUser(targetUsername),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["admin-users"] });
    },
  });

  const sortedUsers = useMemo(
    () => [...(usersQuery.data || [])].sort((a, b) => a.username.localeCompare(b.username)),
    [usersQuery.data]
  );

  const handleCreate = (event: FormEvent) => {
    event.preventDefault();
    if (username.trim().length < 3) {
      setError("Username must be at least 3 characters.");
      return;
    }
    if (password.length < 6) {
      setError("Password must be at least 6 characters.");
      return;
    }
    createMutation.mutate();
  };

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold text-white">Users</h1>
        <p className="text-sm text-gray-400 mt-1">Create and delete dashboard users.</p>
      </div>

      <form onSubmit={handleCreate} className="grid grid-cols-1 md:grid-cols-4 gap-3 bg-[#1F2121] p-4 rounded-lg border border-[#2A2C2C]">
        <input
          value={username}
          onChange={(e) => setUsername(e.target.value)}
          placeholder="Username"
          className="px-3 py-2 bg-[#171717] border border-[#2A2C2C] rounded text-white"
        />
        <input
          value={password}
          onChange={(e) => setPassword(e.target.value)}
          type="password"
          placeholder="Password"
          className="px-3 py-2 bg-[#171717] border border-[#2A2C2C] rounded text-white"
        />
        <select
          value={role}
          onChange={(e) => setRole(e.target.value as NewRole)}
          className="px-3 py-2 bg-[#171717] border border-[#2A2C2C] rounded text-white"
        >
          <option value="read_only">read_only</option>
          <option value="admin">admin</option>
        </select>
        <button
          type="submit"
          disabled={createMutation.isPending}
          className="px-3 py-2 bg-[#1FB8CD] text-black font-semibold rounded disabled:opacity-60"
        >
          {createMutation.isPending ? "Creating..." : "Create User"}
        </button>
      </form>

      {error && <div className="text-red-400 text-sm">{error}</div>}

      <div className="overflow-x-auto border border-[#2A2C2C] rounded-lg">
        <table className="min-w-full text-sm">
          <thead className="bg-[#1F2121] text-gray-300">
            <tr>
              <th className="text-left px-4 py-3">Username</th>
              <th className="text-left px-4 py-3">Role</th>
              <th className="text-left px-4 py-3">Created</th>
              <th className="text-left px-4 py-3">Actions</th>
            </tr>
          </thead>
          <tbody>
            {usersQuery.isLoading && (
              <tr><td className="px-4 py-4 text-gray-400" colSpan={4}>Loading users...</td></tr>
            )}
            {!usersQuery.isLoading && sortedUsers.length === 0 && (
              <tr><td className="px-4 py-4 text-gray-500" colSpan={4}>No users found.</td></tr>
            )}
            {sortedUsers.map((user) => (
              <tr key={user.id} className="border-t border-[#1F2121] text-gray-200">
                <td className="px-4 py-3">{user.username}</td>
                <td className="px-4 py-3">{user.role}</td>
                <td className="px-4 py-3">{new Date(user.created_at).toLocaleString()}</td>
                <td className="px-4 py-3">
                  <button
                    onClick={() => deleteMutation.mutate(user.username)}
                    className="text-red-400 hover:text-red-300 disabled:opacity-60"
                    disabled={deleteMutation.isPending}
                  >
                    Delete
                  </button>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  );
}
