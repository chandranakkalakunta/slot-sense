import { type ChangeEvent, type FormEvent, useRef, useState } from "react";
import { Link } from "react-router-dom";

import { AppHeader } from "../../components/AppHeader";
import { Button } from "../../components/ui/button";
import { ConfirmDialog } from "../../components/ConfirmDialog";
import { type Credential } from "../../components/CredentialDisplay";
import { Input } from "../../components/ui/input";
import { ListRow } from "../../components/ListRow";
import { TempPasswordModal } from "../../components/TempPasswordModal";
import {
  useBulkCreateUsers, useCreateTenantUser,
  useDeleteTenantUserPermanently, useResetTenantUserPassword, useTenantUsers,
} from "../../hooks/tenantAdminHooks";
import { ApiClientError } from "../../lib/api";
import { messageForCode } from "../../lib/messages";
import { compareUsers } from "../../lib/sort";

// Minimal CSV parser — splits on newlines and commas; first row = header.
// Note: quoted fields containing commas are NOT handled (acceptable for v1).
function parseCSV(text: string): Record<string, string>[] {
  const lines = text.trim().split("\n").filter(Boolean);
  if (lines.length < 2) return [];
  const headers = lines[0].split(",").map((h) => h.trim());
  return lines.slice(1).map((line) => {
    const vals = line.split(",").map((v) => v.trim());
    return Object.fromEntries(headers.map((h, i) => [h, vals[i] ?? ""]));
  });
}

function fieldErrorMsg(e: ApiClientError): string {
  if (e.detail && e.detail.length > 0) {
    return e.detail.map((f) => `${String(f.loc.at(-1))}: ${f.msg}`).join("; ");
  }
  return messageForCode(e.code);
}

