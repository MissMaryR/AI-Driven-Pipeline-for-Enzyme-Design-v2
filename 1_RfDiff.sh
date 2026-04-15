#!/bin/bash --norc
#SBATCH --job-name=RFdiff
#SBATCH --partition=gpu-a100          # <-- adjust to your cluster's GPU partition
#SBATCH --account=YOUR_ACCOUNT        # <-- replace with your SLURM account
#SBATCH --time=24:00:00
#SBATCH --gres=gpu:1
#SBATCH --mem=16G
#SBATCH --output=logs/rf_out_%A_%a.out
#SBATCH --error=logs/rf_error_%A_%a.err
#SBATCH --array=0-1                   # <-- number of array tasks (0 to N-1)

conda init

set -e  # Exit immediately if a command exits with a non-zero status
set -u  # Treat unset variables as an error
set -o pipefail  # Consider a pipeline failed if any command fails

##############################################################################
# USER CONFIGURATION — edit these variables before submitting
##############################################################################

# Path to your RFDiffusion All-Atom installation
RFDIFF_DIR=/path/to/rf_diffusion_all_atom

# Path to the Apptainer/Singularity container
CONTAINER=${RFDIFF_DIR}/rf_se3_diffusion.sif

# Root directory for this project (the folder containing docked.pdb, outputs/, etc.)
PROJECT_DIR=/path/to/your/project

# Ligand residue name as it appears in the PDB HETATM records (e.g. 4EP, ATP, HEM)
LIGAND_NAME=YOUR_LIGAND

# Number of designs per array task — must match inference.num_designs below
# and NUM_DESIGNS in 2_LigMPNN.sh
NUM_DESIGNS=2

# Contig string describing the protein topology and insertion.
# Format: 'ChainResStart-ResEnd,inserted_length-inserted_length,...'
# Example below inserts 12 residues between A151 and A155 in a homotrimer (A,B,C).
# See https://github.com/baker-laboratory/rf_diffusion_all_atom for full syntax.
CONTIGS="['A1-151,12-12,A155-183,1-1,A185-262,B1-262,C1-262']"

##############################################################################

# Set MKL default values to avoid unbound variable issues
export MKL_INTERFACE_LAYER=LP64
export MKL_THREADING_LAYER=GNU
export MKL_SERVICE_FORCE_INTEL=1
export DGLBACKEND=pytorch

module load apptainer/latest

# round = name of the current working directory (used to label outputs)
round=$(basename "$PWD")

input_pdb_path="${PROJECT_DIR}/docked.pdb"
output_prefix="${PROJECT_DIR}/outputs/${SLURM_ARRAY_TASK_ID}"

# Change to RFDiffusion directory (required by the container entrypoint)
cd ${RFDIFF_DIR}

######################### Run RFDiffusion #########################
{
apptainer run --bind "$(dirname ${PROJECT_DIR}):$(dirname ${PROJECT_DIR})" \
    --nv ${CONTAINER} -u run_inference.py \
    diffuser.T=100 \
    inference.output_prefix="${output_prefix}" \
    inference.input_pdb="${input_pdb_path}" \
    contigmap.contigs="${CONTIGS}" \
    inference.ligand="${LIGAND_NAME}" \
    inference.num_designs=${NUM_DESIGNS}
} || { echo "Error: RFDiffusion step failed."; exit 1; }
