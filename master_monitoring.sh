#!/bin/bash
#
# Combined Diagnostics Script for Thread Count, Response Time and Outbound Connections monitoring.
# Allows user to select which diagnostics to run and provides additional input as needed.
#
# Author: Mainul Hossain and Anh Tuan Hoang
# Date: 10 July 2024
# Updated: 28th July 2024

# Get the script's name
master_script_name=${0##*/}

# Usage function to display help
function usage() {
    echo "-------------------------------------------------------------------------------------------------------------------"
    echo "Syntax: $master_script_name -d <diagnostics> -t <threshold> [-l <URL>] [-c] [-h] [enable-trace | enable-dump | enable-dump-trace]"
    echo "-------------------------------------------------------------------------------------------------------------------"
    echo "-d <diagnostics> specifies which diagnostic to run. The diagnostics can be one of following:"
    echo "  - threadcount       :  Monitor thread count of a .NET core application"
    echo "  - responsetime      :  Monitor response time of a .NET core application"
    echo "  - outboundconnection:  Monitor outbound connections"
    echo "-------------------------------------------------------------------------------------------------------------------"
    echo "Other script options:"
    echo "  -t <threshold>:  Specify threshold (required for threadcount, outboundconnection and responsetime)"
    echo "  -l <URL>      :  Specify URL to monitor (default: http://localhost:80 for responsetime only)"
    echo "  -c            :  Shutting down the script and all relevant processes"
    echo "  -h            :  Display this help message"
    echo " For 'responsetime' diagnostic, the script will accept one of following arguments as optional:"
    echo "  + enable-dump        :  Enable memory dump collection"
    echo "  + enable-trace       :  Enable profiler trace collection"
    echo "  + enable-dump-trace  :  Enable both memdump and trace collection"
    echo " If no arguments passed in, then no memdump, no trace will be collected. The script will just monitor the response time"
    exit 0
}

# Parse arguments
while getopts ":d:t:l:ch" opt; do
    case $opt in
        d) DIAGNOSTIC=$OPTARG ;;
        t) THRESHOLD=$OPTARG ;;
        l) URL=$OPTARG ;;
        c) CLEANUP=true ;;
        h) usage ;;
        \?) echo "Invalid option -$OPTARG" >&2; usage ;;
        :) echo "Option -$OPTARG requires an argument." >&2; usage ;;
    esac
done
shift $((OPTIND - 1))

# Check if cleanup is requested
if [ "$CLEANUP" = true ]; then
    echo "Stopping all diagnostic scripts..."
    ./threadcount/netcore_threadcount_monitoring.sh -c 2>/dev/null
    ./responsetime/resp_monitoring.sh -c 2>/dev/null
    ./outboundconnection/snat_monitoring.sh -c 2>/dev/null
    kill -SIGTERM $(ps -ef | grep "$master_script_name" | grep -v grep | tr -s " " | cut -d" " -f2 | xargs)
    exit 0
fi

# Interactive input if no diagnostic type is provided
if [ -z "$DIAGNOSTIC" ]; then
    echo "Select diagnostic type:"
    echo "1. threadcount"
    echo "2. responsetime"
    echo "3. outboundconnection"
    read -p "Enter choice [1-3]: " diag_choice

    case $diag_choice in
        1) DIAGNOSTIC="threadcount" ;;
        2) DIAGNOSTIC="responsetime" ;;
        3) DIAGNOSTIC="outboundconnection" ;;
        *) echo "Invalid choice." ; exit 1 ;;
    esac
fi

if [ -z "$THRESHOLD" ]; then
    read -p "Enter threshold: " THRESHOLD
fi

