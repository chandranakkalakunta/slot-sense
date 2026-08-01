import { render, screen } from "@testing-library/react";
import { MemoryRouter } from "react-router-dom";
import { describe, expect, it, vi } from "vitest";

import { PlatformRoute } from "./PlatformRoute";

vi.mock("./AuthContext", () => ({
  useAuth: vi.fn(),
}));
vi.mock("./usePasswordGate", () => ({
  usePasswordGate: vi.fn(() => ({ mustChange: false, loading: false })),
}));

import { useAuth } from "./AuthContext";
import { usePasswordGate } from "./usePasswordGate";

function authState(role: string, hasUser = true) {
  return {
    user: hasUser ? ({ uid: "u1", email: "u@test.com" } as unknown as import("firebase/auth").User) : null,
    claims: { role },
    loading: false,
    idToken: "tok",
    signIn: vi.fn(),
    signInWithGoogle: vi.fn(),
    signOut: vi.fn(),
    claimsError: false,
    retryClaimsRefresh: vi.fn(),
  };
}

describe("PlatformRoute", () => {
  it("redirects resident to / (not rendered)", () => {
    vi.mocked(useAuth).mockReturnValue(authState("resident"));
    render(
      <MemoryRouter>
        <PlatformRoute><div>Admin Panel</div></PlatformRoute>
      </MemoryRouter>,
    );
    expect(screen.queryByText("Admin Panel")).not.toBeInTheDocument();
  });

  it("redirects tenant_admin to / (not rendered)", () => {
    vi.mocked(useAuth).mockReturnValue(authState("tenant_admin"));
    render(
      <MemoryRouter>
        <PlatformRoute><div>Admin Panel</div></PlatformRoute>
      </MemoryRouter>,
    );
    expect(screen.queryByText("Admin Panel")).not.toBeInTheDocument();
  });

  it("renders children for platform_admin", () => {
    vi.mocked(useAuth).mockReturnValue(authState("platform_admin"));
    vi.mocked(usePasswordGate).mockReturnValue({ mustChange: false, loading: false });
    render(
      <MemoryRouter>
        <PlatformRoute><div>Admin Dashboard</div></PlatformRoute>
      </MemoryRouter>,
    );
    expect(screen.getByText("Admin Dashboard")).toBeInTheDocument();
  });

  it("redirects platform_admin to /force-password when must_change_password", () => {
    vi.mocked(useAuth).mockReturnValue(authState("platform_admin"));
    vi.mocked(usePasswordGate).mockReturnValue({ mustChange: true, loading: false });
    render(
      <MemoryRouter>
        <PlatformRoute><div>Admin Dashboard</div></PlatformRoute>
      </MemoryRouter>,
    );
    expect(screen.queryByText("Admin Dashboard")).not.toBeInTheDocument();
  });

  it("redirects to /signin when not logged in", () => {
    vi.mocked(useAuth).mockReturnValue({ ...authState("platform_admin", false), user: null });
    render(
      <MemoryRouter>
        <PlatformRoute><div>Admin Dashboard</div></PlatformRoute>
      </MemoryRouter>,
    );
    expect(screen.queryByText("Admin Dashboard")).not.toBeInTheDocument();
  });
});
