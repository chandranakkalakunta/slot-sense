import { type FormEvent, useState } from "react";
import { Link } from "react-router-dom";

import { AppHeader } from "../../components/AppHeader";
import { Button } from "../../components/ui/button";
import { ConfirmDialog } from "../../components/ConfirmDialog";
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
} from "../../components/ui/dialog";
import { ListRow } from "../../components/ListRow";
import { Input } from "../../components/ui/input";
import {
  defaultCreateSchedule,
  emptyWeeklySchedule,
  WeeklyScheduleEditor,
} from "../../components/tenant/WeeklyScheduleEditor";
import {
  type TenantFacility,
  useCreateFacility,
  useDeactivateFacility,
  useFacilityCatalog,
  useTenantFacilities,
  useUpdateFacility,
} from "../../hooks/tenantAdminHooks";
import { ApiClientError } from "../../lib/api";
import { messageForCode } from "../../lib/messages";
import { compareByName } from "../../lib/sort";
import type { WeeklySchedule } from "../../types/facilitySchedule";

function rupeesToPaise(value: string): number | undefined {
  if (value.trim() === "") return undefined;
  const n = Number(value);
  if (Number.isNaN(n)) return undefined;
  return Math.round(n * 100);
}

function paiseToRupees(pricePaise?: number | null): string {
  return pricePaise != null ? (pricePaise / 100).toFixed(2) : "";
}