if [ "$DIAGNOSTIC" == "responsetime" ] && [ -z "$URL" ]; then
    read -p "Enter URL to monitor (default: http://localhost:80): " URL
    URL=${URL:-http://localhost:80}
fi

# Handle additional options for responsetime
if [ "$DIAGNOSTIC" == "responsetime" ]; then
    if [ -z "$1" ]; then
        echo "Enable additional options for responsetime (default: none):"
        echo "1. enable-dump"
        echo "2. enable-trace"
        echo "3. enable-dump-trace"
        echo "4. none"
        read -p "Enter choice [1-4]: " resp_choice

        case $resp_choice in
            1) RESP_OPTION="enable-dump" ;;
            2) RESP_OPTION="enable-trace" ;;
            3) RESP_OPTION="enable-dump-trace" ;;
            4) RESP_OPTION="" ;;
            *) echo "Invalid choice." ; exit 1 ;;
        esac
    else
        while (( "$#" )); do
            if [ "$1" == "enable-dump" ]; then
                RESP_OPTION="enable-dump"
            elif [ "$1" == "enable-trace" ]; then
                RESP_OPTION="enable-trace"
            elif [ "$1" == "enable-dump-trace" ]; then
                RESP_OPTION="enable-dump-trace"
            fi
            shift
        done
    fi
fi

# Define URLs for the diagnostic scripts
THREADCOUNT_SCRIPT_URL="https://github.com/bkstar123/netcore_counters_monitoring/raw/master/netcore_threadcount_monitoring.sh"
RESPONSETIME_SCRIPT_URL="https://github.com/bkstar123/http_response_time_monitoring/raw/master/resp_monitoring.sh"
OUTBOUND_CONNECTION_COUNT_SCRIPT_URL="https://github.com/bkstar123/outbound_connection_monitoring/raw/master/outbound_connection_count.sh"
SNAT_MONITORING_SCRIPT_URL="https://github.com/bkstar123/outbound_connection_monitoring/raw/master/snat_monitoring.sh"

# Check if wget is installed, if not install it
if ! command -v wget &> /dev/null; then
    echo "wget could not be found, installing it now..."
    apt-get update && apt-get install -y wget &> /dev/null
    if [ $? -ne 0 ]; then
        echo "Failed to install wget. Please install it manually and rerun the script."
        exit 1
    fi
    echo "wget has been successfully installed"
fi

# Function to download and execute the diagnostic scripts
function run_diagnostic_script() {
    local folder_name=$1
    shift
    local script_urls=("$@")

    # Create folder and navigate to it
    mkdir -p ./$folder_name
    cd ./$folder_name

    # Download the scripts if not already downloaded
    for script_url in "${script_urls[@]}"; do
        local diagnostic_script_name=$(basename $script_url)
        if [ ! -f $diagnostic_script_name ]; then
            echo "Downloading $diagnostic_script_name..."
            wget $script_url -O $diagnostic_script_name &> /dev/null
            if [ $? -ne 0 ]; then
                echo "Failed to download the dependent script at $script_url"
                exit 1
            fi
            chmod +x $diagnostic_script_name
        fi
    done

    # Run the first script with the constructed arguments
    nohup ./${script_urls[0]##*/} "${cmd_args[@]}" &
}

# Initialize command arguments
cmd_args=("-t $THRESHOLD")

# Build command arguments based on diagnostic type
case $DIAGNOSTIC in
    threadcount)
        run_diagnostic_script "threadcount" $THREADCOUNT_SCRIPT_URL
        ;;
    responsetime)
        if [ -n "$URL" ]; then
            cmd_args+=("-l $URL")
        else
            cmd_args+=("-l http://localhost:80")
        fi

        if [ -n "$RESP_OPTION" ]; then
            cmd_args+=("$RESP_OPTION")
        fi

        run_diagnostic_script "responsetime" $RESPONSETIME_SCRIPT_URL
        ;;
    outboundconnection)
        run_diagnostic_script "outboundconnection" $SNAT_MONITORING_SCRIPT_URL $OUTBOUND_CONNECTION_COUNT_SCRIPT_URL
        ;;
    *)
        echo "Invalid diagnostic type: $DIAGNOSTIC"
        usage
        ;;
esac

echo "Diagnostic script execution initiated."

# To stop script
# ./master.sh -c 
