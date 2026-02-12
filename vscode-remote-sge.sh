cp ~/bin/vscode-remote-sge ~/bin/vscode-remote-sge.bak.$(date +%Y%m%d-%H%M%S)

cat > ~/bin/vscode-remote-sge <<'EOF'
#!/bin/bash
set -euo pipefail

# Set your SGE parameters for GPU and CPU jobs here
# NOTE: BU SCC uses PE "smp" (common) — change if your group uses "omp".
QSUB_PARAM_CPU="-pe smp 4 -l mem_free=16G -l h_rt=12:00:00"
QSUB_PARAM_GPU="-pe smp 4 -l mem_free=16G -l h_rt=04:00:00"

# The time you expect a job to start in (seconds)
TIMEOUT=1800

####################
# don't edit below this line
####################

usage () {
  echo "Usage :  $0 [command]

General commands:
  list      List running vscode-remote jobs
  cancel    Cancels running vscode-remote jobs
  ssh       SSH into the node of a running job
  help      Display this message

Job commands (see usage below):
  cpu       Connect to a CPU node
  gpu       Connect to a GPU node

These should be used in ProxyCommand in your ~/.ssh/config, for example:
  Host vscode-remote-sge-cpu
    User rgangopa
    IdentityFile ~/.ssh/vscode-remote-sge
    ProxyCommand ssh scc1 \"~/bin/vscode-remote-sge cpu\"
    StrictHostKeyChecking no
"
}

# Find the first job id whose *full* name begins with $JOB_NAME (because qstat truncates names)
find_job_id () {
  local jid full
  while read -r jid; do
    full="$(qstat -j "$jid" 2>/dev/null | awk -F: '/job_name:/ {gsub(/^[ \t]+/,"",$2); print $2; exit}')"
    if [[ -n "$full" && "$full" == "$JOB_NAME"* ]]; then
      echo "$jid"
      return 0
    fi
  done < <(qstat -u "$USER" 2>/dev/null | awk '$1 ~ /^[0-9]+$/ && $3 ~ /^vscode-rem/ {print $1}')
  return 1
}

query_sge () {
  JOB_ID=""
  JOB_FULLNAME=""
  JOB_STATE=""
  JOB_NODE=""
  JOB_PORT=""

  local jid line queueinst full

  jid="$(find_job_id || true)"
  if [[ -z "${jid}" ]]; then
    return 0
  fi

  line="$(qstat -u "$USER" 2>/dev/null | awk -v j="$jid" '$1==j {print; exit}')"
  if [[ -z "${line}" ]]; then
    return 0
  fi

  JOB_ID="$jid"
  JOB_STATE="$(echo "$line" | awk '{print $5}')"
  queueinst="$(echo "$line" | awk '{print $8}')"

  # queue instance looks like: p-int@scc-pi2.scc.bu.edu
  case "$queueinst" in
    *@*) JOB_NODE="${queueinst##*@}" ;;
    *)   JOB_NODE="" ;;
  esac

  # Full job name (not truncated)
  full="$(qstat -j "$JOB_ID" 2>/dev/null | awk -F: '/job_name:/ {gsub(/^[ \t]+/,"",$2); print $2; exit}')"
  JOB_FULLNAME="$full"

  # Port is the last "-" chunk of the full job name
  JOB_PORT="$(echo "$JOB_FULLNAME" | awk -F- '{print $NF}')"

  >&2 echo "Job is $JOB_STATE ( id: $JOB_ID, name: $JOB_FULLNAME${JOB_NODE:+, node: $JOB_NODE} )"
}

cleanup () {
  if [[ -n "${JOB_SUBMIT_ID:-}" ]]; then
    qdel "$JOB_SUBMIT_ID" 2>/dev/null || true
    >&2 echo "Cancelled pending job $JOB_SUBMIT_ID"
  fi
}

timeout_check () {
  if (( $(date +%s) - START > TIMEOUT )); then
    >&2 echo "Timeout, exiting..."
    cleanup
    exit 1
  fi
}