export default function TenantFacilities() {
  const { data: catalog } = useFacilityCatalog();
  const { data: facilities, isLoading } = useTenantFacilities();
  const createFacility = useCreateFacility();
  const updateFacility = useUpdateFacility();
  const deactivate = useDeactivateFacility();

  // Create form state
  const [typeId, setTypeId] = useState("");
  const [name, setName] = useState("");
  const [duration, setDuration] = useState(60);
  const [description, setDescription] = useState("");
  const [price, setPrice] = useState("");
  const [schedule, setSchedule] = useState<WeeklySchedule>(defaultCreateSchedule);
  const [error, setError] = useState<string | null>(null);
  const [ok, setOk] = useState<string | null>(null);

  // Edit/Clone dialog state — shared state family, discriminated by dialogMode
  const [dialogMode, setDialogMode] = useState<"edit" | "clone">("edit");
  const [editingFacility, setEditingFacility] = useState<TenantFacility | null>(null);
  const [editTypeId, setEditTypeId] = useState("");
  const [editName, setEditName] = useState("");
  const [editDuration, setEditDuration] = useState(60);
  const [editDescription, setEditDescription] = useState("");
  const [editPrice, setEditPrice] = useState("");
  const [editSchedule, setEditSchedule] = useState<WeeklySchedule>(emptyWeeklySchedule);
  const [editError, setEditError] = useState<string | null>(null);
  const [editOk, setEditOk] = useState<string | null>(null);

  // Remove-confirm dialog state
  const [confirmFacilityId, setConfirmFacilityId] = useState<string | null>(null);

  function openEdit(f: TenantFacility) {
    setDialogMode("edit");
    setEditingFacility(f);
    setEditTypeId(f.facility_type_id);
    setEditName(f.name);
    setEditDuration(f.slot_duration_minutes);
    setEditDescription(f.description ?? "");
    setEditPrice(paiseToRupees(f.price_paise));
    setEditSchedule(f.weekly_schedule);
    setEditError(null);
    setEditOk(null);
  }

  function openClone(f: TenantFacility) {
    setDialogMode("clone");
    setEditingFacility(f);
    setEditTypeId(f.facility_type_id);
    setEditName("");
    setEditDuration(f.slot_duration_minutes);
    setEditDescription("");
    setEditPrice(paiseToRupees(f.price_paise));
    setEditSchedule(f.weekly_schedule);
    setEditError(null);
    setEditOk(null);
  }

  function closeEdit() {
    setEditingFacility(null);
    setDialogMode("edit");
  }

  async function submit(e: FormEvent) {
    e.preventDefault();
    setError(null); setOk(null);
    if (!typeId) { setError("Select a facility type."); return; }
    try {
      await createFacility.mutateAsync({
        facility_type_id: typeId,
        name,
        slot_duration_minutes: Number(duration),
        description: description || null,
        price_paise: rupeesToPaise(price),
        weekly_schedule: schedule,
      });
      setOk(`Created ${name}.`);
      setName(""); setDescription(""); setPrice(""); setSchedule(defaultCreateSchedule());
    } catch (e) {
      setError(e instanceof ApiClientError ? messageForCode(e.code) : "Failed to create facility.");
    }
  }

  async function submitEdit(e: FormEvent) {
    e.preventDefault();
    if (!editingFacility) return;
    setEditError(null); setEditOk(null);
    try {
      if (dialogMode === "clone") {
        await createFacility.mutateAsync({
          facility_type_id: editTypeId,
          name: editName,
          slot_duration_minutes: Number(editDuration),
          description: editDescription || null,
          price_paise: rupeesToPaise(editPrice),
          weekly_schedule: editSchedule,
        });
        setEditOk(`Cloned facility created.`);
        closeEdit();
      } else {
        await updateFacility.mutateAsync({
          id: editingFacility.id,
          facility_type_id: editTypeId,
          name: editName,
          slot_duration_minutes: Number(editDuration),
          description: editDescription || null,
          price_paise: rupeesToPaise(editPrice),
          weekly_schedule: editSchedule,
        });
        setEditOk(`Updated ${editName}.`);
      }
    } catch (e) {
      setEditError(e instanceof ApiClientError ? messageForCode(e.code) : "Failed to save facility.");
    }
  }

  const catalogMap = new Map(catalog?.items.map((c) => [c.type_id, c.name]) ?? []);

  const activeFacilities = (facilities?.items.filter((f) => f.active) ?? [])
    .slice()
    .sort(compareByName);

  return (
    <>
      <AppHeader />
      <main className="mx-auto max-w-4xl px-4 py-5 space-y-4">
        <Link to="/tenant" className="block text-sm font-medium text-link underline underline-offset-2 hover:text-link/70">← Dashboard</Link>
        <h1 className="text-xl font-semibold text-foreground">Facilities</h1>

        {isLoading && <p className="text-sm text-muted-foreground">Loading…</p>}

        {/* Facility list — name order (numeric-aware: Court 2 before Court 10) */}
        <div className="space-y-1">
          {activeFacilities.map((f) => (
            <ListRow
              key={f.id}
              action={
                <div className="flex flex-wrap items-center gap-1.5">
                  <Button
                    variant="outline"
                    size="xs"
                    onClick={() => openEdit(f)}
                  >
                    Edit
                  </Button>
                  <Button
                    variant="outline"
                    size="xs"
                    onClick={() => openClone(f)}
                  >
                    Clone
                  </Button>
                  {/* De-emphasized trigger per ADR-0028 §5; ConfirmDialog confirms before mutate */}
                  <Button
                    variant="ghost"
                    size="xs"
                    className="text-muted-foreground hover:text-destructive hover:bg-destructive/10"
                    onClick={() => setConfirmFacilityId(f.id)}
                  >
                    Remove
                  </Button>
                </div>
              }
            >
              <p className="text-sm font-medium text-foreground">{f.name}</p>
              <p className="text-xs text-muted-foreground tabular-nums">
                {catalogMap.get(f.facility_type_id) ?? f.sport} · {f.slot_duration_minutes}min slots
                {" · "}
                {f.price_paise != null ? `₹${(f.price_paise / 100).toFixed(2)}` : "No price set"}
                {f.description ? ` · ${f.description}` : ""}
              </p>
            </ListRow>
          ))}
        </div>

        {/* Add facility form */}
        <section className="space-y-4">
          <h2 className="text-lg font-semibold text-foreground">Add a facility</h2>
          <form onSubmit={submit} className="max-w-md space-y-3">
            <div className="space-y-1">
              <label htmlFor="facility-type" className="text-sm font-medium text-foreground">
                Type
              </label>
              <select
                id="facility-type"
                className="w-full rounded-md border border-input bg-background px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-ring"
                value={typeId}
                onChange={(e) => setTypeId(e.target.value)}
              >
                <option value="">Select a type…</option>
                {catalog?.items.map((c) => (
                  <option key={c.type_id} value={c.type_id}>{c.name}</option>
                ))}
              </select>
            </div>
            <div className="space-y-1">
              <label htmlFor="facility-name" className="text-sm font-medium text-foreground">
                Name
              </label>
              <Input
                id="facility-name"
                value={name}
                onChange={(e) => setName(e.target.value)}
                placeholder="North Side Court"
                required
              />
            </div>
            <div className="space-y-1">
              <label htmlFor="facility-duration" className="text-sm font-medium text-foreground">
                Slot duration (minutes)
              </label>
              <Input
                id="facility-duration"
                type="number"
                value={duration}
                onChange={(e) => setDuration(Number(e.target.value))}
                required
              />
            </div>
            <div className="space-y-1">
              <label htmlFor="facility-desc" className="text-sm font-medium text-foreground">
                Description (optional)
              </label>
              <Input
                id="facility-desc"
                value={description}
                onChange={(e) => setDescription(e.target.value)}
              />
            </div>
            <div className="space-y-1">
              <label htmlFor="facility-price" className="text-sm font-medium text-foreground">
                Price per booking (₹, optional)
              </label>
              <Input
                id="facility-price"
                type="number"
                step="0.01"
                value={price}
                onChange={(e) => setPrice(e.target.value)}
              />
            </div>
            <div className="space-y-1">
              <p className="text-sm font-medium text-foreground">Weekly schedule</p>
              <WeeklyScheduleEditor value={schedule} onChange={setSchedule} />
            </div>
            <Button type="submit" disabled={createFacility.isPending} className="w-full">
              {createFacility.isPending ? "Creating…" : "Add facility"}
            </Button>
          </form>
          {error && <p className="text-sm text-destructive">{error}</p>}
          {ok && <p className="text-sm text-success">{ok}</p>}
        </section>
      </main>

      {/* Edit / Clone facility dialog — shared state, discriminated by dialogMode */}
      <Dialog open={editingFacility !== null} onOpenChange={(open) => { if (!open) closeEdit(); }}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>
              {dialogMode === "clone" ? "Clone facility" : "Edit facility"}
            </DialogTitle>
          </DialogHeader>
          {/* Scrollable form body — header stays pinned above this region */}
          <div className="max-h-[70vh] overflow-y-auto pr-1">
            <form onSubmit={submitEdit} className="space-y-3">
              <div className="space-y-1">
                <label htmlFor="edit-facility-type" className="text-sm font-medium text-foreground">
                  Type
                </label>
                <select
                  id="edit-facility-type"
                  className="w-full rounded-md border border-input bg-background px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-ring"
                  value={editTypeId}
                  onChange={(e) => setEditTypeId(e.target.value)}
                >
                  <option value="">Select a type…</option>
                  {catalog?.items.map((c) => (
                    <option key={c.type_id} value={c.type_id}>{c.name}</option>
                  ))}
                </select>
              </div>
              <div className="space-y-1">
                <label htmlFor="edit-facility-name" className="text-sm font-medium text-foreground">
                  Name
                </label>
                <Input
                  id="edit-facility-name"
                  value={editName}
                  onChange={(e) => setEditName(e.target.value)}
                  required
                />
              </div>
              <div className="space-y-1">
                <label htmlFor="edit-facility-duration" className="text-sm font-medium text-foreground">
                  Slot duration (minutes)
                </label>
                <Input
                  id="edit-facility-duration"
                  type="number"
                  value={editDuration}
                  onChange={(e) => setEditDuration(Number(e.target.value))}
                  required
                />
              </div>
              <div className="space-y-1">
                <label htmlFor="edit-facility-desc" className="text-sm font-medium text-foreground">
                  Description (optional)
                </label>
                <Input
                  id="edit-facility-desc"
                  value={editDescription}
                  onChange={(e) => setEditDescription(e.target.value)}
                />
              </div>
              <div className="space-y-1">
                <label htmlFor="edit-facility-price" className="text-sm font-medium text-foreground">
                  Price per booking (₹, optional)
                </label>
                <Input
                  id="edit-facility-price"
                  type="number"
                  step="0.01"
                  value={editPrice}
                  onChange={(e) => setEditPrice(e.target.value)}
                />
              </div>
              <div className="space-y-1">
                <p className="text-sm font-medium text-foreground">Weekly schedule</p>
                <WeeklyScheduleEditor
                  key={`${dialogMode}-${editingFacility?.id ?? ""}`}
                  value={editSchedule}
                  onChange={setEditSchedule}
                />
              </div>
              {editError && <p className="text-sm text-destructive">{editError}</p>}
              {editOk && <p className="text-sm text-success">{editOk}</p>}
              <Button
                type="submit"
                disabled={createFacility.isPending || updateFacility.isPending}
                className="w-full"
              >
                {(createFacility.isPending || updateFacility.isPending)
                  ? "Saving…"
                  : dialogMode === "clone" ? "Create clone" : "Save changes"}
              </Button>
            </form>
          </div>
        </DialogContent>
      </Dialog>

      {confirmFacilityId && (
        <ConfirmDialog
          title="Remove facility"
          body={<p>Remove this facility? Active bookings may be affected.</p>}
          confirmLabel="Remove"
          busy={deactivate.isPending}
          onConfirm={() => { deactivate.mutate(confirmFacilityId); setConfirmFacilityId(null); }}
          onCancel={() => setConfirmFacilityId(null)}
        />
      )}
    </>
  );
}
