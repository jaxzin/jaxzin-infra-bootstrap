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


.PHONY: deps sync-deps
sync-deps:
	@echo "Generating requirements.yml from galaxy.yml..."
	@yq e '.dependencies | to_entries | map({"name": .key, "version": .value}) | {"collections": .}' \
	collections/ansible_collections/jaxzin/infra/galaxy.yml > requirements.yml

deps: sync-deps
	@echo "Installing Ansible Galaxy collections from requirements.yml..."
	@uv run ansible-galaxy collection install -r requirements.yml --force-with-deps

.PHONY: docker-build
docker-build:
	@echo "Building custom Docker runner image..."
	@docker build -t ghcr.io/jaxzin/jaxzin-infra-runner:latest .

REPO := ghcr.io/$(USER)/$(shell basename $(CURDIR))
BRANCH := $(shell git rev-parse --abbrev-ref HEAD)
TAG := $(REPO):$(BRANCH)

.PHONY: devcontainer-build
devcontainer-build:
	@echo "🔨 Building DevContainer with Docker: $(TAG)"
	docker build -f .devcontainer/Dockerfile \
		-t $(TAG) \
		.

.PHONY: devcontainer-buildx
devcontainer-buildx:
	@echo "🔨 Building multi-arch DevContainer with Docker: $(TAG)"
	docker buildx build \
		--platform linux/amd64,linux/arm64 \
		--file .devcontainer/Dockerfile \
		--tag $(TAG) \
		--push \
		.

.PHONY: devcontainer-push
devcontainer-push:
	docker push $(TAG)

# ================ Ansible Molecule helpers BEGIN ======================

# Single source of truth for running molecule against one role.
# Default path for roles directory.
COLLECTION_PATH ?= collections/ansible_collections/jaxzin/infra
EXTENSIONS_PATH ?= $(COLLECTION_PATH)/extensions

.PHONY: link-collection
link-collection:
	@echo "Linking Ansible collection for development..."
	@mkdir -p $(HOME)/.ansible/$(COLLECTION_PATH)
	@ln -sf $(CURDIR)/$(COLLECTION_PATH) $(HOME)/.ansible/$(COLLECTION_PATH)
	@echo "Collection linked at $(HOME)/.ansible/$(COLLECTION_PATH)"

.PHONY: molecule
molecule: link-collection
	if [ "$(word 2,$(MAKECMDGOALS))" = "" ]; then \
		echo "Usage: make molecule -- [MOLECULE_ARGS...]"; \
		exit 1; \
	fi; \
	args="$(wordlist 2,$(words $(MAKECMDGOALS)),$(MAKECMDGOALS))"; \
	echo "--- Testing collection jaxzin.infra with command molecule [$$args] ---"; \
	uv run ansible-galaxy collection install jaxzin.infra -p ./collections; \
	UV_LINK_MODE=copy uv run -v --directory $(EXTENSIONS_PATH) molecule $$args

.PHONY: test
test: link-collection
	@echo "Running tests for the Ansible collection..."; \
	UV_LINK_MODE=copy uv run -v --directory $(EXTENSIONS_PATH) molecule test

# Prevent additional args from being treated as targets.
%:
	@:

# ================ Ansible Molecule helpers END ======================


.PHONY: help
help:
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-30s\033[0m %s\n", $$1, $$2}'