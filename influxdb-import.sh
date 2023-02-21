#!/bin/bash

_usage_short() {
    echo "Usage: ${0} -f FROMDATE -t TODATE -e EXISTINGENTITYID -n NEWENTITYID -c CALCULATIONMODE [-d DECIMALS] [-h]"
}

_usage() {
    echo "Options:"
    echo "-h Help, information about the program."
    echo "-f Mandatory. From date, in format YYYYMMDD."
    echo "-t Mandatory. To date, in format YYYYMMDD."
    echo "-e Mandatory. Existing/from entity_id."
    echo "-n Mandatory. New/to entity_id."
    echo "-c Mandatory. Calculation mode. Can only be one of: first, last, max, min, sum, average."
    echo "-d Number of decimals. Defaults to 3. Between 0 and 9. Not utilized for calculation modes 'first' and 'last'."
    echo ""
    echo "For the given from and to dates, this script exports csv-files from InfluxDB for existing entity_id."
    echo "For each file, and for every hour, the states/values are calculated and summarized based on calculation mode."
    echo ""
    echo "Files will be saved in directory /srv/ha-history-db/import/NEWENTITYID/"
    echo "Files will be named 'import-NEWENTITYID-YYYY-MM-DD.csv"
    echo "Logfile is stored here: /srv/log/influxdb-export-to-hourly.log"
    echo "Only progress will be sent to TTY/screen."
    echo ""
    echo "The values for can be calculated according:"
    echo "- first   - First value for the hour."
    echo "- last    - Last value for the hour."
    echo "- max     - Max value for the hour."
    echo "- min     - Min value for the hour."
    echo "- sum     - Sum of all values for the hour."
    echo "- average - Average of all values for the hour."
    echo ""
    echo "Note that the script can only utilize values that are integers or floats, and not binary states/values."
}

_wrong_options() {
    _usage_short
    exit 1
}

# Manage options.
options_number_mandatory=0
options_calc_decimals=3		# Default.
while getopts ":hf:t:e:n:c:d:" option; do
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
        e) # From/existing entity_id.
            arg=${OPTARG}
            options_entity_id_from=${arg}
            options_number_mandatory=$((${options_number_mandatory}+1))
            ;;
        n) # To/new entity_id.
            arg=${OPTARG}
            options_entity_id_to=${arg}
            options_number_mandatory=$((${options_number_mandatory}+1))
            ;;
        c) # Calculation mode.
            arg=${OPTARG}
            case ${arg} in
                first|last|min|max|sum|average) # Must match one of these.
                    options_calc_mode=${arg}
                    options_number_mandatory=$((${options_number_mandatory}+1))
                    ;;
                *) # Anything else
                    echo "Error: -c can only be one of: first, last, max, min, sum, average."
                    _wrong_options
                esac
             ;;
        d) # Decimals.
             arg=${OPTARG}
             if [[ ${arg} =~ ^-?[0-9]+$ ]]; then
                 if [ ${arg} -ge 0 ] && [ ${arg} -lt 10 ]; then
                     options_calc_decimals=${arg}
                 else
                     echo "Error: -d can only between 0 and 9."
                     _wrong_options
                 fi
             else
                 echo "Error: -d can only be number."
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
if [ ${options_number_mandatory} -ne 5 ]; then
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
logfile="${base_dir}/log/influxdb-convert-to-hourly.log"
logfile_tmp="${base_dir}/log/influxdb-convert-to-hourly.tmp"
import_dir="${base_dir}/${container}/import"
import_tmp_dir="${base_dir}/${container}/import/tmp"
import_entity_dir="${base_dir}/${container}/import/${options_entity_id_to}"
error_occured=0
error_message=""
warning_occured=0
warning_message=""
debug=0						#  No debug = 0, debug = 1, more debug info = 2

