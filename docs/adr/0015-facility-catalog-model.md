# ADR-0015: Facility Catalog Model

Status: Accepted | Date: 2026-06-14 | Author: Chandra Nakkalakunta

## Context
Tenants need consistent facility TYPES but custom INSTANCES.
Today's Facility model is free-form (sport is an arbitrary string),
which prevents cross-tenant consistency and clean reporting.

## Decisions

### 1. Two layers
Global platform-level facility-type catalog at
/facility_catalog/{type_id}: { type_id, name, sport }, seeded with
standard types (badminton, tennis, swimming, gym, turf-football,
table-tennis, basketball). Per-tenant facility instances (existing
/tenants/{id}/facilities/{id}) gain facility_type_id linking to the
catalog, plus an optional description (e.g. "North Side Court").

> Amendment (2026-06-14): tenant branding includes brand_logo_url
> (optional string). Logo is a URL field now; file upload to Cloud
> Storage is deferred (own sub-phase, Phase 7-adjacent).

### 2. Selection then instantiation
Tenant-admin browses the catalog, selects a type, and creates one
or more named instances with that type and tenant-specific config
(name, open/close, slot duration, description). Multiple instances
per type are allowed (Court 1, Court 2).

### 3. Catalog management (platform admin)
~~Deferred in v1~~ **Implemented (2026-08):** platform-admin CRUD over
catalog types at `POST/PATCH/DELETE /api/v1/admin/facility-catalog` and
the `/admin/facility-catalog` UI. Seed script remains for bootstrap of
standard types. Tenants continue to select types when creating instances.

### 4. Migration of the existing facility
The existing free-form "Badminton Court 1" (sport=badminton, no
facility_type_id) is back-linked to the seeded badminton catalog
entry by the seed/migration step.

### 5. Creation constraint
Facility creation now requires selecting a catalog facility_type_id;
free-form sport strings are no longer accepted on creation.

## Consequences
+ Cross-tenant consistency and clean future reporting by type.
+ Tenant flexibility on names, count, and config.
− A catalog seed + schema addition + the migration touch.
− A deliberate creation constraint (must pick a catalog type).

## References
ADR-0008 (data layout), ADR-0010 (booking domain), ADR-0014.
