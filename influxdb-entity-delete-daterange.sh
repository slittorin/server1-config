#!/bin/bash

_usage_short() {
    echo "Usage: ${0} -e ENTITY_ID -f FROMDATE -t TODATE [-h]"
}

_usage() {
    echo "Options:"
    echo "-h Help, information about the program."
    echo "-e Mandatory. Entity ID to delete, e.g. sensor.my_temperature."
    echo "-f Mandatory. From date, in format YYYYMMDD."
    echo "-t Mandatory. To date, in format YYYYMMDD."
    echo ""
    echo "For the given entity_id and date range, this script deletes ALL matching"
    echo "data points from InfluxDB in a single delete operation."
    echo ""
    echo "The predicate used is: entity_id=\"<entity_id>\""
    echo "The time range used is: FROMDATE 00:00:00.000000Z to TODATE 23:59:59.999999Z"
    echo ""
    echo "CAUTION: Deletion from InfluxDB is permanent and cannot be undone."
    echo ""
    echo "Logfile is stored here: /srv/log/influxdb-entity-delete-timerange.log"
    echo ""
    echo "Tip: Before deleting, run influxd-entity-export.sh first to verify"
    echo "     exactly which data points will be removed."
}

_wrong_options() {
    _usage_short
    exit 1
}

# Manage options.
options_number_mandatory=0
while getopts ":he:f:t:" option; do
    case ${option} in
        h) # Help.
            _usage_short
            _usage
            exit 0
            ;;
        e) # Entity ID.
            arg=${OPTARG}
            if [[ ${arg} =~ ^[a-zA-Z0-9_]+\.[a-zA-Z0-9_]+$ ]]; then
                options_entity_id=${arg}
                options_number_mandatory=$((${options_number_mandatory}+1))
            else
                echo "Error: -e Invalid entity_id format. Expected format: domain.entity, e.g. sensor.my_temperature."
                _wrong_options
            fi
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
                echo "Error: -t Wrong date format. Format must be YYYYMMDD."
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
if [ ${options_number_mandatory} -ne 3 ]; then
    echo "Error: Not all mandatory options given."
    _wrong_options
fi

# Check if from and to dates are in the right order.
options_date_from_num=$(date -d ${options_date_from} +%Y%m%d)
options_date_to_num=$(date -d ${options_date_to} +%Y%m%d)
if [[ ${options_date_from_num} -gt ${options_date_to_num} ]]; then
    echo "Error: To date must be newer than or equal to from date."
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
logfile="${base_dir}/log/influxdb-entity-delete-daterange.log"
logfile_tmp="${base_dir}/log/influxdb-entity-delete-daterange.tmp"
# Derive the bare entity_id (without domain prefix) as stored in InfluxDB.
# HA stores entity_id as e.g. "circulation_pump" (without domain) in some setups,
# or as "sensor.circulation_pump" in others — align this with how your export script
# matched: try both forms via the predicate below.
options_entity_id_bare="${options_entity_id#*.}"
datetime_start="$(date -d ${options_date_from} +%Y-%m-%d)T00:00:00.000000Z"
datetime_end="$(date -d ${options_date_to} +%Y-%m-%d)T23:59:59.999999Z"
error_occured=0
error_message=""

_initialize() {
    cd "${base_dir}"
    touch "${logfile}"

    echo ""
    echo "$(date +%Y%m%d_%H%M%S): Starting InfluxDB entity range-delete."
    echo "$(date +%Y%m%d_%H%M%S):   Entity ID : ${options_entity_id}"
    echo "$(date +%Y%m%d_%H%M%S):   From      : ${options_date_from} (${datetime_start})"
    echo "$(date +%Y%m%d_%H%M%S):   To        : ${options_date_to} (${datetime_end})"
}

_preview() {
    echo ""
    echo "====================================================================="
    echo " DATA TO BE DELETED FROM INFLUXDB"
    echo "====================================================================="
    echo " Entity ID  : ${options_entity_id}"
    echo " Predicate  : entity_id=\"${options_entity_id_bare}\""
    echo " Start      : ${datetime_start}"
    echo " Stop       : ${datetime_end}"
    echo " Bucket     : ${HA_HISTORY_DB_BUCKET}"
    echo " Org        : ${HA_HISTORY_DB_ORG}"
    echo "====================================================================="
    echo ""
    echo "CAUTION: ALL data points for this entity in the given date range will"
    echo "         be permanently deleted from InfluxDB."
    echo "         This operation CANNOT be undone."
    echo ""
    echo "Tip: Run influxd-entity-export.sh first to preview the data if you"
    echo "     have not already done so."
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
    echo "$(date +%Y%m%d_%H%M%S): Executing influx delete for entity_id='${options_entity_id_bare}'."
    echo "$(date +%Y%m%d_%H%M%S):   Bucket : ${HA_HISTORY_DB_BUCKET}"
    echo "$(date +%Y%m%d_%H%M%S):   Org    : ${HA_HISTORY_DB_ORG}"
    echo "$(date +%Y%m%d_%H%M%S):   Start  : ${datetime_start}"
    echo "$(date +%Y%m%d_%H%M%S):   Stop   : ${datetime_end}"

    RESULT=$(docker-compose -f "${docker_compose_file}" exec -T ${container} bash -c \
        "influx delete \
            --bucket \"${HA_HISTORY_DB_BUCKET}\" \
            --org \"${HA_HISTORY_DB_ORG}\" \
            --start \"${datetime_start}\" \
            --stop \"${datetime_end}\" \
            --predicate \"entity_id=\\\"${options_entity_id_bare}\\\"\"")
    RESULT_CODE=$?

    if [ ${RESULT_CODE} -ne 0 ]; then
        error_occured=1
        error_message="influx delete failed"
        echo "$(date +%Y%m%d_%H%M%S): ERROR. ${error_message}. Exit code: ${RESULT_CODE}. Result: ${RESULT}"
        return
    fi

    echo "$(date +%Y%m%d_%H%M%S): influx delete command completed successfully."
    echo "$(date +%Y%m%d_%H%M%S):   Note: influx delete does not report how many data points were removed."
    echo "$(date +%Y%m%d_%H%M%S):   Verify the result by re-running influxd-entity-export.sh for the same range."
}

_finalize() {
    if [ ${error_occured} -eq 0 ]; then
        echo "$(date +%Y%m%d_%H%M%S): Finished InfluxDB entity range-delete. No error." >> "${logfile}"
        echo ""
        echo "Finished InfluxDB entity range-delete. No error."
        echo ""
        echo "IMPORTANT: influx delete does not confirm how many data points were actually"
        echo "removed. Always verify the result by re-running influxd-entity-export.sh"
        echo "for the same entity and date range."

        tail -n10000 "${logfile}" > "${logfile_tmp}"
        rm "${logfile}"
        mv "${logfile_tmp}" "${logfile}"

        exit 0
    else
        echo "$(date +%Y%m%d_%H%M%S): Exited InfluxDB entity range-delete. ERROR: ${error_message}." >> "${logfile}"
        echo ""
        echo "Exited InfluxDB entity range-delete. ERROR: ${error_message}."
        echo "See further information in logfile: ${logfile}"

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
_delete     >> "${logfile}" 2>&1
_finalize
