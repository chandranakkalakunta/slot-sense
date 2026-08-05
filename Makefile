# SportSlotReservation — Makefile
#
# Discovery layer for common operations.
# Implementation details live in scripts/ per ADR-0003.

.DEFAULT_GOAL := help

# ═══════════════════════════════════════════════════════════════
# Setup & Verification
# ═══════════════════════════════════════════════════════════════

.PHONY: install
install: ## Install all dependencies (backend + frontend)
	@bash scripts/install.sh

.PHONY: verify-env
verify-env: ## Verify all required tools are installed
	@bash scripts/verify_toolchain.sh

# ═══════════════════════════════════════════════════════════════
# Terraform
# ═══════════════════════════════════════════════════════════════

.PHONY: tf-init
tf-init: ## Initialize Terraform with remote state
	@bash scripts/tf-init.sh

.PHONY: tf-plan
tf-plan: ## Show Terraform execution plan
	@bash scripts/tf-plan.sh

.PHONY: tf-apply-dev
tf-apply-dev: ## Apply Terraform changes to DEV (GUARDED)
	@bash scripts/tf-apply-dev.sh

.PHONY: tf-destroy-dev
tf-destroy-dev: ## Destroy DEV Terraform resources (DOUBLE-GUARDED)
	@bash scripts/tf-destroy-dev.sh

.PHONY: tf-fmt
tf-fmt: ## Format Terraform files
	@cd terraform && terraform fmt -recursive

.PHONY: tf-validate
tf-validate: ## Validate Terraform syntax
	@cd terraform && terraform validate

.PHONY: tf
tf: ## Environment-safe terraform wrapper — make tf ENV=dev CMD=plan [ARGS="-target=..."]
	@bash scripts/tf.sh $(ENV) $(CMD) $(ARGS)

.PHONY: tf-list
tf-list: ## List tf.sh's registered environments (project/bucket/var-file)
	@bash scripts/tf.sh --list

# ═══════════════════════════════════════════════════════════════
# GCP
# ═══════════════════════════════════════════════════════════════

.PHONY: gcp-whoami
gcp-whoami: ## Show current gcloud authentication state
	@bash scripts/gcp-whoami.sh

.PHONY: gcp-set-dev
gcp-set-dev: ## Switch to sport-slot-dev project
	@bash scripts/gcp-set-dev.sh

# ═══════════════════════════════════════════════════════════════
# Env power (ADR-0047 FinOps sleep/wake)
# ═══════════════════════════════════════════════════════════════

.PHONY: env-list
env-list: ## List env power status for all registry envs
	@bash scripts/env-power.sh list

.PHONY: env-status
env-status: ## Power status — make env-status ENV=test-03
	@bash scripts/env-power.sh status --env $(ENV)

.PHONY: env-enable
env-enable: ## Wake env (Redis recreate may take 10–20m) — make env-enable ENV=test-03
	@bash scripts/env-power.sh enable --env $(ENV) --yes

.PHONY: env-disable
env-disable: ## Sleep env (delete Redis, min=0) — make env-disable ENV=test-03
	@bash scripts/env-power.sh disable --env $(ENV) --yes

.PHONY: env-hold
env-hold: ## Hold nightly disable — make env-hold ENV=test-03 DAYS=1 REASON="soak"
	@bash scripts/env-power.sh hold --env $(ENV) --days $(DAYS) --reason "$(or $(REASON),hold)"

.PHONY: env-release-hold
env-release-hold: ## Clear nightly hold — make env-release-hold ENV=test-03
	@bash scripts/env-power.sh release-hold --env $(ENV)

# ═══════════════════════════════════════════════════════════════
# Soak / load (test env only) — docs/runbooks/soak-test.md
# ═══════════════════════════════════════════════════════════════

.PHONY: soak-test
soak-test: ## Soak test-03 — make soak-test [DURATION=30m] [RUSH=--rush-now]
	@cd backend && uv run python ../scripts/soak_test.py \
		--project slot-sense-test-03 \
		--base-domain slotsense-test.chandraailabs.com \
		--duration $(or $(DURATION),30m) \
		--tenant-pct $(or $(TENANT_PCT),15) \
		--workers $(or $(WORKERS),12) \
		$(or $(RUSH),--rush-now) \
		--report ../soak-report.json

# ═══════════════════════════════════════════════════════════════
# Development
# ═══════════════════════════════════════════════════════════════

