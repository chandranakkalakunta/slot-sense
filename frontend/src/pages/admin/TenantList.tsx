import { useState } from "react";
import { Link } from "react-router-dom";

import { AppHeader } from "../../components/AppHeader";
import { Button } from "../../components/ui/button";
import { ConfirmDialog } from "../../components/ConfirmDialog";
import { Input } from "../../components/ui/input";
import { ListRow } from "../../components/ListRow";
import { Tenant, useDeleteTenantPermanently, useTenants } from "../../hooks/adminHooks";

export default function TenantList() {
  const { data, isLoading, error } = useTenants();
  const deleteTenant = useDeleteTenantPermanently();
  const [deleteTarget, setDeleteTarget] = useState<Tenant | null>(null);
  const [search, setSearch] = useState("");

  const allTenants = data?.items ?? [];
  const filtered = allTenants.filter((t) => {
    if (!search) return true;
    const q = search.toLowerCase();
    const name = (t.display_name ?? t.name ?? t.slug).toLowerCase();
    return name.includes(q) || t.slug.toLowerCase().includes(q);
  });

  return (
    <>
      <AppHeader />
      <main className="mx-auto max-w-6xl px-4 py-6 space-y-4">
        <h1 className="text-2xl font-semibold text-foreground">Platform Admin</h1>

        <div className="flex flex-wrap items-center justify-between gap-2">
          <h2 className="text-lg font-semibold text-foreground">Tenants</h2>
          <div className="flex flex-wrap gap-2">
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
            className="max-w-sm"
            aria-label="Search tenants"
          />
        )}
        {allTenants.length > 0 && filtered.length === 0 && (
          <p className="text-sm text-muted-foreground">No tenants match "{search}".</p>
        )}

        <div className="space-y-2">
          {filtered.map((t) => (
            <ListRow
              key={t.tenant_id}
              action={
                <div className="flex flex-wrap items-center gap-2">
                  <Link
                    to={`/admin/tenants/${t.tenant_id}/users/new`}
                    className="text-sm text-primary hover:underline"
                    style={{ textDecoration: "none" }}
                  >
                    + Add admin/user
                  </Link>
                  {/* Permanent delete — irreversible, requires exact slug (ADR-0034 §2) */}
                  <Button
                    variant="destructive"
                    size="sm"
                    className="flex-1 sm:flex-none"
                    onClick={() => setDeleteTarget(t)}
                    disabled={deleteTenant.isPending}
                  >
                    Delete
                  </Button>
                </div>
              }
            >
              <p className="font-semibold text-foreground">
                {t.display_name ?? t.name ?? t.slug}
              </p>
              <p className="text-sm text-muted-foreground tabular-nums mt-0.5">
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
