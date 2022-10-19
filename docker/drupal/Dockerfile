# syntax=docker/dockerfile:1.2.1
ARG repository=local
ARG tag=latest
FROM --platform=$BUILDPLATFORM ${repository}/composer:${tag} AS composer

ARG COMMIT=main

# Islandora based Drupal install.
RUN --mount=type=cache,id=test-composer,sharing=locked,target=/root/.composer/cache \
    --mount=type=cache,id=test-downloads,sharing=locked,target=/opt/downloads \
    --mount=type=bind,source=build,target=/build \
    # Get the Drupal codebase
    git-clone-cached.sh \
        --url https://github.com/Islandora/islandora-starter-site.git \
        --cache-dir "${DOWNLOAD_CACHE_DIRECTORY}" \
        --commit "${COMMIT}" \
        --worktree /var/www/drupal && \
    cd /var/www/drupal && \
    cp /build/default.settings.php /var/www/drupal/assets && \
    git apply /build/default-settings.patch && \
    composer install

FROM ${repository}/drupal:${tag}

COPY --from=composer --chown=nginx:nginx /var/www /var/www

COPY rootfs /