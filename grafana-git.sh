#!/bin/bash

# Inspired by: https://chowdera.com/2020/12/20201216140412674p.html
#              https://gist.github.com/crisidev/bd52bdcc7f029be2f295
#
# Purpose:
# This script extract json for all dashboards in Grafana, and triggers a git push commit.
#
# Pre-req.:
# - The Grafana server must be without login.
# - Git must be configured for the directory.
#
# Usage:
# ./grafana-git.sh HOST COMMENT
#
# HOST is the Grafana host/IP to connect to, including port.
# COMMENT is the comment to add to the push-commit.
# If empty, the default comment will be: "Minor change."

# Load environment variables (mainly secrets).
if [ -f "/srv/.env" ]; then
    export $(cat "/srv/.env" | grep -v '#' | sed 's/\r$//' | awk '/=/ {print $1}' )
fi

# Variables:
base_dir="/srv"
logfile="${base_dir}/log/grafana-git.log"
logfile_tmp="${base_dir}/log/grafana-git.tmp"
json_dir="${base_dir}/ha-grafana/json"
temp_dir="${base_dir}/ha-grafana/temp"

touch ${logfile}

# Check server.
if [ -z "$1" ]; then
    echo "ERROR. Server must be given."
    echo "$(date +%Y%m%d_%H%M%S): ERROR. Server must be given." >> ${logfile}
    exit 1
else
    HOST="$1"
fi

# Check input.
if [ -z "$2" ]
then
    no_comment=1
    COMMENT="Minor change."
else
    no_comment=0
    COMMENT="$2"
fi

_initialize() {
    cd "${base_dir}"

    echo ""
    echo "$(date +%Y%m%d_%H%M%S): Starting Grafana Backup."

    mkdir -p "${temp_dir}"
    mkdir -p "${json_dir}"
}

_grafana_backup() {
    echo "$(date +%Y%m%d_%H%M%S): Backing up..."

    cd ${temp_dir}
    rm -r ${temp_dir}/*

    # Walk through all dashboards.
    for dashboard_uid in $(curl -sS ${HOST}/api/search  | jq -r '.[] | select( .type | contains("dash-db")) | .uid') ; do
       # Retrieve the dashboard.
       dashboard_url=`echo ${HOST}/api/dashboards/uid/${dashboard_uid} | tr -d '\r'`
       dashboard_json=$(curl -sS ${dashboard_url})

       # Extract information from the json.
       dashboard_slug=$(echo ${dashboard_json} | jq -r '.meta | .slug ' | sed -r 's/[ \/]+/_/g' )
       dashboard_title=$(echo ${dashboard_json} | jq -r '.dashboard | .title' | sed -r 's/[ \/]+/_/g' )
       dashboard_version=$(echo ${dashboard_json} | jq -r '.dashboard | .version')
       dashboard_folder="$(echo ${dashboard_json} | jq -r '.meta | .folderTitle')"

       # Save the json to temp-dir
       mkdir -p ${temp_dir}/${dashboard_folder}
       echo ${dashboard_json} | jq -r {meta:.meta}+.dashboard > ${temp_dir}/${dashboard_folder}/${dashboard_slug}.json

       echo "$(date +%Y%m%d_%H%M%S): Retrieved dashboard with UID: ${dashboard_uid}, folder: ${dashboard_folder}, version ${dashboard_version}, title: ${dashboard_title}"
    done
}

_sync_files() {
    # Sync temp-dir with json-dir.
    # Ensure that .git directory is kept.
    cd ${temp_dir}
    rsync -aczvS --delete --exclude '.git' . ${json_dir}
    echo "$(date +%Y%m%d_%H%M%S): Synced temp-dir with json-dir."
}

_github_push() {
    cd ${json_dir}
    
    exit_code=0
    status_error=""
    
    # Add all in /config dir (according to .gitignore).
    echo "$(date +%Y%m%d_%H%M%S): Added all in base directory"
    git add .
    
    # Loop through all directories and add to git (according to .gitignore).
    for dir in */ ; do
        echo "$(date +%Y%m%d_%H%M%S): Added directory: ${dir}"
        git add "${dir}"
    done

    git status
    git_exit_code=$?
    if [ ${git_exit_code} -ne 0 ] 
    then
        exit_code=1
        status_error+=" status (${git_exit_code})"
    fi

    git commit -m "${COMMENT}"
    git_exit_code=$?
    if [ ${git_exit_code} -ne 0 ] 
    then
        exit_code=1
        status_error+=" commit (${git_exit_code})"
    fi

    git push origin master
    git_exit_code=$?
    if [ ${git_exit_code} -ne 0 ] 
    then
        exit_code=1
        status_error+=" push (${git_exit_code})"
    fi

    # Check if error occured with git commands.
    if [ ${exit_code} -eq 0 ] 
    then
        status="No error."
    else
        status="Error in: git${status_error}."
    fi
}

_finalize() {
    echo "$(date +%Y%m%d_%H%M%S): ${status}"

    tail -n10000 ${logfile} > ${logfile_tmp}
    rm ${logfile}
    mv ${logfile_tmp} ${logfile}

    exit 0
}

# Main
_initialize >> "${logfile}" 2>&1
_grafana_backup >> "${logfile}" 2>&1
_sync_files >> "${logfile}" 2>&1
_github_push >> "${logfile}" 2>&1
_finalize >> "${logfile}" 2>&1
