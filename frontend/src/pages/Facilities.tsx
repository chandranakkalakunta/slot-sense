import { Bot } from "lucide-react";
import { Link } from "react-router-dom";

import { AppHeader } from "../components/AppHeader";
import { InstallPrompt } from "../components/InstallPrompt";
import { ResidentNav } from "../components/ResidentNav";
import { useFacilities, useFacilityCatalog } from "../hooks/bookingHooks";
import { DAY_ORDER } from "../types/facilitySchedule";
import type { WeeklySchedule } from "../types/facilitySchedule";

function todayRanges(schedule: WeeklySchedule): string {
  // new Date().getDay() returns 0=Sunday..6=Saturday; DAY_ORDER is monday=0..sunday=6
  const jsDay = new Date().getDay();
  const dayIndex = jsDay === 0 ? 6 : jsDay - 1;
  const ranges = schedule[DAY_ORDER[dayIndex]];
  if (!ranges || ranges.length === 0) return "Closed today";
  return "Today: " + ranges.map((r) => `${r.start}–${r.end}`).join(", ");
}

export default function Facilities() {
  const { data, isLoading, error } = useFacilities();
  const { data: catalogData } = useFacilityCatalog();
  const catalogBySport = new Map(catalogData?.items.map((c) => [c.sport, c.name]) ?? []);

  const activeFacilities = (data?.items.filter((f) => f.active) ?? [])
    .slice()
    .sort((a, b) =>
      (a.name ?? "").localeCompare(b.name ?? "", undefined, {
        sensitivity: "base",
        numeric: true,
      }),
    );

  return (
    <>
      <AppHeader>
        <ResidentNav />
      </AppHeader>

      <main className="mx-auto max-w-6xl px-4 py-6 space-y-6">
        <InstallPrompt />
        <h1 className="text-2xl font-semibold text-foreground">Facilities</h1>

        {/* Loading / error / empty states */}
        {isLoading && (
          <p className="text-sm text-muted-foreground">Loading facilities…</p>
        )}
        {error && (
          <p className="text-sm text-destructive">Couldn't load facilities.</p>
        )}
        {!isLoading && !error && data && activeFacilities.length === 0 && (
          <p className="text-sm text-muted-foreground">No facilities available.</p>
        )}

        {/* Booking Assistant promo */}
        <Link
          to="/assistant"
          className="block rounded-lg border border-primary/40 bg-surface p-2 no-underline hover:bg-accent transition-colors"
          style={{ textDecoration: "none" }}
        >
          <p className="font-semibold text-primary text-sm flex items-center gap-1.5">
            <Bot className="size-4 shrink-0" />
            Booking Assistant
          </p>
          <p className="text-muted-foreground text-xs mt-1">
            Try &ldquo;book tennis tomorrow&rdquo; or &ldquo;is tennis free today?&rdquo;
          </p>
          <p className="text-primary text-xs mt-1.5">Open assistant →</p>
        </Link>

        {/* Facility grid — 1 col mobile / 2 tablet / 3 desktop; plain Link tiles */}
        <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-3">
          {activeFacilities.map((f) => (
            <Link
              key={f.id}
              to={`/facilities/${f.id}`}
              className="block rounded-lg border bg-card p-2 no-underline text-foreground hover:bg-accent transition-colors"
              style={{ textDecoration: "none" }}
            >
              <p className="font-semibold text-foreground">{f.name}</p>
              <p className="text-sm text-muted-foreground tabular-nums mt-0.5">
                {catalogBySport.get(f.sport) ?? f.sport} · {f.slot_duration_minutes}min · {todayRanges(f.weekly_schedule)}
              </p>
            </Link>
          ))}
        </div>
      </main>
    </>
  );
}
