# AI Driven Pipeline for Enzyme Design (IN PROGRESS)
## RFDiffusion -> LigandMPNN -> AlphaFold3/Chai/Boltz
## designs an enzyme with novel inserted sequence
After logging into HIVE, load conda
```
module load conda/latest
module load cuda/12.6.2  # Good to have even when you're not using a GPU
```
```
conda activate pymol_env
```
if not there, make the environment
```
conda create -n pymol_env -y python=3.10
```
then activate and install pymol
```
conda install -c conda-forge -c schrodinger pymol-bundle
```
```
conda deactivate
```

---

## Directory Structure

Each design round gets its own directory named after the round (e.g. `HIVE`). All scripts use `basename "$PWD"` to detect the round name automatically, so **always run scripts from within the round directory**.

```
laccase/
└── HIVE/
    ├── docked.pdb                   # Input: protein-ligand complex
    │                                #   Chain A/B/C = protein (trimer)
    │                                #   Chain Y     = ligand (4EP)
    ├── logs/                        # All SLURM logs
    ├── outputs/                     # RFDiffusion backbone outputs
    ├── MPNN_outputs/                # LigandMPNN sequence designs
    └── top_5_af3_inputs/            # Top 5 AF3 JSON inputs + results
```

---

## Pipeline Overview

Submit the full pipeline with dependencies so each step waits for the previous one:
```bash
jid1=$(sbatch --parsable 1_RfDiff.sh)
jid2=$(sbatch --parsable --dependency=afterok:$jid1 2_LigMPNN.sh)
jid3=$(sbatch --parsable --dependency=afterok:$jid2 3_Top5.sh)
# Then after 3_Top5.sh finishes:
python 4_AF3_bulk.py /quobyte/jbsiegelgrp/missmaryr/laccase/HIVE/top_5_af3_inputs
```

---

## 1) Begin with RFDiffusion

1. Adjust `1_RfDiff.sh` to insert the selected amount of sequence
   * Refer to the [baker RFDiff All Atom](https://github.com/baker-laboratory/rf_diffusion_all_atom) GitHub for specifics
   * Adjust the contigs, directories, and input PDB to match your system
   * Key parameter: `contigmap.contigs=['A1-151,30-30,A159-319,B1-319,C1-319']` — inserts 30 new residues between A151 and A159
2. Upload `1_RfDiff.sh` and `docked.pdb` in the same round directory
   * `docked.pdb` should contain Chain A/B/C (protein trimer) and Chain Y (ligand 4EP)
   * This script runs a SLURM array of 2 jobs × 2 designs = **4 total backbones**
   * To scale up, increase `--array` and `inference.num_designs` (see Scaling Up section)
   * Run with:
   ```
   sbatch 1_RfDiff.sh
   ```
3. Will generate:
   * `logs/` folder with `.out` and `.err` files for each array job
   * If a `ROSETTA_CRASH` file appears — check the error file for details
   * `outputs/` folder with generated PDBs — named `(array_id)_(design_id).pdb`
   * e.g. `0_0.pdb`, `0_1.pdb`, `1_0.pdb`, `1_1.pdb`

> **Note:** RFDiffusion drops the ligand (Chain Y) and chains B/C from output PDBs — this is expected. Downstream scripts handle this.

---

## 2) LigandMPNN Sequence Design

1. Adjust `2_LigMPNN.sh` to match your redesigned residues and array settings
   * `--redesigned_residues` should cover your inserted loop — default is `A152-A181` (the 30 inserted residues)
   * Refer to the [LigandMPNN](https://github.com/dauparas/LigandMPNN) GitHub for additional options
   * Update `NUM_DESIGNS` to match `inference.num_designs` from Step 1
2. Run with:
   ```
   sbatch 2_LigMPNN.sh
   ```
3. Will generate:
   * `MPNN_outputs/` folder containing one subfolder per design per run
   * Each subfolder contains a `seqs/` directory with a `.fa` file
   * `.fa` files contain the designed sequence and confidence scores on line 3
   * Default: 2 designs × 10 runs × 2 array jobs = **40 total sequence designs**

---

## 3) Select Top 5 Designs

1. Adjust `3_Top5.sh` to match your array and design settings at the top of the script:
   ```bash
   ARRAY_IDS="0 1"    # Match --array range in 2_LigMPNN.sh
   NUM_DESIGNS=2      # Match inference.num_designs in 1_RfDiff.sh
   NUM_RUNS=10        # Match NUM_RUNS in 2_LigMPNN.sh
   ```
2. Run with:
   ```
   sbatch 3_Top5.sh
   ```
3. Will generate:
   * `top_5_overall_confidence.txt` — ranked table of top 5 designs with all confidence metrics
   * `top_5_af3_inputs/` folder containing one JSON file per top design, ready for AlphaFold3
   * JSON files are formatted for homotrimer prediction with `id: ["A","B","C"]` and a single monomer sequence

Example JSON:
```json
{
  "name": "HIVE_1",
  "sequences": [
    {
      "protein": {
        "id": ["A","B","C"],
        "sequence": "GEVRHLKMYAE..."
      }
    }
  ],
  "modelSeeds": [1],
  "dialect": "alphafold3",
  "version": 1
}
```

---

## 4) AlphaFold3 Structure Prediction

1. After `3_Top5.sh` completes, run `4_AF3_bulk.py` pointed at your `top_5_af3_inputs` folder
   * Automatically finds all JSON files, generates a SLURM array job, and submits it
   * Each array task runs one AlphaFold3 prediction via Singularity
   * Monitors GPU usage and reports peak VRAM and utilization after each job
2. Run with:
   ```
   python 4_AF3_bulk.py /quobyte/jbsiegelgrp/missmaryr/laccase/HIVE/top_5_af3_inputs
   ```
3. Will generate:
   * `top_5_af3_inputs/top_5_af3_inputs_output/<n>/` — one folder per design with AF3 structure predictions
   * `top_5_af3_inputs/logs/` — SLURM logs and GPU monitoring summaries per job

Useful commands after submission:
```bash
squeue -j <job_id>                          # Check job status
squeue -j <job_id> -t all                   # Check all array tasks
scancel <job_id>                            # Cancel job
tail -f top_5_af3_inputs/logs/af3_*.txt    # Monitor live logs
```

---

## Scaling Up

To generate more designs, update these values consistently across scripts:

| Parameter | Script | Default |
|---|---|---|
| `--array=0-1` | `1_RfDiff.sh`, `2_LigMPNN.sh` | 2 array jobs |
| `inference.num_designs=2` | `1_RfDiff.sh` | 2 designs per job |
| `NUM_DESIGNS=2` | `2_LigMPNN.sh`, `3_Top5.sh` | Must match above |
| `ARRAY_IDS="0 1"` | `3_Top5.sh` | Must match array range |
| `NUM_RUNS=10` | `2_LigMPNN.sh`, `3_Top5.sh` | Runs per design |

For example, to run 4 array jobs × 25 designs × 10 runs = **1,000 total designs**:
```bash
# 1_RfDiff.sh:   --array=0-3,  inference.num_designs=25
# 2_LigMPNN.sh:  --array=0-3,  NUM_DESIGNS=25
# 3_Top5.sh:     ARRAY_IDS="0 1 2 3",  NUM_DESIGNS=25
```
