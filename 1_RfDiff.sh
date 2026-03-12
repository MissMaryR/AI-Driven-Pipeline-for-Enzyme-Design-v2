#!/bin/bash --norc
#SBATCH --job-name=RFdiff
#SBATCH --partition=gpu-a100
#SBATCH --account=genome-center-grp
#SBATCH --time=24:00:00
#SBATCH --gres=gpu:1
#SBATCH --mem=16G
#SBATCH --output=logs/rf_out_%A_%a.out
#SBATCH --error=logs/rf_error_%A_%a.err
#SBATCH --array=0-1

conda init

set -e  # Exit immediately if a command exits with a non-zero status
set -u  # Treat unset variables as an error
set -o pipefail  # Consider a pipeline failed if any command fails

# Define variables
round=$(basename "$PWD")

# Set MKL default values to avoid unbound variable issues
export MKL_INTERFACE_LAYER=LP64
export MKL_THREADING_LAYER=GNU
export MKL_SERVICE_FORCE_INTEL=1
export DGLBACKEND=pytorch

module load apptainer/latest

SCRIPT_DIR=/quobyte/jbsiegelgrp/software/rf_diffusion_all_atom
CONTAINER=${SCRIPT_DIR}/rf_se3_diffusion.sif

# Change to the rf_diffusion_all_atom directory
cd ${SCRIPT_DIR}

input_pdb_path="/quobyte/jbsiegelgrp/missmaryr/laccase/${round}/docked.pdb"
output_prefix="/quobyte/jbsiegelgrp/missmaryr/laccase/${round}/outputs/${SLURM_ARRAY_TASK_ID}"

######################### Run RFDiffusion #########################
{
apptainer run --bind /quobyte:/quobyte \
    --nv ${CONTAINER} -u run_inference.py \
    diffuser.T=100 \
    inference.output_prefix="${output_prefix}" \
    inference.input_pdb="${input_pdb_path}" \
    contigmap.contigs="['A1-151,30-30,A159-319,B1-319,C1-319']" \
    inference.ligand=4EP \
    inference.num_designs=2
} || { echo "Error: RFDiffusion step failed."; exit 1; }
