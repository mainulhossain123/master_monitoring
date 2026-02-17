# Azure App Service .NET Core Diagnostics Master Monitoring Script

## Overview
The Master Monitoring Script provides a unified interface to monitor .NET Core applications running on Azure App Service (Linux). It offers four diagnostic monitoring types with automatic dump/trace collection capabilities and intelligent cleanup management.

## Features
- **Unified Interface**: Single entry point for all diagnostic monitoring types
- **Four Monitoring Types**:
  - **Thread Count Monitoring**: Monitor and alert on thread count thresholds
  - **Response Time Monitoring**: Monitor HTTP endpoint response times
  - **Outbound Connection Monitoring**: Track SNAT port exhaustion and connection issues
  - **Memory Usage Monitoring**: Monitor memory consumption as percentage of container limit
- **Duration-Based Monitoring**: Set time limits (1-48 hours) for automatic cleanup
- **Auto-Cleanup After Diagnostics**: Automatically stops monitoring after successful dump/trace uploads
- **Automatic Diagnostics Collection**: Collect memory dumps and/or profiler traces when thresholds are exceeded
- **Azure Blob Storage Integration**: Uploads diagnostics to Azure Blob Storage with retry logic
- **Instance-Specific Logging**: Separate logs per instance (useful for scaled-out scenarios)
- **Hourly Log Rotation**: Prevents log file size issues
- **Lock File Management**: Prevents duplicate diagnostics, automatically cleaned up for reusability

## Prerequisites
- .NET Core application running on Azure App Service (Linux)
- Azure App Service with Application Insights enabled (for diagnostics blob storage SAS URL)
- The following tools must be available on the App Service:
  - `/tools/dotnet-counters`
  - `/tools/dotnet-dump`
  - `/tools/dotnet-trace`
  - `/tools/azcopy`
  - `curl` (auto-installed if missing)
  - `bc` (auto-installed if missing for thread count and memory monitoring)
  - `netstat` (auto-installed if missing for connection monitoring)

## Usage

### Interactive Mode
```bash
./master_monitoring.sh
```
The script will prompt you to:
1. Select diagnostic type (1-4)
2. Enter threshold value
3. Enter URL (for response time monitoring only)
4. Select diagnostic collection options (dump/trace/both)
5. Enter monitoring duration in hours (1-48, default: 48)

### Non-Interactive Mode
```bash
./master_monitoring.sh -d <diagnostic_type> -t <threshold> [-D <duration>] [-l <URL>] [enable-dump|enable-trace|enable-dump-trace]
```

### Options
- `-d <diagnostic_type>`: Specify which diagnostic to run
  - `threadcount`: Monitor thread count
  - `responsetime`: Monitor HTTP response time
  - `outboundconnection`: Monitor outbound connections
  - `memory`: Monitor memory usage
- `-t <threshold>`: Threshold value (required)
  - Thread count: Number of threads (default: 100)
  - Response time: Milliseconds (default: 1000)
  - Outbound connections: Connection count (default: 100)
  - Memory: Percentage 0-100 (default: 80)
