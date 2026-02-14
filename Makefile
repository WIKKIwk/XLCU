.PHONY: run run-docker run-hw run-sim run-sim-rfid run-legacy doctor bootstrap support-bundle setup
.PHONY: offline-bundle

# Default to hardware-friendly Docker mode (USB/serial access). Override:
#   make run LCE_DOCKER_PRIVILEGED=0
LCE_DOCKER_PRIVILEGED ?= 1

# Compose mode uses bridge networking for portability across Linux/macOS/Windows.
# Keep this variable for backward compatibility with run-legacy.
LCE_DOCKER_HOST_NETWORK ?= 0

# Always restart runtime on each make run to avoid stale bot polling conflicts.
# Override only if you intentionally want reuse:
#   make run LCE_FORCE_RESTART=0
LCE_FORCE_RESTART ?= 1

run:
	@LCE_FORCE_RESTART="$(LCE_FORCE_RESTART)" LCE_DOCKER_PRIVILEGED="$(LCE_DOCKER_PRIVILEGED)" LCE_DOCKER_HOST_NETWORK="$(LCE_DOCKER_HOST_NETWORK)" bash scripts/run_extensions_compose.sh

run-docker:
	@LCE_FORCE_DOCKER=1 LCE_FORCE_RESTART="$(LCE_FORCE_RESTART)" LCE_DOCKER_PRIVILEGED="$(LCE_DOCKER_PRIVILEGED)" LCE_DOCKER_HOST_NETWORK="$(LCE_DOCKER_HOST_NETWORK)" bash scripts/run_extensions_compose.sh

run-hw:
	@LCE_FORCE_DOCKER=1 LCE_FORCE_RESTART="$(LCE_FORCE_RESTART)" LCE_DOCKER_PRIVILEGED=1 LCE_DOCKER_HOST_NETWORK="$(LCE_DOCKER_HOST_NETWORK)" bash scripts/run_extensions_compose.sh

run-sim:
	@LCE_SIM_MODE=1 LCE_CHILDREN_TARGET=zebra LCE_FORCE_RESTART="$(LCE_FORCE_RESTART)" LCE_DOCKER_PRIVILEGED=0 bash scripts/run_extensions_compose.sh

run-sim-rfid:
	@LCE_SIM_MODE=1 LCE_CHILDREN_TARGET=rfid LCE_FORCE_RESTART="$(LCE_FORCE_RESTART)" LCE_DOCKER_PRIVILEGED=0 bash scripts/run_extensions_compose.sh

run-legacy:
	@LCE_FORCE_RESTART="$(LCE_FORCE_RESTART)" LCE_DOCKER_PRIVILEGED="$(LCE_DOCKER_PRIVILEGED)" LCE_DOCKER_HOST_NETWORK="$(LCE_DOCKER_HOST_NETWORK)" bash scripts/run_extensions.sh

doctor:
	@bash scripts/doctor.sh

bootstrap:
	@bash scripts/bootstrap.sh

support-bundle:
	@bash scripts/support_bundle.sh

setup: bootstrap doctor

offline-bundle:
	@bash scripts/offline_bundle.sh "$(LCE_CHILDREN_TARGET)"
