#!/bin/bash

# Purpose:
# This script backs up full influx according to:
# - Daily snapshots, keep for 7 days (monday through saturday).
# - Weekly snapshots (sunday), keep for 8 weeks.
#
# Usage:
# ./influxdb-backup.sh

# Load environment variables (mainly secrets).
if [ -f "/srv/.env" ]; then
    export $(cat "/srv/.env" | grep -v '#' | sed 's/\r$//' | awk '/=/ {print $1}' )
fi

# Variables:
container="ha-history-db"
base_dir="/srv"
docker_compose_file="${base_dir}/docker-compose.yml"
logfile="${base_dir}/log/influxdb-backup.log"
logfile_tmp="${base_dir}/log/influxdb-backup.tmp"
backup_dir="${base_dir}/${container}/backup/backup.tmp"
backup_container_dir="/backup/backup.tmp"
backup_dest="${base_dir}/${container}/backup/"
error_occured=0
error_message=""

# Set name and retention according day of week.
# Default is daily backup.
day_of_week=$(date +%u)
backup_pre="influxdb-backup-daily"
retention_days=7
if [[ "$day_of_week" == 7 ]]; then # On sundays.
    backup_pre="influxdb-backup-weekly"
    retention_days=57 # 8 weeks + 1 day.
fi
backup_filename="${backup_pre}-$(date +%Y%m%d_%H%M%S)"

_initialize() {
    cd "${base_dir}"
    touch "${logfile}"

    echo ""
    echo "$(date +%Y%m%d_%H%M%S): Starting InfluxDB backup."

    rm -r "${backup_dir}/"
    mkdir "${backup_dir}"
}

_backup() {
    echo "$(date +%Y%m%d_%H%M%S): Backup of influxdb started."
    RESULT=`docker-compose -f "${docker_compose_file}" exec -T "${container}" influx backup "${backup_container_dir}" -t "${HA_HISTORY_DB_ROOT_TOKEN}"`
    RESULT_CODE=$?
    if [ ${RESULT_CODE} -ne 0 ]; then
       error_occured=1
       error_message="influx backup error"
       echo "$(date +%Y%m%d_%H%M%S): ERROR. ${error_message}. Exit code: ${RESULT_CODE}: ${RESULT}"
    else
       echo "$(date +%Y%m%d_%H%M%S): Backup of influxdb performed."
    fi
}

_compress() {
    if [ ${error_occured} -eq 0 ]; then    	
	   echo "$(date +%Y%m%d_%H%M%S): Compress of backup started."
	   tar_file="${backup_dest}${backup_filename}.tar"
	   RESULT=`tar -cvf "${tar_file}" "${backup_dir}/"`
	   RESULT_CODE=$?
	   if [ ${RESULT_CODE} -ne 0 ]; then
	      error_occured=1
	      error_message="tar command error when compressing"
	      echo "$(date +%Y%m%d_%H%M%S): ERROR. ${error_message}. Exit code: ${RESULT_CODE}: ${RESULT}"
	   else
         echo "$(date +%Y%m%d_%H%M%S): Compress of backup performed."
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
         echo "$(date +%Y%m%d_%H%M%S): Retention of files performed to ${retention_days} days for filenames starting with ${backup_pre}-"
	   fi
	fi
}

_finalize() {
    if [ ${error_occured} -eq 0 ]; then
       echo "$(date +%Y%m%d_%H%M%S): Finished InfluxDB backup. No error."

       tail -n10000 ${logfile} > ${logfile_tmp}
       rm ${logfile}
       mv ${logfile_tmp} ${logfile}

       exit 0
    else
       echo "$(date +%Y%m%d_%H%M%S): Exited InfluxDB backup. ERROR: ${error_message}."

       tail -n10000 ${logfile} > ${logfile_tmp}
       rm ${logfile}
       mv ${logfile_tmp} ${logfile}

       exit 1
    fi
}

# Main
_initialize >> "${logfile}" 2>&1
_backup >> "${logfile}" 2>&1
_compress >> "${logfile}" 2>&1
_cleanup >> "${logfile}" 2>&1
_finalize >> "${logfile}" 2>&1
