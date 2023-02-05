#!/bin/bash

# Purpose:
# This script saves OS/HW statistics in files to be read by Home Assistant.
# Script takes 15 minuts to run.
# Put in cron to be run every 15 minutes.
#
# Requires sysstat to be installed.
#
# Statistics is saved to:
# /srv/stats/disk_used_pct.txt		- Disk utilization in percent.
# /srv/stats/mem_used_pct.txt		- RAM utilization in percent.
# /srv/stats/swap_used_pct.txt		- Swap utilization in percent.
# /srv/stats/cpu_used_pct.txt		- CPU utilization in percentage over 15 minutes.
# /srv/stats/cpu_temp.txt		- CPU temperature in degrees celcius.
# /srv/stats/uptime.txt			- Uptime since (last reboot).
#
# Usage:
# ./os-stats.sh

# Load environment variables (mainly secrets).
if [ -f "/srv/.env" ]; then
    export $(cat "/srv/.env" | grep -v '#' | sed 's/\r$//' | awk '/=/ {print $1}' )
fi

# Variables:
base_dir="/srv"
stats_dir="/srv/stats"

_initialize() {
    cd "${base_dir}"
    mkdir -p ${stats_dir}
}

# Pct used for specific mount directry, usually /
_disk_used() {
   MOUNT_DIR="/"
   USED_PCT=`df -m ${MOUNT_DIR} | tail -1 | awk '{ print $5 }' | sed 's/%//'`
   echo "$(date +%Y%m%d_%H%M%S),${USED_PCT}" > ${stats_dir}/disk_used_pct.txt
}

# Ram used by the system.
_ram_used() {
   USED_PCT=`free -m | grep "Mem:" | awk '{ printf("%.1f", (($2-$4) / $2)*100) }'`
   echo "$(date +%Y%m%d_%H%M%S),${USED_PCT}" > ${stats_dir}/mem_used_pct.txt
}

# Swap used by the system.
_swap_used() {
   USED_PCT=`free -m | grep "Swap:" | awk '{ printf("%.1f", (($2-$4) / $2)*100) }'`
   echo "$(date +%Y%m%d_%H%M%S),${USED_PCT}" > ${stats_dir}/swap_used_pct.txt
}

# CPU temp.
# Works for RPI.
_cpu_temp() {
   USED_PCT=`cat /sys/class/thermal/thermal_zone0/temp | awk '{ printf("%.f", $1/1000) }'`
   echo "$(date +%Y%m%d_%H%M%S),${USED_PCT}" > ${stats_dir}/cpu_temp.txt
}

# System up since.
_uptime() {
   UPTIME=`uptime -s`
   echo "$(date +%Y%m%d_%H%M%S),${UPTIME}" > ${stats_dir}/uptime.txt
}

# CPU percentage retrieved every 5 seconds for 180 times.
# This gives the load average over 15 minutes. I.e. script runs for 15 minutes.
_cpu_used() {
   USED_PCT=`sar 5 180 | grep "Average" | awk '{ printf("%.f", (100-$8)) }'`
   echo "$(date +%Y%m%d_%H%M%S),${USED_PCT}" > ${stats_dir}/cpu_used_pct.txt
}

_finalize() {
    exit 0
}

# Main
_initialize
_disk_used
_ram_used
_swap_used
_cpu_temp
_uptime
_cpu_used
_finalize
