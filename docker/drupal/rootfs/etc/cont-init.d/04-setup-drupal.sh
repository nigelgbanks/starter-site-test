#!/usr/bin/with-contenv bash
# shellcheck shell=bash
set -e

# shellcheck disable=SC1091
source /etc/islandora/utilities.sh

function setup() {
    local site drupal_root subdir site_directory public_files_directory private_files_directory twig_cache_directory default_settings site
    site="${1}"; shift
    drupal_root=/var/www/drupal/web
    subdir=$(drupal_site_env "${site}" "SUBDIR")
    site_directory="${drupal_root}/sites/${subdir}"
    public_files_directory="${site_directory}/files"
    private_files_directory="/var/www/drupal/private"
    twig_cache_directory="${private_files_directory}/php"
    default_settings="${drupal_root}/sites/default/default.settings.php"

    # Ensure the files directories are writable by nginx, as when it is a new volume it is owned by root.
    mkdir -p "${site_directory}" "${public_files_directory}" "${private_files_directory}" "${twig_cache_directory}"
    chown nginx:nginx "${site_directory}" "${public_files_directory}" "${private_files_directory}" "${twig_cache_directory}"
    chmod ug+rw "${site_directory}" "${public_files_directory}" "${private_files_directory}" "${twig_cache_directory}"

    # Create settings.php if it does not exists, required to install site.
    if [[ ! -f "${site_directory}/settings.php" ]]; then
        s6-setuidgid nginx cp "${default_settings}" "${site_directory}/settings.php"
    fi
}

function main() {
    # Make sure the default drush cache directory exists and is writeable.
    mkdir -p /tmp/drush-/cache
    chmod a+rwx /tmp/drush-/cache
    setup default
}
main
