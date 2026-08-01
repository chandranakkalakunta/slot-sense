/** Error presentation catalog (ADR-0013). Keyed by locale, then by
 * canonical error code. English only in Phase 4.3; the resolver
 * already accepts locale + tenant overrides for future layers. */

type Catalog = Record<string, Record<string, string>>;

const CATALOG: Catalog = {
  en: {
    AUTH_MISSING_TOKEN: "Please sign in to continue.",
    AUTH_INVALID_TOKEN: "Your session expired — please sign in again.",
    TENANT_MISMATCH: "This account doesn't belong to this community.",
    FORBIDDEN_ROLE: "You don't have permission to do that.",
    VALIDATION_FAILED: "Some details look incorrect — please check and retry.",
    FACILITY_NOT_FOUND: "That facility no longer exists.",
    SLOT_NOT_BOOKABLE: "That slot can't be booked.",
    BOOKING_QUOTA_EXCEEDED: "You've reached your daily booking limit.",
    ALREADY_BOOKED: "That slot was just taken.",
    SLOT_CONTENDED: "Someone's booking this slot — please try again.",
    LOCK_UNAVAILABLE: "Booking is temporarily unavailable — please retry.",
    BOOKING_NOT_FOUND: "That booking no longer exists.",
    CANCELLATION_TOO_LATE: "It's too late to cancel this booking.",
    CANCELLATION_FORBIDDEN: "Only the person who booked it can cancel.",
    ALREADY_CANCELLED: "This booking is already cancelled.",
    INVALID_DATE: "Please choose a valid date.",
    NOT_FOUND: "Not found.",
    INTERNAL_ERROR: "Something went wrong — please try again.",
    UNKNOWN: "Something went wrong — please try again.",
    TENANT_SLUG_TAKEN: "That slug is already in use — choose another.",
    INVALID_SLUG: "Slug must be lowercase letters, numbers, and hyphens (3–30 chars).",
    USER_EMAIL_TAKEN: "That email is already registered.",
    USER_NOT_FOUND: "User not found.",
    SELF_DEACTIVATION_FORBIDDEN: "You can't deactivate your own account.",
    WEAK_PASSWORD: "Password must be at least 8 characters and hard to guess.",
    TEMP_PASSWORD_EXPIRED:
      "Your temporary code has expired. Ask an admin to issue a new one.",
    CATALOG_TYPE_EXISTS: "That facility type already exists.",
    CATALOG_TYPE_NOT_FOUND: "Facility type not found.",
    RESET_TOKEN_INVALID: "This reset link is invalid or has expired. Please request a new one.",
  },
};

const DEFAULT_LOCALE = "en";

export function messageForCode(
  code: string,
  locale: string = DEFAULT_LOCALE,
  overrides: Record<string, string> | null = null,
): string {
  return (
    overrides?.[code] ??
    CATALOG[locale]?.[code] ??
    CATALOG[DEFAULT_LOCALE][code] ??
    code
  );
}
