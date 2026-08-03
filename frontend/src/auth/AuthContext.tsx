import {
  GoogleAuthProvider,
  onIdTokenChanged,
  signInWithEmailAndPassword,
  signInWithPopup,
  signOut as fbSignOut,
  type User,
} from "firebase/auth";
import {
  createContext,
  useContext,
  useEffect,
  useMemo,
  useState,
  type ReactNode,
} from "react";
import { useQueryClient } from "@tanstack/react-query";

import { ClaimsErrorFallback } from "../components/ClaimsErrorFallback";
import { loadBrandingForSlug } from "../lib/branding";
import { setClaimsErrorHandler } from "../lib/api";
import { auth } from "../lib/firebase";

/** Per-env base domain (ADR-0046). Must match SPORTSLOT_BASE_DOMAIN / Terraform
 *  var.base_domain for this build (e.g. slotsense-test.chandraailabs.com). */
export function baseDomain(): string {
  return import.meta.env.VITE_BASE_DOMAIN || "slotsense.chandraailabs.com";
}

/**
 * Mirrors the backend's `_slug_from_host` three-way logic (ADR-0007):
 *   exact apex → "" (recognized SlotSense host, no tenant)
 *   {x}.apex   → "{x}" (tenant subdomain)
 *   anything else (localhost, *.web.app, *.run.app, unknown) → null (skip check)
 */
export function slugFromHost(hostname: string, apex: string = baseDomain()): string | null {
  if (hostname === apex) return "";
  if (hostname.endsWith(`.${apex}`)) return hostname.slice(0, hostname.length - apex.length - 1);
  return null;
}

interface AuthState {
  user: User | null;
  idToken: string | null;
  claims: Record<string, unknown> | null;
  loading: boolean;
  claimsError: boolean;
  signIn: (email: string, password: string) => Promise<void>;
  signInWithGoogle: () => Promise<void>;
  signOut: () => Promise<void>;
  retryClaimsRefresh: () => Promise<void>;
}

const Ctx = createContext<AuthState | null>(null);

export function AuthProvider({ children }: { children: ReactNode }) {
  const queryClient = useQueryClient();
  const [user, setUser] = useState<User | null>(null);
  const [idToken, setIdToken] = useState<string | null>(null);
  const [claims, setClaims] = useState<Record<string, unknown> | null>(null);
  const [loading, setLoading] = useState(true);
  const [claimsError, setClaimsError] = useState(false);

  useEffect(() => {
    // Register the claims-error handler so apiFetch can signal this context
    // when a stale-token 401 (AUTH_INVALID_TOKEN "missing provisioned claims") is detected.
    setClaimsErrorHandler(() => setClaimsError(true));
    return () => setClaimsErrorHandler(null);
  }, []);

  useEffect(() => {
    // onIdTokenChanged (not onAuthStateChanged) fires on refresh too,
    // keeping the attached token fresh automatically.
    return onIdTokenChanged(auth, async (u) => {
      setUser(u);
      if (u) {
        const result = await u.getIdTokenResult();
        setIdToken(result.token);
        setClaims(result.claims);

        // Mismatch check: if the current host's slug differs from the token's
        // tenant_slug, sign out and hard-navigate to the correct subdomain.
        // Skips for platform_admin (no tenant_slug) and non-SlotSense hosts
        // (null → local dev / *.web.app / *.run.app).
        const apex = baseDomain();
        const hostSlug = slugFromHost(window.location.hostname, apex);
        if (result.claims.role !== "platform_admin" && hostSlug !== null) {
          const claimSlug = result.claims.tenant_slug;
          if (hostSlug !== claimSlug) {
            await fbSignOut(auth);
            // Stay on this env's base domain (ADR-0046) — never bounce to another zone.
            if (typeof claimSlug === "string" && claimSlug.length > 0) {
              window.location.href = `https://${claimSlug}.${apex}/signin?redirected=1`;
            }
            return;
          }
        }

        const slug = result.claims.tenant_slug;
        if (typeof slug === "string") {
          void loadBrandingForSlug(slug);
        }
      } else {
        setIdToken(null);
        setClaims(null);
      }
      setLoading(false);
    });
  }, []);

  const value = useMemo<AuthState>(
    () => ({
      user,
      idToken,
      claims,
      loading,
      claimsError,
      signIn: async (email, password) => {
        await signInWithEmailAndPassword(auth, email, password);
        // Force a token refresh so the very next API call carries current
        // custom claims (tenant_id, tenant_slug, role), not a stale cached token.
        // Firebase custom claims propagate on next refresh, not immediately.
        await auth.currentUser?.getIdToken(true);
      },
      signInWithGoogle: async () => {
        await signInWithPopup(auth, new GoogleAuthProvider());
        await auth.currentUser?.getIdToken(true);
      },
      signOut: async () => {
        await fbSignOut(auth);
      },
      retryClaimsRefresh: async () => {
        await auth.currentUser?.getIdToken(true);  // force fresh claims
        await queryClient.invalidateQueries();      // re-fetch all stale queries
        setClaimsError(false);                      // dismiss fallback, re-show app
      },
    }),
    [user, idToken, claims, loading, claimsError, queryClient],
  );

  return (
    <Ctx.Provider value={value}>
      {claimsError ? <ClaimsErrorFallback onRetry={value.retryClaimsRefresh} /> : children}
    </Ctx.Provider>
  );
}

export function useAuth(): AuthState {
  const ctx = useContext(Ctx);
  if (!ctx) throw new Error("useAuth must be used within AuthProvider");
  return ctx;
}
