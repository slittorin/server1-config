#!/bin/bash

_usage_short() {
    echo "Usage: ${0} -e ENTITY_ID -f FROMDATE -t TODATE [-h]"
}

_usage() {
    echo "Options:"
    echo "-h Help, information about the program."
    echo "-e Mandatory. Entity ID to export, e.g. sensor.my_temperature."
    echo "-f Mandatory. From date, in format YYYYMMDD."
    echo "-t Mandatory. To date, in format YYYYMMDD."
    echo ""
    echo "For the given entity_id and date range, this script exports a CSV-file from InfluxDB."
    echo "The file contains: timestamp, domain, entity_id and state."
    echo ""
    echo "Export-file will be saved in directory /srv/ha-history-db/entity-export/"
    echo "Export-file will be named 'influx-entity-export-ENTITY_ID-FROMDATE-TODATE.csv'"
    echo "Logfile is stored here: /srv/log/influxdb-entity-export.log"
    echo ""
    echo "Note that the export-file is overwritten if it already exists."
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
logfile="${base_dir}/log/influxdb-entity-export.log"
logfile_tmp="${base_dir}/log/influxdb-entity-export.tmp"
export_dir="${base_dir}/${container}/export"
export_dir_tmp="${base_dir}/${container}/export/tmp"
flux_file="${export_dir_tmp}/flux_entity.flux"
raw_export_file="${export_dir_tmp}/entity_export_raw.csv"
# Derive domain from entity_id (everything before the first dot).
options_domain="${options_entity_id%%.*}"
# Safe name for filename (replace dots with underscores).
entity_id_safe="${options_entity_id//./_}"
export_filename="${export_dir}/influx-entity-export-${entity_id_safe}-${options_date_from}-${options_date_to}.csv"
datetime_start="$(date -d ${options_date_from} +%Y-%m-%d)T00:00:00.000000Z"
datetime_end="$(date -d ${options_date_to} +%Y-%m-%d)T23:59:59.999999Z"
error_occured=0
error_message=""
warning_occured=0
warning_message=""
output_header="timestamp,domain,entity_id,state"

_initialize() {
    cd "${base_dir}"
    touch "${logfile}"

    echo ""
    echo "$(date +%Y%m%d_%H%M%S): Starting InfluxDB entity export."
    echo "$(date +%Y%m%d_%H%M%S):   Entity ID : ${options_entity_id}"
    echo "$(date +%Y%m%d_%H%M%S):   From      : ${options_date_from}"
    echo "$(date +%Y%m%d_%H%M%S):   To        : ${options_date_to}"

    mkdir -p "${export_dir}"
    mkdir -p "${export_dir_tmp}"
}

_export() {
    echo "$(date +%Y%m%d_%H%M%S): Querying InfluxDB for entity_id '${options_entity_id}'."

    # Build Flux query:
    # - Filter by entity_id and _field == "value" (HA stores state as the "value" field).
    # - Keep only the columns we need: _time, domain, entity_id, _value (= state).
    echo "$(date +%Y%m%d_%H%M%S):   Build Flux-query."
    cat > "${flux_file}" <<FLUX
from(bucket: "${HA_HISTORY_DB_BUCKET}")
  |> range(start: ${datetime_start}, stop: ${datetime_end})
  |> filter(fn: (r) => r["entity_id"] == "${options_entity_id%%.*}_${options_entity_id#*.}" or r["entity_id"] == "${options_entity_id#*.}")
  |> filter(fn: (r) => r["_field"] == "value")
  |> keep(columns: ["_time", "domain", "entity_id", "_value"])
FLUX

    # Run the Flux query inside the InfluxDB container.
    # The raw CSV is written to a tmp file inside the container's mapped volume,
    # then copied to the host export directory — identical pattern to the template.
    echo "$(date +%Y%m%d_%H%M%S):   Run Flux-query."
    RESULT=$(docker-compose -f "${docker_compose_file}" exec -T ${container} bash -c \
        "influx query -f /export/tmp/flux_entity.flux -r > /export/tmp/entity_export_raw.csv")
    RESULT_CODE=$?

    if [ ${RESULT_CODE} -ne 0 ]; then
        error_occured=1
        error_message="influx query error"
        echo "$(date +%Y%m%d_%H%M%S): ERROR. ${error_message}. Exit code: ${RESULT_CODE}. Result: ${RESULT}"
        return
    fi

    # Count data rows (subtract InfluxDB annotated CSV overhead: 3 annotation rows + 1 header = 4).
    number_rows=$(wc -l < "${raw_export_file}")
    echo "$(date +%Y%m%d_%H%M%S):   Raw export rows (including InfluxDB header): ${number_rows}"

    if [ ${number_rows} -le 4 ]; then
        warning_occured=1
        warning_message="No data rows returned for entity_id '${options_entity_id}' in the given date range."
        echo "$(date +%Y%m%d_%H%M%S): WARNING. ${warning_message}"
        return
    fi

    # Copy to correct output-fil and strip header, comment rows and empty rows.
    #cp ${raw_export_file} ${export_filename}
    #grep -v -E '^\s*$|^#' "${raw_export_file}" > "${export_filename}"
    grep -v -E '^\s*$|^#|^,result' "${raw_export_file}" > "${export_filename}"

}

_finalize() {
    if [ ${error_occured} -eq 0 ]; then
        if [ ${warning_occured} -eq 0 ]; then
            echo "$(date +%Y%m%d_%H%M%S): Finished InfluxDB entity export. No error." >> "${logfile}"
            echo "Finished InfluxDB entity export. No error."
            echo "CSV-file output: ${export_filename}"
            echo "Update file and keep only rows that are to be deleted."
            echo "Run thereafter the following script: influxdb-entity-delete.sh -i ${export_filename}"
            echo "You can thereafter run this script again to export the data. Note however that file can be overwritten!"


        else
            echo "$(date +%Y%m%d_%H%M%S): Finished InfluxDB entity export. Warning: ${warning_message}." >> "${logfile}"
            echo "Finished InfluxDB entity export. Warning: ${warning_message}."
        fi

        tail -n10000 "${logfile}" > "${logfile_tmp}"
        rm "${logfile}"
        mv "${logfile_tmp}" "${logfile}"

        exit 0
    else
        echo "$(date +%Y%m%d_%H%M%S): Exited InfluxDB entity export. ERROR: ${error_message}." >> "${logfile}"
        echo "Exited InfluxDB entity export. ERROR: ${error_message}."

        tail -n10000 "${logfile}" > "${logfile_tmp}"
        rm "${logfile}"
        mv "${logfile_tmp}" "${logfile}"

        exit 1
    fi
}

# Main
_initialize >> "${logfile}" 2>&1
_export     >> "${logfile}" 2>&1
_finalize
