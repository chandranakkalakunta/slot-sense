/**
 * Tests for AuthContext: Phase 13.7 (slugFromHost, mismatch redirect) and
 * Phase 13.8 (forced token refresh after sign-in, claims-error recovery).
 *
 * window.location mocking: vi.stubGlobal (jsdom makes it read-only).
 * QueryClientProvider: required because AuthProvider now calls useQueryClient().
 */
import { act, render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { slugFromHost } from "./AuthContext";

// ── slugFromHost unit tests ───────────────────────────────────────────────────

describe("slugFromHost", () => {
  it("returns '' for the exact apex domain", () => {
    expect(slugFromHost("slotsense.chandraailabs.com")).toBe("");
  });

  it("returns the slug for a tenant subdomain", () => {
    expect(slugFromHost("acme.slotsense.chandraailabs.com")).toBe("acme");
    expect(slugFromHost("ddsociety.slotsense.chandraailabs.com")).toBe("ddsociety");
  });

  it("ADR-0046: parses slug under a non-prod base domain when apex is passed", () => {
    const testApex = "slotsense-test.chandraailabs.com";
    expect(slugFromHost("slotsense-test.chandraailabs.com", testApex)).toBe("");
    expect(slugFromHost("rvrg.slotsense-test.chandraailabs.com", testApex)).toBe("rvrg");
    // Must not treat parent zone as this env's apex
    expect(slugFromHost("rvrg.slotsense.chandraailabs.com", testApex)).toBeNull();
  });

  it("returns null for localhost (dev-safety)", () => {
    expect(slugFromHost("localhost")).toBeNull();
  });

  it("returns null for *.web.app (Firebase hosting preview)", () => {
    expect(slugFromHost("sport-slot-abc123.web.app")).toBeNull();
  });

  it("returns null for *.run.app (Cloud Run preview)", () => {
    expect(slugFromHost("service-abc123.run.app")).toBeNull();
  });

  it("returns null for completely unrecognized hostnames", () => {
    expect(slugFromHost("example.com")).toBeNull();
  });
});

// ── Shared mock setup ─────────────────────────────────────────────────────────

vi.mock("../lib/firebase", () => ({ auth: { currentUser: null } }));
vi.mock("../lib/branding", () => ({ loadBrandingForSlug: vi.fn() }));

// Capture callbacks set by AuthContext
let _idTokenCallback: ((user: unknown) => Promise<void>) | null = null;
let _claimsErrorHandlerFromContext: (() => void) | null = null;

const { mockFbSignOut, mockSignIn, mockSignInWithPopup, mockGetIdToken } = vi.hoisted(() => ({
  mockFbSignOut: vi.fn().mockResolvedValue(undefined),
  mockSignIn: vi.fn().mockResolvedValue(undefined),
  mockSignInWithPopup: vi.fn().mockResolvedValue(undefined),
  mockGetIdToken: vi.fn().mockResolvedValue("fresh-token"),
}));

vi.mock("firebase/auth", () => ({
  onIdTokenChanged: (_auth: unknown, cb: (u: unknown) => Promise<void>) => {
    _idTokenCallback = cb;
    return () => {};
  },
  signInWithEmailAndPassword: mockSignIn,
  signInWithPopup: mockSignInWithPopup,
  GoogleAuthProvider: vi.fn(),
  signOut: mockFbSignOut,
}));

// Capture the claimsErrorHandler registration
vi.mock("../lib/api", () => ({
  setClaimsErrorHandler: vi.fn((fn) => { _claimsErrorHandlerFromContext = fn; }),
  apiFetch: vi.fn(),
}));

import { AuthProvider, useAuth } from "./AuthContext";
import { loadBrandingForSlug } from "../lib/branding";
import * as firebaseLib from "../lib/firebase";

function makeUser(claims: Record<string, unknown>) {
  return {
    getIdTokenResult: vi.fn().mockResolvedValue({ token: "tok", claims }),
    getIdToken: mockGetIdToken,
  };
}

function renderProvider(children: React.ReactNode = <div />) {
  const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  render(
    <QueryClientProvider client={queryClient}>
      <AuthProvider>{children}</AuthProvider>
    </QueryClientProvider>,
  );
  return { queryClient };
}

// ── Phase 13.7: onIdTokenChanged mismatch-redirect tests ─────────────────────

describe("onIdTokenChanged — mismatch redirect", () => {
  let originalLocation: Location;

  beforeEach(() => {
    originalLocation = window.location;
    mockFbSignOut.mockClear();
    vi.mocked(loadBrandingForSlug).mockClear();
    _idTokenCallback = null;
  });

  afterEach(() => {
    vi.stubGlobal("location", originalLocation);
  });

  it("(a) apex host with tenant_admin claims: signs out and redirects to correct subdomain", async () => {
    const mockLocation = { hostname: "slotsense.chandraailabs.com", href: "" };
    vi.stubGlobal("location", mockLocation);
    renderProvider();
    await waitFor(() => expect(_idTokenCallback).not.toBeNull());
    await act(async () => {
      await _idTokenCallback!(makeUser({ role: "tenant_admin", tenant_slug: "ddsociety", tenant_id: "t-1" }));
    });
    expect(mockFbSignOut).toHaveBeenCalledOnce();
    expect(mockLocation.href).toBe("https://ddsociety.slotsense.chandraailabs.com/signin?redirected=1");
    expect(loadBrandingForSlug).not.toHaveBeenCalled();
  });

  it("(a) apex host with resident claims: signs out and redirects", async () => {
    const mockLocation = { hostname: "slotsense.chandraailabs.com", href: "" };
    vi.stubGlobal("location", mockLocation);
    renderProvider();
    await waitFor(() => expect(_idTokenCallback).not.toBeNull());
    await act(async () => {
      await _idTokenCallback!(makeUser({ role: "resident", tenant_slug: "acme", tenant_id: "t-2" }));
    });
    expect(mockFbSignOut).toHaveBeenCalledOnce();
    expect(mockLocation.href).toBe("https://acme.slotsense.chandraailabs.com/signin?redirected=1");
  });

  it("(b) matching subdomain: no sign-out, no redirect, branding loads normally", async () => {
    const mockLocation = { hostname: "acme.slotsense.chandraailabs.com", href: "" };
    vi.stubGlobal("location", mockLocation);
    renderProvider();
    await waitFor(() => expect(_idTokenCallback).not.toBeNull());
    await act(async () => {
      await _idTokenCallback!(makeUser({ role: "tenant_admin", tenant_slug: "acme", tenant_id: "t-2" }));
    });
    expect(mockFbSignOut).not.toHaveBeenCalled();
    expect(mockLocation.href).toBe("");
    expect(loadBrandingForSlug).toHaveBeenCalledWith("acme");
  });

  it("(c) wrong subdomain (rvrg host, ddsociety token): signs out and redirects", async () => {
    const mockLocation = { hostname: "rvrg.slotsense.chandraailabs.com", href: "" };
    vi.stubGlobal("location", mockLocation);
    renderProvider();
    await waitFor(() => expect(_idTokenCallback).not.toBeNull());
    await act(async () => {
      await _idTokenCallback!(makeUser({ role: "tenant_admin", tenant_slug: "ddsociety", tenant_id: "t-3" }));
    });
    expect(mockFbSignOut).toHaveBeenCalledOnce();
    expect(mockLocation.href).toBe("https://ddsociety.slotsense.chandraailabs.com/signin?redirected=1");
  });

  it("(d) platform_admin on apex: no sign-out, no redirect (explicitly verified)", async () => {
    const mockLocation = { hostname: "slotsense.chandraailabs.com", href: "" };
    vi.stubGlobal("location", mockLocation);
    renderProvider();
    await waitFor(() => expect(_idTokenCallback).not.toBeNull());
    await act(async () => {
      await _idTokenCallback!(makeUser({ role: "platform_admin" }));
    });
    expect(mockFbSignOut).not.toHaveBeenCalled();
    expect(mockLocation.href).toBe("");
  });

  it("(e) localhost host: no redirect regardless of claims (dev-safety guard)", async () => {
    const mockLocation = { hostname: "localhost", href: "" };
    vi.stubGlobal("location", mockLocation);
    renderProvider();
    await waitFor(() => expect(_idTokenCallback).not.toBeNull());
    await act(async () => {
      await _idTokenCallback!(makeUser({ role: "tenant_admin", tenant_slug: "ddsociety", tenant_id: "t-4" }));
    });
    expect(mockFbSignOut).not.toHaveBeenCalled();
    expect(mockLocation.href).toBe("");
    expect(loadBrandingForSlug).toHaveBeenCalledWith("ddsociety");
  });

  it("(e) *.web.app host: no redirect regardless of claims", async () => {
    const mockLocation = { hostname: "sport-slot-abc123.web.app", href: "" };
    vi.stubGlobal("location", mockLocation);
    renderProvider();
    await waitFor(() => expect(_idTokenCallback).not.toBeNull());
    await act(async () => {
      await _idTokenCallback!(makeUser({ role: "resident", tenant_slug: "acme", tenant_id: "t-5" }));
    });
    expect(mockFbSignOut).not.toHaveBeenCalled();
    expect(mockLocation.href).toBe("");
  });

  it("null user (signed-out state): no redirect, no error", async () => {
    const mockLocation = { hostname: "slotsense.chandraailabs.com", href: "" };
    vi.stubGlobal("location", mockLocation);
    renderProvider();
    await waitFor(() => expect(_idTokenCallback).not.toBeNull());
    await act(async () => { await _idTokenCallback!(null); });
    expect(mockFbSignOut).not.toHaveBeenCalled();
    expect(mockLocation.href).toBe("");
  });
});

// ── Phase 13.8: forced token refresh after sign-in ───────────────────────────
//
// Captures signIn/signInWithGoogle from the real AuthContext via a consumer
// component, then asserts that getIdToken(true) is called after the Firebase
// auth call — this is the primary guard against stale cached claims.

let _capturedSignIn: ((email: string, pw: string) => Promise<void>) | null = null;
let _capturedSignInWithGoogle: (() => Promise<void>) | null = null;

function AuthFnCapturer() {
  const { signIn, signInWithGoogle } = useAuth();
  _capturedSignIn = signIn;
  _capturedSignInWithGoogle = signInWithGoogle;
  return null;
}

describe("signIn — forced token refresh", () => {
  beforeEach(() => {
    mockSignIn.mockClear();
    mockSignInWithPopup.mockClear();
    mockGetIdToken.mockClear();
    _capturedSignIn = null;
    _capturedSignInWithGoogle = null;
  });

  afterEach(() => {
    (firebaseLib.auth as unknown as { currentUser: unknown }).currentUser = null;
  });

  it("calls getIdToken(true) after signInWithEmailAndPassword succeeds", async () => {
    (firebaseLib.auth as unknown as { currentUser: unknown }).currentUser = { getIdToken: mockGetIdToken };
    renderProvider(<AuthFnCapturer />);
    await waitFor(() => expect(_capturedSignIn).not.toBeNull());

    await act(async () => { await _capturedSignIn!("u@test.com", "pass"); });

    expect(mockSignIn).toHaveBeenCalledWith(expect.anything(), "u@test.com", "pass");
    // The forced refresh must have been called with true (not false/undefined)
    expect(mockGetIdToken).toHaveBeenCalledWith(true);
  });

  it("calls getIdToken(true) after signInWithPopup (Google) succeeds", async () => {
    (firebaseLib.auth as unknown as { currentUser: unknown }).currentUser = { getIdToken: mockGetIdToken };
    renderProvider(<AuthFnCapturer />);
    await waitFor(() => expect(_capturedSignInWithGoogle).not.toBeNull());

    await act(async () => { await _capturedSignInWithGoogle!(); });

    expect(mockSignInWithPopup).toHaveBeenCalledOnce();
    expect(mockGetIdToken).toHaveBeenCalledWith(true);
  });
});

// ── Phase 13.8: claims-error state and retry UI ──────────────────────────────

describe("claims-error state and ClaimsErrorFallback", () => {
  beforeEach(() => {
    _claimsErrorHandlerFromContext = null;
    _idTokenCallback = null;
  });

  it("registers the claims-error handler with setClaimsErrorHandler on mount", async () => {
    renderProvider();
    await waitFor(() => expect(_claimsErrorHandlerFromContext).toBeTypeOf("function"));
  });

  it("shows ClaimsErrorFallback when the claims-error handler is called", async () => {
    renderProvider(<div data-testid="app-content">App</div>);
    await waitFor(() => expect(_claimsErrorHandlerFromContext).toBeTypeOf("function"));

    // Normal state: children are shown
    expect(screen.getByTestId("app-content")).toBeInTheDocument();
    expect(screen.queryByRole("button", { name: /retry/i })).not.toBeInTheDocument();

    // Trigger the claims error (simulates apiFetch detecting AUTH_INVALID_TOKEN)
    await act(async () => { _claimsErrorHandlerFromContext!(); });

    // Fallback is now shown instead of children
    expect(screen.getByRole("button", { name: /retry/i })).toBeInTheDocument();
    expect(screen.queryByTestId("app-content")).not.toBeInTheDocument();
  });

  it("Retry button calls getIdToken(true) and dismisses the fallback", async () => {
    const mockCurrentUser = { getIdToken: mockGetIdToken };
    (firebaseLib.auth as unknown as { currentUser: unknown }).currentUser = mockCurrentUser;

    renderProvider(<div data-testid="app-content">App</div>);
    await waitFor(() => expect(_claimsErrorHandlerFromContext).toBeTypeOf("function"));

    // Trigger claims error
    await act(async () => { _claimsErrorHandlerFromContext!(); });
    expect(screen.getByRole("button", { name: /retry/i })).toBeInTheDocument();

    // Click Retry
    const user = userEvent.setup();
    await user.click(screen.getByRole("button", { name: /retry/i }));

    // After retry: getIdToken(true) was called, fallback dismissed, children shown
    expect(mockGetIdToken).toHaveBeenCalledWith(true);
    expect(screen.getByTestId("app-content")).toBeInTheDocument();
    expect(screen.queryByRole("button", { name: /retry/i })).not.toBeInTheDocument();

    (firebaseLib.auth as unknown as { currentUser: unknown }).currentUser = null;
    mockGetIdToken.mockClear();
  });
});
