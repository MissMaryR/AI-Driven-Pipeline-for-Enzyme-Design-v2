# AI-Driven Pipeline for Enzyme Design with a Trimeric Structure
## RFDiffusion → LigandMPNN → AlphaFold3
### Design enzymes with novel inserted sequences

This pipeline takes a docked protein-ligand complex (`.pdb`) and:
1. Uses **RFDiffusion All-Atom** to generate backbone structures with a novel inserted loop
2. Uses **LigandMPNN** to design sequences for the inserted region
3. Selects the **top 5** designs by confidence score
4. Runs **AlphaFold3** structure prediction on the top designs

---

## Requirements

The following tools must be installed and accessible on your HPC cluster:

- [RFDiffusion All-Atom](https://github.com/baker-laboratory/rf_diffusion_all_atom) — with Apptainer/Singularity container (`rf_se3_diffusion.sif`)
- [LigandMPNN](https://github.com/dauparas/LigandMPNN) — with a conda environment
- [AlphaFold3](https://github.com/google-deepmind/alphafold3) — with Singularity container, model weights, and `public_databases/`
- SLURM workload manager
- Apptainer/Singularity


---

## Setup: Configure Paths and Parameters

Before submitting any job, open each script and update the following hardcoded values:

| What to edit | Script | Description |
|---|---|---|
| `SCRIPT_DIR=...` | 1 | Path to your RFDiffusion All-Atom installation |
| `input_pdb_path=...` | 1 | Full path to your `docked.pdb` input file |
| `output_prefix=...` | 1 | Full path prefix for RFDiffusion output PDBs |
| `inference.ligand=...` | 1 | 3-letter ligand residue code from your PDB (e.g. `ATP`, `HEM`) |
| `contigmap.contigs=...` | 1 | Contig string describing your protein topology and insertion |
| `inference.num_designs=...` | 1 | Number of designs per array task |
| `LIGAND_MPNN_DIR=...` | 2 | Path to your LigandMPNN installation |
| `conda activate ...` | 2 | Path to your LigandMPNN conda environment |
| `pdb_file=...` | 2 | Base path to RFDiffusion output PDBs (must match `output_prefix` in script 1) |
| `out_folder=...` | 2 | Base path for LigandMPNN output folders |
| `--redesigned_residues ...` | 2 | Space-separated residues to redesign — use `update_MPNN.py` to compute automatically |
| `--symmetry_residues ...` | 2 | Comma-separated residues to keep symmetric across chains (e.g. `A1,A2,A3`) |
| `--symmetry_weights ...` | 2 | Per-residue symmetry weights (must sum to 1, e.g. `0.33,0.33,0.33`) |
| `SEQ_LENGTH=...` | 3 | Length of the designed monomer chain for AF3 input |
| `NUM_CHAINS=...` | 3 | Number of chains for AF3 prediction (1=monomer, 2=dimer, 3=homotrimer) |
| `af3_dir = ...` | 4 | Path to your AlphaFold3 installation — inside the `main()` function |

Also update `--account` and `--partition` in the `#SBATCH` headers to match your cluster.

---

## Directory Structure

Each design round gets its own directory. All scripts use `basename "$PWD"` to detect the round name automatically, so **always run scripts from within the round directory**.

```
your_project/
└── round_name/          # e.g. "round1" — name this whatever you like
    ├── docked.pdb                   # Input: protein-ligand complex
    ├── logs/                        # All SLURM logs (auto-created)
    ├── outputs/                     # RFDiffusion backbone outputs
    ├── MPNN_outputs/                # LigandMPNN sequence designs
    └── top_5_af3_inputs/            # Top 5 AF3 JSON inputs + results
```

Your `docked.pdb` should contain:
- One or more protein chains (e.g. Chain A, B, C for a homotrimer)
- A ligand chain (the HETATM residue you specify as `LIGAND_NAME`)

---

## Running the Pipeline

Submit all steps with SLURM dependencies so each waits for the previous to finish:

```bash
cd /path/to/your/project/round_name

jid1=$(sbatch --parsable 1_RfDiff.sh)
jid2=$(sbatch --parsable --dependency=afterok:$jid1 2_LigMPNN.sh)
jid3=$(sbatch --parsable --dependency=afterok:$jid2 3_Top5.sh)
# After 3_Top5.sh completes:
python 4_AF3_bulk.py /path/to/your/project/round_name/top_5_af3_inputs
```

Or just run separate, shown below.

Useful monitoring commands:
```bash
squeue -u <username>         #shows all of your running jobs
squeue -u <username> -o%j -h | sort | uniq -c | sort -rn    #shows your jobs organized by job name
squeue -j <job_id>                     # Check job status
squeue -j <job_id> -t all              # Check all array tasks
scancel <job_id>                       # Cancel job
tail -f /logs/rf_out_*.out  # Monitor live logs
```

## 1) RFDiffusion — Backbone Generation

Configure `1_RfDiff.sh`:

- **`CONTIGS`**: Defines the protein topology and where the new loop is inserted.
  - Format: `'[ChainResStart-ResEnd,insert_len-insert_len,ChainResStart-ResEnd,...]'`
  - Multimer Example: `['A1-100,12-12,A102-200,B1-200,C1-200']` inserts 12 residues between A100 and A102 in a trimer on chain A
  - note - RFdiffusion doesnt support design on 3 chains simultaneously, we have to do RFDiffusion on one chain and then LigandMPNN can take that chain and design on it as a trimer
  - Monomer Example: `['A1-100,12-12,A102-200']` inserts 12 residues between A100 and A102 in a single chain A
  - The insert amount can be adjusted to a range ex: 10-20 and will generate a range of structures, but deciding on one length is critical for this pipeline as LigandMPNN needs specific residues to design on which can vary when running a range. We use a script later on that reads the 1_RFDiff script and automatically updates the designed residues in 2_LigMPNN but it must be in the 12-12 format. 
  - See the [RFDiffusion All-Atom docs](https://github.com/baker-laboratory/rf_diffusion_all_atom) for full syntax
- **`--array`**: adjust this to decide how many designs to generate
  - each design takes 20-40 minutes to run

Run:
```bash
sbatch 1_RfDiff.sh
```

Output: `outputs/` folder with PDBs named `{array_id}_{design_id}.pdb` (e.g. `0_0.pdb`, `0_1.pdb`)


---

## 2) LigandMPNN — Sequence Design

Configure `2_LigMPNN.sh`:

- **update_MPNN.py**: use script in same directory (on your mac) to update the 2_LigMPNN.sh with your current RFDiffusion contigmap
  ```
  python3 update_MPNN.py
  ``` 
- **`--array`**: Must match `1_RfDiff.sh`.
- **`NUM_RUNS`**: How many independent LigandMPNN sequences to generate per design (default: 10)
- **`--symmetry_residues`**: Comma-separated residue IDs that should be kept symmetric across chains (e.g. `A1,A2,A3`). Useful for homotrimers where the inserted loop must be identical on all chains.
- **`--symmetry_weights`**: Comma-separated weights for each symmetry group (must sum to 1, e.g. `0.33,0.33,0.33`). Must have the same number of entries as `--symmetry_residues`.
- See [LigandMPNN](https://github.com/dauparas/LigandMPNN) for additional options

Run:
```bash
sbatch 2_LigMPNN.sh
```

Output: `MPNN_outputs/` with one subfolder per design per run, each containing a `seqs/` directory with `.fa` files.

---

## 3) Top 5 Selection

Configure `3_Top5.sh`:

```bash
ARRAY_IDS="0 1"    # Match --array range in 1_RfDiff.sh
NUM_DESIGNS=2      # Match inference.num_designs in 1_RfDiff.sh
NUM_RUNS=10        # Match NUM_RUNS in 2_LigMPNN.sh
SEQ_LENGTH=341     # Length of designed chain A (original + inserted residues)
NUM_CHAINS=3       # 1=monomer, 2=dimer, 3=homotrimer
```

Run:
```bash
sbatch 3_Top5.sh
```

Output:
- `top_5_overall_confidence.txt` — ranked table of the top 5 designs
- `top_5_af3_inputs/` — one AlphaFold3 JSON file per top design

Example JSON:
```json
{
  "name": "round1_1",
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

Run after `3_Top5.sh` completes:

```bash
python 4_AF3_bulk.py /path/to/your/project/round_name/top_5_af3_inputs
```

> **Note:** The path to the AlphaFold3 installation (`af3_dir`) is hardcoded inside the `main()` function of `4_AF3_bulk.py`. Edit that variable directly before running.

This script automatically finds all JSON files, generates a SLURM array job script, and submits it. Each array task runs one AlphaFold3 prediction.

Output:
- `top_5_af3_inputs/top_5_af3_inputs_output/<name>/` — AF3 predictions per design
- `top_5_af3_inputs/logs/` — SLURM logs per job

---

## Scaling Up

To generate more designs, update these values consistently across scripts:

| Parameter | Script | Default |
|---|---|---|
| `--array=0-1` | `1_RfDiff.sh` | 2 array tasks |
| `inference.num_designs=1` | `1_RfDiff.sh` | 2 designs per task |
| `NUM_RFD_TASKS=2` | `2_LigMPNN.sh` | Must match above |
| `NUM_DESIGNS=1` | `2_LigMPNN.sh`, `3_Top5.sh` | Must match above |
| `--array=0-3` | `2_LigMPNN.sh` | `NUM_RFD_TASKS * NUM_DESIGNS - 1` |
| `ARRAY_IDS="0 1"` | `3_Top5.sh` | Must match array range in step 1 |
| `NUM_RUNS=10` | `2_LigMPNN.sh`, `3_Top5.sh` | Sequences per design |

Example — 4 array tasks × 25 designs × 10 runs = **1,000 total designs**:
```bash
# 1_RfDiff.sh:   --array=0-3,  NUM_DESIGNS=25,  inference.num_designs=25
# 2_LigMPNN.sh:  --array=0-99, NUM_RFD_TASKS=4,  NUM_DESIGNS=25
# 3_Top5.sh:     ARRAY_IDS="0 1 2 3",  NUM_DESIGNS=25
```
