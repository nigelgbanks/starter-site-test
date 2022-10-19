#!/usr/bin/with-contenv bash
# shellcheck shell=bash
set -e

# shellcheck disable=SC1091
source /etc/islandora/utilities.sh

readonly SITE="default"
readonly QUEUES=(
  islandora-connector-fits
  islandora-connector-homarus
  islandora-connector-houdini
  islandora-connector-ocr
)

function drush {
  /usr/local/bin/drush --root=/var/www/drupal --uri="${DRUPAL_DRUSH_URI}" "$@"
}

function jolokia {
  local type="${1}"
  local queue="${2}"
  local action="${3}"
  # @todo use environment variables?
  local url="http://${DRUPAL_DEFAULT_BROKER_HOST}:8161/api/jolokia/${type}/org.apache.activemq:type=Broker,brokerName=localhost,destinationType=Queue,destinationName=${queue}"
  if [ "$action" != "" ]; then
    url="${url}/$action"
  fi
  # @todo fetch from environment variable.
  curl -u "admin:${ACTIVEMQ_WEB_ADMIN_PASSWORD}" "${url}"
}

function pause_queues {
  for queue in "${QUEUES[@]}"; do
    jolokia "exec" "${queue}" "pause" &
  done
  wait
}

function resume_queues {
  for queue in "${QUEUES[@]}"; do
    jolokia "exec" "${queue}" "resume" &
  done
  wait
}

function purge_queues {
  for queue in "${QUEUES[@]}"; do
    jolokia "exec" "${queue}" "purge" &
  done
  wait
}

function wait_for_dequeue {
  local queue_size=-1
  local continue_waiting=1
  while [ "${continue_waiting}" -ne 0 ]; do
    continue_waiting=0
    for queue in "${QUEUES[@]}"; do
      queue_size=$(jolokia "read" "${queue}" | jq .value.QueueSize) || exit $?
      if [ "${queue_size}" -ne 0 ]; then
        continue_waiting=1
      fi
    done
    sleep 3
  done
}

function mysql_count_query {
    cat <<- EOF
SELECT COUNT(DISTINCT table_name)
FROM information_schema.columns
WHERE table_schema = '${DRUPAL_DEFAULT_DB_NAME}';
EOF
}

# Check the number of tables to determine if it has already been installed.
function installed {
  local count
  count=$(execute-sql-file.sh <(mysql_count_query) -- -N 2>/dev/null) || exit $?
  [[ $count -ne 0 ]]
}

function import {
  # Make sure the uuid matches what is stored in content-sync, clear caches.
  # Set the created/modified date to 1970 to allow it to be updated.
  drush sql:query "UPDATE users SET uuid='bd530a2b-ec6c-4e98-8b66-2621c688440b' WHERE uid=0"
  drush sql:query "UPDATE users SET uuid='2b939a79-0f98-444d-8de6-435d40eefbd0' WHERE uid=1"
  drush sql:query 'update users_field_data set created=1, changed=1 where uid=0'
  drush sql:query 'update users_field_data set created=1, changed=1  where uid=1'

  # Due to: https://www.drupal.org/project/content_sync/issues/3134102
  # Rebuild content-sync snapshot.
  drush sql:query "TRUNCATE cs_db_snapshot"
  drush sql:query "TRUNCATE cs_logs"
  drush cr
  drush php:eval "\Drupal::service('content_sync.snaphoshot')->snapshot(); drush_backend_batch_process();"

  # Pause queue consumption during import.
  pause_queues

  # Users must exists before all else.
  drush content-sync:import -y --entity-types=user
  drush content-sync:import -y --entity-types=taxonomy_term
  drush content-sync:import -y --entity-types=node
  drush content-sync:import -y --entity-types=file,media
  drush content-sync:import -y --entity-types=group,group_content
  drush content-sync:import -y --entity-types=menu_link_content
  drush pathauto:aliases-generate all all

  # Overwrite the password from content_sync with the one provided by the environment.
  drush user:password admin "${DRUPAL_DEFAULT_ACCOUNT_PASSWORD}"

  # Files already exist clear the brokers to prevent generating derivatives again.
  purge_queues

  # Resume consumption of the queues.
  resume_queues

  # Add check to wait for queue's to empty
  wait_for_dequeue &

  # Add check to wait for solr index to complete.
  drush search-api:index &

  wait
}

function install {
  create_database "${SITE}"
  install_site "${SITE}"
}

function main() {
  if installed; then
    echo "Already Installed"
  else
    install
    # Must add fedoraadmin role to admin to be able to write to Fedora.
    drush user:role:add fedoraadmin admin
    # Import taxonomy terms.
    drush migrate:import --userid=1 islandora_tags,islandora_defaults_tags
    # Unused database backends.
    drush pm:uninstall pgsql sqlite
  fi
}
main
