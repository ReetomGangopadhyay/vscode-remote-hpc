#!/bin/bash

# SGE qsub resource presets.
#
# Defaults are intentionally short-running because the job continues running after you
# disconnect from VS Code. Adjust as needed for your cluster.
#
# Add more presets by defining variables named QSUB_PARAM_<PROFILE>, e.g.
#   QSUB_PARAM_CPU_4="..."
#   QSUB_PARAM_CPU_28="..."
#
# Use the profile name as the argument to this script in your ProxyCommand:
#   ProxyCommand ssh HPC-LOGIN "~/bin/vscode-remote-sge cpu_4"
#
# NOTE (BU SCC): job names are truncated in `qstat` (vscode-remote-* -> vscode-rem),
# so this script uses `qstat -j` to recover the full job name.
QSUB_PARAM_CPU="-pe omp 1   -l h_rt=04:00:00"
QSUB_PARAM_GPU="-pe omp 4   -l gpus=1,gpu_c=6.0 -l h_rt=04:00:00"

# The time you expect a job to start in (seconds)
# If a job doesn't start within this time, the script will exit and cancel the pending job
TIMEOUT=1800


####################
# don't edit below this line
####################

function usage ()
{
    echo "Usage :  $0 [command|profile]

    General commands:
    list      List running vscode-remote jobs
    cancel    Cancels all running vscode-remote jobs
    ssh       SSH into the node of a running job
    help      Display this message

    Job profiles:
    Any argument that is not a general command is treated as a job profile.
    Profiles are defined by variables named QSUB_PARAM_<PROFILE> at the top of this file.

    Built-in defaults:
    cpu       Connect to a CPU node   (QSUB_PARAM_CPU)
    gpu       Connect to a GPU node   (QSUB_PARAM_GPU)

    Examples:
        Host vscode-remote-sge-cpu
            User USERNAME
            IdentityFile ~/.ssh/vscode-remote-sge
            ProxyCommand ssh HPC-LOGIN \"~/bin/vscode-remote-sge cpu\"
            StrictHostKeyChecking no

        Host vscode-remote-sge-cpu4
            User USERNAME
            IdentityFile ~/.ssh/vscode-remote-sge
            ProxyCommand ssh HPC-LOGIN \"~/bin/vscode-remote-sge cpu_4\"
            StrictHostKeyChecking no

    "
}

function query_sge () {
    # qstat truncates long names (vscode-remote-* becomes vscode-rem),
    # so match the truncated prefix and then confirm full name via qstat -j.
    local prefix="${1:-$JOB_NAME}"

    job_info=""
    JOB_FULLNAME=""

    while read -r line; do
      jid="$(echo "$line" | awk '{print $1}')"
      full="$(qstat -j "$jid" 2>/dev/null | awk -F: '/job_name:/ {gsub(/^[ 	]+/,"",$2); print $2; exit}')"
      if [[ "$full" == "$prefix"* ]]; then
        job_info="$line"
        JOB_FULLNAME="$full"
        break
      fi
    done < <(qstat -u "$USER" 2>/dev/null | awk '$3 ~ /^vscode-rem/ {print}')

    if [ ! -z "$job_info" ]; then
        # Parse qstat output to extract job ID, state, and queue instance
        JOB_ID=$(echo "$job_info" | awk '{print $1}')
        JOB_STATE=$(echo "$job_info" | awk '{print $5}')
        JOB_QUEUE_INSTANCE=$(echo "$job_info" | awk '{print $8}')

        # Extract port from full job name (format: vscode-remote-<profile>-PORT)
        JOB_PORT=$(echo "$JOB_FULLNAME" | rev | cut -d'-' -f1 | rev)

        # Convert queue instance like "p-int@scc-pi4.scc.bu.edu" -> "scc-pi4.scc.bu.edu"
        # If not yet assigned (no '@'), leave JOB_NODE empty
        case "$JOB_QUEUE_INSTANCE" in
            *@*) JOB_NODE="${JOB_QUEUE_INSTANCE##*@}" ;;
            *)   JOB_NODE="" ;;
        esac

        >&2 echo "Job is $JOB_STATE ( id: $JOB_ID, name: $JOB_FULLNAME${JOB_NODE:+, node: $JOB_NODE} )"
    else
        JOB_ID=""
        JOB_FULLNAME=""
        JOB_STATE=""
        JOB_QUEUE_INSTANCE=""
        JOB_NODE=""
        JOB_PORT=""
    fi
}

function cleanup () {
    if [ ! -z "${JOB_SUBMIT_ID:-}" ]; then
        qdel "$JOB_SUBMIT_ID" 2>/dev/null
        >&2 echo "Cancelled pending job $JOB_SUBMIT_ID"
    fi
}

function timeout () {
    if (( $(date +%s)-START > TIMEOUT )); then
        >&2 echo "Timeout, exiting..."
        cleanup
        exit 1
    fi
}



function list_profiles () {
    # List available QSUB_PARAM_* presets, printed as profile names (lowercase)
    compgen -A variable QSUB_PARAM_ | sed 's/^QSUB_PARAM_//' | tr '[:upper:]' '[:lower:]'
}

