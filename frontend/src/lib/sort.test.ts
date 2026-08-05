import { describe, expect, it } from "vitest";

import {
  compareByName,
  compareLocale,
  compareTenants,
  compareUsers,
  tenantDisplayName,
} from "./sort";

describe("compareLocale", () => {
  it("sorts numeric segments naturally", () => {
    const items = ["F-0140", "F-2", "F-0108", "F-0109"];
    expect([...items].sort(compareLocale)).toEqual([
      "F-2",
      "F-0108",
      "F-0109",
      "F-0140",
    ]);
  });

  it("sorts names case-insensitively", () => {
    expect(compareLocale("palm", "Emerald")).toBeGreaterThan(0);
  });
});

describe("compareTenants", () => {
  it("orders by display name A–Z", () => {
    const items = [
      { slug: "palm-meadows", display_name: "Palm Meadows" },
      { slug: "emerald-hills", display_name: "Emerald Hills Township" },
      { slug: "prestige-oaks", display_name: "Prestige Oaks" },
    ];
    const sorted = [...items].sort(compareTenants).map(tenantDisplayName);
    expect(sorted).toEqual([
      "Emerald Hills Township",
      "Palm Meadows",
      "Prestige Oaks",
    ]);
  });
});

describe("compareUsers", () => {
  it("puts tenant admins first, then flat natural order", () => {
    const items = [
      { role: "resident", flat_number: "F-0140", display_name: "R 140", email: "a@x" },
      { role: "tenant_admin", flat_number: "", display_name: "Admin", email: "admin@x" },
      { role: "resident", flat_number: "F-0108", display_name: "R 108", email: "b@x" },
      { role: "resident", flat_number: "F-2", display_name: "R 2", email: "c@x" },
    ];
    const sorted = [...items].sort(compareUsers);
    expect(sorted.map((u) => u.display_name)).toEqual([
      "Admin",
      "R 2",
      "R 108",
      "R 140",
    ]);
  });
});

describe("compareByName", () => {
  it("orders facilities by name with numeric awareness", () => {
    const items = [
      { name: "Badminton - 10" },
      { name: "Badminton - 2" },
      { name: "Basketball - 1" },
    ];
    expect([...items].sort(compareByName).map((f) => f.name)).toEqual([
      "Badminton - 2",
      "Badminton - 10",
      "Basketball - 1",
    ]);
  });
});
