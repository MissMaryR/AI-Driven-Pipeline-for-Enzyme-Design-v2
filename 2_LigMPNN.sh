#!/bin/bash --norc
# Generated with Siegel Lab HIVE Cluster Skill v1.1
#SBATCH --job-name=LigMPNN
#SBATCH --partition=gpu-a100
#SBATCH --account=genome-center-grp
#SBATCH --time=00:15:00
#SBATCH --gres=gpu:1
#SBATCH --cpus-per-task=16
#SBATCH --mem=16G
#SBATCH --output=logs/out_ligandMPNN_%A_%a.out
#SBATCH --error=logs/err_ligandMPNN_%A_%a.err
#SBATCH --array=0-9   # NUM_RFD_TASKS * NUM_DESIGNS - 1 = 10 * 1 - 1 = 9

set -euo pipefail

##### Set variables #####
NUM_RFD_TASKS=10        # Must match --array range in 1_RfDiff.sh  (0-9 → 10 tasks)
NUM_DESIGNS=1           # Must match inference.num_designs in 1_RfDiff.sh
NUM_RUNS=10             # LigandMPNN runs per design

round=$(basename "$PWD")

# Decode 2D index: SLURM_ARRAY_TASK_ID encodes (num1, num2)
num1=$(( SLURM_ARRAY_TASK_ID / NUM_DESIGNS ))   # RFDiffusion array task ID
num2=$(( SLURM_ARRAY_TASK_ID % NUM_DESIGNS ))   # design index within that task

export TORCH_HOME=/quobyte/jbsiegelgrp/software/LigandMPNN/.cache

mkdir -p logs

eval "$(conda shell.bash hook)"
conda activate /quobyte/jbsiegelgrp/software/envs/ligandmpnn_env

LIGAND_MPNN_DIR="/quobyte/jbsiegelgrp/software/LigandMPNN"
cd "$LIGAND_MPNN_DIR"

pdb_file="/quobyte/jbsiegelgrp/username/${round}/outputs/${num1}_${num2}.pdb"
filename="${num1}_${num2}"

if [[ ! -f "$pdb_file" ]]; then
    echo "Error: $pdb_file not found."
    exit 1
fi

for i in $(seq 1 $NUM_RUNS); do
    out_folder="/quobyte/jbsiegelgrp/<username>/${round}/MPNN_outputs/${filename}_run${i}"

    python run.py \
        --model_type "ligand_mpnn" \
        --pdb_path "$pdb_file" \
        --out_folder "$out_folder" \
	--symmetry_residues "A1,A2,A3" \
        --symmetry_weights "0.33,0.33,0.33" \
        --redesigned_residues "A151 A152 A153 A154 A155 A156 A157 A158 A159 A160 A161 A162"
done
