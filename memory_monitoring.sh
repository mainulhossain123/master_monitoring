#!/bin/bash
#
# This script is for monitoring the memory usage of a .NET core application.
# If the memory usage exceeds a predefined threshold, then the script will automatically generate a memory dump and/or profiler trace for investigation.
#
# author: Mainul Hossain
# Created: 16 Feb 2026

script_name=${0##*/}

function usage()
{
    echo "###Syntax: $script_name -t <threshold> -d <duration> [enable-dump|enable-trace|enable-dump-trace]"
    echo "- Without specifying -t <threshold>, the default will be 80%."
    echo "###Threshold: when the memory usage percentage exceeds the threshold value (0-100), the script will automatically take a memory dump and/or trace for that instance."
    echo "- The percentage is calculated based on Working Set vs container memory limit."
    echo "-d <duration>: Optional - specify monitoring duration in hours. Script will auto-cleanup after this time or after collecting diagnostics."
}

function die()
{
    echo "$1" && exit $2
}

function teardown()
{
    echo "Shutting down dotnet-counters collect process..."
    kill -SIGTERM $(ps -ef | grep "/tools/dotnet-counters" | grep -v grep | tr -s " " | cut -d" " -f2 | xargs)
    echo "Shutting down 'dotnet-trace collect' process..."
    kill -SIGTERM $(ps -ef | grep "/tools/dotnet-trace" | grep -v grep | tr -s " " | cut -d" " -f2 | xargs)
    echo "Shutting down 'dotnet-dump collect' process..."
    kill -SIGTERM $(ps -ef | grep "/tools/dotnet-dump" | grep -v grep | tr -s " " | cut -d" " -f2 | xargs)
    echo "Shutting down 'azcopy copy' process..."
    kill -SIGTERM $(ps -ef | grep "/tools/azcopy" | grep -v grep | tr -s " " | cut -d" " -f2 | xargs)
    echo "Shutting down $script_name process..."
    kill -SIGTERM $(ps -ef | grep "$script_name" | grep -v grep | tr -s " " | cut -d" " -f2 | xargs)
    echo "Removing lock files..."
    rm -f dump_taken_*.lock trace_taken_*.lock dump_completed_*.lock trace_completed_*.lock
    echo "Finishing up..."
    echo "Completed"
    exit 0
}

function getcomputername()
{
    # $1-pid
    instance=$(cat "/proc/$1/environ" | tr '\0' '\n' | grep -w COMPUTERNAME)
    instance=${instance#*=}
    echo "$instance"
}

function getsasurl()
{
    # $1-pid
    sas_url=$(cat "/proc/$1/environ" | tr '\0' '\n' | grep -w DIAGNOSTICS_AZUREBLOBCONTAINERSASURL)
    sas_url=${sas_url#*=}
    echo "$sas_url"
}

function collectdump()
{
    # $1-$output_file, $2-$dump_lock_file, $3-$instance, $4-$pid
    local instance_lock_file="dump_taken_${3}.lock"
    if [[ ! -e "$instance_lock_file" ]]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S'): Acquiring lock for dumping..." >> "$1" && touch "$instance_lock_file" && echo "Memory dump is collected by $3" >> "$instance_lock_file"
        echo "$(date '+%Y-%m-%d %H:%M:%S'): Collecting memory dump..." >> "$1"
        local dump_file="dump_$3_$(date '+%Y%m%d_%H%M%S').dmp"
        local sas_url=$(getsasurl "$4")
        /tools/dotnet-dump collect -p "$4" -o "$dump_file" > /dev/null
        echo "$(date '+%Y-%m-%d %H:%M:%S'): Memory dump has been collected. Uploading it to Azure Blob Container 'insights-logs-appserviceconsolelogs'" >> "$1"

        # Initial attempt
        azcopy_output=$(/tools/azcopy copy "$dump_file" "$sas_url" 2>&1)
        if echo "$azcopy_output" | grep -q "Final Job Status: Completed"; then
            echo "$(date '+%Y-%m-%d %H:%M:%S'): Memory dump has been successfully uploaded to Azure Blob Container." >> "$1"
            touch "dump_completed_${3}.lock"
            check_and_cleanup "$1" "$3"
            return 0
        fi

        # If initial attempt fails, start retry logic
        local retry_count=1
        local max_retries=5
        
        while [[ $retry_count -le $max_retries ]]; do
            echo "$(date '+%Y-%m-%d %H:%M:%S'): AzCopy failed to upload memory dump. Retrying... (Attempt $retry_count/$max_retries)" >> "$1"
            sleep 5
            
            azcopy_output=$(/tools/azcopy copy "$dump_file" "$sas_url" 2>&1)
            if echo "$azcopy_output" | grep -q "Final Job Status: Completed"; then
                echo "$(date '+%Y-%m-%d %H:%M:%S'): Memory dump has been successfully uploaded to Azure Blob Container." >> "$1"
                touch "dump_completed_${3}.lock"
                check_and_cleanup "$1" "$3"
                return 0
            fi
            
            ((retry_count++))
        done

        # If we get here, all retries failed
        echo "$(date '+%Y-%m-%d %H:%M:%S'): ERROR: AzCopy failed to upload memory dump after $max_retries attempts." >> "$1"
    fi
}

function collecttrace()
{
    # $1-$output_file, $2-$trace_lock_file, $3-$instance, $4-$pid
    local instance_lock_file="trace_taken_${3}.lock"
    if [[ ! -e "$instance_lock_file" ]]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S'): Acquiring lock for tracing..." >> "$1" && touch "$instance_lock_file" && echo "Profiler trace is collected by $3" >> "$instance_lock_file"
        echo "$(date '+%Y-%m-%d %H:%M:%S'): Collecting profiler trace..." >> "$1"
        local trace_file="trace_$3_$(date '+%Y%m%d_%H%M%S').nettrace"
        local sas_url=$(getsasurl "$4")
        /tools/dotnet-trace collect -p "$4" -o "$trace_file" --duration 00:01:00 > /dev/null
        echo "$(date '+%Y-%m-%d %H:%M:%S'): Profiler trace has been collected. Uploading it to Azure Blob Container 'insights-logs-appserviceconsolelogs'" >> "$1"

        # Initial attempt
        azcopy_output=$(/tools/azcopy copy "$trace_file" "$sas_url" 2>&1)
        if echo "$azcopy_output" | grep -q "Final Job Status: Completed"; then
            echo "$(date '+%Y-%m-%d %H:%M:%S'): Profiler trace has been successfully uploaded to Azure Blob Container." >> "$1"
            touch "trace_completed_${3}.lock"
            check_and_cleanup "$1" "$3"
            return 0
        fi

        # If initial attempt fails, start retry logic
        local retry_count=1
        local max_retries=5
        
        while [[ $retry_count -le $max_retries ]]; do
            echo "$(date '+%Y-%m-%d %H:%M:%S'): AzCopy failed to upload profiler trace. Retrying... (Attempt $retry_count/$max_retries)" >> "$1"
            sleep 5
            
            azcopy_output=$(/tools/azcopy copy "$trace_file" "$sas_url" 2>&1)
            if echo "$azcopy_output" | grep -q "Final Job Status: Completed"; then
                echo "$(date '+%Y-%m-%d %H:%M:%S'): Profiler trace has been successfully uploaded to Azure Blob Container." >> "$1"
                touch "trace_completed_${3}.lock"
                check_and_cleanup "$1" "$3"
                return 0
            fi
            
            ((retry_count++))
        done

        # If we get here, all retries failed
        echo "$(date '+%Y-%m-%d %H:%M:%S'): ERROR: AzCopy failed to upload profiler trace after $max_retries attempts." >> "$1"
    fi
}

function check_and_cleanup()
{
    # $1-$output_file, $2-$instance
    local all_complete=true
    
    # Check if all enabled diagnostics are complete
    if [[ "$enable_dump" == true ]] && [[ ! -e "dump_completed_${2}.lock" ]]; then
        all_complete=false
    fi
    
    if [[ "$enable_trace" == true ]] && [[ ! -e "trace_completed_${2}.lock" ]]; then
        all_complete=false
    fi
    
    # If all enabled diagnostics are complete, initiate cleanup
    if [[ "$all_complete" == true ]]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S'): All diagnostics collected and uploaded successfully. Initiating automatic cleanup..." >> "$1"
        # Kill the timer process if it exists
        if [[ -n "$timer_pid" ]]; then
            kill "$timer_pid" 2>/dev/null
        fi
        sleep 2
        teardown
    fi
}

while getopts ":t:d:hc" opt; do
    case $opt in
        t)
           threshold=$OPTARG
           ;;
        d)
           duration=$OPTARG
           ;;
        h)
           usage
           exit 0
           ;;
        c)
           clean_flag=1
           ;;
        *)
           die "Invalid option: -$OPTARG" 1
           ;;
    esac
