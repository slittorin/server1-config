#!/bin/bash

# Inspired by: https://medium.com/homullus/how-to-inspect-volumes-size-in-docker-de1068d57f6b
#

# Purpose:
# This script lists all docker containers volumes and sizes.
# Data is written to log-file and to comma separated file.
# Sizes are in MB.
#
# Usage:
# ./docker_volume_sizes.sh

# Load environment variables (mainly secrets).
if [ -f "/srv/.env" ]; then
    export $(cat "/srv/.env" | grep -v '#' | sed 's/\r$//' | awk '/=/ {print $1}' )
fi

# Variables:
base_dir="/srv"
stats_dir="/srv/stats"
statsfile="${stats_dir}/docker_volume_sizes.txt"
logfile="${base_dir}/log/docker-volume-sizes.log"
logfile_tmp="${base_dir}/log/docker-volume-sizes.tmp"
timestamp="$(date +%Y%m%d_%H%M%S)"

_initialize() {
    cd "${base_dir}"
    touch "${logfile}"
    > "${statsfile}"

    echo ""
    echo "$(date +%Y%m%d_%H%M%S): Starting Docker volume sizes."
}

_volume_sizes() {
    for DOCKER_ID in `docker ps -a | awk '{ print $1 }' | tail -n +2`; do
        DOCKER_NAME=`docker inspect -f {{.Name}} ${DOCKER_ID}`
        echo "$(date +%Y%m%d_%H%M%S): For docker container: ${DOCKER_NAME} (${DOCKER_ID})"

        VOLUME_IDS=$(docker inspect -f "{{.Config.Volumes}}" ${DOCKER_ID})
	VOLUME_IDS=$(echo ${VOLUME_IDS} | sed 's/map\[//' | sed 's/]//')

        ARRAY=(${VOLUME_IDS// / })
        for i in "${!ARRAY[@]}"; do
            VOLUME_ID=$(echo ${ARRAY[i]} | sed 's/:{}//')
            VOLUME_SIZE=`docker exec -i ${DOCKER_NAME} du -d 0 -m ${VOLUME_ID} | awk '{ print $1 }'`

	    echo "$(date +%Y%m%d_%H%M%S): Size in MB for volume ${VOLUME_ID}: ${VOLUME_SIZE}"

            echo "${timestamp},${DOCKER_NAME},${VOLUME_ID},${VOLUME_SIZE}" >> "${statsfile}"
        done
    done
}

_finalize() {
    echo "$(date +%Y%m%d_%H%M%S): Finished Docker volume sizes."

    tail -n10000 ${logfile} > ${logfile_tmp}
    rm ${logfile}
    mv ${logfile_tmp} ${logfile}

    exit 0
}

# Main
_initialize >> "${logfile}" 2>&1
_volume_sizes >> "${logfile}" 2>&1
_finalize >> "${logfile}" 2>&1
