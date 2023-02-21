#!/bin/bash

# Purpose:
# This script exports all data in InfluxDB for yesterday.
# The export is made to csv-files.
#
# Usage:
# ./influxdb-export-yesterday.sh

# Load environment variables (mainly secrets).
if [ -f "/srv/.env" ]; then
    export $(cat "/srv/.env" | grep -v '#' | sed 's/\r$//' | awk '/=/ {print $1}' )
fi

# Variables:
container="ha-history-db"
base_dir="/srv"
docker_compose_file="${base_dir}/docker-compose.yml"
logfile="${base_dir}/log/influxdb-export-yesterday.log"
logfile_tmp="${base_dir}/log/influxdb-export-yesterday.tmp"
export_year=$(date +%Y)
export_dir="${base_dir}/${container}/export/${export_year}/"
export_dir_tmp="${base_dir}/${container}/export/tmp"
flux_file="${export_dir_tmp}/flux.flux"
error_occured=0
error_message=""
warning_occured=0
warning_message=""
header_row=",result,table,_start,_stop,_time,_value,_field,_measurement,domain,entity_id"

# Get the yesterdays date.
date_export=$(date -d "yesterday" +%Y-%m-%d)

# Set name of export file.
export_filename="${export_dir}/influx-export-${date_export}.csv"

# Set the timestamps.
datetime_start="${date_export}T00:00:00.000000Z"
datetime_end="${date_export}T23:59:59.999999Z"

_initialize() {
    cd "${base_dir}"
    touch "${logfile}"

    echo ""
    echo "$(date +%Y%m%d_%H%M%S): Starting InfluxDB export."

    mkdir -p "${export_dir}"
    mkdir -p "${export_dir_tmp}"
}

_export() {
    echo "$(date +%Y%m%d_%H%M%S): Export of influxdb for date ${date_export} started."

    flux="from(bucket: \"${HA_HISTORY_DB_BUCKET}\") |> range(start: ${datetime_start}, stop: ${datetime_end})"
    echo "${flux}" > ${flux_file}

# http-api did not return the right header to be able to perform 'influx write'.
#    curl --request POST "http://localhost:8086/api/v2/query?org=${HA_HISTORY_DB_ORG}&bucket=${HA_HISTORY_DB_BUCKET=}" \
#         -H "Authorization: Token ${HA_HISTORY_DB_GRAFANA_TOKEN}" \
#         -H "Accept: application/csv" \
#         -H "Content-type: application/vnd.flux" \
#         -s -S \
#         -o ${export_filename} \
#         -d @${flux_file}
# Therefore we utilize command line instead.
    RESULT=$(docker-compose -f "${docker_compose_file}" exec -T ha-history-db bash -c "influx query -f /export/tmp/flux.flux -r > /export/tmp/export.csv")
    RESULT_CODE=$?
    if [ ${RESULT_CODE} -ne 0 ]; then
        error_occured=1
        error_message="influx export error"
        echo "$(date +%Y%m%d_%H%M%S): ERROR. ${error_message}. Exit code: ${RESULT_CODE}. Result: ${RESULT}"
    else
        cp ${export_dir_tmp}/export.csv ${export_filename}

        number_rows=$(wc -l < ${export_filename})
        echo "$(date +%Y%m%d_%H%M%S):   Export of influxdb for date ${date_export} performed. Number of rows: ${number_rows}"

        if [ ${number_rows} -gt 4 ]; then
            headers_found=$(cat ${export_filename} | grep "${header_row}" | wc -l | awk '{ print $1 }')
            if [ ${headers_found} -eq 0 ]; then
                error_occured=1
                error_message="influx query to csv"
                echo "$(date +%Y%m%d_%H%M%S): ERROR. No headers found in the export-file."
            fi
        else
            error_occured=1
            error_message="influx query to csv"
            echo "$(date +%Y%m%d_%H%M%S): ERROR. To few rows in the export-file, should be larger than 4."
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
            echo "$(date +%Y%m%d_%H%M%S):   Compress of backup performed."
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
_export >> "${logfile}" 2>&1
_compress >> "${logfile}" 2>&1
_finalize >> "${logfile}" 2>&1
