## Development Targets

.PHONY: act-test
act-test:
	@echo "Running GitHub Actions workflow locally with act..."
	@act -W .github/workflows/bootstrap.yml --secret-file .secrets --var-file .vars --input dry_run=true --container-architecture linux/amd64 -P self-hosted=ghcr.io/jaxzin/jaxzin-infra-runner:latest


.PHONY: health-check
health-check:
	@echo "Running health-check GitHub Actions workflow locally with act..."
	@act -W .github/workflows/health-check.yml --secret-file .secrets --var-file .vars --container-architecture linux/amd64 -P self-hosted=ghcr.io/jaxzin/jaxzin-infra-runner:latest


.PHONY: install-ansible-collections
install-ansible-collections:
	@echo "Installing Ansible Galaxy collections..."
	@ansible-galaxy collection install -r playbooks/galaxy-requirements.yml

.PHONY: docker-build
docker-build:
	@echo "Building custom Docker runner image..."
	@docker build -t ghcr.io/jaxzin/jaxzin-infra-runner:latest .

.PHONY: help
help:
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-30s\033[0m %s\n", $$1, $$2}'