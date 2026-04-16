#!/bin/bash --norc
# Generated with Siegel Lab HIVE Cluster Skill v1.1
#SBATCH --job-name=RFdiff
#SBATCH --partition=low
#SBATCH --account=publicgrp
#SBATCH --requeue
#SBATCH --time=01:30:00
#SBATCH --cpus-per-task=4
#SBATCH --gres=gpu:1
#SBATCH --mem=16G
#SBATCH --output=logs/rf_out_%A_%a.out
#SBATCH --error=logs/rf_error_%A_%a.err
#SBATCH --array=0-9

set -euo pipefail

# Create logs directory
mkdir -p logs

# Define variables
round=$(basename "$PWD")

# Set MKL default values to avoid unbound variable issues
export MKL_INTERFACE_LAYER=LP64
export MKL_THREADING_LAYER=GNU
export MKL_SERVICE_FORCE_INTEL=1
export DGLBACKEND=pytorch

# Load modules
module load conda/latest
module load apptainer/latest

# Activate conda environment
eval "$(conda shell.bash hook)"
conda activate /quobyte/jbsiegelgrp/software/envs/SE3nv

SCRIPT_DIR=/quobyte/jbsiegelgrp/software/rf_diffusion_all_atom
CONTAINER=${SCRIPT_DIR}/rf_se3_diffusion.sif

# Change to the rf_diffusion_all_atom directory
cd ${SCRIPT_DIR}

input_pdb_path="/quobyte/jbsiegelgrp/missmaryr/laccase/${round}/docked.pdb"
output_prefix="/quobyte/jbsiegelgrp/missmaryr/laccase/${round}/outputs/${SLURM_ARRAY_TASK_ID}"

######################### Run RFDiffusion #########################
apptainer run --bind /quobyte:/quobyte \
    --nv ${CONTAINER} -u run_inference.py \
    diffuser.T=100 \
    inference.output_prefix="${output_prefix}" \
    inference.input_pdb="${input_pdb_path}" \
    contigmap.contigs="['A1-150,10-10,A160-250]" \
    inference.ligand=4EP \
    inference.num_designs=1 \
|| { echo "Error: RFDiffusion step failed."; exit 1; }
