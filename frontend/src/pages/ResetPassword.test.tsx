import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { MemoryRouter } from "react-router-dom";
import { beforeEach, expect, test, vi } from "vitest";

vi.mock("../lib/api", () => ({
  apiFetch: vi.fn(),
  ApiClientError: class ApiClientError extends Error {
    code: string;
    status: number;
    constructor(e: { code: string; message: string; status: number }) {
      super(e.message);
      this.code = e.code;
      this.status = e.status;
    }
  },
}));

import { ApiClientError, apiFetch } from "../lib/api";
import { messageForCode } from "../lib/messages";
import ResetPassword from "./ResetPassword";

beforeEach(() => {
  vi.mocked(apiFetch).mockReset();
});

function renderWithToken(token?: string) {
  const url = token ? `/reset?token=${token}` : "/reset";
  return render(
    <MemoryRouter initialEntries={[url]}>
      <ResetPassword />
    </MemoryRouter>,
  );
}

function fillAndSubmit(pw = "validpassword123", confirmPw?: string) {
  fireEvent.change(screen.getByPlaceholderText("New password"), {
    target: { value: pw },
  });
  fireEvent.change(screen.getByPlaceholderText("Confirm new password"), {
    target: { value: confirmPw ?? pw },
  });
  fireEvent.click(screen.getByRole("button", { name: /reset password/i }));
}

test("no token in URL -> shows invalid-link message, no form", () => {
  renderWithToken();
  expect(screen.getByText(/invalid or has expired/i)).toBeInTheDocument();
  expect(screen.queryByPlaceholderText("New password")).not.toBeInTheDocument();
  expect(screen.getByRole("link", { name: /request a new link/i })).toBeInTheDocument();
});

test("token stripped from URL on mount via history.replaceState", () => {
  const spy = vi.spyOn(window.history, "replaceState");
  renderWithToken("tok_abc123");
  expect(spy).toHaveBeenCalledWith(null, "", "/reset");
});

test("pw < 12 chars -> client error shown, apiFetch NOT called", () => {
  renderWithToken("tok_abc123");
  fillAndSubmit("short", "short");
  expect(screen.getByText(/at least 8 characters/i)).toBeInTheDocument();
  expect(apiFetch).not.toHaveBeenCalled();
});

test("pw !== confirm -> client error shown, apiFetch NOT called", () => {
  renderWithToken("tok_abc123");
  fillAndSubmit("validpassword123", "different_password");
  expect(screen.getByText(/don't match/i)).toBeInTheDocument();
  expect(apiFetch).not.toHaveBeenCalled();
});

test("happy path: calls apiFetch with token + new_password, shows success", async () => {
  vi.mocked(apiFetch).mockResolvedValueOnce({});
  renderWithToken("tok_abc123");
  fillAndSubmit("validpassword123");
  await waitFor(() =>
    expect(screen.getByText(/password has been reset/i)).toBeInTheDocument(),
  );
  expect(vi.mocked(apiFetch)).toHaveBeenCalledWith(
    "/auth/forgot-password/confirm",
    expect.objectContaining({
      method: "POST",
      body: JSON.stringify({ token: "tok_abc123", new_password: "validpassword123" }),
    }),
  );
  expect(screen.getByRole("link", { name: /sign in/i })).toBeInTheDocument();
});

test("server WEAK_PASSWORD -> renders messageForCode(WEAK_PASSWORD)", async () => {
  vi.mocked(apiFetch).mockRejectedValueOnce(
    new ApiClientError({ code: "WEAK_PASSWORD", message: "weak", status: 422 }),
  );
  renderWithToken("tok_abc123");
  fillAndSubmit("validpassword123");
  await waitFor(() =>
    expect(screen.getByText(messageForCode("WEAK_PASSWORD"))).toBeInTheDocument(),
  );
  // No /forgot-password link — token error flag not set for WEAK_PASSWORD
  expect(screen.queryByRole("link", { name: /request a new link/i })).not.toBeInTheDocument();
});

test("server RESET_TOKEN_INVALID -> renders invalid-link message and /forgot-password link", async () => {
  vi.mocked(apiFetch).mockRejectedValueOnce(
    new ApiClientError({ code: "RESET_TOKEN_INVALID", message: "invalid", status: 400 }),
  );
  renderWithToken("tok_abc123");
  fillAndSubmit("validpassword123");
  await waitFor(() =>
    expect(screen.getByText(messageForCode("RESET_TOKEN_INVALID"))).toBeInTheDocument(),
  );
  expect(screen.getByRole("link", { name: /request a new link/i })).toBeInTheDocument();
});
