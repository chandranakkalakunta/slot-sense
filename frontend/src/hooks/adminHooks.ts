import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";

import { apiFetch } from "../lib/api";

export interface Tenant {
  tenant_id: string;
  slug: string;
  display_name?: string;
  name?: string;
  active?: boolean;
  created_at?: string;
  admin_emails?: string[];
}

export interface CreatedUser {
  uid: string;
  temp_password: string;
}

export function useTenants() {
  return useQuery({
    queryKey: ["admin", "tenants"],
    queryFn: () => apiFetch<{ items: Tenant[] }>("/admin/tenants"),
  });
}

export function useCreateTenant() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (body: { slug: string; display_name: string }) =>
      apiFetch<{ tenant_id: string; slug: string }>("/admin/tenants", {
        method: "POST", body: JSON.stringify(body),
      }),
    onSuccess: () => qc.invalidateQueries({ queryKey: ["admin", "tenants"] }),
  });
}

export function useDeleteTenantPermanently() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (tenantId: string) =>
      apiFetch(`/admin/tenants/${tenantId}/permanent`, { method: "DELETE" }),
    onSuccess: () => qc.invalidateQueries({ queryKey: ["admin", "tenants"] }),
  });
}

export function useCreateUser(tenantId: string) {
  return useMutation({
    mutationFn: (body: {
      email: string; display_name: string; flat_number?: string;
      role: string; household_id?: string | null;
    }) =>
      apiFetch<CreatedUser>(`/admin/tenants/${tenantId}/users`, {
        method: "POST", body: JSON.stringify(body),
      }),
  });
}

/** Global facility-type catalog (ADR-0015) — platform admin CRUD. */
export interface CatalogType {
  type_id: string;
  name: string;
  sport: string;
}

export function useAdminFacilityCatalog() {
  return useQuery({
    queryKey: ["admin", "facility-catalog"],
    queryFn: () => apiFetch<{ items: CatalogType[] }>("/facility-catalog"),
  });
}

export function useCreateCatalogType() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (body: CatalogType) =>
      apiFetch<CatalogType>("/admin/facility-catalog", {
        method: "POST",
        body: JSON.stringify(body),
      }),
    onSuccess: () => {
      void qc.invalidateQueries({ queryKey: ["admin", "facility-catalog"] });
      void qc.invalidateQueries({ queryKey: ["facility-catalog"] });
    },
  });
}

export function useUpdateCatalogType() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: ({
      type_id,
      ...body
    }: {
      type_id: string;
      name?: string;
      sport?: string;
    }) =>
      apiFetch<CatalogType>(`/admin/facility-catalog/${type_id}`, {
        method: "PATCH",
        body: JSON.stringify(body),
      }),
    onSuccess: () => {
      void qc.invalidateQueries({ queryKey: ["admin", "facility-catalog"] });
      void qc.invalidateQueries({ queryKey: ["facility-catalog"] });
    },
  });
}

export function useDeleteCatalogType() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (typeId: string) =>
      apiFetch(`/admin/facility-catalog/${typeId}`, { method: "DELETE" }),
    onSuccess: () => {
      void qc.invalidateQueries({ queryKey: ["admin", "facility-catalog"] });
      void qc.invalidateQueries({ queryKey: ["facility-catalog"] });
    },
  });
}