_initialize() {
    cd "${base_dir}"
    touch "${logfile}"

    echo ""
    echo "$(date +%Y%m%d_%H%M%S): Starting InfluxDB convert to hourly."

    mkdir -p "${import_dir}"
    mkdir -p "${import_tmp_dir}"
    mkdir -p "${import_entity_dir}"

    
    if [ ${debug} -gt 0 ]; then
        echo "Options:"
        echo "Date from: ${options_date_from}"
        echo "Date to: ${options_date_to}"
        echo "From/existing entity_id: ${options_entity_id_from}"
        echo "To/new entity_id: ${options_entity_id_to}"
        echo "Calculation mode: ${options_calc_mode}"
        echo "Decimals: ${options_calc_decimals}"
    fi

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
        flux_file="${import_tmp_dir}/flux.flux"
        csv_export_file="${import_tmp_dir}/export.csv"
        csv_export_tmp="${import_tmp_dir}/export.tmp"
        csv_number_of_split_files=0
        import_file="${import_entity_dir}/import-${options_entity_id_to}-${date_export}.csv"

        # Set the timestamps.
        datetime_start="${date_export}T00:00:00.000000Z"
        datetime_end="${date_export}T23:59:59.999999Z"

        # Reset errors.
        error_occured=0
        error_message=""
        warning_occured=0
        warning_message=""

        # For each date, we export and convert.
        echo "$(date +%Y%m%d_%H%M%S): Performing for ${date_export}."
        _export >> "${logfile}" 2>&1
        if [ ${error_occured} -eq 0 ]; then
            _split >> "${logfile}" 2>&1

            if [ ${error_occured} -eq 0 ]; then
                _import_file_setup >> "${logfile}" 2>&1

                if [ ${error_occured} -eq 0 ]; then
                    _import_file_iterate >> "${logfile}" 2>&1
                else
                    echo "$(date +%Y%m%d_%H%M%S): Error occured. No setup of import-files for date ${date_export}."
                fi
            else
                echo "$(date +%Y%m%d_%H%M%S): Error occured. No split of import-file for date ${date_export}."
            fi
        else
            echo "$(date +%Y%m%d_%H%M%S): Error occured. No export for date ${date_export}."
        fi

        iterate_current=$(date -d ${iterate_current}+1day +%Y%m%d)
    done
    echo "$(date +%Y%m%d_%H%M%S): Done iterate through dates ${options_date_from} to ${options_date_to}."
}

_export() {
    echo "$(date +%Y%m%d_%H%M%S):   Export of influxdb for date ${date_export} started."

    cd ${import_tmp_dir}

    flux="from(bucket: \"${HA_HISTORY_DB_BUCKET}\") |> range(start: ${datetime_start}, stop: ${datetime_end}) |> filter(fn: (r) => r[\"entity_id\"] == \"${options_entity_id_from}\")"
    echo "${flux}" > ${flux_file}

    curl --request POST "http://localhost:8086/api/v2/query?org=${HA_HISTORY_DB_ORG}&bucket=${HA_HISTORY_DB_BUCKET=}" \
         -H "Authorization: Token ${HA_HISTORY_DB_GRAFANA_TOKEN}" \
         -H "Accept: application/csv" \
         -H "Content-type: application/vnd.flux" \
         -s -S \
         -o ${csv_export_file} \
         -d @${flux_file}
    RESULT_CODE=$?
    if [ ${RESULT_CODE} -ne 0 ]; then
        error_occured=1
        error__message="influx export error"
        echo "$(date +%Y%m%d_%H%M%S): ERROR. ${error_message}. Exit code: ${RESULT_CODE}"
    else
        number_rows=$(wc -l < ${csv_export_file})
        echo "$(date +%Y%m%d_%H%M%S):     Export of influxdb for date ${date_export} performed. Number of rows: ${number_rows}"

        # Check if head of file is correct.
        head_of_file=$(head -1 ${csv_export_file} | sed 's/\r$//' | sed 's/\n$//')
        if [ "${head_of_file}" == ",result,table,_start,_stop,_time,_value,_field,_measurement,domain,entity_id" ]; then
            echo "$(date +%Y%m%d_%H%M%S):     Header of file is correct."
            echo "$(date +%Y%m%d_%H%M%S):     Export of influxdb for date ${date_export} started."
        else
            error_occured=1
            error_message="influx export error"
            echo "$(date +%Y%m%d_%H%M%S): ERROR. Header of file is not correct."
        fi
    fi
}

