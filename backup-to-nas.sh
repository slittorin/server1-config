#!/bin/bash

# This script backs up all files in /srv to NAS:
# - Ensure that copy on NAS is exact copy of /srv (besides unix permissions).
#
# Usage:
# ./backup-to-nas.sh

# Load environment variables (mainly secrets).
if [ -f "/srv/.env" ]; then
    export $(cat "/srv/.env" | grep -v '#' | sed 's/\r$//' | awk '/=/ {print $1}' )
fi

# Variables:
# -----------------------------------------------------------------
base_dir="/srv"
logfile="${base_dir}/log/backup-to-nas.log"
logfile_tmp="${base_dir}/log/backup-to-nas.tmp"
logfile_rsync="${base_dir}/log/backup-to-nas.rsync"
source_dir="/srv/"
mount_dir="/mnt/nas"
dest_dir="${mount_dir}/server1/srv"
nas_host="//192.168.2.10/server-backup"
nas_user="pi-backup"
error_occured=0
error_message=""

_initialize() {
    cd "${base_dir}"

    touch "${logfile}"

    mkdir -p ${mount_dir}

    echo ""
    echo "$(date +%Y%m%d_%H%M%S): Starting backup to NAS."
}

_mount() {
    echo "$(date +%Y%m%d_%H%M%S): Mount of NAS-share started."
    RESULT=`mount -t cifs -o username=${nas_user},password=${NAS_BACKUP_PASSWORD},vers=2.0 ${nas_host} ${mount_dir}`
    RESULT_CODE=$?
    if [ ${RESULT_CODE} -ne 0 ]; then
       error_occured=1
       error_message="Mount error"
       echo "$(date +%Y%m%d_%H%M%S): ERROR. ${error_message}. Exit code: ${RESULT_CODE}: ${RESULT}"
    else
       echo "$(date +%Y%m%d_%H%M%S): Mount of NAS-share performed."
    fi
}

_mkdir() {
    if [ ${error_occured} -eq 0 ]; then
       echo "$(date +%Y%m%d_%H%M%S): Creation of dir on NAS started."
       RESULT=`mkdir -p ${dest_dir}`
       RESULT_CODE=$?
       if [ ${RESULT_CODE} -ne 0 ]; then
          error_occured=1
          error_message="mkdir error"
          echo "$(date +%Y%m%d_%H%M%S): ERROR. ${error_message}. Exit code: ${RESULT_CODE}: ${RESULT}"
       else
          echo "$(date +%Y%m%d_%H%M%S): Creation of dir on NAS performed."
       fi
   fi
}

_rsync() {
    if [ ${error_occured} -eq 0 ]; then
       echo "$(date +%Y%m%d_%H%M%S): Rsync to NAS-share started."
       RESULT=`rsync -tr --delete --stats ${source_dir} ${dest_dir} > ${logfile_rsync}`
       RESULT_CODE=$?
       if [ ${RESULT_CODE} -ne 0 ]; then
          error_occured=1
          error_message="Rsync error"
          echo "$(date +%Y%m%d_%H%M%S): ERROR. ${error_message}. Exit code: ${RESULT_CODE}: ${RESULT}"
       else
          echo "$(date +%Y%m%d_%H%M%S): Rsync to NAS-share performed, output:"
          cat ${logfile_rsync} | sed '0,/^$/d' | sed '/^$/d'
       fi
   fi
}

_unmount() {
    if [ ${error_occured} -eq 0 ]; then
       echo "$(date +%Y%m%d_%H%M%S): Unmount of NAS-share started."
       RESULT=`umount ${mount_dir}`
       RESULT_CODE=$?
       if [ ${RESULT_CODE} -ne 0 ]; then
          error_occured=1
          error_message="Unmount error"
          echo "$(date +%Y%m%d_%H%M%S): ERROR. ${error_message}. Exit code: ${RESULT_CODE}: ${RESULT}"
       else
          echo "$(date +%Y%m%d_%H%M%S): Unmount of NAS-share performed."
       fi
   fi
}

_finalize() {
    if [ ${error_occured} -eq 0 ]; then
       echo "$(date +%Y%m%d_%H%M%S): Finished backup to NAS. No error."

       tail -n10000 ${logfile} > ${logfile_tmp}
       rm ${logfile}
       mv ${logfile_tmp} ${logfile}

       exit 0
    else
       echo "$(date +%Y%m%d_%H%M%S): Exited backup to NAS. ERROR: ${error_message}."

       tail -n10000 ${logfile} > ${logfile_tmp}
       rm ${logfile}
       mv ${logfile_tmp} ${logfile}

       exit 1
    fi
}

# Main
_initialize >> "${logfile}" 2>&1
_mount >> "${logfile}" 2>&1
_mkdir >> "${logfile}" 2>&1
_rsync >> "${logfile}" 2>&1
_unmount >> "${logfile}" 2>&1
_finalize >> "${logfile}" 2>&1
