# Load Balancer Routing — Phase 8b.2
#
# URL maps, target proxies, and forwarding rules that wire together the
# backends from load_balancer_backends.tf with the static IP and certificate
# map provisioned in Phase 8b.1 (load_balancer_network.tf).
#
# Two forwarding rules share the same static IP:
#   port 443 → HTTPS → slotsense_https_url_map  (routes traffic to backends)
#   port 80  → HTTP  → slotsense_http_redirect   (301 HTTPS redirect, no content)
#
# URL map host_rule matches ONLY *.${var.base_domain} & ${var.base_domain}
# (ADR-0046 multi-env bases). Path matcher routes /api/*, /health, /readyz
# to Cloud Run and everything else to the GCS frontend bucket. SPA 404
# catch-all re-serves /index.html (see load_balancer_backends.tf).

# ── Main HTTPS URL map ──

resource "google_compute_url_map" "slotsense_https" {
  name            = "slotsense-https-url-map"
  project         = var.project_id
  default_service = google_compute_backend_bucket.frontend.id

  host_rule {
    hosts        = ["*.${var.base_domain}", var.base_domain]
    path_matcher = "slotsense-paths"
  }

  path_matcher {
    name            = "slotsense-paths"
    default_service = google_compute_backend_bucket.frontend.id

    # Root path rewrite: GCS treats "/" as a list-bucket operation (allUsers has
    # storage.objects.list via objectViewer) and returns HTTP 200 with XML rather
    # than 404 -- so the default_custom_error_response_policy below never engages
    # for this specific path. Rewriting "/" to "/index.html" before the request
    # reaches GCS ensures GCS always receives a request for a real named object.
    path_rule {
      paths   = ["/"]
      service = google_compute_backend_bucket.frontend.id
      route_action {
        url_rewrite {
          path_prefix_rewrite = "/index.html"
        }
      }
    }

    # SPA client routes: rewrite to /index.html BEFORE GCS (same technique as "/").
    # Relying solely on default_custom_error_response_policy (404→index.html) is
    # unreliable with backend buckets — observed HTTP 200 + Content-Length: 0 with
    # the correct index.html etag but an empty body, which blanks the UI and fails
    # Playwright (heading / #sign-in-email never mount). Explicit path rewrites
    # make GCS fetch the real object every time.
    #
    # Use exact paths only. path_prefix_rewrite on "/prefix/*" appends the
    # remainder (e.g. /facilities/xyz → /index.html/xyz), which 404s. Dynamic
    # segments (/facilities/:id, /admin/tenants/:id/users/new) fall through to
    # custom error (best-effort) or client-side navigation after SPA load.
    # Paths mirror frontend/src/App.tsx static routes.
    path_rule {
      paths = [
        "/signin",
        "/forgot-password",
        "/reset",
        "/force-password",
        "/bookings",
        "/invoices",
        "/account",
        "/assistant",
        "/admin",
        "/admin/facility-catalog",
        "/admin/tenants/new",
        "/tenant",
        "/tenant/facilities",
        "/tenant/branding",
        "/tenant/policies",
        "/tenant/users",
        "/tenant/overview",
        "/tenant/invoices",
      ]
      service = google_compute_backend_bucket.frontend.id
      route_action {
        url_rewrite {
          path_prefix_rewrite = "/index.html"
        }
      }
    }

    path_rule {
      paths   = ["/api/*", "/health", "/readyz", "/version"]
      service = google_compute_backend_service.api.id
    }

    # Best-effort SPA fallback for paths not listed above. Prefer path_rule
    # rewrites for production client routes (see comment on SPA path_rule).
    default_custom_error_response_policy {
      error_response_rule {
        match_response_codes   = ["404"]
        path                   = "/index.html"
        override_response_code = 200
      }
      error_service = google_compute_backend_bucket.frontend.id
    }
  }

  # Applies when no host_rule matches (direct IP access or unrecognised host).
  default_custom_error_response_policy {
    error_response_rule {
      match_response_codes   = ["404"]
      path                   = "/index.html"
      override_response_code = 200
    }
    error_service = google_compute_backend_bucket.frontend.id
  }
}

# ── HTTPS target proxy (references 8b.1 cert map) ──

# certificate_map uses the full Certificate Manager resource name format:
# //certificatemanager.googleapis.com/<id>
resource "google_compute_target_https_proxy" "slotsense" {
  name            = "slotsense-https-proxy"
  project         = var.project_id
  url_map         = google_compute_url_map.slotsense_https.id
  certificate_map = "//certificatemanager.googleapis.com/${google_certificate_manager_certificate_map.slotsense.id}"
}

# ── HTTPS forwarding rule (port 443, uses 8b.1 static IP) ──

resource "google_compute_global_forwarding_rule" "slotsense_https" {
  name                  = "slotsense-https-forwarding-rule"
  project               = var.project_id
  load_balancing_scheme = "EXTERNAL_MANAGED"
  target                = google_compute_target_https_proxy.slotsense.id
  ip_address            = google_compute_global_address.slotsense_lb_ip.id
  port_range            = "443"

  labels = var.default_labels
}

# ── HTTP → HTTPS redirect (port 80, same static IP) ──

resource "google_compute_url_map" "slotsense_http_redirect" {
  name    = "slotsense-http-redirect"
  project = var.project_id

  default_url_redirect {
    https_redirect = true
    strip_query    = false
  }
}

resource "google_compute_target_http_proxy" "slotsense_redirect" {
  name    = "slotsense-http-proxy"
  project = var.project_id
  url_map = google_compute_url_map.slotsense_http_redirect.id
}

resource "google_compute_global_forwarding_rule" "slotsense_http" {
  name                  = "slotsense-http-forwarding-rule"
  project               = var.project_id
  load_balancing_scheme = "EXTERNAL_MANAGED"
  target                = google_compute_target_http_proxy.slotsense_redirect.id
  ip_address            = google_compute_global_address.slotsense_lb_ip.id
  port_range            = "80"

  labels = var.default_labels
}
