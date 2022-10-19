# Display help by default.
.DEFAULT_GOAL := help

# Require bash to use foreach loops.
SHELL := bash

# Used to include host-platform specific docker compose files.
OS := $(shell uname -s | tr A-Z a-z)

# Output directory for generated / downloaded artifacts.
BUILDDIR ?= $(CURDIR)/build

# For text display in the shell.
RESET=$(shell tput sgr0)
RED=$(shell tput setaf 9)
BLUE=$(shell tput setaf 6)
TARGET_MAX_CHAR_NUM=30

# Some targets will only be included if the appropriate condition is met.
DOCKER_COMPOSE_INSTALLED=$(shell docker compose version &>/dev/null && echo "true")
HELMFILE_INSTALLED=$(shell helmfile -v &>/dev/null && echo "true")
KUBECTL_INSTALLED=$(shell kubectl version &>/dev/null && echo "true")
SSH_AGENT_RUNNING=$(shell test -S "$${SSH_AUTH_SOCK}" && echo "true")

# Display text for requirements.
README_MESSAGE=${BLUE}Consult the README.md for how to install requirements.${RESET}\n

# Bash snippet to check for the existance an executable.
define executable-exists
	@if ! command -v $(1) >/dev/null; \
	then \
		printf "${RED}Could not find executable: %s${RESET}\n${README_MESSAGE}" $(1); \
		exit 1; \
	fi;
endef

