import { type FormEvent, useState } from "react";
import { Link } from "react-router-dom";

import { AuthCard } from "../components/AuthCard";
import { Button } from "../components/ui/button";
import { Input } from "../components/ui/input";
import { ApiClientError, apiFetch } from "../lib/api";
import { messageForCode } from "../lib/messages";

export default function Account() {
  const [pw, setPw] = useState("");
  const [confirm, setConfirm] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [done, setDone] = useState(false);

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
      setDone(true);
    } catch (e) {
      setError(e instanceof ApiClientError ? messageForCode(e.code) : "Failed to change password.");
    } finally {
      setBusy(false);
    }
  }

  if (done) {
    return (
      <AuthCard title="Change password">
        <p className="text-sm text-foreground">Your password has been changed.</p>
        <Link to="/" className="block text-sm font-medium text-link underline underline-offset-2 hover:text-link/70">
          Back to home
        </Link>
      </AuthCard>
    );
  }

  return (
    <AuthCard title="Change password">
      <Link to="/" className="block text-sm font-medium text-link underline underline-offset-2 hover:text-link/70">← Back</Link>
      <p className="text-sm text-muted-foreground">Update your account password.</p>
      <form onSubmit={submit} className="space-y-2">
        <div className="space-y-1">
          <label htmlFor="account-pw" className="text-sm font-medium text-foreground">
            New password
          </label>
          <Input
            id="account-pw"
            type="password"
            placeholder="New password"
            value={pw}
            onChange={(e) => setPw(e.target.value)}
            required
          />
        </div>
        <div className="space-y-1">
          <label htmlFor="account-confirm" className="text-sm font-medium text-foreground">
            Confirm new password
          </label>
          <Input
            id="account-confirm"
            type="password"
            placeholder="Confirm new password"
            value={confirm}
            onChange={(e) => setConfirm(e.target.value)}
            required
          />
        </div>
        <Button type="submit" disabled={busy} className="w-full">
          {busy ? "Saving…" : "Change password"}
        </Button>
      </form>
      {error && <p className="text-sm text-destructive">{error}</p>}
    </AuthCard>
  );
}
