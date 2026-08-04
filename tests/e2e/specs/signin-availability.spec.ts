import { expect, test } from "@playwright/test";

/**
 * Browser S-FUNC smoke (ADR-0045 F5 partial).
 * Env:
 *   E2E_BASE_URL — tenant origin (default marina-skies test)
 *   E2E_EMAIL / E2E_PASSWORD — or FUNC_RESIDENT_EMAIL / FUNC_RESIDENT_PASSWORD
 */
const email = process.env.E2E_EMAIL || process.env.FUNC_RESIDENT_EMAIL || "";
const password = process.env.E2E_PASSWORD || process.env.FUNC_RESIDENT_PASSWORD || "";

test.describe("resident sign-in + facilities", () => {
  test.skip(!email || !password, "E2E_EMAIL/E2E_PASSWORD (or FUNC_RESIDENT_*) required");

  test("sign in and see facilities list", async ({ page }) => {
    await page.goto("/signin");
    await expect(page.getByRole("heading", { name: /SlotSense/i })).toBeVisible({
      timeout: 20_000,
    });

    await page.locator("#sign-in-email").fill(email);
    await page.locator("#sign-in-password").fill(password);
    await page.getByRole("button", { name: "Sign in" }).click();

    // After auth: home facilities or force-password
    await page.waitForURL(/\/($|force-password|facilities)/, { timeout: 30_000 });

    if (page.url().includes("force-password")) {
      test.skip(true, "user still on force-password gate — use post-change credentials");
    }

    // Facilities heading or list content
    await expect(
      page.getByRole("heading", { name: /facilit/i }).or(page.getByText(/facility/i).first()),
    ).toBeVisible({ timeout: 20_000 });
  });

  test("open first facility availability date picker", async ({ page }) => {
    await page.goto("/signin");
    await page.locator("#sign-in-email").fill(email);
    await page.locator("#sign-in-password").fill(password);
    await page.getByRole("button", { name: "Sign in" }).click();
    await page.waitForURL(/\/($|force-password)/, { timeout: 30_000 });
    if (page.url().includes("force-password")) {
      test.skip(true, "force-password gate");
    }

    // Click first facility link/card if present
    const link = page.locator('a[href*="/facilities/"]').first();
    if ((await link.count()) === 0) {
      test.skip(true, "no facility links on home");
    }
    await link.click();
    await expect(page.locator("#availability-date")).toBeVisible({ timeout: 20_000 });
  });
});
