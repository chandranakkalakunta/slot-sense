import { type FormEvent, useState } from "react";
import { Eye, EyeOff } from "lucide-react";
import { Navigate, useNavigate } from "react-router-dom";
import { useQueryClient } from "@tanstack/react-query";

import { PASSWORD_GATE_QUERY_KEY } from "../auth/usePasswordGate";
import { useAuth } from "../auth/AuthContext";
import { ApiClientError } from "../lib/api";
import { apiFetch } from "../lib/api";
import { messageForCode } from "../lib/messages";
import { AuthCard } from "../components/AuthCard";
import { Button } from "../components/ui/button";
import { Input } from "../components/ui/input";

export default function ForcePasswordChange() {
  const navigate = useNavigate();
  const queryClient = useQueryClient();
  const { user, loading, signOut } = useAuth();
  const [pw, setPw] = useState("");
  const [confirm, setConfirm] = useState("");
  const [showPw, setShowPw] = useState(false);
  const [showConfirm, setShowConfirm] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  async function submit(e: FormEvent) {
    e.preventDefault();
    setError(null);
    if (pw.length < 8) { setError("Password must be at least 8 characters."); return; }
    if (pw !== confirm) { setError("Passwords don't match."); return; }
    setBusy(true);
    try {
      await apiFetch("/users/me/change-password", {
        method: "POST", body: JSON.stringify({ new_password: pw }),
      });
      // /force-password has no active usePasswordGate observer (it's
      // a standalone route), so a default refetch ("active" only) is
      // a silent no-op and the gate's first render after navigate()
      // would read the stale cached true synchronously. type: "all"
      // forces it regardless of observers; setQueryData below is the
      // final guarantee even if this refetch fails.
      try {
        await queryClient.refetchQueries({ queryKey: PASSWORD_GATE_QUERY_KEY, type: "all" });
      } catch {
        // Best-effort refresh; the password change above already
        // succeeded. setQueryData below still guarantees a correct
        // gate read regardless of this failing.
      }
      queryClient.setQueryData(
        PASSWORD_GATE_QUERY_KEY,
        (old: { must_change_password?: boolean } | undefined) =>
          old ? { ...old, must_change_password: false } : old,
      );
      navigate("/");
    } catch (e) {
      setError(e instanceof ApiClientError ? messageForCode(e.code) : "Failed to change password.");
    } finally {
      setBusy(false);
    }
  }

  if (loading) return <p className="p-6">Loading…</p>;
  if (!user) return <Navigate to="/signin" replace />;

  return (
    <AuthCard title="Set a new password">
      <p className="text-sm text-muted-foreground">
        Your account uses a temporary code. Please set a new password (at least
        8 characters, hard to guess) to continue.
      </p>
      <form onSubmit={submit} className="space-y-2">
        <div className="space-y-1">
          <label htmlFor="force-pw" className="text-sm font-medium text-foreground">
            New password
          </label>
          <div className="relative">
            <Input
              id="force-pw"
              type={showPw ? "text" : "password"}
              placeholder="New password"
              value={pw}
              onChange={(e) => setPw(e.target.value)}
              required
              className="pr-10"
            />
            <button
              type="button"
              onClick={() => setShowPw((s) => !s)}
              aria-label={showPw ? "Hide password" : "Show password"}
              className="absolute right-2 top-2 text-muted-foreground hover:text-foreground"
            >
              {showPw ? <EyeOff className="size-5" /> : <Eye className="size-5" />}
            </button>
          </div>
        </div>
        <div className="space-y-1">
          <label htmlFor="force-confirm" className="text-sm font-medium text-foreground">
            Confirm new password
          </label>
          <div className="relative">
            <Input
              id="force-confirm"
              type={showConfirm ? "text" : "password"}
              placeholder="Confirm new password"
              value={confirm}
              onChange={(e) => setConfirm(e.target.value)}
              required
              className="pr-10"
            />
            <button
              type="button"
              onClick={() => setShowConfirm((s) => !s)}
              aria-label={showConfirm ? "Hide confirm password" : "Show confirm password"}
              className="absolute right-2 top-2 text-muted-foreground hover:text-foreground"
            >
              {showConfirm ? <EyeOff className="size-5" /> : <Eye className="size-5" />}
            </button>
          </div>
        </div>
        <Button type="submit" disabled={busy} className="w-full">
          {busy ? "Saving…" : "Set password"}
        </Button>
      </form>
      {error && <p className="text-sm text-destructive">{error}</p>}
      <p className="text-sm">
        <button
          type="button"
          onClick={() => signOut().then(() => navigate("/signin"))}
          className="text-muted-foreground hover:text-foreground bg-transparent border-0 p-0 cursor-pointer"
        >
          Sign out
        </button>
      </p>
    </AuthCard>
  );
}
