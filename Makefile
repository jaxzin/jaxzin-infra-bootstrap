## Development Targets

.PHONY: nuke
nuke:
	@echo "Nuking the development environment..."
	@$(MAKE) clean
	@echo "Removing all ansible cache files..."
	@echo rm -rf ~/.ansible
	@echo "Removing Docker containers and images related to molecule testing..."
	@docker ps -aq --filter ancestor=molecule_local | xargs -r docker rm -f
	@docker images | grep molecule_local | awk '{print $$3}' | xargs -r docker rmi -f
	@docker image prune -f
	@echo "Cleaning up Docker system..."
	@docker system df
	@docker system prune -af --volumes
	@echo "Development environment nuked."

.PHONY: clean
clean:
	@echo "Tearing down any molecule scenarios..."
	@($(MAKE) molecule -- destroy --all && $(MAKE) molecule -- reset) || true
	@echo "Cleanup complete."

.PHONY: run-bootstrap
run-bootstrap:
	@echo "Running Bootstrap workflow locally with act..."
	@act -W .github/workflows/bootstrap.yml --secret-file .secrets --var-file .vars --container-architecture linux/amd64 -P self-hosted=ghcr.io/jaxzin/jaxzin-infra-runner:latest

.PHONY: deploy
deploy:
	@echo "Running Deploy Gitea workflow locally with act..."
	@act -W .gitea/workflows/deploy.yml --secret-file .secrets --var-file .vars --container-architecture linux/amd64 -P self-hosted=ghcr.io/jaxzin/jaxzin-infra-runner:latest

.PHONY: run-restore
run-restore:
	@echo "Running Restore Gitea Data workflow locally with act..."
	@act -W .github/workflows/restore.yml --secret-file .secrets --var-file .vars --container-architecture linux/amd64 -P self-hosted=ghcr.io/jaxzin/jaxzin-infra-runner:latest

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

# ================ Ansible Molecule helpers BEGIN ======================

# Single source of truth for running molecule against one role.
# Default path for roles directory.
COLLECTION_PATH ?= collections/ansible_collections/jaxzin/infra
EXTENSIONS_PATH ?= $(COLLECTION_PATH)/extensions

.PHONY: molecule
molecule:
	# Conditionally add ./collections to ANSIBLE_COLLECTIONS_PATHS if not already present
	@COLLECTIONS_PATH="$$PWD/collections"; \
	case ":$${ANSIBLE_COLLECTIONS_PATH}:" in \
	  *:"$$COLLECTIONS_PATH":*) ;; \
	  *) export ANSIBLE_COLLECTIONS_PATH="$$COLLECTIONS_PATH:$${ANSIBLE_COLLECTIONS_PATH}";; \
	esac; \
	echo "ANSIBLE_COLLECTIONS_PATH=$${ANSIBLE_COLLECTIONS_PATH}"; \
	uv run ansible-galaxy collection install --force-with-deps ~./ansible/collections; \
	if [ "$(word 2,$(MAKECMDGOALS))" = "" ]; then \
		echo "Usage: make molecule -- [MOLECULE_ARGS...]"; \
		exit 1; \
	fi; \
	args="$(wordlist 2,$(words $(MAKECMDGOALS)),$(MAKECMDGOALS))"; \
	echo "--- Testing collection jaxzin.infra with command molecule [$$args] ---"; \
	UV_LINK_MODE=copy uv run -v --directory $(EXTENSIONS_PATH) molecule $$args

# Prevent additional args from being treated as targets.
%:
	@:

# ================ Ansible Molecule helpers END ======================


.PHONY: help
help:
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-30s\033[0m %s\n", $$1, $$2}'