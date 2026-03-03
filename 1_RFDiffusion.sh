#!/bin/bash --norc
#SBATCH --job-name=RFdiff
#SBATCH --partition=gpu-a100
#SBATCH --account=genome-center-grp
#SBATCH --time=24:00:00
#SBATCH --gres=gpu:1
#SBATCH --mem=16G
#SBATCH --output=logs/rf_out_%A_%a.out
#SBATCH --error=logs/rf_error_%A_%a.err
#SBATCH --array=0-3

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
    

input_pdb_path="/quobyte/jbsiegelgrp/username/${round}/input.pdb"
output_prefix="/quobyte/jbsiegelgrp/username/${round}/outputs/${SLURM_ARRAY_TASK_ID}"



######################### Step 1: Run RFDiffusion #########################
{
apptainer run --bind /quobyte:/quobyte \
    --nv ${CONTAINER} -u run_inference.py \
    inference.output_prefix=$output_prefix \
    inference.input_pdb=$input_pdb_path \
    "contigmap.contigs=['A1-145,30-30,A150-300']" \
    inference.ligand=4EP \
    inference.num_designs=250
} || { echo "Error: RFDiffusion step failed."; exit 1; }

######################### Step 2: Dock Ligands #########################
# Avoid Biopython and use simpler file parsing

{
python - <<EOF
import os
from pymol import cmd, finish_launching
import re

# Initialize PyMOL
finish_launching(['pymol', '-qc'])  # '-qc' for quiet and no GUI

# Paths setup
x_pdb_folder = './outputs/'
y_pdb_path = './input.pdb'
output_folder = './aligned_outputs/'

# Ensure the output folder exists
os.makedirs(output_folder, exist_ok=True)

# Chain ID of the ligand in the Y PDB
ligand_chain = 'Y'

# Load the Y PDB
cmd.load(y_pdb_path, 'y_pdb')

# Extract the ligand
cmd.select('ligand', f'y_pdb and chain {ligand_chain}')
cmd.create('y_ligand', 'ligand')

# Regular expression to match the naming pattern like "0_0.pdb", "1_1.pdb", etc.
pattern = re.compile(r'^\d+_\d+\.pdb$')

# Process each X PDB file in the folder
for pdb_file in os.listdir(x_pdb_folder):
    if pattern.match(pdb_file):  # Check if file matches the pattern
        x_pdb_path = os.path.join(x_pdb_folder, pdb_file)
        pdb_name = os.path.splitext(pdb_file)[0]

        # Load the X PDB
        cmd.load(x_pdb_path, pdb_name)

        # Align X PDB to Y PDB
        cmd.align(pdb_name, 'y_pdb')

        # Create a new object that contains the aligned X PDB and the ligand
        cmd.create(f'input_{pdb_name}', f'{pdb_name} + y_ligand')

        # Save the new object as a PDB
        cmd.save(os.path.join(output_folder, f'input_{pdb_name}.pdb'), f'input_{pdb_name}')

        # Delete the loaded objects to keep the session clean
        cmd.delete(pdb_name)
        cmd.delete(f'input_{pdb_name}')

# Clean up
cmd.delete('y_pdb')
cmd.delete('y_ligand')
EOF


} || { echo "Error: Ligand docking step failed."; exit 1; }