function resolve_profile () {
    PROFILE_RAW="$1"
    # Map profile to variable key: cpu-4 -> CPU_4, cpu_4 -> CPU_4
    PROFILE_KEY="$(echo "$PROFILE_RAW" | tr '[:lower:]-' '[:upper:]_')"
    QSUB_VAR="QSUB_PARAM_${PROFILE_KEY}"
    QSUB_PARAM="${!QSUB_VAR:-}"

    if [ -z "$QSUB_PARAM" ]; then
        >&2 echo "Unknown profile '$PROFILE_RAW' (expected variable $QSUB_VAR)."
        >&2 echo "Available profiles:"
        list_profiles | sed 's/^/  - /' >&2
        exit 1
    fi
}

function collect_jobs () {
    # Collect (jid, full_name, state, node, port) for jobs with name starting with "$1"
    local prefix="$1"
    JOB_ROWS=()

    while read -r line; do
      jid="$(echo "$line" | awk '{print $1}')"
      state="$(echo "$line" | awk '{print $5}')"
      queueinst="$(echo "$line" | awk '{print $8}')"
      full="$(qstat -j "$jid" 2>/dev/null | awk -F: '/job_name:/ {gsub(/^[ \t]+/,"",$2); print $2; exit}')"
      if [[ "$full" == "$prefix"* ]]; then
        port="$(echo "$full" | rev | cut -d'-' -f1 | rev)"
        case "$queueinst" in
            *@*) node="${queueinst##*@}" ;;
            *)   node="" ;;
        esac
        JOB_ROWS+=("$jid|$full|$state|$node|$port")
      fi
    done < <(qstat -u "$USER" 2>/dev/null | awk '$3 ~ /^vscode-rem/ {print}')
}

function cancel () {
    # Cancel all running/pending vscode-remote jobs (any profile)
    while true; do
        collect_jobs "${JOB_NAME}-"
        if [ ${#JOB_ROWS[@]} -eq 0 ]; then
            break
        fi
        for row in "${JOB_ROWS[@]}"; do
            jid="$(echo "$row" | cut -d'|' -f1)"
            full="$(echo "$row" | cut -d'|' -f2)"
            node="$(echo "$row" | cut -d'|' -f4)"
            echo "Cancelling job $jid (${full}${node:+ on $node})"
            qdel "$jid" 2>/dev/null
        done
        timeout
        sleep 2
    done
}

function list () {
    qstat -u "$USER" 2>/dev/null | awk 'NR==1 || $3 ~ /^vscode-rem/ {print}'
}

function ssh_connect () {
    # SSH into the node of a running vscode-remote job (any profile)
    collect_jobs "${JOB_NAME}-"

    if [ ${#JOB_ROWS[@]} -eq 0 ]; then
        echo "No running job found"
        exit 1
    fi

    if [ ${#JOB_ROWS[@]} -gt 1 ]; then
        echo "Multiple jobs found, please choose:"
        i=1
        for row in "${JOB_ROWS[@]}"; do
            full="$(echo "$row" | cut -d'|' -f2)"
            state="$(echo "$row" | cut -d'|' -f3)"
            node="$(echo "$row" | cut -d'|' -f4)"
            port="$(echo "$row" | cut -d'|' -f5)"
            printf "%d) %s (state: %s%s%s)
" "$i" "$full" "$state" "${node:+, node: }" "${node:-}"
            i=$((i+1))
        done
        read -p "Enter a number: " choice
        if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt ${#JOB_ROWS[@]} ]; then
            echo "Invalid choice"
            exit 1
        fi
        row="${JOB_ROWS[$((choice-1))]}"
    else
        row="${JOB_ROWS[0]}"
    fi

    node="$(echo "$row" | cut -d'|' -f4)"
    port="$(echo "$row" | cut -d'|' -f5)"
    full="$(echo "$row" | cut -d'|' -f2)"

    if [ -z "$node" ] || [ -z "$port" ]; then
        echo "Selected job is not yet running on a node (name: $full)"
        exit 1
    fi

    echo "Connecting to $node:$port via SSH"
    ssh -p "$port" "$node"
}

function connect_profile () {
    local profile="$1"
    resolve_profile "$profile"
    local job_prefix="${JOB_NAME}-${profile}"

    query_sge "$job_prefix"

    if [ -z "${JOB_STATE}" ]; then
        PORT=$(shuf -i 10000-65000 -n 1)
        # Submit job with qsub, capture job ID from output
        submit_output=$(qsub -N "$job_prefix-$PORT" $QSUB_PARAM "$SCRIPT_DIR/vscode-remote-job-sge.sh" "$PORT" 2>&1)
        JOB_SUBMIT_ID=$(echo "$submit_output" | grep -oE '[0-9]+' | head -1)
        >&2 echo "Submitted new $job_prefix job (id: $JOB_SUBMIT_ID)"
    fi

    while [ ! "$JOB_STATE" == "r" ]; do
        timeout
        sleep 5
        query_sge "$job_prefix"
    done

    >&2 echo "Connecting to $JOB_NODE"

    while ! nc -z "$JOB_NODE" "$JOB_PORT"; do
        timeout
        sleep 1
    done

    nc "$JOB_NODE" "$JOB_PORT"
}

if [ ! -z "${1:-}" ]; then
    JOB_NAME=vscode-remote
    SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
    START=$(date +%s)
    trap "cleanup && exit 1" INT TERM
    case $1 in
        list)   list ;;
        cancel) cancel ;;
        ssh)    ssh_connect ;;
        help)   usage ;;
        *)      connect_profile "$1" ;;
    esac
    exit 0
else
    usage
    exit 0
fi
