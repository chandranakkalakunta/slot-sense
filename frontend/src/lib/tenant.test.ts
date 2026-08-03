import { expect, test, vi } from "vitest";

import { tenantSlugFromHost } from "./tenant";

test("extracts slug from tenant subdomain", () => {
  expect(tenantSlugFromHost("demo.slotsense.chandraailabs.com")).toBe("demo");
});

test("ADR-0046: extracts slug under VITE_BASE_DOMAIN test apex", () => {
  vi.stubEnv("VITE_BASE_DOMAIN", "slotsense-test.chandraailabs.com");
  vi.stubEnv("VITE_DEFAULT_TENANT_SLUG", "");
  expect(tenantSlugFromHost("rvrg.slotsense-test.chandraailabs.com")).toBe("rvrg");
  expect(tenantSlugFromHost("slotsense-test.chandraailabs.com")).toBeNull();
  // Parent shared zone is not this env (and no default slug configured)
  expect(tenantSlugFromHost("rvrg.slotsense.chandraailabs.com")).toBeNull();
  vi.unstubAllEnvs();
});

test("returns null for unrelated host when no default configured", () => {
  vi.stubEnv("VITE_DEFAULT_TENANT_SLUG", "");
  expect(tenantSlugFromHost("example.com")).toBeNull();
  vi.unstubAllEnvs();
});

test("uses dev fallback on localhost", () => {
  vi.stubEnv("VITE_DEV_TENANT_SLUG", "demo");
  expect(tenantSlugFromHost("localhost")).toBe("demo");
  vi.unstubAllEnvs();
});

test("uses default-tenant fallback on non-subdomain host", () => {
  vi.stubEnv("VITE_DEFAULT_TENANT_SLUG", "demo");
  expect(tenantSlugFromHost("sport-slot-dev.web.app")).toBe("demo");
  vi.unstubAllEnvs();
});

test("real subdomain wins over default", () => {
  vi.stubEnv("VITE_DEFAULT_TENANT_SLUG", "other");
  expect(tenantSlugFromHost("demo.slotsense.chandraailabs.com")).toBe("demo");
  vi.unstubAllEnvs();
});
