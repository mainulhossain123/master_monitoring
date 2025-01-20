#!/bin/bash
#
# This script monitors thread counts for a .NET Core application.
# If thread counts exceed a predefined threshold, it will generate a memory dump, profiler trace, or both for diagnostics.
#
# Author: Updated Version
# Date: January 2025

script_name=${0##*/}
function usage()
{
    echo "### Syntax: $script_name -t <threshold> -f <interval>"
    echo "-t <threshold> Threshold of thread count to trigger dump/trace. Default: 200"
    echo "-f <interval> Polling interval in seconds. Default: 10"
}

function die()
{
    echo "$1" && exit $2
}

function teardown()
{
    echo "Terminating all relevant processes..."
    kill -SIGTERM $(ps -ef | grep "$script_name" | grep -v grep | awk '{print $2}')
    echo "Cleanup complete."
    exit 0
}

function getsasurl()
{
    local pid=$1
    sas_url=$(cat "/proc/$pid/environ" | tr '\0' '\n' | grep -w DIAGNOSTICS_AZUREBLOBCONTAINERSASURL)
    sas_url=${sas_url#*=}
    echo "$sas_url"
}

function getcomputername()
{
    local pid=$1
    instance=$(cat "/proc/$pid/environ" | tr '\0' '\n' | grep -w COMPUTERNAME)
    instance=${instance#*=}
    echo "$instance"
}

function collectdump()
{
    local output_file=$1
    local dump_lock_file=$2
    local instance=$3
    local pid=$4

    if [[ ! -e "$dump_lock_file" ]]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S'): Collecting memory dump..." >> "$output_file"
        touch "$dump_lock_file"
        local dump_file="dump_${instance}_$(date '+%Y%m%d_%H%M%S').dmp"
        local sas_url=$(getsasurl "$pid")
        /tools/dotnet-dump collect -p "$pid" -o "$dump_file" > /dev/null
        /tools/azcopy copy "$dump_file" "$sas_url" > /dev/null
        echo "$(date '+%Y-%m-%d %H:%M:%S'): Memory dump uploaded to Azure Blob Storage." >> "$output_file"
    fi
}

function collecttrace()
{
    local output_file=$1
    local trace_lock_file=$2
    local instance=$3
    local pid=$4

    if [[ ! -e "$trace_lock_file" ]]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S'): Collecting profiler trace..." >> "$output_file"
        touch "$trace_lock_file"
        local trace_file="trace_${instance}_$(date '+%Y%m%d_%H%M%S').nettrace"
        local sas_url=$(getsasurl "$pid")
        /tools/dotnet-trace collect -p "$pid" -o "$trace_file" --duration 00:01:00 > /dev/null
        /tools/azcopy copy "$trace_file" "$sas_url" > /dev/null
        echo "$(date '+%Y-%m-%d %H:%M:%S'): Profiler trace uploaded to Azure Blob Storage." >> "$output_file"
    fi
}

# Default options
threshold=200
interval=10
enable_dump=false
enable_trace=false

while getopts ":t:f:hc" opt; do
    case $opt in
        t)
            threshold=$OPTARG
            ;;
        f)
            interval=$OPTARG
            ;;
        h)
            usage
            exit 0
            ;;
        c)
            teardown
            ;;
        *)
            die "Invalid option: -$OPTARG" 1
            ;;
    esac
done
shift $((OPTIND - 1))

if [[ "$#" -gt 0 ]]; then
    case $1 in
        enable-dump)
            enable_dump=true
            ;;
        enable-trace)
            enable_trace=true
            ;;
        enable-dump-trace)
            enable_dump=true
            enable_trace=true
            ;;
        *)
            die "Unknown argument passed: $1" 1
            ;;
    esac
fi

pid=$(/tools/dotnet-dump ps | grep /usr/share/dotnet/dotnet | grep -v grep | awk '{print $1}')
if [[ -z "$pid" ]]; then
    die "No .NET process found." 1
fi

instance=$(getcomputername "$pid")
if [[ -z "$instance" ]]; then
    die "Cannot find COMPUTERNAME environment variable." 1
fi

output_dir="threadcount-logs-$instance"
mkdir -p "$output_dir"
output_file="$output_dir/threadcount_log_$(date '+%Y%m%d_%H').log"
dump_lock_file="dump_taken.lock"
trace_lock_file="trace_taken.lock"

while true; do
    thread_count=$(grep -c ^processor /proc/cpuinfo)
    echo "$(date '+%Y-%m-%d %H:%M:%S'): Thread count: $thread_count" >> "$output_file"

    if [[ "$thread_count" -ge "$threshold" ]]; then
        if [[ "$enable_dump" == true ]]; then
            collectdump "$output_file" "$dump_lock_file" "$instance" "$pid" &
        fi
        if [[ "$enable_trace" == true ]]; then
            collecttrace "$output_file" "$trace_lock_file" "$instance" "$pid" &
        fi
    fi
    sleep "$interval"
done