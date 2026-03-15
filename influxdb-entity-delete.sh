#!/bin/bash

_usage_short() {
    echo "Usage: ${0} -i INPUTFILE [-h]"
}

_usage() {
    echo "Options:"
    echo "-h Help, information about the program."
    echo "-i Mandatory. Path to the CSV input file produced by influxdb_entity_export.sh."
    echo ""
    echo "This script reads the export CSV, displays the data rows to the user,"
    echo "asks for confirmation, and then deletes each data point from InfluxDB"
    echo "using the exact timestamp and entity_id from the file."
    echo ""
    echo "The input CSV must have the header: timestamp,domain,entity_id,state"
    echo ""
    echo "Logfile is stored here: /srv/log/influxdb-entity-delete.log"
    echo ""
    echo "CAUTION: Deletion from InfluxDB is permanent and cannot be undone."
}

_wrong_options() {
    _usage_short
    exit 1
}

# Manage options.
options_number_mandatory=0
while getopts ":hi:" option; do
    case ${option} in
        h) # Help.
            _usage_short
            _usage
            exit 0
            ;;
        i) # Input file.
            arg=${OPTARG}
            if [ -f "${arg}" ]; then
                options_input_file="${arg}"
                options_number_mandatory=$((${options_number_mandatory}+1))
            else
                echo "Error: -i File not found: ${arg}"
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

# Check if we have all mandatory options.
if [ ${options_number_mandatory} -ne 1 ]; then
    echo "Error: Not all mandatory options given."
    _wrong_options
fi

# Load environment variables (mainly secrets).
if [ -f "/srv/.env" ]; then
    export $(cat "/srv/.env" | grep -v '#' | sed 's/\r$//' | awk '/=/ {print $1}' )
fi

# Variables.
container="ha-history-db"
base_dir="/srv"
docker_compose_file="${base_dir}/docker-compose.yml"
logfile="${base_dir}/log/influxdb-entity-delete.log"
logfile_tmp="${base_dir}/log/influxdb-entity-delete.tmp"
error_occured=0
error_message=""
warning_occured=0
warning_message=""
delete_count=0
delete_error_count=0
delete_warning_count=0
row_count=0

_initialize() {
    cd "${base_dir}"
    touch "${logfile}"

    echo ""
    echo "$(date +%Y%m%d_%H%M%S): Starting InfluxDB entity delete."
    echo "$(date +%Y%m%d_%H%M%S):   Input file: ${options_input_file}"
}

_preview() {
    # Count data rows, excluding empty rows and rows starting with #.
    total_rows=$(grep -v -E '^\s*$|^#' "${options_input_file}" | wc -l)
    #total_rows=$(( $(wc -l < "${options_input_file}") ))

    echo ""
    echo "====================================================================="
    echo " DATA TO BE DELETED FROM INFLUXDB"
    echo "====================================================================="
    echo " Input file : ${options_input_file}"
    echo " Total rows : ${total_rows}"
    echo "====================================================================="
    echo ""
    echo "CAUTION: The ${total_rows} datapoints will be permanently deleted from InfluxDB."
    echo "         This operation CANNOT be undone."
    echo "NOTE: Each row will take a few seconds to delete, so expect long time for larger amount of datapoints."
    echo ""
}

_confirm() {
    # Interactive confirmation — must be read from the terminal directly,
    # not from stdin, so that pipe usage does not accidentally bypass this.
    read -r -p "Type YES (uppercase) to confirm deletion, or anything else to abort: " user_input </dev/tty

    if [ "${user_input}" != "YES" ]; then
        echo ""
        echo "Aborted. No data was deleted."
        echo "$(date +%Y%m%d_%H%M%S): Delete aborted by user." >> "${logfile}"
        exit 0
    fi

    echo ""
    echo "Confirmed. Starting deletion..."
    echo "$(date +%Y%m%d_%H%M%S): User confirmed deletion." >> "${logfile}"
}