_split() {
    echo "$(date +%Y%m%d_%H%M%S):   Split of export-file for date ${date_export} started."

    cd ${import_tmp_dir}
    rm -f ${csv_export_tmp}
    rm -f export-split-*.csv
    rm -f import-split-*.csv

    # Inspired from https://stackoverflow.com/questions/33294986/splitting-large-text-file-on-every-blank-line
    # Files can be kept in memory, so we only worry about open file decriptors.
    # The export contains both /r and /n for each line, we remote all /r as it otherwise will not work for awk.
    tr -d '\r' < ${csv_export_file} > ${csv_export_tmp}
    awk -v RS= '{print > ("export-split-" NR ".csv")}' ${csv_export_tmp}
    RESULT_CODE=$?
    if [ ${RESULT_CODE} -ne 0 ]; then
        error_occured=1
        error_message="influx export error"
        echo "$(date +%Y%m%d_%H%M%S): ERROR. ${error_message}. Exit code: ${RESULT_CODE}"
    else
        csv_number_of_split_files=$(ls -1 export-split-*.csv | wc -l)

        echo "$(date +%Y%m%d_%H%M%S):     Split of export-file performed, into ${csv_number_of_split_files} files."
    fi
}

_import_file_setup() {
    echo "$(date +%Y%m%d_%H%M%S):   Setup of import-files for date ${date_export} started."

    cd ${import_tmp_dir}

    # Create the header for all import-files.
    for LOOP in $(seq ${csv_number_of_split_files}); do
       head -1 "export-split-${LOOP}.csv" > "import-split-${LOOP}.csv"
    done

    # Isolate which of the export-files that contains values.
    csv_file_with_value=0
    csv_files_with_value=0
    for LOOP in $(seq ${csv_number_of_split_files}); do
        result=$(cat "export-split-${LOOP}.csv" | grep ",value,")

        if [ ! -z "${result}" ]; then
           csv_file_with_value=${LOOP}
           csv_files_with_value=$((${csv_files_with_value}+1))
        fi
    done

    if [ ${csv_files_with_value} -ne 1 ]; then
        error_occured=1
        error_message="Find export-file with values error"
        echo "$(date +%Y%m%d_%H%M%S): ERROR. Number of export-files with value should be 1, is: ${csv_files_with_value}"
    else
        # Get the number of columns
        columns=$(head -1 "export-split-${csv_file_with_value}.csv" | awk -F, '{print NF-1}')

        # Set the variables for columns.
        column_datetime=4 # HARDCODED.
        column_value=5 # HARDCODED.
        column_entity_id=$((${columns}-1)) # The entity_id is always last (columns-1).

        echo "$(date +%Y%m%d_%H%M%S):     Export-file with values is: ${csv_file_with_value}, and number of columns is ${columns}."
    fi

    echo "$(date +%Y%m%d_%H%M%S):     Setup of import-files for date ${date_export} performed."
}

