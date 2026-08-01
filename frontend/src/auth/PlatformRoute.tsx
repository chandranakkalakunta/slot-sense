import { type ReactNode } from "react";
import { Navigate } from "react-router-dom";

import { useAuth } from "./AuthContext";
import { usePasswordGate } from "./usePasswordGate";

export function PlatformRoute({ children }: { children: ReactNode }) {
  const { user, claims, loading } = useAuth();
  const { mustChange, loading: pwLoading } = usePasswordGate();
  if (loading || pwLoading) return <p style={{ padding: 24 }}>Loading…</p>;
  if (!user) return <Navigate to="/signin" replace />;
  if (claims?.role !== "platform_admin") return <Navigate to="/" replace />;
  if (mustChange) return <Navigate to="/force-password" replace />;
  return <>{children}</>;
}