.PHONY: seed-dev
seed-dev: ## Seed dev Firebase user + profile (dev only)
	@cd backend && uv run python scripts/seed_dev_user.py

.PHONY: seed-platform-admin
seed-platform-admin: ## Seed first platform-admin user (run once, idempotent — Coordinator runs this)
	@cd backend && uv run python scripts/seed_platform_admin.py

.PHONY: reset-superadmin
reset-superadmin:  ## Reset dev superadmin password (NEWPW=...)
	cd backend && NEWPW=$(NEWPW) uv run python scripts/reset_superadmin.py

.PHONY: seed-facility-catalog
seed-facility-catalog: ## Seed global facility-type catalog + migrate legacy facilities (idempotent — Coordinator runs this)
	@cd backend && uv run python scripts/seed_facility_catalog.py

.PHONY: dev-env
dev-env: ## Create backend/.env from template (first-time setup)
	@if [ -f backend/.env ]; then \
		echo "backend/.env already exists — not overwriting."; \
	else \
		cp backend/.env.example backend/.env; \
		echo "Created backend/.env — fill in SPORTSLOT_WEB_API_KEY before running the server."; \
	fi

.PHONY: run-dev
run-dev: ## Run backend locally (uvicorn, reload)
	@cd backend && PYTHONPATH=src uv run uvicorn sport_slot.main:app --reload --port 8000

.PHONY: docker-build
docker-build: ## Build backend Docker image locally
	@cd backend && docker build -t sport-slot-api:local .

.PHONY: docker-run
docker-run: ## Run container locally (mounts gcloud ADC read-only)
	@docker run --rm -p 8080:8080 \
		-v "$$HOME/.config/gcloud:/home/app/.config/gcloud:ro" \
		-e GOOGLE_CLOUD_PROJECT=sport-slot-dev \
		-e SPORTSLOT_ENVIRONMENT=development \
		sport-slot-api:local

.PHONY: redis-local
redis-local: ## Run local Redis for dev (docker)
	@docker run --rm -d -p 6379:6379 --name sport-slot-redis redis:7-alpine

.PHONY: redis-local-stop
redis-local-stop: ## Stop local Redis container
	@docker stop sport-slot-redis

.PHONY: build-push
build-push: ## Build and push backend image via Cloud Build (Coordinator-run)
	@./scripts/build_push.sh

# deploy_cloud_run.sh refuses to guess a project. Makefile provides
# sport-slot-dev defaults for the legacy `make deploy-dev` path; any other
# environment must export SLOTSENSE_* explicitly (or use drill-bootstrap).
.PHONY: deploy-dev
deploy-dev: ## Deploy backend to Cloud Run (defaults: sport-slot-dev; override SLOTSENSE_*)
	@SLOTSENSE_PROJECT="$${SLOTSENSE_PROJECT:-sport-slot-dev}" \
	 SLOTSENSE_REGION="$${SLOTSENSE_REGION:-asia-south1}" \
	 SLOTSENSE_ARTIFACT_REPO="$${SLOTSENSE_ARTIFACT_REPO:-sport-slot-repo}" \
	 ./scripts/deploy_cloud_run.sh

# ═══════════════════════════════════════════════════════════════
# Frontend
# ═══════════════════════════════════════════════════════════════

.PHONY: fe-install
fe-install: ## Install frontend dependencies
	@(cd frontend && pnpm install)

.PHONY: fe-dev
fe-dev: ## Run frontend dev server (proxies /api → :8000)
	@(cd frontend && pnpm dev)

.PHONY: fe-lint
fe-lint: ## Lint frontend
	@(cd frontend && pnpm lint)

.PHONY: fe-test
fe-test: ## Run frontend tests
	@(cd frontend && pnpm test)

.PHONY: fe-build
fe-build: ## Build frontend for production
	@(cd frontend && pnpm build)

.PHONY: deploy-hosting
deploy-hosting: ## Build + deploy PWA to Firebase Hosting (Coordinator)
	@./scripts/deploy_hosting.sh

# ═══════════════════════════════════════════════════════════════
# Help
# ═══════════════════════════════════════════════════════════════

.PHONY: help
help: ## Show this help message
	@echo ""
	@echo "SportSlotReservation — Available Commands"
	@echo "═══════════════════════════════════════════════════════════"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  %-20s %s\n", $$1, $$2}'
	@echo ""
	@echo "Run any command with: make <command>"
	@echo ""