_import_file_iterate() {
    echo "$(date +%Y%m%d_%H%M%S):   Iteration for import-files for date ${date_export} started, in calculation mode: ${options_calc_mode}."

    cd ${import_tmp_dir}

    # We only start if the file has more than header.
    rows_total=$(wc -l < "export-split-${csv_file_with_value}.csv")
    if [ ${rows_total} -gt 1 ]; then
        # We set initial values.
        row_current=1
        rows_for_hour=0
        hour_previous=
        hour_result_found=0
 
        # We iterate through the file with values, i.e., this will influence all lines to import.
        # https://stackoverflow.com/questions/16854280/a-variable-modified-inside-a-while-loop-is-not-remembered
        while read line
        do
            # We ignore the header on row 1.
            if [ ${row_current} -ne 1 ]; then
                # We get values from the current line.
                line_current_array=(${line//,/ })
                value_current=${line_current_array[${column_value}]}

                # We get the hour for the timestamp.
                # Format is: 2023-01-01T00:01:02.044883Z
                hour_current=${line_current_array[${column_datetime}]:11:2} 

                # We check if we are at second row.
                [ ${row_current} -eq 2 ] && check_second_row=1 || check_second_row=0

                # We check if we are at last row.
                [ ${row_current} -eq ${rows_total} ] && check_last_row=1 || check_last_row=0

                # We check if hour has changed.
                [ "${hour_current}" != "${hour_previous}" ] && check_hour_change=1 || check_hour_change=0

                # If we have are at second row, and last row. then there is only one result.
                if [ ${check_second_row} -eq 1 ] && [ ${check_last_row} -eq 1 ]; then
                    if [ ${debug} -gt 0 ]; then
                       echo "$(date +%Y%m%d_%H%M%S):     At ${row_current} of ${rows_total}: Result at second row, and last row."
                    fi

                    value_result=${value_current}

                    # Output the result.
                    hour_result_found=$((${hour_result_found}+1))
                    line_result=${line}
                    _import_file_add
                fi

                # If we are at second row, and not last row. then we start fresh.
                if [ ${check_second_row} -eq 1 ] && [ ${check_last_row} -eq 0 ]; then
                    if [ ${debug} -gt 0 ]; then
                       echo "$(date +%Y%m%d_%H%M%S):     At ${row_current} of ${rows_total}: At second row, and not last row."
                    fi

                    rows_for_hour=1
                    check_hour_change=0 # We do not want to trigger any of the below functions.

                    if [ ${options_calc_mode} == "sum" ] || [ ${options_calc_mode} == "average" ]; then
                        value_sum=${value_current}
                    elif [ ${options_calc_mode} == "min" ]; then
                        value_min=${value_current}
                    elif [ ${options_calc_mode} == "max" ]; then
                        value_max=${value_current}
                    fi

                    value_first=${value_current}
                    value_last=${value_current}
                fi

                # If we are not at second row, we have same hour, and are not at last row.
                if [ ${check_second_row} -eq 0 ] && [ ${check_hour_change} -eq 0 ] && [ ${check_last_row} -eq 0 ]; then
                    if [ ${debug} -eq 2 ]; then
                       echo "$(date +%Y%m%d_%H%M%S):       At ${row_current} of ${rows_total}: Not at second row, same hour and not last row."
                    fi

                    rows_for_hour=$((${rows_for_hour}+1))

                    if [ ${options_calc_mode} == "sum" ] || [ ${options_calc_mode} == "average" ]; then
                        value_sum=$(bc <<< "scale=${options_calc_decimals}; ${value_sum}+${value_current}")
                    elif [ ${options_calc_mode} == "min" ]; then
                        if (( $(bc -l <<< "${value_current} < ${value_min}") )); then
                            value_min=${value_current}
                        fi
                    elif [ ${options_calc_mode} == "max" ]; then
                        if (( $(bc -l <<< "${value_current} > ${value_max}") )); then
                            value_max=${value_current}
                        fi
                    fi

                    value_last=${value_current}
                fi

                # If we have same hour, and are at last row.
                if [ ${check_hour_change} -eq 0 ] && [ ${check_last_row} -eq 1 ]; then
                    rows_for_hour=$((${rows_for_hour}+1))

                    if [ ${options_calc_mode} == "sum" ] || [ ${options_calc_mode} == "average" ]; then
                        value_sum=$(bc <<< "scale=${options_calc_decimals}; ${value_sum}+${value_current}")

                        if [ ${options_calc_mode} == "sum" ]; then
                            value_result=${value_sum}
                        elif [ ${options_calc_mode} == "average" ]; then
                            value_result=$(bc <<< "scale=${options_calc_decimals}; ${value_sum}/${rows_for_hour}")
                        fi
                    elif [ ${options_calc_mode} == "min" ]; then
                        if (( $(bc -l <<< "${value_current} < ${value_min}") )); then
                            value_min=${value_current}
                        fi
                        value_result=${value_min}
                    elif [ ${options_calc_mode} == "max" ]; then
                        if (( $(bc -l <<< "${value_current} > ${value_max}") )); then
                            value_max=${value_current}
                        fi
                        value_result=${value_max}
                    elif [ ${options_calc_mode} == "last" ]; then
                        value_result=${value_current}
                    elif [ ${options_calc_mode} == "first" ]; then
                        value_result=${value_first}
                    fi

                    # Output the result.
                    hour_result_found=$((${hour_result_found}+1))
                    line_result=${line}
                    _import_file_add

                    if [ ${debug} -gt 0 ]; then
                       echo "$(date +%Y%m%d_%H%M%S):     At ${row_current} of ${rows_total}: Result at same hour, and last row. Rows for hour: ${rows_for_hour}."
                    fi
                fi

                # If we have not same hour, and are not at last row.
                if [ ${check_hour_change} -eq 1 ] && [ ${check_last_row} -eq 0 ]; then
                    if [ ${debug} -gt 0 ]; then
                       echo "$(date +%Y%m%d_%H%M%S):     At ${row_current} of ${rows_total}: Result at not same hour, and not last row. Rows for hour: ${rows_for_hour}."
                    fi

                    if [ ${options_calc_mode} == "sum" ]; then
                        value_result=${value_sum}
                    elif [ ${options_calc_mode} == "average" ]; then
                        value_result=$(bc <<< "scale=${options_calc_decimals}; ${value_sum}/${rows_for_hour}")
                    elif [ ${options_calc_mode} == "min" ]; then
                        value_result=${value_min}
                    elif [ ${options_calc_mode} == "max" ]; then
                        value_result=${value_max}
                    elif [ ${options_calc_mode} == "last" ]; then
                        value_result=${value_last}
                    elif [ ${options_calc_mode} == "first" ]; then
                        value_result=${value_first}
                    fi

                    # Output the result.
                    hour_result_found=$((${hour_result_found}+1))
                    line_result=${line_previous}
                    _import_file_add
                    # We start fresh.
                    rows_for_hour=1

                    if [ ${options_calc_mode} == "sum" ] || [ ${options_calc_mode} == "average" ]; then
                        value_sum=${value_current}
                    elif [ ${options_calc_mode} == "min" ]; then
                        value_min=${value_current}
                    elif [ ${options_calc_mode} == "max" ]; then
                        value_max=${value_current}
                    fi

                    value_first=${value_current}
                    value_last=${value_current}
                fi

                # If we have not same hour, and are at last row.
                if [ ${check_hour_change} -eq 1 ] && [ ${check_last_row} -eq 1 ]; then
                    if [ ${options_calc_mode} == "sum" ]; then
                        value_result=${value_sum}
                    elif [ ${options_calc_mode} == "average" ]; then
                        value_result=$(bc <<< "scale=${options_calc_decimals}; ${value_sum}/${rows_for_hour}")
                    elif [ ${options_calc_mode} == "min" ]; then
                        value_result=${value_min}
                    elif [ ${options_calc_mode} == "max" ]; then
                        value_result=${value_max}
                    elif [ ${options_calc_mode} == "last" ]; then
                        value_result=${value_last}
                    elif [ ${options_calc_mode} == "first" ]; then
                        value_result=${value_first}
                    fi

                    # Output the result.
                    hour_result_found=$((${hour_result_found}+1))
                    line_result=${line_previous}
                    _import_file_add

                    if [ ${debug} -gt 0 ]; then
                       echo "$(date +%Y%m%d_%H%M%S):     At ${row_current} of ${rows_total}: Results at not same how, and last row. Rows for hour: ${rows_for_hour}."
                    fi

                    # We start fresh.
                    rows_for_hour=1

                    # There is only one possible outcome for the last row.
                    value_result=${value_current}

                    # Output the result.
                    hour_result_found=$((${hour_result_found}+1))
                    line_result=${line}
                    _import_file_add

                    if [ ${debug} -gt 0 ]; then
                       echo "$(date +%Y%m%d_%H%M%S):     At ${row_current} of ${rows_total}: Results at not same how, and last row. Rows for hour: ${rows_for_hour}."
                    fi
                fi

                # We set hour for previous line (when we start again at the top of the do-script.
                line_previous=${line}
                hour_previous=${hour_current}
            fi

            # We prepare for next line.
            row_current=$((${row_current}+1))
        done < export-split-${csv_file_with_value}.csv

        # Verify that all import-files has same number of rows.
        equal_number_of_rows=1
        number_of_rows=$(wc -l < import-split-1.csv)
        for LOOP in $(seq 2 ${csv_number_of_split_files}); do
            test_number_of_rows=$(wc -l < import-split-${LOOP}.csv)
            if [ ${number_of_rows} -ne ${test_number_of_rows} ]; then
                 equal_number_of_rows=0
            fi
        done
        if [ ${equal_number_of_rows} -eq 0 ]; then
            warning_occured=1
            warning_message="Import-files are not equal in number of rows."
            echo "$(date +%Y%m%d_%H%M%S): WARNING. Import-files are not equal in number of rows."
        else
            echo "$(date +%Y%m%d_%H%M%S):     Iteration for import-files for date ${date_export} performed, number of hour results found: ${hour_result_found}."

            # Summarize to one import-file.
            rm -f  ${import_file}
            for LOOP in $(seq ${csv_number_of_split_files}); do
                cat "import-split-${LOOP}.csv" >> ${import_file}
                echo "" >> ${import_file}
            done
        fi
    else
        warning_occured=1
        warning_message="Import-file with values does only contain header."
        echo "$(date +%Y%m%d_%H%M%S): WARNING. Import-file with values does only contain header, no data."
    fi
}

_import_file_add() {
    cd ${import_tmp_dir}

    # We get values from the result line.
    line_result_array=(${line_result//,/ })
    datetime_result=${line_result_array[${column_datetime}]}

    # We start adding to line, that will be added to file, changing value and entity_id.
    line_add=""
    for LOOP in $(seq 0 $((${columns}-1))); do
        value_loop=${line_result_array[${LOOP}]}

        # Set the variables for columns.
        if [ ${LOOP} -eq ${column_value} ]; then
           line_add="${line_add},${value_result}"
        elif [ ${LOOP} -eq ${column_entity_id} ]; then
            line_add="${line_add},${options_entity_id_to}"
        else
            line_add="${line_add},${value_loop}"
        fi
    done

    # Add row to import-file.
    echo "${line_add}" >> import-split-${csv_file_with_value}.csv

    # Add to the other import-files, based on datetime, only changing entity_id.
    for LOOP in $(seq ${csv_number_of_split_files}); do
        # We only do it for import-files without values.
        if [ ${LOOP} -ne ${csv_file_with_value} ]; then
            line_extract=$(cat "export-split-${LOOP}.csv" | grep ",${datetime_result}")
            line_extract_array=(${line_extract//,/ })

            line_add=""
            for LOOP2 in $(seq 0 $((${columns}-1))); do
                value_loop=${line_extract_array[${LOOP2}]}

                # Set the variables for columns.
                if [ ${LOOP2} -eq ${column_entity_id} ]; then
                    line_add="${line_add},${options_entity_id_to}"
                else
                    line_add="${line_add},${value_loop}"
                fi
            done

            echo "${line_add}" >> import-split-${LOOP}.csv
        fi
    done
}

_finalize() {
    if [ ${error_occured} -eq 0 ]; then
       echo "$(date +%Y%m%d_%H%M%S): Finished InfluxDB convert to hourly. No last error."

       tail -n30000 ${logfile} > ${logfile_tmp}
       rm ${logfile}
       mv ${logfile_tmp} ${logfile}

       exit 0
    else
       echo "$(date +%Y%m%d_%H%M%S): Exited InfluxDB convert to hourly. ERROR: ${error_message}."

       tail -n30000 ${logfile} > ${logfile_tmp}
       rm ${logfile}
       mv ${logfile_tmp} ${logfile}

       exit 1
    fi
}

# Main
_initialize >> "${logfile}" 2>&1
_iterate >> "${logfile}" 2>&1
_finalize >> "${logfile}" 2>&1
