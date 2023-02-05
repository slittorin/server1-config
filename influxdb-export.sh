#!/bin/bash

# Purpose:
# This script exports all data in InfluxDB for given date interval.
# The export is made to csv-files.
# Note that files/dates are overwritten.
# Note also that the variables for from and to-date must be set below.
#
# Usage:
# ./influxdb-export.sh

# Load environment variables (mainly secrets).
if [ -f "/srv/.env" ]; then
    export $(cat "/srv/.env" | grep -v '#' | sed 's/\r$//' | awk '/=/ {print $1}' )
fi

# Variables:
container="ha-history-db"
base_dir="/srv"
logfile="${base_dir}/log/influxdb-export.log"
logfile_tmp="${base_dir}/log/influxdb-export.tmp"
error_occured=0
error_message=""
warning_occured=0
warning_message=""

date_from="2022-02-11"
date_to="2023-02-02"

# Get the yesterdays date.
date_yesterday=$(date -d "yesterday" +%Y-%m-%d)

# Set name of export file.
export_filename="${export_dir}/influx-export-${date_yesterday}.csv"

# Set the timestamps.
datetime_start="${date_yesterday}T00:00:00.000000Z"
datetime_end="${date_yesterday}T23:59:59.999999Z"

_initialize() {
    cd "${base_dir}"
    touch "${logfile}"

    echo ""
    echo "$(date +%Y%m%d_%H%M%S): Starting InfluxDB export."
}

_iterate() {
    echo "$(date +%Y%m%d_%H%M%S): Starting to iterate through dates ${date_from} to ${date_to}."

    iterate_start=$(date -d ${date_from} +%Y%m%d)
    iterate_current=${iterate_start}
    iterate_end=$(date -d ${date_to} +%Y%m%d)
    while [[ ${iterate_current} -le ${iterate_end} ]]
    do
        date_export=$(date -d ${iterate_current} +%Y-%m-%d)

        # Set variables dependent on date.
        export_year=$(date -d ${iterate_current} +%Y)
        export_dir="${base_dir}/${container}/export/${export_year}/"
        flux_file="${export_dir}/flux.flux"

        # Create dir and file.
        mkdir -p "${export_dir}"

        # Set name of export file.
        export_filename="${export_dir}/influx-export-${date_export}.csv"

        # Set the timestamps.
        datetime_start="${date_export}T00:00:00.000000Z"
        datetime_end="${date_export}T23:59:59.999999Z"

        # For each date, we export and compress.
        _export >> "${logfile}" 2>&1
        _compress >> "${logfile}" 2>&1

        iterate_current=$(date -d ${iterate_current}+1day +%Y%m%d)
    done
    echo "$(date +%Y%m%d_%H%M%S): Done iterate through dates ${date_from} to ${date_to}."
}

_export() {
    echo "$(date +%Y%m%d_%H%M%S): Export of influxdb for date ${date_export} started."

    flux="from(bucket: \"${HA_HISTORY_DB_BUCKET}\") |> range(start: ${datetime_start}, stop: ${datetime_end}) |> filter(fn: (r) => r[\"_field\"] == \"value\")"
    echo "${flux}" > ${flux_file}

    curl --request POST "http://localhost:8086/api/v2/query?org=${HA_HISTORY_DB_ORG}&bucket=${HA_HISTORY_DB_BUCKET=}" \
         -H "Authorization: Token ${HA_HISTORY_DB_GRAFANA_TOKEN}" \
         -H "Accept: application/csv" \
         -H "Content-type: application/vnd.flux" \
         -s -S \
         -o ${export_filename} \
         -d @${flux_file}
    RESULT_CODE=$?
    if [ ${RESULT_CODE} -ne 0 ]; then
        warning_occured=1
        warning_message="influx export error"
        echo "$(date +%Y%m%d_%H%M%S): WARNING. ${error_message}. Exit code: ${RESULT_CODE}"
    else
        number_rows=$(wc -l < ${export_filename})
        echo "$(date +%Y%m%d_%H%M%S): Export of influxdb for date ${date_export} performed. Number of rows: ${number_rows}"

        # Check if head of file is correct.
        head_of_file=$(head -1 ${export_filename} | sed 's/\r$//' | sed 's/\n$//')
        if [ "${head_of_file}" == ",result,table,_start,_stop,_time,_value,_field,_measurement,domain,entity_id" ]; then
            echo "$(date +%Y%m%d_%H%M%S): Header of file is correct."

            # File should be at least 1 MB large.
            file_size=$(wc -c < ${export_filename})
            if [ ${file_size} -ge 1048576 ]; then
                echo "$(date +%Y%m%d_%H%M%S): File size is larger than or equal to 1 MB."
            else
                warning_occured=1
                warning_message="influx export warning, size should be larger than 1 MB"
                echo "$(date +%Y%m%d_%H%M%S): WARNING. File size is lower than 1 MB."
            fi
        else
            warning_occured=1
            warning_message="influx export error"
            echo "$(date +%Y%m%d_%H%M%S): WARNING. Header of file is not correct."
        fi
    fi
}

_compress() {
    if [ ${error_occured} -eq 0 ]; then    	
        echo "$(date +%Y%m%d_%H%M%S): Compress of backup started."
	RESULT=`gzip -f ${export_filename}`
	RESULT_CODE=$?
	if [ ${RESULT_CODE} -ne 0 ]; then
	    error_occured=1
	    error_message="gzip command error when compressing"
	    echo "$(date +%Y%m%d_%H%M%S): ERROR. ${error_message}. Exit code: ${RESULT_CODE}: ${RESULT}"
	else
            echo "$(date +%Y%m%d_%H%M%S): Compress of backup performed."
	fi
    fi
}

_finalize() {
    if [ ${error_occured} -eq 0 ]; then
       if [ ${warning_occured} -eq 0 ]; then
          echo "$(date +%Y%m%d_%H%M%S): Finished InfluxDB export. No error."
       else
          echo "$(date +%Y%m%d_%H%M%S): Finished InfluxDB export. Warning: ${warning_message}."
       fi

       tail -n10000 ${logfile} > ${logfile_tmp}
       rm ${logfile}
       mv ${logfile_tmp} ${logfile}

       exit 0
    else
       echo "$(date +%Y%m%d_%H%M%S): Exited InfluxDB export. ERROR: ${error_message}."

       tail -n10000 ${logfile} > ${logfile_tmp}
       rm ${logfile}
       mv ${logfile_tmp} ${logfile}

       exit 1
    fi
}

# Main
_initialize >> "${logfile}" 2>&1
_iterate >> "${logfile}" 2>&1
#_export >> "${logfile}" 2>&1
#_compress >> "${logfile}" 2>&1
_finalize >> "${logfile}" 2>&1
