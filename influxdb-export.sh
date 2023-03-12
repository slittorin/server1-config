#!/bin/bash

_usage_short() {
    echo "Usage: ${0} -f FROMDATE -t TODATE [-h]"
}

_usage() {
    echo "Options:"
    echo "-h Help, information about the program."
    echo "-f Mandatory. From date, in format YYYYMMDD."
    echo "-t Mandatory. To date, in format YYYYMMDD."
    echo ""
    echo "For the given from and to dates, this script exports csv-files from InfluxDB."
    echo ""
    echo "Export-files will be saved in directory /srv/ha-history-db/export/YYYY/"
    echo "Export-files will be named 'influx-export-YYYY-MM-DD.csv"
    echo "Logfile is stored here: /srv/log/influxdb-export.log"
    echo ""
    echo "Note that export-files are overwritten."
}

_wrong_options() {
    _usage_short
    exit 1
}

# Manage options.
options_number_mandatory=0
while getopts ":hf:t:" option; do
    case ${option} in
        h) # Help.
            _usage_short
            _usage
            exit 0
            ;;
        f) # From date.
            arg=${OPTARG}
            if [[ ${arg} =~ ^[0-9]{4}[0-9]{2}[0-9]{2}$ ]]; then
                options_date_from=${arg}
                options_number_mandatory=$((${options_number_mandatory}+1))
            else
                echo "Error: -f Wrong date format. Format must be YYYYMMDD."
                _wrong_options
            fi
            ;;
        t) # To date.
            arg=${OPTARG}
            if [[ ${arg} =~ ^[0-9]{4}[0-9]{2}[0-9]{2}$ ]]; then
                options_date_to=${arg}
                options_number_mandatory=$((${options_number_mandatory}+1))
            else
                echo "Error: -f Wrong date format. Format must be YYYYMMDD."
                _wrong_options
            fi
            ;;
        :) # If expected argument omitted:
            echo "Error: -${OPTARG} requires an argument."
            _wrong_options
            ;;
        \?) # Invalid option
            echo "Error: Invalid option"
            _wrong_options
            ;;
    esac
done

# If no options.
if [ ${OPTIND} -eq 1 ]; then
    echo "Error: No options given."
    _wrong_options
fi

# Check if we have all mandatory options
if [ ${options_number_mandatory} -ne 2 ]; then
    echo "Error: Not all mandatory options given."
    _wrong_options
fi

# Check if from and to dates are in the right order.
options_date_from_num=$(date -d ${options_date_from} +%Y%m%d)
options_date_to_num=$(date -d ${options_date_to} +%Y%m%d)
if [[ ${options_date_from_num} -gt ${options_date_to_num} ]]; then
    echo "Error: To date must be newer than from date."
    _wrong_options
fi

# Load environment variables (mainly secrets).
if [ -f "/srv/.env" ]; then
    export $(cat "/srv/.env" | grep -v '#' | sed 's/\r$//' | awk '/=/ {print $1}' )
fi

# Variables:
container="ha-history-db"
base_dir="/srv"
docker_compose_file="${base_dir}/docker-compose.yml"
logfile="${base_dir}/log/influxdb-export.log"
logfile_tmp="${base_dir}/log/influxdb-export.tmp"
export_dir_tmp="${base_dir}/${container}/export/tmp"
error_occured=0
error_message=""
warning_occured=0
warning_message=""
header_row=",result,table,_start,_stop,_time,_value,_field,_measurement,domain,entity_id"

_initialize() {
    cd "${base_dir}"
    touch "${logfile}"

    echo ""
    echo "$(date +%Y%m%d_%H%M%S): Starting InfluxDB export."

    mkdir -p "${export_dir_tmp}"
}

_iterate() {
    echo "$(date +%Y%m%d_%H%M%S): Starting to iterate through dates ${options_date_from} to ${options_date_to}."

    iterate_start=$(date -d ${options_date_from} +%Y%m%d)
    iterate_current=${iterate_start}
    iterate_end=$(date -d ${options_date_to} +%Y%m%d)
    while [[ ${iterate_current} -le ${iterate_end} ]]
    do
        date_export=$(date -d ${iterate_current} +%Y-%m-%d)

        # Set variables dependent on date.
        export_year=$(date -d ${iterate_current} +%Y)
        export_dir="${base_dir}/${container}/export/${export_year}/"
        flux_file="${export_dir_tmp}/flux.flux"

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
    echo "$(date +%Y%m%d_%H%M%S): Done iterate through dates ${options_date_from} to ${options_date_to}."
}

_export() {
    echo "$(date +%Y%m%d_%H%M%S):   Export of influxdb for date ${date_export} started."

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
    RESULT=$(docker-compose -f "${docker_compose_file}" exec -T ${container} bash -c "influx query -f /export/tmp/flux.flux -r > /export/tmp/export.csv")
    RESULT_CODE=$?
    if [ ${RESULT_CODE} -ne 0 ]; then
        warning_occured=1
        warning_message="influx export error"
        echo "$(date +%Y%m%d_%H%M%S): WARNING. ${error_message}. Exit code: ${RESULT_CODE}. Result: ${RESULT}"
    else
        cp ${export_dir_tmp}/export.csv ${export_filename}

        number_rows=$(wc -l < ${export_filename})
        echo "$(date +%Y%m%d_%H%M%S):     Export of influxdb for date ${date_export} performed. Number of rows: ${number_rows}"

        if [ ${number_rows} -gt 4 ]; then
            headers_found=$(cat ${export_filename} | grep "${header_row}" | wc -l | awk '{ print $1 }')
            if [ ${headers_found} -eq 0 ]; then
                warning_occured=1
                warning_message="influx query to csv"
                echo "$(date +%Y%m%d_%H%M%S): WARNING. No headers found in the export-file."
            fi
        else
            warning_occured=1
            warning_message="influx query to csv"
            echo "$(date +%Y%m%d_%H%M%S): WARNING. To few rows in the export-file, should be larger than 4."
        fi
    fi
}

_compress() {
    if [ ${error_occured} -eq 0 ]; then    	
        echo "$(date +%Y%m%d_%H%M%S):     Compress of backup-file started."
	RESULT=`gzip -f ${export_filename}`
	RESULT_CODE=$?
	if [ ${RESULT_CODE} -ne 0 ]; then
	    error_occured=1
	    error_message="gzip command error when compressing"
	    echo "$(date +%Y%m%d_%H%M%S): ERROR. ${error_message}. Exit code: ${RESULT_CODE}: ${RESULT}"
	else
            echo "$(date +%Y%m%d_%H%M%S):     Compress of backup performed."
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
_finalize >> "${logfile}" 2>&1