cancel () {
  query_sge >/dev/null 2>&1
  while [[ -n "${JOB_ID}" ]]; do
    echo "Cancelling running job $JOB_ID${JOB_NODE:+ on $JOB_NODE}"
    qdel "$JOB_ID" || true
    timeout_check
    sleep 2
    query_sge >/dev/null 2>&1
  done
}

list () {
  # qstat truncates name column -> show all vscode-rem jobs for this user
  qstat -u "$USER" 2>/dev/null | awk 'NR==1 || $3 ~ /^vscode-rem/ {print}'
}

ssh_connect () {
  local ROOT_NAME NODE PORT TYPE
  ROOT_NAME="$JOB_NAME"

  JOB_NAME="$ROOT_NAME-cpu"
  query_sge
  local CPU_NODE="$JOB_NODE" CPU_PORT="$JOB_PORT"

  JOB_NAME="$ROOT_NAME-gpu"
  query_sge
  local GPU_NODE="$JOB_NODE" GPU_PORT="$JOB_PORT"

  if [[ -n "${CPU_NODE}" && -n "${GPU_NODE}" ]]; then
    echo "Multiple jobs found, please specify which node to connect to:"
    echo "1) $CPU_NODE (CPU)"
    echo "2) $GPU_NODE (GPU)"
    read -p "Enter 1 or 2: " choice
    if [[ "$choice" == "1" ]]; then
      GPU_NODE=""
    elif [[ "$choice" == "2" ]]; then
      CPU_NODE=""
    else
      echo "Invalid choice"
      exit 1
    fi
  fi

  if [[ -n "${CPU_NODE}" ]]; then
    NODE="$CPU_NODE"; PORT="$CPU_PORT"; TYPE="CPU"
  elif [[ -n "${GPU_NODE}" ]]; then
    NODE="$GPU_NODE"; PORT="$GPU_PORT"; TYPE="GPU"
  else
    echo "No running job found"
    exit 1
  fi

  echo "Connecting to $NODE:$PORT ($TYPE) via SSH"
  ssh -p "$PORT" "$NODE"
}

connect () {
  query_sge

  if [[ -z "${JOB_STATE}" ]]; then
    local PORT submit_output
    PORT="$(shuf -i 10000-65000 -n 1)"
    submit_output="$(qsub -N "$JOB_NAME-$PORT" $QSUB_PARAM "$SCRIPT_DIR/vscode-remote-job-sge.sh" "$PORT" 2>&1)"
    JOB_SUBMIT_ID="$(echo "$submit_output" | grep -oE '[0-9]+' | head -1)"
    >&2 echo "Submitted new $JOB_NAME job (id: $JOB_SUBMIT_ID)"
  fi

  while [[ "${JOB_STATE}" != "r" ]]; do
    timeout_check
    sleep 5
    query_sge
  done

  >&2 echo "Connecting to ${JOB_NODE}"

  while ! nc -z "$JOB_NODE" "$JOB_PORT" >/dev/null 2>&1; do
    timeout_check
    sleep 1
  done

  # Provide the TCP stream for ProxyCommand
  nc "$JOB_NODE" "$JOB_PORT"
}

if [[ -n "${1:-}" ]]; then
  JOB_NAME="vscode-remote"
  SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
  START="$(date +%s)"
  trap "cleanup && exit 1" INT TERM

  case "$1" in
    list)   list ;;
    cancel) cancel ;;
    ssh)    ssh_connect ;;
    cpu)    JOB_NAME="$JOB_NAME-cpu"; QSUB_PARAM="$QSUB_PARAM_CPU"; connect ;;
    gpu)    JOB_NAME="$JOB_NAME-gpu"; QSUB_PARAM="$QSUB_PARAM_GPU"; connect ;;
    help)   usage ;;
    *)      echo "Command '$1' does not exist" >&2; usage; exit 1 ;;
  esac
else
  usage
fi
EOF

chmod +x ~/bin/vscode-remote-sge
