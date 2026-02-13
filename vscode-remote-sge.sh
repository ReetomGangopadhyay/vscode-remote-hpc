#!/bin/bash

# Set your SGE parameters for GPU and CPU jobs here
# Example: "-l mem=32G,cpu=1" or "-l gpu=1,mem=32G"
# NOTE (BU SCC): job names are truncated in `qstat` (vscode-remote-* -> vscode-rem),
# so this script uses `qstat -j` to recover the full job name.
QSUB_PARAM_CPU="-pe smp 4 -l mem_free=16G -l h_rt=12:00:00"
QSUB_PARAM_GPU="-pe smp 4 -l mem_free=16G -l h_rt=04:00:00"

# The time you expect a job to start in (seconds)
# If a job doesn't start within this time, the script will exit and cancel the pending job
TIMEOUT=1800


####################
# don't edit below this line
####################

function usage ()
{
    echo "Usage :  $0 [command]

    General commands:
    list      List running vscode-remote jobs
    cancel    Cancels running vscode-remote jobs
    ssh       SSH into the node of a running job
    help      Display this message

    Job commands (see usage below):
    cpu       Connect to a CPU node
    gpu       Connect to a GPU node

    You should _NOT_ manually call the script with 'cpu' or 'gpu' commands.
    They should be used in the ProxyCommand in your ~/.ssh/config file, for example:
        Host vscode-remote-cpu
            User USERNAME
            IdentityFile ~/.ssh/vscode-remote
            ProxyCommand ssh HPC-LOGIN \"~/bin/vscode-remote-sge cpu\"
            StrictHostKeyChecking no

    You can have a CPU and GPU job running at the same time, just add them as separate hosts in your config.
    "
}

function query_sge () {
    # qstat truncates long names (vscode-remote-* becomes vscode-rem),
    # so match the truncated prefix and then confirm full name via qstat -j.
    job_info=""
    JOB_FULLNAME=""

    while read -r line; do
      jid="$(echo "$line" | awk '{print $1}')"
      full="$(qstat -j "$jid" 2>/dev/null | awk -F: '/job_name:/ {gsub(/^[ \t]+/,"",$2); print $2; exit}')"
      if [[ "$full" == "$JOB_NAME"* ]]; then
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

        # Extract port from full job name (format: vscode-remote-cpu-PORT or vscode-remote-gpu-PORT)
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

function cancel () {
    query_sge > /dev/null 2>&1
    while [ ! -z "${JOB_ID}" ]; do
        echo "Cancelling running job $JOB_ID on ${JOB_NODE:-unknown}"
        qdel "$JOB_ID"
        timeout
        sleep 2
        query_sge > /dev/null 2>&1
    done
}

function list () {
    qstat -u "$USER" 2>/dev/null | awk 'NR==1 || $3 ~ /^vscode-rem/ {print}'
}

function ssh_connect () {
    ROOT_NAME=$JOB_NAME

    JOB_NAME=$ROOT_NAME-cpu
    query_sge
    CPU_NODE=$JOB_NODE
    CPU_PORT=$JOB_PORT

    JOB_NAME=$ROOT_NAME-gpu
    query_sge
    GPU_NODE=$JOB_NODE
    GPU_PORT=$JOB_PORT

    if [ ! -z "${CPU_NODE}" ] && [ ! -z "${GPU_NODE}" ]; then
        echo "Multiple jobs found, please specify which node to connect to:"
        echo "1) $CPU_NODE (CPU)"
        echo "2) $GPU_NODE (GPU)"
        read -p "Enter 1 or 2: " choice
        if [ "$choice" == "1" ]; then
            GPU_NODE=
        elif [ "$choice" == "2" ]; then
            CPU_NODE=
        else
            echo "Invalid choice"
            exit 1
        fi
    fi

    if [ ! -z "${CPU_NODE}" ]; then
        NODE=$CPU_NODE
        PORT=$CPU_PORT
        TYPE=CPU
    elif [ ! -z "${GPU_NODE}" ]; then
        NODE=$GPU_NODE
        PORT=$GPU_PORT
        TYPE=GPU
    else
        echo "No running job found"
        exit 1
    fi

    echo "Connecting to $NODE:$PORT ($TYPE) via SSH"
    ssh -p "$PORT" "$NODE"
}

function connect () {
    query_sge

    if [ -z "${JOB_STATE}" ]; then
        PORT=$(shuf -i 10000-65000 -n 1)
        # Submit job with qsub, capture job ID from output
        submit_output=$(qsub -N "$JOB_NAME-$PORT" $QSUB_PARAM "$SCRIPT_DIR/vscode-remote-job-sge.sh" "$PORT" 2>&1)
        JOB_SUBMIT_ID=$(echo "$submit_output" | grep -oE '[0-9]+' | head -1)
        >&2 echo "Submitted new $JOB_NAME job (id: $JOB_SUBMIT_ID)"
    fi

    while [ ! "$JOB_STATE" == "r" ]; do
        timeout
        sleep 5
        query_sge
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
        cpu)    JOB_NAME=$JOB_NAME-cpu; QSUB_PARAM=$QSUB_PARAM_CPU; connect ;;
        gpu)    JOB_NAME=$JOB_NAME-gpu; QSUB_PARAM=$QSUB_PARAM_GPU; connect ;;
        help)   usage ;;
        *)  echo -e "Command '$1' does not exist" >&2
            usage; exit 1 ;;
    esac
    exit 0
else
    usage
    exit 0
fi