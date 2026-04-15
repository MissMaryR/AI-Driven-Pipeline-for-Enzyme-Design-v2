#!/bin/bash --norc
#SBATCH --job-name=top5
#SBATCH --partition=low               # <-- adjust to your cluster's CPU partition
#SBATCH --account=YOUR_ACCOUNT        # <-- replace with your SLURM account
#SBATCH --requeue
#SBATCH --time=01:00:00
#SBATCH --cpus-per-task=2
#SBATCH --mem=8G
#SBATCH --output=logs/out_top5_%A_%a.out
#SBATCH --error=logs/err_top5_%A_%a.err

set -euo pipefail

mkdir -p logs

##############################################################################
# USER CONFIGURATION — edit these variables before submitting
##############################################################################

# Root directory for this project (same as PROJECT_DIR in 1_RfDiff.sh)
PROJECT_DIR=/path/to/your/project

# Space-separated list of RFDiffusion array task IDs — must match --array in 1_RfDiff.sh
ARRAY_IDS="0 1"

# Must match inference.num_designs in 1_RfDiff.sh
NUM_DESIGNS=2

# Must match NUM_RUNS in 2_LigMPNN.sh
NUM_RUNS=10

# Number of residues to take from the start of the monomer sequence for AF3 input.
# Set this to the total length of your designed chain A (original + inserted residues).
SEQ_LENGTH=341

# Number of chains for AF3 prediction:
#   1 = monomer       -> id: ["A"]
#   2 = dimer         -> id: ["A","B"]
#   3 = homotrimer    -> id: ["A","B","C"]
NUM_CHAINS=3

##############################################################################

# Build chain ID string based on NUM_CHAINS
case $NUM_CHAINS in
    1) CHAIN_IDS='"A"' ;;
    2) CHAIN_IDS='"A","B"' ;;
    3) CHAIN_IDS='"A","B","C"' ;;
    *) echo "ERROR: NUM_CHAINS must be 1, 2, or 3."; exit 1 ;;
esac

# round = name of the current working directory (used to label outputs)
round=$(basename "$PWD")

# Initialize results array
results=()

# Collect results across all array jobs and designs
for num1 in $ARRAY_IDS; do
    for num2 in $(seq 0 $((NUM_DESIGNS - 1))); do
        filename="${num1}_${num2}"
        for i in $(seq 1 $NUM_RUNS); do

            fa_file="${PROJECT_DIR}/MPNN_outputs/${filename}_run${i}/seqs/${filename}.fa"

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
done

if [[ ${#results[@]} -eq 0 ]]; then
    echo "ERROR: No .fa files found. Check that 2_LigMPNN.sh completed successfully."
    exit 1
fi

# Sort by overall confidence descending, keep top 5
sorted_results=$(printf "%s\n" "${results[@]}" | sort -k1,1nr | head -n 5)

# Save ranking summary
output_file="${PROJECT_DIR}/top_5_overall_confidence.txt"
{
    echo "Top 5 overall confidence scores:"
    echo "Overall Confidence | Filename | ID | T | Seed | Ligand Confidence | Seq Rec | File Path"
    printf "%s\n" "${sorted_results[@]}"
} > "$output_file"

echo "Top 5 summary written to: $output_file"

# Write top 5 AlphaFold3 JSON files
output_dir="${PROJECT_DIR}/top_5_af3_inputs"
mkdir -p "$output_dir"

rank=1
echo "$sorted_results" | while IFS= read -r result; do
    fa_file_path=$(echo "$result" | awk '{print $8}')

    # Line 4 is the full sequence — take first segment (before any ':') then trim to SEQ_LENGTH
    full_seq=$(sed -n '4p' "$fa_file_path")
    monomer_seq=$(echo "$full_seq" | cut -d':' -f1 | cut -c1-${SEQ_LENGTH})

    actual_len=${#monomer_seq}
    if [[ $actual_len -lt $SEQ_LENGTH ]]; then
        echo "Warning: top_${rank} sequence is only ${actual_len} residues (expected ${SEQ_LENGTH})"
    fi

    # Name uses round and rank, e.g. "myproject_1"
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