# Images produced by this repository. The logic in this Makefile assumes
# docker compose services are named after their respective images.
IMAGES := $(foreach x,$(wildcard docker/*),$(patsubst docker/%,%,$(x)))

# Release name and namespace to use for resouces created with helm.
export HELM_RELEASE_NAME?= leaf
export HELM_NAMESPACE ?= islandora

$(BUILDDIR):
	mkdir -p $(BUILDDIR)

# This is a catch all target that is used to check for existance of an
# executable when declared as a dependency.
.PHONY: %
%:
	$(call executable-exists,$@)

# Must be defined explicitly as we already have a folder named docker.
.PHONY: docker
docker:
	$(call executable-exists,docker)

# Checks for docker compose plugin.
.PHONY: docker-compose
docker-compose: MISSING_DOCKER_PLUGIN_MESSAGE = ${RED}docker compose plugin is not installed${RESET}\n${README_MESSAGE}
docker-compose: | docker
  # Check for `docker compose` as compose version 2+ is used is assumed.
	@if ! docker compose version &>/dev/null; \
	then \
		printf "$(MISSING_DOCKER_PLUGIN_MESSAGE)"; \
		exit 1; \
	fi

# Checks for helmfile and helmfile plugins.
.PHONY: helmfile
helmfile: MISSING_HELM_PLUGIN_MESSAGE = ${RED}helm plugin %s is not installed${RESET}\n${README_MESSAGE}
helmfile: | helm kubectl # These are invoked by helmfile internally.
helmfile:
  # Cannot be a dependency as that would be circular.
	$(call executable-exists,helmfile)
  # Check for `helm PLUGIN` as some are required for use with helmfile.
	@for plugin in diff secrets; \
	do \
		if ! helm $$plugin -h &>/dev/null; \
		then \
			printf "$(MISSING_HELM_PLUGIN_MESSAGE)" $$plugin; \
			exit 1; \
		fi; \
	done

.PHONY: login
login: REGISTRIES = gitlab.com registry.gitlab.com https://index.docker.io/v1/
login: | docker jq
login:
	@for registry in $(REGISTRIES); \
	do \
		if ! jq -e ".auths|keys|any(. == \"$$registry\")" ~/.docker/config.json &>/dev/null; \
		then \
			printf "Log into $$registry\n"; \
			docker login $$registry; \
		fi; \
	done

# Using mkcert to generate local certificates rather than traefik certs
# as they often get revoked.
$(BUILDDIR)/certs/cert.pem $(BUILDDIR)/certs/privkey.pem $(BUILDDIR)/certs/rootCA.pem $(BUILDDIR)/certs/rootCA-key.pem  &: | mkcert $(BUILDDIR)
	mkdir -p $(BUILDDIR)/certs
  # Requires mkcert to be installed first (It may fail on some systems due to how Java is configured, but this can be ignored).
	-mkcert -install
	mkcert -cert-file $(BUILDDIR)/certs/cert.pem -key-file $(BUILDDIR)/certs/privkey.pem *.islandora.dev islandora.dev localhost 127.0.0.1 ::1
	cp "$$(mkcert -CAROOT)/rootCA-key.pem" $(BUILDDIR)/certs/rootCA-key.pem
	cp "$$(mkcert -CAROOT)/rootCA.pem" $(BUILDDIR)/certs/rootCA.pem

$(BUILDDIR)/certs/tls.crt: $(BUILDDIR)/certs/rootCA.pem
	cp $(BUILDDIR)/certs/rootCA.pem $(BUILDDIR)/certs/tls.crt

$(BUILDDIR)/certs/tls.key: $(BUILDDIR)/certs/rootCA-key.pem
	cp $(BUILDDIR)/certs/rootCA-key.pem $(BUILDDIR)/certs/tls.key

# When doing local development it is preferable to have the containers nginx
# user have the same uid/gid as the host machine to prevent permission issues.
$(BUILDDIR)/secrets/UID $(BUILDDIR)/secrets/GID &: | id $(BUILDDIR)
	mkdir -p $(BUILDDIR)/secrets
	id -u > $(BUILDDIR)/secrets/UID
	id -g > $(BUILDDIR)/secrets/GID

# Mounting SSH-Agent socket is platform dependent.
docker-compose.override.yml:
	@if [[ -S "$${SSH_AUTH_SOCK}" ]]; then \
		cp docker-compose.$(OS).yml docker-compose.override.yml; \
	fi

.PHONY:
## Builds local images from the 'docker' folder.
compose-build: login
compose-build: | docker-compose
	docker compose build $(IMAGES)

.PHONY: compose-pull
## Pull service images from 'docker-compose.yml'.
compose-pull: REMOTE_IMAGES = $(filter-out $(IMAGES),$(shell docker compose config --services 2>/dev/null))
compose-pull: login | docker-compose
	-docker compose pull $(REMOTE_IMAGES)

.PHONY: compose-up
## Starts up the local development environment.
compose-up: $(BUILDDIR)/certs/cert.pem $(BUILDDIR)/certs/privkey.pem $(BUILDDIR)/certs/rootCA.pem
compose-up: $(BUILDDIR)/secrets/UID $(BUILDDIR)/secrets/GID
compose-up: $(if $(filter true,$(SSH_AGENT_RUNNING)),docker-compose.override.yml)
compose-up: compose-pull compose-build | docker-compose
  # jetbrains cache / config is created externally so it will persist indefinitely.
	docker volume create jetbrains-cache
	docker volume create jetbrains-config
	docker compose up -d
	@docker compose exec drupal timeout 600 bash -c "while ! test -f /installed; do sleep 5; done"
	@printf "  Credentials:\n"
	@printf "  ${RED}%-$(TARGET_MAX_CHAR_NUM)s${RESET} ${BLUE}%s${RESET}\n" "Username" "admin"
	@printf "  ${RED}%-$(TARGET_MAX_CHAR_NUM)s${RESET} ${BLUE}%s${RESET}\n" "Password" "password"
	@printf "\n  Services Available:\n"
	@for link in \
		"http://activemq.islandora.dev|The ActiveMQ administrative console." \
		"http://islandora.dev|The Drupal website." \
		"http://ide.islandora.dev|The in browser editor." \
		"http://solr.islandora.dev|The Solr search engine administrative console." \
		"http://traefik.islandora.dev|The Traefik router administrative console." \
	; \
	do \
		echo $$link | tr -s '|' '\000' | xargs -0 -n2 printf "  ${RED}%-$(TARGET_MAX_CHAR_NUM)s${RESET} ${BLUE}%s${RESET}"; \
	done

.PHONY: compose-down
## Stops the local development environment.
compose-down: | docker-compose
	docker compose down

.PHONY: clean
## Destroys local environment and cleans up any uncommitted files.
clean: | git
	-docker compose down -v
	git clean -xfd .

.PHONY: help
.SILENT: help
## Displays this help message.
help: | awk
	@echo ''
	@echo 'Usage:'
	@echo '  ${RED}make${RESET} ${BLUE}<target>${RESET}'
	@echo ''
	@echo 'General:'
	@awk '/^[a-zA-Z\-_0-9]+:/ { \
		helpMessage = match(lastLine, /^## (.*)/); \
		if (helpMessage) { \
			helpCommand = $$1; sub(/:$$/, "", helpCommand); \
			helpMessage = substr(lastLine, RSTART + 3, RLENGTH); \
			if (helpCommand !~ "^compose-" && helpCommand !~ "^helm-" && helpCommand !~ "^helmfile-" && helpCommand !~ "^kubectl-") { \
				printf "  ${RED}%-$(TARGET_MAX_CHAR_NUM)s${RESET} ${BLUE}%s${RESET}\n", helpCommand, helpMessage; \
			} \
		} \
	} \
	{lastLine = $$0}' $(MAKEFILE_LIST)
	@echo ''
	@echo 'Docker Compose:'
	@awk '/^[a-zA-Z\-_0-9]+:/ { \
		helpMessage = match(lastLine, /^## (.*)/); \
		if (helpMessage) { \
			helpCommand = $$1; sub(/:$$/, "", helpCommand); \
			helpMessage = substr(lastLine, RSTART + 3, RLENGTH); \
			if (helpCommand ~ "^compose-") { \
				printf "  ${RED}%-$(TARGET_MAX_CHAR_NUM)s${RESET} ${BLUE}%s${RESET}\n", helpCommand, helpMessage; \
			} \
		} \
	} \
	{lastLine = $$0}' $(MAKEFILE_LIST)
	@echo ''
	@echo 'Helmfile:'
	@awk '/^[a-zA-Z\-_0-9]+:/ { \
		helpMessage = match(lastLine, /^## (.*)/); \
		if (helpMessage) { \
			helpCommand = $$1; sub(/:$$/, "", helpCommand); \
			helpMessage = substr(lastLine, RSTART + 3, RLENGTH); \
			if (helpCommand ~ "^helmfile-") { \
				printf "  ${RED}%-$(TARGET_MAX_CHAR_NUM)s${RESET} ${BLUE}%s${RESET}\n", helpCommand, helpMessage; \
			} \
		} \
	} \
	{lastLine = $$0}' $(MAKEFILE_LIST)
	@echo ''
	@echo 'Helm:'
	@awk '/^[a-zA-Z\-_0-9]+:/ { \
		helpMessage = match(lastLine, /^## (.*)/); \
		if (helpMessage) { \
			helpCommand = $$1; sub(/:$$/, "", helpCommand); \
			helpMessage = substr(lastLine, RSTART + 3, RLENGTH); \
			if (helpCommand ~ "^helm-") { \
				printf "  ${RED}%-$(TARGET_MAX_CHAR_NUM)s${RESET} ${BLUE}%s${RESET}\n", helpCommand, helpMessage; \
			} \
		} \
	} \
	{lastLine = $$0}' $(MAKEFILE_LIST)
	@echo ''
	@echo 'Kubectl:'
	@awk '/^[a-zA-Z\-_0-9]+:/ { \
		helpMessage = match(lastLine, /^## (.*)/); \
		if (helpMessage) { \
			helpCommand = $$1; sub(/:$$/, "", helpCommand); \
			helpMessage = substr(lastLine, RSTART + 3, RLENGTH); \
			if (helpCommand ~ "^kubectl-") { \
				printf "  ${RED}%-$(TARGET_MAX_CHAR_NUM)s${RESET} ${BLUE}%s${RESET}\n", helpCommand, helpMessage; \
			} \
		} \
	} \
	{lastLine = $$0}' $(MAKEFILE_LIST)
	@echo ''
