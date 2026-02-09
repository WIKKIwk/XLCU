.PHONY: run run-docker doctor

run:
	@bash scripts/run_extensions.sh

run-docker:
	@LCE_FORCE_DOCKER=1 bash scripts/run_extensions.sh

doctor:
	@bash scripts/doctor.sh
