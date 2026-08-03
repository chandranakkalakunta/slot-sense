# Load Balancer Network Foundation — Phase 8b.1
#
# Static global IP and Certificate Manager wildcard cert for the
# Global External HTTPS Load Balancer (ADR-0031). These resources
# have no dependencies on the LB, NEG, or backend service resources
# that follow in later sub-phases — the IP can be provisioned and
# DNS routing record pointed at it before the LB itself exists.
#
# Certificate Manager (not google_compute_managed_ssl_certificate)
# is required because classic managed certs do not support wildcard
# domains. DNS authorization proves ownership of the parent domain;
# a permanent CNAME record at Namecheap is required (see ADR-0031
# addendum). certificatemanager.googleapis.com was enabled via
# gcloud in Phase 8b.1 correction and is documented in apis.tf.

# Static IPv4 address for the LB frontend. Reserving this first lets
# the routing DNS record (*.slotsense.chandraailabs.com A → this IP)
# be configured before the full LB is wired, so DNS propagation runs
# in parallel with remaining sub-phases.
resource "google_compute_global_address" "slotsense_lb_ip" {
  name         = "slotsense-lb-ip"
  project      = var.project_id
  description  = "Static global IP for the SlotSense wildcard subdomain LB (ADR-0031)"
  ip_version   = "IPV4"
  address_type = "EXTERNAL"

  labels = var.default_labels
}

# DNS authorization proves ownership of the parent domain to Certificate
# Manager. One authorization covers both slotsense.chandraailabs.com and
# *.slotsense.chandraailabs.com. After apply, run:
#   gcloud certificate-manager dns-authorizations describe slotsense-dns-auth \
#     --project sport-slot-dev
# to retrieve the exact CNAME record (name + data) that must be added at
# Namecheap. The CNAME must remain permanently — removing it prevents
# automatic cert renewal.
# Per-env base domain (ADR-0046): each project owns
#   var.base_domain + *.var.base_domain
# e.g. slotsense-test.chandraailabs.com for test.
resource "google_certificate_manager_dns_authorization" "slotsense" {
  name    = "slotsense-dns-auth"
  project = var.project_id
  domain  = var.base_domain
}

# Managed wildcard certificate covering both the apex and wildcard,
# authorized via the DNS authorization above.
resource "google_certificate_manager_certificate" "slotsense_wildcard_cert" {
  name    = "slotsense-wildcard-cert"
  project = var.project_id

  managed {
    domains = [
      var.base_domain,
      "*.${var.base_domain}",
    ]
    dns_authorizations = [
      google_certificate_manager_dns_authorization.slotsense.id,
    ]
  }
}

# Certificate map and PRIMARY entry — the target_https_proxy in Phase 8b.2
# will reference this map (not the certificate directly).
resource "google_certificate_manager_certificate_map" "slotsense" {
  name    = "slotsense-cert-map"
  project = var.project_id
}

resource "google_certificate_manager_certificate_map_entry" "slotsense_wildcard" {
  name         = "slotsense-wildcard-entry"
  project      = var.project_id
  map          = google_certificate_manager_certificate_map.slotsense.name
  certificates = [google_certificate_manager_certificate.slotsense_wildcard_cert.id]
  matcher      = "PRIMARY"
}
