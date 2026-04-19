#!/bin/bash --norc
# Generated with Siegel Lab HIVE Cluster Skill v1.1
#SBATCH --job-name=top5
#SBATCH --partition=low
#SBATCH --account=publicgrp
#SBATCH --requeue
#SBATCH --time=01:00:00
#SBATCH --cpus-per-task=2
#SBATCH --mem=8G
#SBATCH --output=logs/out_top5_%A_%a.out
#SBATCH --error=logs/err_top5_%A_%a.err

set -euo pipefail

mkdir -p logs

##### Set variables #####
round=$(basename "$PWD")
NUM_RFD_TASKS=10      # Must match --array range in 1_RfDiff.sh (0-9 → 10 tasks)
NUM_DESIGNS=1         # Must match inference.num_designs in 1_RfDiff.sh
NUM_RUNS=10           # Must match NUM_RUNS in 2_LigMPNN.sh

NUM_CHAINS=3          # Number of chains for AF3 prediction
                      # 1 = monomer          -> id: ["A"]
                      # 2 = dimer            -> id: ["A","B"]
                      # 3 = homotrimer       -> id: ["A","B","C"]

# Build chain ID string based on NUM_CHAINS
case $NUM_CHAINS in
    1) CHAIN_IDS='"A"' ;;
    2) CHAIN_IDS='"A","B"' ;;
    3) CHAIN_IDS='"A","B","C"' ;;
    *) echo "ERROR: NUM_CHAINS must be 1, 2, or 3."; exit 1 ;;
esac

# Initialize results array
results=()

# Collect results across all array jobs and designs
# Mirrors the 2D index decoding in 2_LigMPNN.sh:
#   num1 = SLURM_ARRAY_TASK_ID / NUM_DESIGNS  (RFDiffusion task)
#   num2 = SLURM_ARRAY_TASK_ID % NUM_DESIGNS  (design index)
for task_id in $(seq 0 $(( NUM_RFD_TASKS * NUM_DESIGNS - 1 ))); do
    num1=$(( task_id / NUM_DESIGNS ))
    num2=$(( task_id % NUM_DESIGNS ))
    filename="${num1}_${num2}"

    for i in $(seq 1 $NUM_RUNS); do

        fa_file="/quobyte/jbsiegelgrp/missmaryr/laccase/${round}/MPNN_outputs/${filename}_run${i}/seqs/${filename}.fa"

        if [[ -f "$fa_file" ]]; then
            line=$(sed -n '3p' "$fa_file")

            overall_confidence=$(echo "$line" | grep -oP "(?<=overall_confidence=)[0-9.]+")
            id=$(echo "$line" | grep -oP "(?<=id=)[^,]+")
            T=$(echo "$line" | grep -oP "(?<=T=)[^,]+")
            seed=$(echo "$line" | grep -oP "(?<=seed=)[^,]+")
            ligand_confidence=$(echo "$line" | grep -oP "(?<=ligand_confidence=)[0-9.]+")
            seq_rec=$(echo "$line" | grep -oP "(?<=seq_rec=)[0-9.]+")

            results+=("$overall_confidence ${filename}_run${i} $id $T $seed $ligand_confidence $seq_rec $fa_file")
        fi
    done
done

if [[ ${#results[@]} -eq 0 ]]; then
    echo "ERROR: No .fa files found. Check that 2_LigMPNN.sh completed successfully."
    exit 1
fi

# Sort by overall confidence descending, keep top 5
sorted_results=$(printf "%s\n" "${results[@]}" | sort -k1,1nr | head -n 5)

# Save ranking summary
output_file="/quobyte/jbsiegelgrp/missmaryr/laccase/${round}/top_5_overall_confidence.txt"
{
    echo "Top 5 overall confidence scores:"
    echo "Overall Confidence | Filename | ID | T | Seed | Ligand Confidence | Seq Rec | File Path"
    printf "%s\n" "${sorted_results[@]}"
} > "$output_file"

echo "Top 5 summary written to: $output_file"

# Write top 5 AlphaFold3 JSON files
output_dir="/quobyte/jbsiegelgrp/missmaryr/laccase/${round}/top_5_af3_inputs"
mkdir -p "$output_dir"

rank=1
echo "$sorted_results" | while IFS= read -r result; do
    fa_file_path=$(echo "$result" | awk '{print $8}')

    # Line 4 is the full sequence — the monomer is repeated 3 times (homotrimer).
    # Find the repeat boundary by searching for the second occurrence of the
    # first 20 characters (a unique anchor) within the full sequence.
    full_seq=$(sed -n '4p' "$fa_file_path")
    anchor="${full_seq:0:20}"
    monomer_len=$(python3 -c "s='${full_seq}'; anchor=s[:20]; pos=s.find(anchor,1); print(pos)")
    if [[ -z "$monomer_len" || "$monomer_len" -le 0 ]]; then
        echo "Warning: top_${rank} could not find repeat boundary, falling back to full_len/3"
        monomer_len=$(( ${#full_seq} / 3 ))
    fi
    monomer_seq="${full_seq:0:$monomer_len}"

    actual_len=${#monomer_seq}
    if [[ $actual_len -lt $monomer_len ]]; then
        echo "Warning: top_${rank} sequence is only ${actual_len} residues (expected ${monomer_len})"
    fi

    # Name uses round and rank, e.g. "HIVE_1"
    name="${round}_${rank}"

    json_file="${output_dir}/top_${rank}.json"
    cat > "$json_file" << JSONEOF
{
  "name": "${name}",
  "sequences": [
    {
      "protein": {
          "id": [${CHAIN_IDS}],
        "sequence": "${monomer_seq}"
      }
    }
  ],
  "modelSeeds": [1],
  "dialect": "alphafold3",
  "version": 1
}
JSONEOF

    echo "Created: $json_file (${actual_len} residues, ${NUM_CHAINS} chain(s))"
    rank=$((rank + 1))
done

echo "Done. Top 5 AlphaFold3 JSON files saved to: $output_dir"

# Auto-submit AF3 array job for the top 5 JSONs
AF3_SCRIPT="$(dirname "$0")/4_AF3_bulk.py"
if [[ ! -f "$AF3_SCRIPT" ]]; then
    echo "WARNING: 4_AF3_bulk.py not found at $AF3_SCRIPT — skipping AF3 submission."
    echo "To submit manually: python 4_AF3_bulk.py $output_dir"
else
    echo ""
    echo "Submitting AF3 array job for top 5 JSONs..."
    python "$AF3_SCRIPT" "$output_dir"
fi
