#!/bin/bash

_usage_short() {
    echo "Usage: ${0} -f FROMDATE -t TODATE -e ENTITYID [-h]"
}

_usage() {
    echo "Options:"
    echo "-h Help, information about the program."
    echo "-f Mandatory. From date, in format YYYYMMDD."
    echo "-t Mandatory. To date, in format YYYYMMDD."
    echo "-e Mandatory. Entity_id."
    echo ""
    echo "For the given from and to dates, this script imports csv-files from InfluxDB for existing entity_id."
    echo ""
    echo "Files will be retrieved in directory /srv/ha-history-db/import/ENTITYID/"
    echo "Files must be named 'influx-import-ENTITYID-YYYY-MM-DD.csv"
    echo "Logfile is stored here: /srv/log/influxdb-import.log"
}

_wrong_options() {
    _usage_short
    exit 1
}

# Manage options.
options_number_mandatory=0
while getopts ":hf:t:e:" option; do
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
        e) # Entity_id.
            arg=${OPTARG}
            options_entity_id=${arg}
            options_number_mandatory=$((${options_number_mandatory}+1))
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
if [ ${options_number_mandatory} -ne 3 ]; then
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
logfile="${base_dir}/log/influxdb-import.log"
logfile_tmp="${base_dir}/log/influxdb-import.tmp"
import_dir="${base_dir}/${container}/import"
import_tmp_dir="${base_dir}/${container}/import/tmp"
import_entity_dir="${base_dir}/${container}/import/${options_entity_id}"
error_occured=0
warning_message=""
debug=0						#  No debug = 0, debug = 1, more debug info = 2

_initialize() {
    cd "${base_dir}"
    touch "${logfile}"

    echo ""
    echo "$(date +%Y%m%d_%H%M%S): Starting InfluxDB convert to hourly."

    echo "Options:"
    echo "Date from: ${options_date_from}"
    echo "Date to: ${options_date_to}"
    echo "Entity_id: ${options_entity_id}"
}

_iterate() {
    echo "$(date +%Y%m%d_%H%M%S): Starting to iterate through dates ${options_date_from} to ${options_date_to}."

    iterate_start=$(date -d ${options_date_from} +%Y%m%d)
    iterate_current=${iterate_start}
    iterate_end=$(date -d ${options_date_to} +%Y%m%d)
    while [[ ${iterate_current} -le ${iterate_end} ]]
    do
        date_import=$(date -d ${iterate_current} +%Y-%m-%d)

        # Set variables dependent on date.
        import_file="${import_entity_dir}/influx-import-${options_entity_id}-${date_import}.csv"

        # Reset errors.
        error_occured=0
        error_message=""
        warning_occured=0
        warning_message=""

        # For each date, we import.
        echo "$(date +%Y%m%d_%H%M%S): Performing for ${date_import}."
        if [ -f "${import_file}" ]; then
            _import >> "${logfile}" 2>&1

            if [ ${error_occured} -ne 0 ]; then
                echo "$(date +%Y%m%d_%H%M%S): Error occured. No import for date ${date_import}."
            fi
        else
            echo "$(date +%Y%m%d_%H%M%S):   No import-file existed for ${date_import}."
        fi

        iterate_current=$(date -d ${iterate_current}+1day +%Y%m%d)
    done
    echo "$(date +%Y%m%d_%H%M%S): Done iterate through dates ${options_date_from} to ${options_date_to}."
}

_import() {
    echo "$(date +%Y%m%d_%H%M%S):   Import of influxdb for date ${date_import} started."

    rm -f "${import_tmp_dir}/import.csv"
    cp "${import_file}" "${import_tmp_dir}/import.csv"

    # RESULT=$(docker-compose -f "${docker_compose_file}" exec -T ${container} bash -c "influx write -b ${HA_HISTORY_DB_BUCKET} --format csv --skipRowOnError -f /import/tmp/import.csv")
    # 'Influx write' seems to require an interactive TTY, and since docker-compose does not give that through command line (if you do not add 'tty: true' to compose-file.
    # https://github.com/influxdata/influx-cli/issues/270
    # Therefore we run this through docker command instead with -ti as parameters.
    RESULT=$(docker exec -ti ${container} bash -c "influx write -b ${HA_HISTORY_DB_BUCKET} --debug --format csv --skipRowOnError -f /import/tmp/import.csv")
    RESULT_CODE=$?
    if [ ${RESULT_CODE} -ne 0 ]; then
        error_occured=1
        error_message="influx import error"
        echo "$(date +%Y%m%d_%H%M%S): ERROR. ${error_message}. Exit code: ${RESULT_CODE}. Error: ${RESULT}"
    else
        echo "$(date +%Y%m%d_%H%M%S):     Import of influxdb for date ${date_import} performed."
    fi

}

_finalize() {
    if [ ${error_occured} -eq 0 ]; then
       echo "$(date +%Y%m%d_%H%M%S): Finished InfluxDB convert to hourly. No last error."

       tail -n50000 ${logfile} > ${logfile_tmp}
       rm ${logfile}
       mv ${logfile_tmp} ${logfile}

       exit 0
    else
       echo "$(date +%Y%m%d_%H%M%S): Exited InfluxDB convert to hourly. ERROR: ${error_message}."

       tail -n50000 ${logfile} > ${logfile_tmp}
       rm ${logfile}
       mv ${logfile_tmp} ${logfile}

       exit 1
    fi
}

# Main
_initialize >> "${logfile}" 2>&1
_iterate >> "${logfile}" 2>&1
_finalize >> "${logfile}" 2>&1
