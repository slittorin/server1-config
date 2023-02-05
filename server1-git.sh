#!/bin/bash

# Purpose:
# This script triggers a git push commit.
#
# Pre-req.:
# - Git must be configured for the directory.
#
# Usage:
# ./server1-git.sh COMMENT
#
# COMMENT is the comment to add to the push-commit.
# If empty, the default comment will be: "Minor change."

# Load environment variables (mainly secrets).
if [ -f "/srv/.env" ]; then
    export $(cat "/srv/.env" | grep -v '#' | sed 's/\r$//' | awk '/=/ {print $1}' )
fi

# Variables:
base_dir="/srv"
logfile="${base_dir}/log/server1-git.log"
logfile_tmp="${base_dir}/log/server1-git.tmp"

touch ${logfile}

# Check input.
if [ -z "$1" ]
then
    no_comment=1
    COMMENT="Minor change."
else
    no_comment=0
    COMMENT="$1"
fi

_initialize() {
    cd "${base_dir}"

    echo ""
    echo "$(date +%Y%m%d_%H%M%S): Starting Github push."
}

_github_push() {
    cd ${base_dir}
    
    exit_code=0
    status_error=""
    
    # Add all in /srv dir (according to .gitignore).
    echo "$(date +%Y%m%d_%H%M%S): Added all in base directory"
    git add .
    
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
_github_push >> "${logfile}" 2>&1
_finalize >> "${logfile}" 2>&1
