const DEV_HOSTS = new Set(["localhost", "127.0.0.1"]);

function baseDomain(): string {
  return import.meta.env.VITE_BASE_DOMAIN || "slotsense.chandraailabs.com";
}

/** Tenant slug from the hostname (ADR-0046 per-env base domain).
 *  - {slug}.{VITE_BASE_DOMAIN} → that slug
 *  - localhost / 127.0.0.1 → VITE_DEV_TENANT_SLUG
 *  - other hosts → VITE_DEFAULT_TENANT_SLUG if set */
export function tenantSlugFromHost(host = window.location.hostname): string | null {
  const apex = baseDomain();
  if (host === apex) return null;
  const suffix = "." + apex;
  if (host.endsWith(suffix)) {
    return host.slice(0, -suffix.length);
  }
  if (DEV_HOSTS.has(host)) {
    return import.meta.env.VITE_DEV_TENANT_SLUG ?? null;
  }
  return import.meta.env.VITE_DEFAULT_TENANT_SLUG || null;
}
