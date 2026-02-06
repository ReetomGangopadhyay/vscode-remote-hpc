# Slurm vs SGE Conversion Guide

This document explains the key differences between the Slurm and SGE versions of vscode-remote-hpc.

## Command Mapping

| Operation | Slurm Command | SGE Command |
|-----------|---------------|------------|
| Submit job | `sbatch` | `qsub` |
| Query jobs | `squeue` | `qstat` |
| Cancel job | `scancel` | `qdel` |
| Job name | `-J <name>` | `-N <name>` |

## Parameter Conversion

### Memory Request
- **Slurm:** `--mem=32G`
- **SGE:** `-l mem=32G`

### CPU Cores
- **Slurm:** `-c 8`
- **SGE:** `-l cpu=8` or `-pe pe_name 8`

### Wall Clock Time Limit
- **Slurm:** `-t 12:00:00`
- **SGE:** `-l h_rt=12:00:00`

### GPU Request
- **Slurm:** `--gpus=1`
- **SGE:** `-l gpu=1` (or your site's specific GPU resource name)

### Queue/Partition
- **Slurm:** `-p partition_name` or `-q queue_name`
- **SGE:** `-q queue_name.q` (queues often end with `.q`)

## Job State Differences

### Slurm Job States
- `R` - Running
- `PD` - Pending
- `S` - Suspended
- `CF` - Configuring
- `RF` - Requeuing after failure
- `RH` - Requeuing held job
- `RQ` - Requeued job

### SGE Job States
- `r` - Running
- `qw` - Queued waiting
- `hqw` - Held, queued waiting
- `h` - Held
- `E` - Error
- `e` - Error/executing

The SGE version uses `r` as the sole target running state, whereas Slurm checks for `RUNNING`.

## File Changes

### Main Script (vscode-remote.sh → vscode-remote-sge.sh)

1. **Parameter variables:**
   ```bash
   # Slurm
   SBATCH_PARAM_CPU="-q ni -t 12:00:00 --mem=32G -c 8"
   
   # SGE
   QSUB_PARAM_CPU="-l mem=32G,cpu=8 -l h_rt=12:00:00"
   ```

2. **Query function:**
   - Slurm: Uses `squeue` with structured output format
   - SGE: Uses `qstat` and parses job status from output

3. **Job submission:**
   ```bash
   # Slurm
   /usr/bin/sbatch -J $JOB_NAME%$PORT $SBATCH_PARAM ...
   
   # SGE
   qsub -N $JOB_NAME-$PORT $QSUB_PARAM ...
   ```

4. **Job status check:**
   - Slurm: `while [ ! "$JOB_STATE" == "RUNNING" ]`
   - SGE: `while [ ! "$JOB_STATE" == "r" ]`

### Job Script (vscode-remote-job.sh → vscode-remote-job-sge.sh)

1. **Header directives:**
   ```bash
   # Slurm
   #SBATCH -t 12:00:00
   #SBATCH -o none
   
   # SGE
   #$ -l h_rt=12:00:00
   #$ -o none
   ```

## Installation

- **Slurm:** `bash install.sh`
- **SGE:** `bash install-sge.sh`

Both install to `~/bin/vscode-remote` or `~/bin/vscode-remote-sge` respectively.

## SSH Config Entries

**Slurm:**
```bash
Host vscode-remote-cpu
    User USERNAME
    IdentityFile ~/.ssh/vscode-remote
    ProxyCommand ssh HPC-LOGIN "~/bin/vscode-remote cpu"
    StrictHostKeyChecking no
```

**SGE:**
```bash
Host vscode-remote-sge-cpu
    User USERNAME
    IdentityFile ~/.ssh/vscode-remote-sge
    ProxyCommand ssh HPC-LOGIN "~/bin/vscode-remote-sge cpu"
    StrictHostKeyChecking no
```

## Common SGE Configuration Issues

### Issue: Regular expressions in qstat
SGE's `qstat` output is less structured than Slurm's. The SGE version uses `grep` to match job names and parses whitespace-separated fields.

### Issue: Complex resource requests
If your SGE system uses custom complex attributes, you may need to adjust the `-l` parameters. Check with:
```bash
qconf -sc  # List complex attributes
qconf -sql # List queues
```

### Issue: GPU resources
GPU naming varies by site. Common options:
- `-l gpu=1` (if GPU is a standard complex)
- `-l gpu_total=1` or `-l gpus_total=1` (alternative naming)
- `-pe gpu_pe 1` (if GPUs are managed via parallel environment)

Check your site's configuration for the correct resource name.

## When to Use Each

### Use **Slurm version** if:
- Your HPC uses Slurm scheduler
- You need structured squeue output parsing
- Your system uses sbatch for job submission

### Use **SGE version** if:
- Your HPC uses Sun Grid Engine (SGE/OGE)
- Your system uses qsub for job submission
- Your system uses -l directives for resource requests

## Porting Scripts to Another Scheduler

To port to other schedulers (PBS, Torque, LoadLeveler, etc.), you'll need to adapt:

1. **Job submission command** and its parameter format
2. **Status query command** and state abbreviations
3. **Job cancellation command**
4. **Job state detection logic**
5. **Job name parsing** (how the port number is stored/retrieved)

The overall script structure remains the same.
