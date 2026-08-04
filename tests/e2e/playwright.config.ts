import { defineConfig, devices } from "@playwright/test";

const baseURL =
  process.env.E2E_BASE_URL ||
  process.env.FUNC_TENANT_ORIGIN ||
  "https://marina-skies.slotsense-test.chandraailabs.com";

export default defineConfig({
  testDir: "./specs",
  fullyParallel: false,
  forbidOnly: !!process.env.CI,
  retries: process.env.CI ? 1 : 0,
  workers: 1,
  reporter: [["list"], ["html", { open: "never", outputFolder: "playwright-report" }]],
  use: {
    baseURL,
    trace: "on-first-retry",
    screenshot: "only-on-failure",
    video: "off",
  },
  projects: [{ name: "chromium", use: { ...devices["Desktop Chrome"] } }],
  timeout: 60_000,
});
