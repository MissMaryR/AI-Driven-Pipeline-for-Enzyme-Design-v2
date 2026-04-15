"""
AlphaFold 3 Array Job Submission Script

This script finds all JSON files in a specified directory and submits them as a SLURM array job.

Usage:
    python 4_AF3_bulk.py <json_directory> [--af3-dir /path/to/alphafold3]

Arguments:
    json_directory   Directory containing AlphaFold3 JSON input files (e.g. top_5_af3_inputs/)
    --af3-dir        Path to your AlphaFold3 installation (default: /path/to/alphafold3).
                     Must contain alphafold3.sif, the model weights, and public_databases/.

SLURM settings:
    Edit the SLURM header variables near the top of generate_slurm_script() to match
    your cluster's partition names and account.
"""

import sys
import os
import subprocess
from pathlib import Path
import argparse

# ─────────────────────────────────────────────────────────────────────────────
# USER CONFIGURATION — set defaults for your cluster here
# ─────────────────────────────────────────────────────────────────────────────

DEFAULT_AF3_DIR = "/path/to/alphafold3"   # <-- replace with your AF3 installation path
SLURM_PARTITION = "low"                   # <-- replace with your CPU/GPU partition
SLURM_ACCOUNT   = "YOUR_ACCOUNT"          # <-- replace with your SLURM account

# ─────────────────────────────────────────────────────────────────────────────


def generate_slurm_script(input_dir, base_output_dir, logs_dir, json_list_file,
                           array_spec, af3_dir):
    """Return the SLURM batch script as a string."""
    return f"""\
#!/bin/bash --norc
#SBATCH --job-name=af3_array
#SBATCH --partition={SLURM_PARTITION}
#SBATCH --account={SLURM_ACCOUNT}
#SBATCH --requeue
#SBATCH --time=01:00:00
#SBATCH --cpus-per-task=8
#SBATCH --mem=64G
#SBATCH --gres=gpu:1
#SBATCH --array={array_spec}
#SBATCH --output={logs_dir}/af3_%A_%a.out
#SBATCH --error={logs_dir}/af3_%A_%a.err

set -euo pipefail

module load apptainer/latest

mkdir -p "{logs_dir}"

# 0-indexed: get line (SLURM_ARRAY_TASK_ID + 1) from list
JSON_FILE=$(sed -n "$((SLURM_ARRAY_TASK_ID + 1))p" "{json_list_file}")
if [ -z "$JSON_FILE" ]; then
    echo "Error: Could not get JSON file for array task ${{SLURM_ARRAY_TASK_ID}}"
    exit 1
fi

BASE_NAME="${{JSON_FILE%.json}}"
SAFE_NAME=$(echo "$BASE_NAME" | tr ' ' '_' | tr -cd '[:alnum:]._-')

INPUT_DIR="{input_dir}"
OUTPUT_DIR="{base_output_dir}/${{SAFE_NAME}}"
mkdir -p "$OUTPUT_DIR"

echo "Starting AF3 for $JSON_FILE at $(date)"
echo "Job: ${{SLURM_JOB_ID}}  Array task: ${{SLURM_ARRAY_TASK_ID}}  Node: ${{SLURM_NODELIST}}"
echo "Input:  $INPUT_DIR/$JSON_FILE"
echo "Output: $OUTPUT_DIR"

singularity exec \\
    --bind "$INPUT_DIR:/input" \\
    --bind "$OUTPUT_DIR:/output" \\
    --bind "{af3_dir}:/models" \\
    --bind "{af3_dir}/public_databases:/databases" \\
    --nv \\
    "{af3_dir}/alphafold3.sif" \\
    python /app/alphafold/run_alphafold.py \\
    --json_path="/input/$JSON_FILE" \\
    --model_dir=/models \\
    --output_dir=/output \\
    --db_dir=/databases

echo "Finished $JSON_FILE at $(date)"
echo "Output files:"
ls -la "$OUTPUT_DIR/"
"""


def main():
    parser = argparse.ArgumentParser(
        description="Submit AlphaFold 3 predictions as a SLURM array job"
    )
    parser.add_argument(
        "directory",
        help="Directory containing JSON files to process (e.g. top_5_af3_inputs/)"
    )
    parser.add_argument(
        "--af3-dir",
        default=DEFAULT_AF3_DIR,
        help=f"Path to AlphaFold3 installation (default: {DEFAULT_AF3_DIR})"
    )
    args = parser.parse_args()

    input_dir = Path(args.directory).resolve()
    af3_dir   = args.af3_dir

    if not input_dir.exists():
        print(f"Error: Directory {input_dir} does not exist")
        sys.exit(1)

    if not input_dir.is_dir():
        print(f"Error: {input_dir} is not a directory")
        sys.exit(1)

    json_files = sorted(input_dir.glob("*.json"))

    if not json_files:
        print(f"No JSON files found in {input_dir}")
        sys.exit(1)

    n = len(json_files)
    print(f"Found {n} JSON file(s) to process")
    print(f"Directory: {input_dir}")
    print()

    # Setup directories
    base_output_dir = input_dir / f"{input_dir.name}_output"
    logs_dir = input_dir / "logs"
    logs_dir.mkdir(exist_ok=True)

    print(f"Base output directory: {base_output_dir}")
    print(f"Logs directory: {logs_dir}")
    print()

    # Write 0-indexed file list for array job
    json_list_file = logs_dir / "json_files_list.txt"
    with open(json_list_file, 'w') as f:
        for json_file in json_files:
            f.write(f"{json_file.name}\n")

    print(f"Created file list: {json_list_file}")
    print(f"Array job will process indices 0-{n - 1}")
    print()

    # Throttle concurrency for large arrays
    concurrency = min(n, 10)
    array_spec = f"0-{n - 1}%{concurrency}" if n > 1 else "0"

    slurm_script_path = input_dir / "af3_array_job.sbatch"
    slurm_script_content = generate_slurm_script(
        input_dir, base_output_dir, logs_dir, json_list_file, array_spec, af3_dir
    )

    with open(slurm_script_path, 'w') as f:
        f.write(slurm_script_content)

    print(f"Created SLURM script: {slurm_script_path}")
    print()

    print("Submitting array job...")
    try:
        result = subprocess.run(
            ["sbatch", str(slurm_script_path)],
            cwd=input_dir,
            capture_output=True,
            text=True,
            check=True
        )

        print("Job submitted successfully!")
        print(f"SLURM output: {result.stdout.strip()}")

        if "Submitted batch job" in result.stdout:
            job_id = result.stdout.split()[-1]
            print()
            print("Useful commands:")
            print(f"  Check status:     squeue -j {job_id}")
            print(f"  Cancel job:       scancel {job_id}")
            print(f"  Monitor logs:     tail -f {logs_dir}/af3_{job_id}_*.out")

    except subprocess.CalledProcessError as e:
        print(f"Error submitting job: {e}")
        print(f"STDOUT: {e.stdout}")
        print(f"STDERR: {e.stderr}")
        sys.exit(1)
    except FileNotFoundError:
        print("Error: sbatch command not found. Make sure SLURM is available.")
        sys.exit(1)


if __name__ == "__main__":
    main()
