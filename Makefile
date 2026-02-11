.PHONY: run run-docker run-hw doctor bootstrap setup

# Default to hardware-friendly Docker mode (USB/serial access). Override:
#   make run LCE_DOCKER_PRIVILEGED=0
LCE_DOCKER_PRIVILEGED ?= 1

# Default to host networking in Docker so LAN/broadcast discovery and "any port"
# access work without extra port publishing. Override:
#   make run LCE_DOCKER_HOST_NETWORK=0
LCE_DOCKER_HOST_NETWORK ?= 1

# Always restart runtime on each make run to avoid stale bot polling conflicts.
# Override only if you intentionally want reuse:
#   make run LCE_FORCE_RESTART=0
LCE_FORCE_RESTART ?= 1

run:
	@LCE_FORCE_RESTART="$(LCE_FORCE_RESTART)" LCE_DOCKER_PRIVILEGED="$(LCE_DOCKER_PRIVILEGED)" LCE_DOCKER_HOST_NETWORK="$(LCE_DOCKER_HOST_NETWORK)" bash scripts/run_extensions.sh

run-docker:
	@LCE_FORCE_DOCKER=1 LCE_FORCE_RESTART="$(LCE_FORCE_RESTART)" LCE_DOCKER_PRIVILEGED="$(LCE_DOCKER_PRIVILEGED)" LCE_DOCKER_HOST_NETWORK="$(LCE_DOCKER_HOST_NETWORK)" bash scripts/run_extensions.sh

run-hw:
	@LCE_FORCE_DOCKER=1 LCE_FORCE_RESTART="$(LCE_FORCE_RESTART)" LCE_DOCKER_PRIVILEGED=1 LCE_DOCKER_HOST_NETWORK="$(LCE_DOCKER_HOST_NETWORK)" bash scripts/run_extensions.sh

doctor:
	@bash scripts/doctor.sh

bootstrap:
	@bash scripts/bootstrap.sh

setup: bootstrap doctor