done
shift $(( OPTIND - 1 ))

# Cleaning all processes generated by the script
if [[ "$clean_flag" -eq 1 ]]; then
    teardown
fi

# Define default threshold value for memory usage percentage
if [[ -z "$threshold" ]]; then
    echo "###Info: If not specify the option -t <threshold>, the script will set the default threshold of memory usage to 80%"
    threshold=80
fi

# Validate threshold is between 0-100
if [[ "$threshold" -lt 0 ]] || [[ "$threshold" -gt 100 ]]; then
    die "Threshold must be between 0 and 100 (percentage)" 1
fi

# Initialize dump and trace flags
enable_dump=false
enable_trace=false
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

# Validate if bc is installed (needed for floating point comparisons)
if ! command -v bc &> /dev/null; then
    echo "###Info: bc is not installed. Installing bc...."
    apt-get update && apt-get install -y bc
fi

# Find the PID of the .NET application
pid=$(/tools/dotnet-dump ps | grep /usr/share/dotnet/dotnet | grep -v grep | tr -s " " | cut -d" " -f2)
if [ -z "$pid" ]; then
    die "There is no .NET process running" 1
fi

# Get the computer name from /proc/PID/environ, where PID is .net core process's pid
instance=$(getcomputername "$pid")
if [[ -z "$instance" ]]; then
    die "Cannot find the environment variable of COMPUTERNAME" >&2 1
