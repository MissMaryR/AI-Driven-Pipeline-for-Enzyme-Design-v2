#!/bin/bash --norc
#SBATCH --job-name=top5
#SBATCH --partition=gpu-a100
#SBATCH --account=genome-center-grp
#SBATCH --time=01:00:00
#SBATCH --mem=8G
#SBATCH --output=logs/out_top5_%j.out
#SBATCH --error=logs/err_top5_%j.err

##### Set variables #####
round=$(basename "$PWD")
ARRAY_IDS="0 1"       # Must match --array range in 2_ligandmpnn.sh
NUM_DESIGNS=2         # Must match inference.num_designs in 1_rfdiffusion.sh
NUM_RUNS=10           # Must match NUM_RUNS in 2_ligandmpnn.sh

# Initialize results array
results=()

# Collect results across all array jobs and designs
for num1 in $ARRAY_IDS; do
    for num2 in $(seq 0 $((NUM_DESIGNS - 1))); do
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
done

if [[ ${#results[@]} -eq 0 ]]; then
    echo "ERROR: No .fa files found. Check that 2_ligandmpnn.sh completed successfully."
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

# Write top 5 AlphaFold3 JSON files using a single monomer sequence
# The .fa sequence line is already a trimer (seq:seq:seq) — extract just the first copy
output_dir="/quobyte/jbsiegelgrp/missmaryr/laccase/${round}/top_5_af3_inputs"
mkdir -p "$output_dir"

rank=1
echo "$sorted_results" | while IFS= read -r result; do
    fa_file_path=$(echo "$result" | awk '{print $8}')

    # Line 4 is the full trimer sequence (seq:seq:seq) — take only the first segment
    full_seq=$(sed -n '4p' "$fa_file_path")
    monomer_seq=$(echo "$full_seq" | cut -d':' -f1)

    # Name uses round and rank, e.g. "HIVE_1"
    name="${round}_${rank}"

    json_file="${output_dir}/top_${rank}.json"
    cat > "$json_file" << JSONEOF
{
  "name": "${name}",
  "sequences": [
    {
      "protein": {
          "id": ["A","B","C"],
        "sequence": "${monomer_seq}"
      }
    }
  ],
  "modelSeeds": [1],
  "dialect": "alphafold3",
  "version": 1
}
JSONEOF

    echo "Created: $json_file"
    rank=$((rank + 1))
done

echo "Done. Top 5 AlphaFold3 JSON files saved to: $output_dir"
