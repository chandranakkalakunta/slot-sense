import { type FormEvent, useState } from "react";
import { Link } from "react-router-dom";

import { AppHeader } from "../../components/AppHeader";
import { ConfirmDialog } from "../../components/ConfirmDialog";
import { ListRow } from "../../components/ListRow";
import { Button } from "../../components/ui/button";
import { Input } from "../../components/ui/input";
import {
  type CatalogType,
  useAdminFacilityCatalog,
  useCreateCatalogType,
  useDeleteCatalogType,
  useUpdateCatalogType,
} from "../../hooks/adminHooks";
import { ApiClientError } from "../../lib/api";
import { messageForCode } from "../../lib/messages";

export default function FacilityCatalog() {
  const { data, isLoading, error } = useAdminFacilityCatalog();
  const createType = useCreateCatalogType();
  const updateType = useUpdateCatalogType();
  const deleteType = useDeleteCatalogType();

  const [typeId, setTypeId] = useState("");
  const [name, setName] = useState("");
  const [sport, setSport] = useState("");
  const [formError, setFormError] = useState<string | null>(null);
  const [formOk, setFormOk] = useState<string | null>(null);

  const [editing, setEditing] = useState<CatalogType | null>(null);
  const [editName, setEditName] = useState("");
  const [editSport, setEditSport] = useState("");
  const [editError, setEditError] = useState<string | null>(null);

  const [deleteTarget, setDeleteTarget] = useState<CatalogType | null>(null);

  const items = data?.items ?? [];

  async function onCreate(e: FormEvent) {
    e.preventDefault();
    setFormError(null);
    setFormOk(null);
    try {
      await createType.mutateAsync({
        type_id: typeId.trim().toLowerCase(),
        name: name.trim(),
        sport: sport.trim().toLowerCase(),
      });
      setTypeId("");
      setName("");
      setSport("");
      setFormOk("Facility type added.");
    } catch (err) {
      setFormError(
        err instanceof ApiClientError
          ? messageForCode(err.code)
          : "Could not create facility type.",
      );
    }
  }

  async function onSaveEdit(e: FormEvent) {
    e.preventDefault();
    if (!editing) return;
    setEditError(null);
    try {
      await updateType.mutateAsync({
        type_id: editing.type_id,
        name: editName.trim(),
        sport: editSport.trim().toLowerCase(),
      });
      setEditing(null);
    } catch (err) {
      setEditError(
        err instanceof ApiClientError
          ? messageForCode(err.code)
          : "Could not update facility type.",
      );
    }
  }

  return (
    <>
      <AppHeader />
      <main className="mx-auto max-w-6xl px-4 py-6 space-y-6">
        <div className="flex items-center justify-between gap-4">
          <div>
            <h1 className="text-2xl font-semibold text-foreground">
              Facility catalog
            </h1>
            <p className="text-sm text-muted-foreground mt-1">
              Master facility types for all tenants. Tenant admins pick from
              this list when creating courts and facilities.
            </p>
          </div>
          <Button asChild variant="outline" size="sm">
            <Link to="/admin" style={{ textDecoration: "none" }}>
              ← Tenants
            </Link>
          </Button>
        </div>

        <section className="space-y-3 rounded-lg border border-border p-4">
          <h2 className="text-lg font-semibold text-foreground">Add type</h2>
          <form onSubmit={onCreate} className="grid gap-3 sm:grid-cols-3">
            <div className="space-y-1">
              <label htmlFor="cat-id" className="text-sm font-medium">
                Type ID
              </label>
              <Input
                id="cat-id"
                placeholder="e.g. squash"
                value={typeId}
                onChange={(e) => setTypeId(e.target.value)}
                required
                pattern="[a-z][a-z0-9-]*[a-z0-9]"
                title="Lowercase letters, numbers, hyphens"
              />
            </div>
            <div className="space-y-1">
              <label htmlFor="cat-name" className="text-sm font-medium">
                Display name
              </label>
              <Input
                id="cat-name"
                placeholder="Squash"
                value={name}
                onChange={(e) => setName(e.target.value)}
                required
              />
            </div>
            <div className="space-y-1">
              <label htmlFor="cat-sport" className="text-sm font-medium">
                Sport key
              </label>
              <Input
                id="cat-sport"
                placeholder="squash"
                value={sport}
                onChange={(e) => setSport(e.target.value)}
                required
              />
            </div>
            <div className="sm:col-span-3">
              <Button type="submit" disabled={createType.isPending}>
                {createType.isPending ? "Saving…" : "Add facility type"}
              </Button>
            </div>
          </form>
          {formError && <p className="text-sm text-destructive">{formError}</p>}
          {formOk && <p className="text-sm text-foreground">{formOk}</p>}
        </section>

        <section className="space-y-3">
          <h2 className="text-lg font-semibold text-foreground">
            All types ({items.length})
          </h2>
          {isLoading && (
            <p className="text-sm text-muted-foreground">Loading catalog…</p>
          )}
          {error && (
            <p className="text-sm text-destructive">Couldn&apos;t load catalog.</p>
          )}
          {!isLoading && !error && items.length === 0 && (
            <p className="text-sm text-muted-foreground">
              No facility types yet. Seed the catalog or add types above.
            </p>
          )}
          <ul className="space-y-2">
            {items.map((t) => (
              <ListRow key={t.type_id}>
                <div className="flex flex-1 flex-wrap items-center justify-between gap-2">
                  <div>
                    <p className="font-medium text-foreground">{t.name}</p>
                    <p className="text-sm text-muted-foreground">
                      {t.type_id} · sport: {t.sport}
                    </p>
                  </div>
                  <div className="flex gap-2">
                    <Button
                      type="button"
                      variant="outline"
                      size="sm"
                      onClick={() => {
                        setEditing(t);
                        setEditName(t.name);
                        setEditSport(t.sport);
                        setEditError(null);
                      }}
                    >
                      Edit
                    </Button>
                    <Button
                      type="button"
                      variant="outline"
                      size="sm"
                      onClick={() => setDeleteTarget(t)}
                    >
                      Delete
                    </Button>
                  </div>
                </div>
              </ListRow>
            ))}
          </ul>
        </section>

        {editing && (
          <div
            className="fixed inset-0 z-50 flex items-center justify-center bg-black/40 p-4"
            role="dialog"
            aria-modal="true"
            aria-labelledby="edit-catalog-title"
          >
            <form
              onSubmit={onSaveEdit}
              className="w-full max-w-md space-y-3 rounded-lg border border-border bg-background p-4"
            >
              <h2 id="edit-catalog-title" className="text-lg font-semibold">
                Edit {editing.type_id}
              </h2>
              <div className="space-y-1">
                <label htmlFor="edit-name" className="text-sm font-medium">
                  Display name
                </label>
                <Input
                  id="edit-name"
                  value={editName}
                  onChange={(e) => setEditName(e.target.value)}
                  required
                />
              </div>
              <div className="space-y-1">
                <label htmlFor="edit-sport" className="text-sm font-medium">
                  Sport key
                </label>
                <Input
                  id="edit-sport"
                  value={editSport}
                  onChange={(e) => setEditSport(e.target.value)}
                  required
                />
              </div>
              {editError && (
                <p className="text-sm text-destructive">{editError}</p>
              )}
              <div className="flex justify-end gap-2">
                <Button
                  type="button"
                  variant="outline"
                  onClick={() => setEditing(null)}
                >
                  Cancel
                </Button>
                <Button type="submit" disabled={updateType.isPending}>
                  {updateType.isPending ? "Saving…" : "Save"}
                </Button>
              </div>
            </form>
          </div>
        )}

        {deleteTarget && (
          <ConfirmDialog
            title="Delete facility type?"
            body={
              <>
                Remove “{deleteTarget.name}” ({deleteTarget.type_id}) from the
                master catalog? Existing tenant facilities that reference it keep
                their type id but will no longer appear in the picker as a live
                catalog entry.
              </>
            }
            confirmLabel="Delete"
            busy={deleteType.isPending}
            onCancel={() => setDeleteTarget(null)}
            onConfirm={() => {
              void deleteType
                .mutateAsync(deleteTarget.type_id)
                .then(() => setDeleteTarget(null));
            }}
          />
        )}
      </main>
    </>
  );
}
