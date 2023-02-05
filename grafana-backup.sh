#!/bin/bash

# This script backs up full Grafana according to:
# - Daily snapshots, keep for 7 days (monday through saturday).
# - Weekly snapshots (sunday), keep for 8 weeks.
#
# Usage:
# ./grafana-backup.sh

# Load environment variables (mainly secrets).
if [ -f "/srv/.env" ]; then
    export $(cat "/srv/.env" | grep -v '#' | sed 's/\r$//' | awk '/=/ {print $1}' )
fi

# Variables:
# -----------------------------------------------------------------
container="ha-grafana"
base_dir="/srv"
docker_compose_file="${base_dir}/docker-compose.yml"
logfile="${base_dir}/log/grafana-backup.log"
logfile_tmp="${base_dir}/log/grafana-backup.tmp"
backup_dir="${base_dir}/${container}/backup/backup.tmp"
backup_container_dir="/backup/backup.tmp"
backup_dest="${base_dir}/${container}/backup/"
error_occured=0
error_message=""

# Set name and retention according day of week.
# Default is daily backup.
# -----------------------------------------------------------------
day_of_week=$(date +%u)
backup_pre="grafana-backup-daily"
retention_days=7
if [[ "$day_of_week" == 7 ]]; then # On sundays.
    backup_pre="grafana-backup-weekly"
    retention_days=57 # 8 weeks + 1 day.
fi
backup_filename="${backup_pre}-$(date +%Y%m%d_%H%M%S)"

_initialize() {
    cd "${base_dir}"
    touch "${logfile}"

    echo ""
    echo "$(date +%Y%m%d_%H%M%S): Starting Grafana Backup."

    rm -r "${backup_dir}/"
    mkdir "${backup_dir}"
}

_backup() {
    echo "$(date +%Y%m%d_%H%M%S): Copy of grafana.db started."
    RESULT=`docker cp "${container}:/var/lib/grafana/grafana.db" "${backup_dir}"`
    RESULT_CODE=$?
    if [ ${RESULT_CODE} -ne 0 ]; then
       error_occured=1
       error_message="docker cp error"
       echo "$(date +%Y%m%d_%H%M%S): ERROR. ${error_message}. Exit code: ${RESULT_CODE}: ${RESULT}"
    else
       echo "$(date +%Y%m%d_%H%M%S): Copy of grafana.db performed."
    fi

    if [ ${error_occured} -eq 0 ]; then
       echo "$(date +%Y%m%d_%H%M%S): Compression of backup started."
       tar_file="${backup_dest}${backup_filename}.tar"
       RESULT=`tar -cvf "${tar_file}" "${backup_dir}/"`
       RESULT_CODE=$?
       if [ ${RESULT_CODE} -ne 0 ]; then
          error_occured=1
          error_message="tar command error when compressing"
          echo "$(date +%Y%m%d_%H%M%S): ERROR. ${error_message}. Exit code: ${RESULT_CODE}: ${RESULT}"
       else
          echo "$(date +%Y%m%d_%H%M%S): Compression of backup performed to: ${tar_file}"
       fi
   fi
}

_cleanup() {
    if [ ${error_occured} -eq 0 ]; then
       echo "$(date +%Y%m%d_%H%M%S): Retention of files started."
       RESULT=`find "${backup_dest}" -name "${backup_pre}-*" -mtime +${retention_days} -delete`
       RESULT_CODE=$?
       if [ ${RESULT_CODE} -ne 0 ]; then
          error_occured=1
          error_message="Error when removing files (retention)"
          echo "$(date +%Y%m%d_%H%M%S): ERROR. ${error_message}. Exit code: ${RESULT_CODE}: ${RESULT}"
       else
          echo "$(date +%Y%m%d_%H%M%S): Retention of files performed to ${retention_days} days, for filenames starting with ${backup_pre}-"
       fi
    fi
}

_finalize() {
    if [ ${error_occured} -eq 0 ]; then
       echo "$(date +%Y%m%d_%H%M%S): Finished Grafana backup. No error."

       tail -n10000 ${logfile} > ${logfile_tmp}
       rm ${logfile}
       mv ${logfile_tmp} ${logfile}

       exit 0
    else
       echo "$(date +%Y%m%d_%H%M%S): Exited Grafana backup. ERROR: ${error_message}."

       tail -n10000 ${logfile} > ${logfile_tmp}
       rm ${logfile}
       mv ${logfile_tmp} ${logfile}

       exit 1
    fi
}

# Main
_initialize >> "${logfile}" 2>&1
_backup >> "${logfile}" 2>&1
_cleanup >> "${logfile}" 2>&1
_finalize >> "${logfile}" 2>&1
