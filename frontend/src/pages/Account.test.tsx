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
import Account from "./Account";

beforeEach(() => {
  vi.mocked(apiFetch).mockReset();
});

function renderPage() {
  return render(
    <MemoryRouter>
      <Account />
    </MemoryRouter>,
  );
}

test("renders the two password fields", () => {
  renderPage();
  expect(screen.getByPlaceholderText("New password")).toBeInTheDocument();
  expect(screen.getByPlaceholderText("Confirm new password")).toBeInTheDocument();
  expect(screen.getByRole("button", { name: /change password/i })).toBeInTheDocument();
});

test("pw < 12 chars -> client error, apiFetch NOT called", () => {
  renderPage();
  fireEvent.change(screen.getByPlaceholderText("New password"), {
    target: { value: "short" },
  });
  fireEvent.change(screen.getByPlaceholderText("Confirm new password"), {
    target: { value: "short" },
  });
  fireEvent.click(screen.getByRole("button", { name: /change password/i }));
  expect(screen.getByText(/at least 8 characters/i)).toBeInTheDocument();
  expect(apiFetch).not.toHaveBeenCalled();
});

test("pw !== confirm -> client error, apiFetch NOT called", () => {
  renderPage();
  fireEvent.change(screen.getByPlaceholderText("New password"), {
    target: { value: "validpassword123" },
  });
  fireEvent.change(screen.getByPlaceholderText("Confirm new password"), {
    target: { value: "differentpassword" },
  });
  fireEvent.click(screen.getByRole("button", { name: /change password/i }));
  expect(screen.getByText(/don't match/i)).toBeInTheDocument();
  expect(apiFetch).not.toHaveBeenCalled();
});

test("happy path: apiFetch called with new_password; success message shown", async () => {
  vi.mocked(apiFetch).mockResolvedValueOnce({});
  renderPage();
  fireEvent.change(screen.getByPlaceholderText("New password"), {
    target: { value: "validpassword123" },
  });
  fireEvent.change(screen.getByPlaceholderText("Confirm new password"), {
    target: { value: "validpassword123" },
  });
  fireEvent.click(screen.getByRole("button", { name: /change password/i }));
  await waitFor(() =>
    expect(screen.getByText(/password has been changed/i)).toBeInTheDocument(),
  );
  expect(vi.mocked(apiFetch)).toHaveBeenCalledWith(
    "/users/me/change-password",
    expect.objectContaining({
      method: "POST",
      body: JSON.stringify({ new_password: "validpassword123" }),
    }),
  );
  // Stays on /account — no navigation; back-to-home link rendered
  expect(screen.getByRole("link", { name: /back to home/i })).toBeInTheDocument();
});

test("server WEAK_PASSWORD -> renders messageForCode(WEAK_PASSWORD)", async () => {
  vi.mocked(apiFetch).mockRejectedValueOnce(
    new ApiClientError({ code: "WEAK_PASSWORD", message: "weak", status: 422 }),
  );
  renderPage();
  fireEvent.change(screen.getByPlaceholderText("New password"), {
    target: { value: "validpassword123" },
  });
  fireEvent.change(screen.getByPlaceholderText("Confirm new password"), {
    target: { value: "validpassword123" },
  });
  fireEvent.click(screen.getByRole("button", { name: /change password/i }));
  await waitFor(() =>
    expect(screen.getByText(messageForCode("WEAK_PASSWORD"))).toBeInTheDocument(),
  );
});
