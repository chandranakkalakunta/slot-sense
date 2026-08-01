import { useQuery } from "@tanstack/react-query";

import { apiFetch } from "../lib/api";
import { useAuth } from "./AuthContext";

/** Shared with anything that mutates must_change_password (e.g.
 *  ForcePasswordChange) so the gate's cache can be refreshed under
 *  the exact key it reads — never re-derive this string elsewhere. */
export const PASSWORD_GATE_QUERY_KEY = ["profile"] as const;

/** Returns whether the current user must change their password.
 *  Applies to all roles including platform_admin (ADR-0014 §3–§4;
 *  platform_admins/{uid}.must_change_password via GET /users/me). */
export function usePasswordGate(): { mustChange: boolean; loading: boolean } {
  const { user } = useAuth();
  const { data, isLoading } = useQuery({
    queryKey: PASSWORD_GATE_QUERY_KEY,
    queryFn: () => apiFetch<{ must_change_password?: boolean }>("/users/me"),
    enabled: Boolean(user),
  });
  return { mustChange: Boolean(data?.must_change_password), loading: isLoading };
}
