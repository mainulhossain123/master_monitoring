function collectdump()
{
    # $1-$output_file, $2-$dump_lock_file, $3-$instance, $4-$pid
    if [[ ! -e "$2" ]]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S'): Acquiring lock for dumping..." >> "$1" && touch "$2" && echo "Memory dump is collected by $3" >> "$2"
        echo "$(date '+%Y-%m-%d %H:%M:%S'): Collecting memory dump..." >> "$1"
        local dump_file="dump_$3_$(date '+%Y%m%d_%H%M%S').dmp"
        local sas_url="https://invalid.url" #$(getsasurl "$4")
        /tools/dotnet-dump collect -p "$4" -o "$dump_file" > /dev/null
        echo "$(date '+%Y-%m-%d %H:%M:%S'): Memory dump has been collected. Uploading it to Azure Blob Container 'insights-logs-appserviceconsolelogs'" >> "$1"

        # Initial attempt
        azcopy_output=$(/tools/azcopy copy "$dump_file" "$sas_url" 2>&1)
        if echo "$azcopy_output" | grep -q "Final Job Status: Completed"; then
            echo "$(date '+%Y-%m-%d %H:%M:%S'): Memory dump has been successfully uploaded to Azure Blob Container." >> "$1"
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
    if [[ ! -e "$2" ]]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S'): Acquiring lock for tracing..." >> "$1" && touch "$2" && echo "Profiler trace is collected by $3" >> "$2"
        echo "$(date '+%Y-%m-%d %H:%M:%S'): Collecting profiler trace..." >> "$1"
        local trace_file="trace_$3_$(date '+%Y%m%d_%H%M%S').nettrace"
        local sas_url="https://invalid.url" #$(getsasurl "$4")
        /tools/dotnet-trace collect -p "$4" -o "$trace_file" --duration 00:01:00 > /dev/null
        echo "$(date '+%Y-%m-%d %H:%M:%S'): Profiler trace has been collected. Uploading it to Azure Blob Container 'insights-logs-appserviceconsolelogs'" >> "$1"

        # Initial attempt
        azcopy_output=$(/tools/azcopy copy "$trace_file" "$sas_url" 2>&1)
        if echo "$azcopy_output" | grep -q "Final Job Status: Completed"; then
            echo "$(date '+%Y-%m-%d %H:%M:%S'): Profiler trace has been successfully uploaded to Azure Blob Container." >> "$1"
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
                return 0
            fi
            
            ((retry_count++))
        done

        # If we get here, all retries failed
        echo "$(date '+%Y-%m-%d %H:%M:%S'): ERROR: AzCopy failed to upload profiler trace after $max_retries attempts." >> "$1"
    fi
}