fi

# Output dir is named after instance name
output_dir="memory-logs-$instance"
# Create output directory if it doesn't exist
mkdir -p "$output_dir"

# Start duration timer if specified
timer_pid=""
if [[ -n "$duration" ]] && [[ "$duration" -gt 0 ]]; then
    duration_seconds=$((duration * 3600))
    echo "###Info: Monitoring will run for $duration hour(s) and then auto-cleanup"
    (
        sleep "$duration_seconds"
        current_hour=$(date +"%Y-%m-%d_%H")
        log_file="$output_dir/memory_usage_${current_hour}.log"
        echo "$(date '+%Y-%m-%d %H:%M:%S'): Monitoring duration of $duration hour(s) elapsed. Threshold was not exceeded within the time frame. Initiating automatic cleanup..." >> "$log_file"
        teardown
    ) &
    timer_pid=$!
    echo "###Info: Timer started (PID: $timer_pid) - will cleanup after $duration hour(s)"
fi

# Get container memory limit from cgroups
# Try cgroups v2 first, then v1
memory_limit=""

if [[ -f "/sys/fs/cgroup/memory.max" ]]; then
    memory_limit=$(cat /sys/fs/cgroup/memory.max 2>/dev/null)
    # memory.max returns "max" for unlimited, fall back to system memory
    if [[ "$memory_limit" == "max" ]] || [[ -z "$memory_limit" ]]; then
        memory_limit=""
    fi
fi

if [[ -z "$memory_limit" ]] && [[ -f "/sys/fs/cgroup/memory/memory.limit_in_bytes" ]]; then
    memory_limit=$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes 2>/dev/null)
    # Check if value is very large (indicates no limit) using awk which handles scientific notation
    if [[ -n "$memory_limit" ]]; then
        is_large=$(echo "$memory_limit" | awk '{if ($1 > 9000000000000000) print "1"; else print "0"}')
        if [[ "$is_large" == "1" ]]; then
            memory_limit=""
        fi
    fi
fi

# Fallback to total system memory if no cgroup limit found
if [[ -z "$memory_limit" ]]; then
    memory_limit=$(grep MemTotal /proc/meminfo | awk '{print $2 * 1024}')
fi

# Convert to MB using awk which handles scientific notation properly
memory_limit_mb=$(echo "$memory_limit" | awk '{printf "%.0f", $1 / 1024 / 1024}')