_delete() {
    echo "$(date +%Y%m%d_%H%M%S): Starting deletion of data points." >> "${logfile}" 2>&1
    echo "Starting deletion of data points."

    # InfluxDB 2.x delete API requires a time range per call. We target each
    # data point individually using a 1-nanosecond-wide window around its exact
    # RFC3339 timestamp, combined with an entity_id predicate, so only that
    # specific data point is removed.
    #
    # influx delete syntax used inside the container:
    #   influx delete --bucket BUCKET --org ORG \
    #     --start <RFC3339> --stop <RFC3339> \
    #     --predicate '_measurement="state" AND entity_id="<entity_id>"'

    # We expect rows with the following format (empty rows removed, and rows starting with # are also removed:
    # ,,0,2026-03-02T00:59:58.251112Z,2.61815000000001,sensor,balboa_spa_circulation_pump_heater_consumption_hour

    while IFS=',' read -r empty1 empty2 empty3 timestamp state domain entity_id; do
        # Strip carriage returns.
        timestamp=$(echo "${timestamp}" | tr -d '\r')
        state=$(echo "${state}" | tr -d '\r')
        domain=$(echo "${domain}" | tr -d '\r')
        entity_id=$(echo "${entity_id}" | tr -d '\r')
        row_count=$((row_count+1))

        # Validate that timestamp looks like an RFC3339 value.
        if [[ ! "${timestamp}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2} ]]; then
            warning_occured=1
            warning_message="skipped row with invalid timestamp"
            echo "$(date +%Y%m%d_%H%M%S): WARNING. Skipping row with invalid timestamp: '${timestamp}'" >> "${logfile}" 2>&1
            delete_warning_count=$((delete_warning_count+1))
            continue
        fi

        echo "$(date +%Y%m%d_%H%M%S):   Deleting: entity_id='${entity_id}'  timestamp='${timestamp}'" >> "${logfile}" 2>&1
        echo -ne "\rProcessing row ${row_count} of ${total_rows}..."

        RESULT=$(docker-compose -f "${docker_compose_file}" exec -T ${container} bash -c \
            "influx delete \
                --bucket \"${HA_HISTORY_DB_BUCKET}\" \
                --org \"${HA_HISTORY_DB_ORG}\" \
                --start \"${timestamp}\" \
                --stop \"${timestamp}\" \
                --predicate \"entity_id=\\\"${entity_id}\\\"\"")
        RESULT_CODE=$?

        if [ ${RESULT_CODE} -ne 0 ]; then
            warning_occured=1
            warning_message="one or more delete commands failed"
            echo "$(date +%Y%m%d_%H%M%S): WARNING. Delete failed for timestamp='${timestamp}' entity_id='${entity_id}'. Exit code: ${RESULT_CODE}. Result: ${RESULT}" >> "${logfile}" 2>&1
            delete_error_count=$((delete_error_count+1))
        else
            echo "$(date +%Y%m%d_%H%M%S):     Deleted OK." >> "${logfile}" 2>&1
            delete_count=$((delete_count+1))
        fi

    done < <(grep -v -E '^\s*$|^#' "${options_input_file}")

    echo "$(date +%Y%m%d_%H%M%S): Deletion complete. Deleted: ${delete_count}. Failed: ${delete_error_count}." >> "${logfile}" 2>&1
    echo ""
    echo "Deletion complete. Deleted: ${delete_count}. Failed: ${delete_error_count}. Warning: ${delete_warning_count}"
    echo "Note that influx delete does not indicate if the actual datapoint was removed, therefore verify always after delete with influxdb-entity-export.sh that datapoints are deleted."
    echo "See further information in logfile: ${logfile}"
}

_finalize() {
    if [ ${error_occured} -eq 0 ]; then
        if [ ${warning_occured} -eq 0 ]; then
            echo "$(date +%Y%m%d_%H%M%S): Finished InfluxDB entity delete. No error." >> "${logfile}"
            echo "Finished InfluxDB entity delete. No error."
        else
            echo "$(date +%Y%m%d_%H%M%S): Finished InfluxDB entity delete. Warning: ${warning_message}." >> "${logfile}"
            echo "Finished InfluxDB entity delete. Warning: ${warning_message}."
        fi

        tail -n10000 "${logfile}" > "${logfile_tmp}"
        rm "${logfile}"
        mv "${logfile_tmp}" "${logfile}"

        exit 0
    else
        echo "$(date +%Y%m%d_%H%M%S): Exited InfluxDB entity delete. ERROR: ${error_message}." >> "${logfile}"
        echo "Exited InfluxDB entity delete. ERROR: ${error_message}."

        tail -n10000 "${logfile}" > "${logfile_tmp}"
        rm "${logfile}"
        mv "${logfile_tmp}" "${logfile}"

        exit 1
    fi
}

# Main
# Note: _preview and _confirm write directly to the terminal (stdout/stderr)
# so the user can read and respond. Only _initialize, _delete and _finalize
# are fully logged.
_initialize >> "${logfile}" 2>&1
_preview
_confirm
_delete
_finalize