export default function TenantUsers() {
  const { data, isLoading } = useTenantUsers();
  const createUser = useCreateTenantUser();
  const deletePermanently = useDeleteTenantUserPermanently();
  const resetPw = useResetTenantUserPassword();
  const bulkCreate = useBulkCreateUsers();

  // Search
  const [search, setSearch] = useState("");

  // Add-user form
  const [email, setEmail] = useState("");
  const [displayName, setDisplayName] = useState("");
  const [flat, setFlat] = useState("");
  const [role, setRole] = useState("resident");
  const [addError, setAddError] = useState<string | null>(null);
  const [newCred, setNewCred] = useState<Credential | null>(null);

  // Reset-password per-user
  const [resetCred, setResetCred] = useState<Credential | null>(null);
  const [resetError, setResetError] = useState<string | null>(null);

  // Permanent delete confirm
  const [deleteUid, setDeleteUid] = useState<string | null>(null);

  // Bulk CSV
  const csvInputRef = useRef<HTMLInputElement>(null);
  const [csvFileName, setCsvFileName] = useState<string | null>(null);
  type BulkResult = { row: number; email: string; status: string; temp_password?: string; reason?: string };
  const [bulkReport, setBulkReport] = useState<{
    total: number; created: number; failed: number; results: BulkResult[];
  } | null>(null);
  const [bulkError, setBulkError] = useState<string | null>(null);

  async function submitAdd(e: FormEvent) {
    e.preventDefault();
    setAddError(null); setNewCred(null);
    try {
      const res = await createUser.mutateAsync({
        email, display_name: displayName,
        flat_number: role === "resident" ? flat : undefined,
        role,
      });
      setNewCred({ email, temp_password: res.temp_password });
      setEmail(""); setDisplayName(""); setFlat("");
    } catch (err) {
      setAddError(err instanceof ApiClientError ? fieldErrorMsg(err) : "Failed to create user.");
    }
  }

  async function handleReset(uid: string, userEmail: string) {
    setResetCred(null); setResetError(null);
    try {
      const res = await resetPw.mutateAsync(uid);
      setResetCred({ email: userEmail, temp_password: res.temp_password });
    } catch (err) {
      setResetError(err instanceof ApiClientError ? messageForCode(err.code) : "Reset failed.");
    }
  }

  async function handleCSV(e: ChangeEvent<HTMLInputElement>) {
    const file = e.target.files?.[0];
    if (!file) return;
    setCsvFileName(file.name);
    setBulkReport(null); setBulkError(null);
    const text = await file.text();
    const rows = parseCSV(text);
    if (rows.length === 0) { setBulkError("No data rows found in CSV."); setCsvFileName(null); return; }
    try {
      const report = await bulkCreate.mutateAsync(rows);
      setBulkReport(report);
    } catch (err) {
      setBulkError(err instanceof ApiClientError ? messageForCode(err.code) : "Bulk import failed.");
    }
    e.target.value = "";
    setCsvFileName(null);
  }

  const active = data?.items.filter((u) => u.active !== false) ?? [];

  const filtered = active
    .filter((u) => {
      if (!search) return true;
      const q = search.toLowerCase();
      return (
        u.display_name.toLowerCase().includes(q) ||
        u.email.toLowerCase().includes(q) ||
        (u.flat_number ?? "").toLowerCase().includes(q)
      );
    })
    .slice()
    .sort(compareUsers);

  const bulkCreated = bulkReport?.results.filter((r) => r.status === "created") ?? [];
  const bulkFailed = bulkReport?.results.filter((r) => r.status !== "created") ?? [];

  return (
    <>
      <AppHeader />
      <main className="mx-auto max-w-4xl px-4 py-5 space-y-5">
        <Link to="/tenant" className="block text-sm font-medium text-link underline underline-offset-2 hover:text-link/70">← Dashboard</Link>
        <h1 className="text-xl font-semibold text-foreground">Residents &amp; Admins</h1>

        {/* User list */}
        <section className="space-y-2">
          <h2 className="text-base font-semibold text-foreground">Active users</h2>
          {isLoading && <p className="text-sm text-muted-foreground">Loading…</p>}

          {/* Search — client-side filter of the current page only */}
          {!isLoading && active.length > 0 && (
            <Input
              placeholder="Search by name, email or flat…"
              value={search}
              onChange={(e) => setSearch(e.target.value)}
              className="max-w-md h-8"
              aria-label="Search users"
            />
          )}

          {active.length === 0 && !isLoading && (
            <p className="text-sm text-muted-foreground">No users yet.</p>
          )}
          {active.length > 0 && filtered.length === 0 && (
            <p className="text-sm text-muted-foreground">No users match "{search}".</p>
          )}
          <div className="space-y-1">
            {filtered.map((u) => (
              <ListRow
                key={u.uid}
                action={
                  <div className="flex flex-wrap gap-1.5">
                    <Button
                      variant="outline"
                      size="xs"
                      onClick={() => handleReset(u.uid, u.email)}
                      disabled={resetPw.isPending}
                    >
                      Issue temp password
                    </Button>
                    {/* Permanent delete — irreversible, requires type-to-confirm (ADR-0034 §2) */}
                    <Button
                      variant="destructive"
                      size="xs"
                      onClick={() => setDeleteUid(u.uid)}
                      disabled={deletePermanently.isPending}
                    >
                      Delete
                    </Button>
                  </div>
                }
              >
                <p className="text-sm font-medium text-foreground">{u.display_name}</p>
                <p className="text-xs text-muted-foreground tabular-nums">
                  {u.email} · {u.role}{u.flat_number ? ` · ${u.flat_number}` : ""}
                </p>
              </ListRow>
            ))}
          </div>
          {resetError && <p className="text-sm text-destructive">{resetError}</p>}
        </section>

        {/* Add user form */}
        <section className="space-y-3">
          <h2 className="text-base font-semibold text-foreground">Add user</h2>
          <form onSubmit={submitAdd} className="max-w-md space-y-3">
            <div className="space-y-1">
              <label htmlFor="user-email" className="text-sm font-medium text-foreground">
                Email
              </label>
              <Input
                id="user-email"
                type="email"
                value={email}
                onChange={(e) => setEmail(e.target.value)}
                required
              />
            </div>
            <div className="space-y-1">
              <label htmlFor="user-name" className="text-sm font-medium text-foreground">
                Display name
              </label>
              <Input
                id="user-name"
                value={displayName}
                onChange={(e) => setDisplayName(e.target.value)}
                required
              />
            </div>
            <div className="space-y-1">
              <label htmlFor="user-role" className="text-sm font-medium text-foreground">
                Role
              </label>
              <select
                id="user-role"
                className="w-full rounded-md border border-input bg-background px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-ring"
                value={role}
                onChange={(e) => setRole(e.target.value)}
              >
                <option value="resident">Resident</option>
                <option value="tenant_admin">Tenant admin</option>
              </select>
            </div>
            {role === "resident" && (
              <div className="space-y-1">
                <label htmlFor="user-flat" className="text-sm font-medium text-foreground">
                  Flat number
                </label>
                <Input
                  id="user-flat"
                  value={flat}
                  onChange={(e) => setFlat(e.target.value)}
                  placeholder="A-101"
                  required
                />
              </div>
            )}
            <Button type="submit" disabled={createUser.isPending} className="w-full">
              {createUser.isPending ? "Creating…" : "Add user"}
            </Button>
          </form>
          {addError && <p className="text-sm text-destructive">{addError}</p>}
        </section>

        {/* Bulk CSV import */}
        <section className="space-y-2">
          <h2 className="text-base font-semibold text-foreground">Bulk import (CSV)</h2>
          <p className="text-sm text-muted-foreground">
            CSV headers: email, display_name, flat_number, role, household_id
          </p>
          <div className="flex items-center gap-3">
            {/* Native input visually hidden; triggered via button below for consistent styling */}
            <input
              ref={csvInputRef}
              type="file"
              accept=".csv,text/csv"
              onChange={handleCSV}
              disabled={bulkCreate.isPending}
              aria-label="Upload CSV for bulk user import"
              className="sr-only"
            />
            <Button
              type="button"
              variant="outline"
              size="sm"
              onClick={() => csvInputRef.current?.click()}
              disabled={bulkCreate.isPending}
            >
              {bulkCreate.isPending ? "Importing…" : "Choose CSV file…"}
            </Button>
            {csvFileName && (
              <span className="text-sm text-muted-foreground truncate max-w-[200px]">{csvFileName}</span>
            )}
          </div>
          {bulkError && <p className="text-sm text-destructive">{bulkError}</p>}
          {bulkReport && (
            <div className="space-y-3">
              <p className="text-sm text-foreground tabular-nums">
                Total: {bulkReport.total} · Created: {bulkReport.created} · Failed: {bulkReport.failed}
              </p>
              {bulkFailed.length > 0 && (
                <div className="space-y-1">
                  <p className="text-sm font-medium text-foreground">Failed rows:</p>
                  {bulkFailed.map((r) => (
                    <p key={r.row} className="text-sm text-destructive tabular-nums">
                      Row {r.row} — {r.email}: {r.reason}
                    </p>
                  ))}
                </div>
              )}
            </div>
          )}
        </section>
      </main>

      {/* Temp-password modals — shown immediately after credential issuance */}
      <TempPasswordModal
        creds={resetCred ? [resetCred] : null}
        title="Temp password issued"
        onClose={() => setResetCred(null)}
      />
      <TempPasswordModal
        creds={newCred ? [newCred] : null}
        title="User created"
        onClose={() => setNewCred(null)}
      />

      {/* Bulk-created credentials shown separately via CredentialDisplay below report */}
      {bulkReport && bulkCreated.length > 0 && (
        <TempPasswordModal
          creds={bulkCreated
            .filter((r): r is BulkResult & { temp_password: string } => !!r.temp_password)
            .map((r) => ({ email: r.email, temp_password: r.temp_password }))}
          title={`${bulkCreated.length} user(s) created`}
          onClose={() => setBulkReport(null)}
        />
      )}

      {deleteUid && (
        <ConfirmDialog
          title="Permanently delete user"
          body={
            <p>
              This will permanently delete all of this user&apos;s data —
              including their booking history — and remove their account.
              <strong> This action cannot be undone.</strong>
            </p>
          }
          confirmLabel="Confirm"
          confirmationPhrase="DELETE"
          busy={deletePermanently.isPending}
          onConfirm={() => { deletePermanently.mutate(deleteUid); setDeleteUid(null); }}
          onCancel={() => setDeleteUid(null)}
        />
      )}
    </>
  );
}