- `-D <duration>`: Monitoring duration in hours (1-48, default: 48)
- `-l <URL>`: URL to monitor (only for responsetime, default: http://localhost:80)
- `-c`: Cleanup mode - stops all running diagnostic processes
- `-h`: Display help message

### Diagnostic Collection Arguments
- `enable-dump`: Collect memory dump when threshold is exceeded
- `enable-trace`: Collect profiler trace when threshold is exceeded
- `enable-dump-trace`: Collect both memory dump and profiler trace

## Examples

### Example 1: Thread Count Monitoring (Interactive)
```bash
./master_monitoring.sh
# Select: 1 (threadcount)
# Enter threshold: 150
# Select: 3 (enable-dump-trace)
# Enter duration: 24
```

### Example 2: Memory Monitoring (Non-Interactive)
```bash
./master_monitoring.sh -d memory -t 85 -D 12 enable-dump-trace
```
Monitors memory usage and collects dump+trace when exceeding 85%, runs for 12 hours maximum.

### Example 3: Response Time Monitoring
```bash
./master_monitoring.sh -d responsetime -t 2000 -l http://localhost:8080/health -D 6 enable-dump
```
Monitors response time of `/health` endpoint and collects dump when exceeding 2000ms, runs for 6 hours.

### Example 4: Outbound Connection Monitoring
```bash
./master_monitoring.sh -d outboundconnection -t 200 -D 48 enable-dump-trace
```
Monitors outbound connections and collects diagnostics when exceeding 200 connections, runs for 48 hours.

### Example 5: Stop All Monitoring
```bash
./master_monitoring.sh -c
```

## How It Works

### Script Flow
1. **Selection**: User selects diagnostic type (interactive or via -d flag)
2. **Configuration**: User provides threshold, duration, and diagnostic options
3. **Download**: Script downloads the appropriate diagnostic script from GitHub
4. **Execution**: Launches the selected monitoring script in background with nohup
5. **Monitoring**: The diagnostic script continuously monitors the application
6. **Auto-Cleanup**: Script automatically stops when:
   - All enabled diagnostics (dump/trace) are collected and uploaded, OR
   - The specified duration (in hours) expires

### Automatic Cleanup Features
- **After Diagnostics**: Once all enabled diagnostics are successfully uploaded to Azure Blob Storage, the script automatically:
  - Stops the duration timer
  - Removes lock files (`dump_taken_*.lock`, `trace_taken_*.lock`)
  - Terminates all monitoring processes
  - Cleans up and exits

- **After Duration**: If the time limit is reached before diagnostics complete:
  - Removes lock files to allow future monitoring
  - Terminates all monitoring processes
  - Cleans up and exits

### Lock File Management
The scripts use lock files to prevent duplicate diagnostics:
- `dump_taken_<instance>.lock`: Prevents multiple dumps per instance
- `trace_taken_<instance>.lock`: Prevents multiple traces per instance

These lock files are **automatically removed** during cleanup, allowing you to run diagnostics multiple times without manual intervention.

## Output Files

### Log File Locations
Each diagnostic type creates its own log directory:
- Thread Count: `threadcount-logs-<instance>/`
- Response Time: `resptime-logs-<instance>/`
- Outbound Connections: `outconn-logs-<instance>/`
- Memory Usage: `memory-logs-<instance>/`

### Log File Format
Logs are rotated hourly with the format: `<diagnostic>_stats_YYYY-MM-DD_HH.log`

Example log entries:
```
2026-02-17 10:15:30: Thread count: 125 (threshold: 100)
2026-02-17 10:15:30: Thread count exceeded threshold
2026-02-17 10:15:30: Acquiring lock for dumping...
2026-02-17 10:15:30: Collecting memory dump...
2026-02-17 10:16:45: Memory dump has been successfully uploaded to Azure Blob Container.
2026-02-17 10:16:45: All enabled diagnostics have been collected and uploaded successfully.
2026-02-17 10:16:45: Stopping duration timer (PID: 12345)
2026-02-17 10:16:45: Initiating automatic cleanup...
```

### Diagnostic Artifacts
When threshold is exceeded:
- Memory dumps: `dump_<instance>_<timestamp>.dmp`
- Profiler traces: `trace_<instance>_<timestamp>.nettrace` (1 minute duration)

All artifacts are automatically uploaded to: `insights-logs-appserviceconsolelogs` blob container

## Diagnostic Script Details

### 1. Thread Count Monitoring (`netcore_threadcount_monitoring.sh`)
- **Metrics Monitored**: ThreadPool Thread Count from System.Runtime
- **Default Threshold**: 100 threads
- **Polling Interval**: 10 seconds (configurable with `-f`)
- **Use Case**: Detect thread pool exhaustion, deadlocks, or excessive async operations

### 2. Response Time Monitoring (`resp_monitoring.sh`)
- **Metrics Monitored**: HTTP response time via curl
- **Default Threshold**: 1000 milliseconds
- **Default URL**: http://localhost:80
- **Polling Interval**: 10 seconds (configurable with `-f`)
- **Use Case**: Detect slow responses, timeouts, or performance degradation

### 3. Outbound Connection Monitoring (`snat_connection_monitoring.sh`)
- **Metrics Monitored**: Outbound TCP connections via netstat
- **Default Threshold**: 100 connections
- **Polling Interval**: 10 seconds (configurable with `-f`)
- **Excludes**: Connections on ports 80, 443, 2222 (App Service infrastructure)
- **Use Case**: Detect SNAT port exhaustion, connection leaks, or excessive external calls

### 4. Memory Usage Monitoring (`memory_monitoring.sh`)
- **Metrics Monitored**: Working Set percentage of container memory limit
- **Default Threshold**: 80%
- **Memory Limit Detection**: Automatic from cgroups v1/v2
- **Polling Interval**: Real-time with dotnet-counters (5 second refresh)
- **Use Case**: Detect memory leaks, high GC pressure, or out-of-memory conditions

## Duration-Based Monitoring

The duration feature allows you to set a maximum runtime for monitoring sessions:

- **Range**: 1-48 hours
- **Default**: 48 hours
- **Behavior**: 
  - Script spawns a background timer process
  - When duration expires, automatic cleanup is triggered
  - If diagnostics complete first, timer is killed before expiry

This ensures monitoring doesn't run indefinitely and automatically cleans up resources.

## Troubleshooting

### Script Not Finding .NET Process
**Issue**: "There is no .NET process running"
**Solution**: Ensure your .NET Core application is running. Check with:
```bash
ps aux | grep dotnet
```

### SAS URL Not Found
**Issue**: "Cannot find SAS URL"
**Solution**: Ensure Application Insights is enabled on your App Service and the environment variable `DIAGNOSTICS_AZUREBLOBCONTAINERSASURL` is set.

### Lock Files Prevent New Diagnostics
**Solution**: Lock files are now automatically cleaned up. If you need to manually clean up:
```bash
./master_monitoring.sh -c
```

### Downloads Failed
**Issue**: Script can't download diagnostic scripts from GitHub
**Solution**: 
- Check network connectivity
- Verify GitHub URL is correct in script
- Check if curl is installed

### Duration Not Working
**Issue**: Script doesn't stop after duration
**Solution**: 
- Check if timer process is running: `ps aux | grep sleep`
- Verify duration was provided correctly (1-48 range)
- Check logs for timer start message

## Architecture

```
master_monitoring.sh (Unified Interface)
│
├── Downloads and executes one of:
│   ├── netcore_threadcount_monitoring.sh (Thread Count)
│   ├── resp_monitoring.sh (Response Time)
│   ├── snat_connection_monitoring.sh (Outbound Connections)
│   └── memory_monitoring.sh (Memory Usage)
│
└── Each diagnostic script:
    ├── Monitors specific metrics
    ├── Collects diagnostics when threshold exceeded
    ├── Uploads to Azure Blob Storage
    ├── Tracks completion with flags
    ├── Auto-cleanup when done or duration expires
    └── Removes lock files for reusability
```

## Best Practices

1. **Start with Default Thresholds**: Use default values initially, then adjust based on your application's baseline
2. **Enable Traces Over Dumps**: Traces are less intrusive and provide timeline information
3. **Set Realistic Durations**: Don't set very short durations if you expect threshold violations to be rare
4. **Monitor Logs Regularly**: Check hourly log files to understand patterns before issues occur
5. **Use in Staging First**: Test monitoring thresholds in non-production environments
6. **Combine Diagnostics**: Use `enable-dump-trace` to get both stack snapshots and timeline data

## GitHub Repository
- **Repository**: https://github.com/mainulhossain123/master_monitoring
- **Branch**: main
- **Scripts Auto-Downloaded From**: 
  - https://raw.githubusercontent.com/mainulhossain123/master_monitoring/refs/heads/main/

## Authors
- Mainul Hossain - https://github.com/mainulhossain123
- Anh Tuan Hoang - https://github.com/bkstar123

## Version History
- **v1.0** (July 2024): Initial release with thread count, response time, and outbound connection monitoring
- **v2.0** (February 2025): Added memory monitoring with percentage-based thresholds
- **v3.0** (February 2026): Added duration-based monitoring, auto-cleanup after diagnostics, improved lock file management

## License
For use within Azure App Service environments for diagnostic purposes.
