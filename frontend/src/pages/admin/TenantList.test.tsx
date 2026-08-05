import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter } from "react-router-dom";
import { beforeEach, describe, expect, it, vi } from "vitest";

vi.mock("../../components/AppHeader", () => ({ AppHeader: () => null }));

// No importOriginal — avoids loading real adminHooks → api.ts → firebase.ts
// (which throws auth/invalid-api-key in CI where no Firebase env vars exist).
vi.mock("../../hooks/adminHooks", () => ({
  useTenants: vi.fn(),
  useDeleteTenantPermanently: vi.fn(),
}));

import { useTenants, useDeleteTenantPermanently } from "../../hooks/adminHooks";
import TenantList from "./TenantList";

const TENANT = {
  tenant_id: "t-1", slug: "oakwood", display_name: "Oakwood Residency",
  name: "Oakwood", active: true,
};

function renderPage() {
  return render(<MemoryRouter><TenantList /></MemoryRouter>);
}

describe("TenantList", () => {
  beforeEach(() => {
    vi.mocked(useTenants).mockReturnValue({
      data: { items: [TENANT] },
      isLoading: false,
      error: null,
    } as unknown as ReturnType<typeof useTenants>);
    vi.mocked(useDeleteTenantPermanently).mockReturnValue({
      mutate: vi.fn(), isPending: false,
    } as unknown as ReturnType<typeof useDeleteTenantPermanently>);
  });

  it("renders Platform Admin and Tenants headings", () => {
    renderPage();
    expect(screen.getByRole("heading", { name: "Platform Admin" })).toBeInTheDocument();
    expect(screen.getByRole("heading", { name: "Tenants" })).toBeInTheDocument();
  });

  it("renders the + New tenant link with correct href", () => {
    renderPage();
    expect(screen.getByRole("link", { name: /new tenant/i })).toHaveAttribute(
      "href",
      "/admin/tenants/new",
    );
  });

  it("renders a tenant row from mock data", () => {
    renderPage();
    expect(screen.getByText("Oakwood Residency")).toBeInTheDocument();
    expect(screen.getByText(/oakwood/)).toBeInTheDocument();
  });

  it("lists tenants in natural A–Z display-name order", () => {
    vi.mocked(useTenants).mockReturnValue({
      data: {
        items: [
          { tenant_id: "t-p", slug: "palm-meadows", display_name: "Palm Meadows", active: true },
          { tenant_id: "t-e", slug: "emerald-hills", display_name: "Emerald Hills Township", active: true },
          { tenant_id: "t-z", slug: "prestige-oaks", display_name: "Prestige Oaks", active: true },
        ],
      },
      isLoading: false,
      error: null,
    } as unknown as ReturnType<typeof useTenants>);
    renderPage();
    const names = screen.getAllByText(/Township|Meadows|Oaks/).map((el) => el.textContent);
    expect(names).toEqual([
      "Emerald Hills Township",
      "Palm Meadows",
      "Prestige Oaks",
    ]);
  });

  it("shows loading state", () => {
    vi.mocked(useTenants).mockReturnValue({
      data: undefined, isLoading: true, error: null,
    } as unknown as ReturnType<typeof useTenants>);
    renderPage();
    expect(screen.getByText("Loading tenants…")).toBeInTheDocument();
  });

  it("shows error state", () => {
    vi.mocked(useTenants).mockReturnValue({
      data: undefined, isLoading: false, error: new Error("network"),
    } as unknown as ReturnType<typeof useTenants>);
    renderPage();
    expect(screen.getByText("Couldn't load tenants.")).toBeInTheDocument();
  });

  it("shows empty state when no tenants", () => {
    vi.mocked(useTenants).mockReturnValue({
      data: { items: [] }, isLoading: false, error: null,
    } as unknown as ReturnType<typeof useTenants>);
    renderPage();
    expect(screen.getByText("No tenants yet.")).toBeInTheDocument();
  });

  // ── Phase 13.4: tenant permanent delete ──────────────────────────────────

  it("(d) renders a Delete button for each tenant row", () => {
    // RED: before Phase 13.4 no Delete button exists in TenantList.
    renderPage();
    expect(screen.getByRole("button", { name: /delete/i })).toBeInTheDocument();
  });

  it("(d) Delete button opens a confirm dialog requiring the tenant's slug", async () => {
    const user = userEvent.setup();
    renderPage();
    await user.click(screen.getByRole("button", { name: /delete/i }));
    // ConfirmDialog uses placeholder={confirmationPhrase}, slug="oakwood".
    expect(screen.getByPlaceholderText("oakwood")).toBeInTheDocument();
    // The phrase label shows the actual tenant slug, not a generic literal.
    expect(screen.getByText(/Type oakwood to confirm/i)).toBeInTheDocument();
  });

  it("(d) confirm button disabled for non-matching input including another tenant's slug", async () => {
    const user = userEvent.setup();
    renderPage();
    await user.click(screen.getByRole("button", { name: /delete/i }));
    const confirmBtn = screen.getByRole("button", { name: /confirm/i });
    // Non-empty but wrong slug must not enable the button.
    await user.type(screen.getByPlaceholderText("oakwood"), "different-tenant");
    expect(confirmBtn).toBeDisabled();
  });

  it("(d) confirm button enabled only on exact matching tenant slug", async () => {
    const user = userEvent.setup();
    renderPage();
    await user.click(screen.getByRole("button", { name: /delete/i }));
    await user.type(screen.getByPlaceholderText("oakwood"), "oakwood");
    expect(screen.getByRole("button", { name: /confirm/i })).not.toBeDisabled();
  });

  it("(d) confirming deletion calls the mutation with the correct tenant_id", async () => {
    const mutate = vi.fn();
    vi.mocked(useDeleteTenantPermanently).mockReturnValue({
      mutate, isPending: false,
    } as unknown as ReturnType<typeof useDeleteTenantPermanently>);
    const user = userEvent.setup();
    renderPage();
    await user.click(screen.getByRole("button", { name: /delete/i }));
    await user.type(screen.getByPlaceholderText("oakwood"), "oakwood");
    await user.click(screen.getByRole("button", { name: /confirm/i }));
    expect(mutate).toHaveBeenCalledWith("t-1");
  });

  // NOTE: search is client-side only — filters the current page's loaded tenants.
  it("search filters tenants by name", async () => {
    vi.mocked(useTenants).mockReturnValue({
      data: {
        items: [
          { tenant_id: "t-1", slug: "oakwood", display_name: "Oakwood Residency", name: "Oakwood", active: true },
          { tenant_id: "t-2", slug: "maplegrove", display_name: "Maple Grove", name: "Maple", active: true },
        ],
      },
      isLoading: false,
      error: null,
    } as unknown as ReturnType<typeof useTenants>);
    const user = userEvent.setup();
    renderPage();

    expect(screen.getByText("Oakwood Residency")).toBeInTheDocument();
    expect(screen.getByText("Maple Grove")).toBeInTheDocument();

    await user.type(screen.getByLabelText(/search tenants/i), "oak");

    expect(screen.getByText("Oakwood Residency")).toBeInTheDocument();
    expect(screen.queryByText("Maple Grove")).not.toBeInTheDocument();
  });

  it("search shows empty-state message when no tenants match", async () => {
    const user = userEvent.setup();
    renderPage();
    await user.type(screen.getByLabelText(/search tenants/i), "zzz");
    expect(screen.getByText(/no tenants match/i)).toBeInTheDocument();
  });

  it("displays admin_emails when present", () => {
    vi.mocked(useTenants).mockReturnValue({
      data: {
        items: [{ ...TENANT, admin_emails: ["admin@demo.com", "ops@demo.com"] }],
      },
      isLoading: false,
      error: null,
    } as unknown as ReturnType<typeof useTenants>);
    renderPage();
    expect(screen.getByText(/admin@demo\.com, ops@demo\.com/)).toBeInTheDocument();
  });

  it("does not render admin emails section when admin_emails is empty or absent", () => {
    renderPage(); // TENANT has no admin_emails
    expect(screen.queryByText(/Admins:/)).not.toBeInTheDocument();
  });
});
