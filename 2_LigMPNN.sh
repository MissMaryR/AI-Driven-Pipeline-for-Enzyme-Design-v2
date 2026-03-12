#!/bin/bash --norc
#SBATCH --job-name=LigMPNN
#SBATCH --partition=gpu-a100
#SBATCH --time=48:00:00
#SBATCH --account=genome-center-grp
#SBATCH --gres=gpu:1
#SBATCH --cpus-per-task=16
#SBATCH --mem=128G
#SBATCH --output=logs/out_ligandMPNN_%A_%a.out
#SBATCH --error=logs/err_ligandMPNN_%A_%a.err
#SBATCH --array=0-1

##### Set variables #####
round=$(basename "$PWD")
num1=$SLURM_ARRAY_TASK_ID   # 0 or 1, matching RFDiffusion array IDs
NUM_DESIGNS=2               # Must match inference.num_designs in 1_rfdiffusion.sh
NUM_RUNS=10                 # LigandMPNN runs per design

export TORCH_HOME=/quobyte/jbsiegelgrp/software/LigandMPNN/.cache

module load conda/latest
eval "$(conda shell.bash hook)"
conda activate /quobyte/jbsiegelgrp/software/envs/ligandmpnn_env

LIGAND_MPNN_DIR="/quobyte/jbsiegelgrp/software/LigandMPNN"
cd "$LIGAND_MPNN_DIR"

# Loop over designs produced by this array job (0 to NUM_DESIGNS-1)
for num2 in $(seq 0 $((NUM_DESIGNS - 1))); do

    pdb_file="/quobyte/jbsiegelgrp/missmaryr/laccase/${round}/outputs/${num1}_${num2}.pdb"
    filename="${num1}_${num2}"

    if [[ ! -f "$pdb_file" ]]; then
        echo "Warning: $pdb_file not found, skipping."
        continue
    fi

    for i in $(seq 1 $NUM_RUNS); do
        out_folder="/quobyte/jbsiegelgrp/missmaryr/laccase/${round}/MPNN_outputs/${filename}_run${i}"

        python run.py \
            --model_type "ligand_mpnn" \
            --pdb_path "$pdb_file" \
            --out_folder "$out_folder" \
            --redesigned_residues "A152 A153 A154 A155 A156 A157 A158 A159 A160 A161 A162 A163 A164 A165 A166 A167 A168 A169 A170 A171 A172 A173 A174 A175 A176 A177 A178 A179 A180 A181"
    done
done