# Validate we have a reasonable value
if [[ -z "$memory_limit_mb" ]] || [[ "$memory_limit_mb" -le 0 ]]; then
    die "Failed to detect container memory limit. Cannot proceed with percentage-based monitoring." 1
fi

echo "###Info: Container memory limit detected: $memory_limit_mb MB"

# Output dir is named after instance name
output_dir="memory-logs-$instance"
# Create output directory if it doesn't exist
mkdir -p "$output_dir"

# Name of the lock files for generating memdump and trace (now instance-specific)
dump_lock_file="dump_taken_${instance}.lock"
trace_lock_file="trace_taken_${instance}.lock"
# Name of the file storing output of dotnet-counters collect
runtime_counter_log_file="dotnet-memory-metrics-$instance.csv"

# Collect the .NET process' runtime metrics by starting the dotnet-counters collect command in background
/tools/dotnet-counters collect --process-id "$pid" --counters System.Runtime --output "$runtime_counter_log_file" > /dev/null &

# Wait until the dotnet-counters collect start writing its collected data to the output file
while [[ ! -e "$runtime_counter_log_file" ]]; do
   sleep 1
done

# Function to truncate collected metric data file
function trunc() {
    MAX_SIZE=$(( 1*1024*1024 )) # 1 MB
    while [[ -f "$1" ]]; do
        file_size=$(stat -c%s "$1")
        if [[ "$file_size" -ge "$MAX_SIZE" ]]; then
            #truncate the file
            truncate -s 0 "$1"
        fi
    done
}

# Start monitoring
if [[ -e "$runtime_counter_log_file" ]]; then
    # Start a thread to monitor the size of $runtime_counter_log_file & truncate it
    trunc "$runtime_counter_log_file" &
    
    # Reading metric data in $runtime_counter_log_file to extract memory information
    tail -f "$runtime_counter_log_file" | while read -r line; do
        # Check if it's a new hour for rotating logs
        current_hour=$(date +"%Y-%m-%d_%H")
        if [ "$current_hour" != "$previous_hour" ]; then
            # Rotate the file
            output_file="$output_dir/memory_usage_${current_hour}.log"
            previous_hour="$current_hour"
        fi
        
        # Monitor GC Heap Size (MB)
        if [[ $line == *"GC Heap Size"* ]]; then
            gc_heap_size=$(echo "$line" | awk -F ',' '{print $NF}')
            timestamp=$(echo "$line" | awk -F ',' '{print $1}')
            # Calculate percentage with bc and handle errors
            gc_heap_percentage=$(echo "scale=2; $gc_heap_size * 100 / $memory_limit_mb" | bc 2>/dev/null || echo "0")
            echo "$timestamp: GC Heap Size: $gc_heap_size MB (${gc_heap_percentage}%)" >> "$output_file"
        fi
        
        # Monitor Working Set (MB) - this is the primary metric for percentage calculation
        if [[ $line == *"Working Set"* ]]; then
            working_set=$(echo "$line" | awk -F ',' '{print $NF}')
            timestamp=$(echo "$line" | awk -F ',' '{print $1}')
            
            # Calculate memory percentage based on Working Set with bc and handle errors
            memory_percentage=$(echo "scale=2; $working_set * 100 / $memory_limit_mb" | bc 2>/dev/null || echo "0")
            
            echo "$timestamp: Working Set: $working_set MB (${memory_percentage}% of ${memory_limit_mb} MB limit)" >> "$output_file"
            
            # Compare with the threshold percentage and collect dump/trace if exceeded
            # Using bc for floating point comparison
            if (( $(echo "$memory_percentage >= $threshold" | bc -l 2>/dev/null || echo "0") )); then
                echo "$timestamp: Memory usage (${memory_percentage}%) exceeded threshold (${threshold}%)" >> "$output_file"
                
                if [[ "$enable_dump" == true ]]; then
                    collectdump "$output_file" "$dump_lock_file" "$instance" "$pid" &
                fi
                
                if [[ "$enable_trace" == true ]]; then
                    collecttrace "$output_file" "$trace_lock_file" "$instance" "$pid" &
                fi
            fi
        fi
    done
fi
