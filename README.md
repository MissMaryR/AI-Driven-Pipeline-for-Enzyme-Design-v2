# AI-Driven Pipeline for Enzyme Design
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

Run after opening HIVE:
```
module load conda/latest
module load cuda/12.6.2
```

---

## Setup: Configure Paths and Parameters

Before submitting any job, open each script and fill in the **USER CONFIGURATION** block at the top:

| Variable | Scripts | Description |
|---|---|---|
| `PROJECT_DIR` | 1, 2, 3 | Absolute path to your project folder (contains `docked.pdb`) |
| `RFDIFF_DIR` | 1 | Path to your RFDiffusion All-Atom installation |
| `LIGMPNN_DIR` | 2 | Path to your LigandMPNN installation |
| `LIGMPNN_ENV` | 2 | Path to your LigandMPNN conda environment |
| `LIGAND_NAME` | 1 | 3-letter ligand residue code from your PDB (e.g. `ATP`, `HEM`) |
| `CONTIGS` | 1 | Contig string describing your protein topology and insertion |
| `REDESIGNED_RESIDUES` | 2 | Space-separated list of residues to redesign (e.g. `A152 A153 ...`) |
| `SEQ_LENGTH` | 3 | Length of the designed monomer chain for AF3 input |
| `NUM_CHAINS` | 3 | Number of chains for AF3 prediction (1=monomer, 2=dimer, 3=homotrimer) |
| `--af3-dir` | 4 (arg) | Path to your AlphaFold3 installation |

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
python 4_AF3_bulk.py /path/to/your/project/round_name/top_5_af3_inputs \
    --af3-dir /path/to/alphafold3
```

Or just run separate, shown below.

## 1) RFDiffusion — Backbone Generation

Configure `1_RfDiff.sh`:

- **`CONTIGS`**: Defines the protein topology and where the new loop is inserted.
  - Format: `'[ChainResStart-ResEnd,insert_len-insert_len,ChainResStart-ResEnd,...]'`
  - Example: `['A1-150,12-12,A155-200,B1-200,C1-200']` inserts 12 residues between A151 and A155 in a homotrimer
  - See the [RFDiffusion All-Atom docs](https://github.com/baker-laboratory/rf_diffusion_all_atom) for full syntax
- **`NUM_DESIGNS`**: Designs per array task. Also update `--array=0-N` in the SBATCH header.

Run:
```bash
sbatch 1_RfDiff.sh
```

Output: `outputs/` folder with PDBs named `{array_id}_{design_id}.pdb` (e.g. `0_0.pdb`, `0_1.pdb`)

> **Note:** RFDiffusion drops the ligand chain and any extra protein chains from output PDBs — this is expected. Downstream scripts handle this.

---

## 2) LigandMPNN — Sequence Design

Configure `2_LigMPNN.sh`:

- **`REDESIGNED_RESIDUES`**: Space-separated chain+residue IDs for the inserted loop (e.g. `A152 A153 ... A163`). Check the residue numbering in your RFDiffusion output PDBs.
- **`NUM_RFD_TASKS`**, **`NUM_DESIGNS`**: Must match `1_RfDiff.sh`. Update `--array` accordingly: `--array=0-$((NUM_RFD_TASKS * NUM_DESIGNS - 1))`
- **`NUM_RUNS`**: How many independent LigandMPNN sequences to generate per design (default: 10)
- See [LigandMPNN](https://github.com/dauparas/LigandMPNN) for additional options

Run:
```bash
sbatch 2_LigMPNN.sh
```

Output: `MPNN_outputs/` with one subfolder per design per run, each containing a `seqs/` directory with `.fa` files.

Default with 2 tasks × 2 designs × 10 runs = **40 total sequence designs**.

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
python 4_AF3_bulk.py /path/to/your/project/round_name/top_5_af3_inputs \
    --af3-dir /path/to/alphafold3
```

This script automatically finds all JSON files, generates a SLURM array job script, and submits it. Each array task runs one AlphaFold3 prediction.

Output:
- `top_5_af3_inputs/top_5_af3_inputs_output/<name>/` — AF3 predictions per design
- `top_5_af3_inputs/logs/` — SLURM logs per job

Useful monitoring commands:
```bash
squeue -j <job_id>                     # Check job status
squeue -j <job_id> -t all              # Check all array tasks
scancel <job_id>                       # Cancel job
tail -f top_5_af3_inputs/logs/af3_*.out  # Monitor live logs
```

---

## Scaling Up

To generate more designs, update these values consistently across scripts:

| Parameter | Script | Default |
|---|---|---|
| `--array=0-1` | `1_RfDiff.sh` | 2 array tasks |
| `inference.num_designs=2` | `1_RfDiff.sh` | 2 designs per task |
| `NUM_RFD_TASKS=2` | `2_LigMPNN.sh` | Must match above |
| `NUM_DESIGNS=2` | `2_LigMPNN.sh`, `3_Top5.sh` | Must match above |
| `--array=0-3` | `2_LigMPNN.sh` | `NUM_RFD_TASKS * NUM_DESIGNS - 1` |
| `ARRAY_IDS="0 1"` | `3_Top5.sh` | Must match array range in step 1 |
| `NUM_RUNS=10` | `2_LigMPNN.sh`, `3_Top5.sh` | Sequences per design |

Example — 4 array tasks × 25 designs × 10 runs = **1,000 total designs**:
```bash
# 1_RfDiff.sh:   --array=0-3,  NUM_DESIGNS=25,  inference.num_designs=25
# 2_LigMPNN.sh:  --array=0-99, NUM_RFD_TASKS=4,  NUM_DESIGNS=25
# 3_Top5.sh:     ARRAY_IDS="0 1 2 3",  NUM_DESIGNS=25
```
