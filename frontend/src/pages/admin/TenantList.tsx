import { useState } from "react";
import { Link } from "react-router-dom";

import { AppHeader } from "../../components/AppHeader";
import { Button } from "../../components/ui/button";
import { ConfirmDialog } from "../../components/ConfirmDialog";
import { Input } from "../../components/ui/input";
import { ListRow } from "../../components/ListRow";
import { Tenant, useDeleteTenantPermanently, useTenants } from "../../hooks/adminHooks";
import { compareTenants, tenantDisplayName } from "../../lib/sort";

export default function TenantList() {
  const { data, isLoading, error } = useTenants();
  const deleteTenant = useDeleteTenantPermanently();
  const [deleteTarget, setDeleteTarget] = useState<Tenant | null>(null);
  const [search, setSearch] = useState("");

  const allTenants = data?.items ?? [];
  const filtered = allTenants
    .filter((t) => {
      if (!search) return true;
      const q = search.toLowerCase();
      const name = tenantDisplayName(t).toLowerCase();
      return name.includes(q) || t.slug.toLowerCase().includes(q);
    })
    .slice()
    .sort(compareTenants);

  return (
    <>
      <AppHeader />
      <main className="mx-auto max-w-4xl px-4 py-5 space-y-3">
        <h1 className="text-xl font-semibold text-foreground">Platform Admin</h1>

        <div className="flex flex-wrap items-center justify-between gap-2">
          <h2 className="text-base font-semibold text-foreground">Tenants</h2>
          <div className="flex flex-wrap gap-1.5">
            <Button asChild variant="outline" size="sm">
              <Link to="/admin/facility-catalog" style={{ textDecoration: "none" }}>
                Facility catalog
              </Link>
            </Button>
            <Button asChild variant="outline" size="sm">
              <Link to="/admin/tenants/new" style={{ textDecoration: "none" }}>
                + New tenant
              </Link>
            </Button>
          </div>
        </div>

        {isLoading && <p className="text-sm text-muted-foreground">Loading tenants…</p>}
        {error && <p className="text-sm text-destructive">Couldn't load tenants.</p>}
        {!isLoading && !error && allTenants.length === 0 && (
          <p className="text-sm text-muted-foreground">No tenants yet.</p>
        )}

        {/* Search — client-side filter of the current page only */}
        {!isLoading && !error && allTenants.length > 0 && (
          <Input
            placeholder="Search by name or slug…"
            value={search}
            onChange={(e) => setSearch(e.target.value)}
            className="max-w-md h-8"
            aria-label="Search tenants"
          />
        )}
        {allTenants.length > 0 && filtered.length === 0 && (
          <p className="text-sm text-muted-foreground">No tenants match "{search}".</p>
        )}

        <div className="space-y-1">
          {filtered.map((t) => (
            <ListRow
              key={t.tenant_id}
              action={
                <div className="flex flex-wrap items-center gap-1.5">
                  <Link
                    to={`/admin/tenants/${t.tenant_id}/users/new`}
                    className="text-xs text-primary hover:underline px-1"
                    style={{ textDecoration: "none" }}
                  >
                    + Add admin/user
                  </Link>
                  {/* Permanent delete — irreversible, requires exact slug (ADR-0034 §2) */}
                  <Button
                    variant="destructive"
                    size="xs"
                    onClick={() => setDeleteTarget(t)}
                    disabled={deleteTenant.isPending}
                  >
                    Delete
                  </Button>
                </div>
              }
            >
              <p className="text-sm font-medium text-foreground">
                {tenantDisplayName(t)}
              </p>
              <p className="text-xs text-muted-foreground tabular-nums">
                slug: {t.slug} · {t.active === false ? "inactive" : "active"}
                {t.admin_emails && t.admin_emails.length > 0 && (
                  <> · Admins: {t.admin_emails.join(", ")}</>
                )}
              </p>
            </ListRow>
          ))}
        </div>
      </main>

      {deleteTarget && (
        <ConfirmDialog
          title="Permanently delete tenant"
          body={
            <p>
              This will permanently delete <strong>{deleteTarget.display_name ?? deleteTarget.slug}</strong>,
              all its users, facilities, bookings, and audit logs. This cannot be undone.
            </p>
          }
          confirmLabel="Confirm"
          confirmationPhrase={deleteTarget.slug}
          busy={deleteTenant.isPending}
          onConfirm={() => {
            deleteTenant.mutate(deleteTarget.tenant_id);
            setDeleteTarget(null);
          }}
          onCancel={() => setDeleteTarget(null)}
        />
      )}
    </>
  );
}
