/**
 * Default list ordering for admin UIs (natural order unless a screen
 * specifies otherwise).
 *
 * Uses locale-aware compare with `numeric: true` so values like
 * F-0108 / F-0140 and "Court 2" / "Court 10" sort as humans expect.
 */

export function compareLocale(
  a: string | null | undefined,
  b: string | null | undefined,
): number {
  return (a ?? "").localeCompare(b ?? "", undefined, {
    sensitivity: "base",
    numeric: true,
  });
}

/** Display name for a tenant row (stable fallback chain). */
export function tenantDisplayName(t: {
  display_name?: string | null;
  name?: string | null;
  slug: string;
}): string {
  return t.display_name ?? t.name ?? t.slug;
}

export function compareTenants(
  a: { display_name?: string | null; name?: string | null; slug: string },
  b: { display_name?: string | null; name?: string | null; slug: string },
): number {
  return compareLocale(tenantDisplayName(a), tenantDisplayName(b));
}

/**
 * Users: tenant admins first, then residents by flat (natural), then name.
 */
export function compareUsers(
  a: {
    role?: string | null;
    flat_number?: string | null;
    display_name?: string | null;
    email?: string | null;
  },
  b: {
    role?: string | null;
    flat_number?: string | null;
    display_name?: string | null;
    email?: string | null;
  },
): number {
  const roleRank = (r?: string | null) => (r === "tenant_admin" ? 0 : 1);
  const byRole = roleRank(a.role) - roleRank(b.role);
  if (byRole !== 0) return byRole;
  const byFlat = compareLocale(a.flat_number, b.flat_number);
  if (byFlat !== 0) return byFlat;
  const byName = compareLocale(a.display_name, b.display_name);
  if (byName !== 0) return byName;
  return compareLocale(a.email, b.email);
}

export function compareByName(
  a: { name?: string | null },
  b: { name?: string | null },
): number {
  return compareLocale(a.name, b.name);
}
