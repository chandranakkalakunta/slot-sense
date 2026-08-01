import { type FormEvent, useEffect, useState } from "react";
import { Eye, EyeOff } from "lucide-react";
import { Link, useSearchParams } from "react-router-dom";

import { ApiClientError, apiFetch } from "../lib/api";
import { messageForCode } from "../lib/messages";
import { AuthCard } from "../components/AuthCard";
import { Button } from "../components/ui/button";
import { Input } from "../components/ui/input";

export default function ResetPassword() {
  const [searchParams] = useSearchParams();
  // Capture token into state immediately so it survives the URL strip below.
  const [token] = useState(() => searchParams.get("token") ?? "");
  const [pw, setPw] = useState("");
  const [confirm, setConfirm] = useState("");
  const [showPw, setShowPw] = useState(false);
  const [showConfirm, setShowConfirm] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [tokenError, setTokenError] = useState(false);
  const [busy, setBusy] = useState(false);
  const [done, setDone] = useState(false);

  useEffect(() => {
    // Strip token from URL so it doesn't persist in browser history or referrer
    // (ADR-0020 security note). Token is already captured in state above.
    if (token) {
      window.history.replaceState(null, "", "/reset");
    }
  }, []); // eslint-disable-line react-hooks/exhaustive-deps

  if (!token) {
    return (
      <AuthCard title="Reset your password">
        <p className="text-sm text-destructive">
          This reset link is invalid or has expired.
        </p>
        <Link to="/forgot-password" className="block text-sm font-medium text-link underline underline-offset-2 hover:text-link/70">
          Request a new link
        </Link>
      </AuthCard>
    );
  }

  if (done) {
    return (
      <AuthCard title="Reset your password">
        <p className="text-sm text-foreground">Your password has been reset.</p>
        <Link to="/signin" className="block text-sm font-medium text-link underline underline-offset-2 hover:text-link/70">
          Sign in
        </Link>
      </AuthCard>
    );
  }

  async function submit(e: FormEvent) {
    e.preventDefault();
    setError(null);
    setTokenError(false);
    if (pw.length < 8) {
      setError("Password must be at least 8 characters.");
      return;
    }
    if (pw !== confirm) {
      setError("Passwords don't match.");
      return;
    }
    setBusy(true);
    try {
      await apiFetch("/auth/forgot-password/confirm", {
        method: "POST",
        body: JSON.stringify({ token, new_password: pw }),
      });
      setDone(true);
    } catch (e) {
      if (e instanceof ApiClientError) {
        if (e.code === "RESET_TOKEN_INVALID") setTokenError(true);
        setError(messageForCode(e.code));
      } else {
        setError("Failed to reset password.");
      }
    } finally {
      setBusy(false);
    }
  }

  return (
    <AuthCard title="Reset your password">
      <form onSubmit={submit} className="space-y-2">
        <div className="space-y-1">
          <label htmlFor="reset-pw" className="text-sm font-medium text-foreground">
            New password
          </label>
          <div className="relative">
            <Input
              id="reset-pw"
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
          <label htmlFor="reset-confirm" className="text-sm font-medium text-foreground">
            Confirm new password
          </label>
          <div className="relative">
            <Input
              id="reset-confirm"
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
          {busy ? "Resetting…" : "Reset password"}
        </Button>
      </form>
      {error && <p className="text-sm text-destructive">{error}</p>}
      {tokenError && (
        <Link to="/forgot-password" className="block text-sm font-medium text-link underline underline-offset-2 hover:text-link/70">
          Request a new link
        </Link>
      )}
    </AuthCard>
  );
}
