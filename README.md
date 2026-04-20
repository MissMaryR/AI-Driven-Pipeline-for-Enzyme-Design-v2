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

## Runtime Estimates

Wall-clock time depends heavily on cluster GPU availability. The numbers below assume the `gpu-a100` partition with ~10 concurrent A100 GPUs available and no heavy queue contention. Real times can be longer if the queue is busy.

Per-task rough costs (observed):

- RFDiffusion: **~20–40 min per design** (1 GPU, sequential within an array task)
- LigandMPNN: **~30 s per run**, so `NUM_RUNS=10` → ~5 min per array task (1 GPU)
- Top 5 selection: **< 1 min** regardless of scale (CPU-only file parsing)
- AlphaFold3: **~30–45 min per prediction** for a ~270 aa homotrimer (1 GPU). Only 5 predictions ever run here, so this stage has a fixed cost.

End-to-end estimates at `NUM_DESIGNS=1`, `NUM_RUNS=10`:

| RFDiff designs | LigMPNN total runs | 1) RFDiff | 2) LigMPNN | 3) Top 5 | 4) AF3 (top 5) | **End-to-end (parallel)** |
|---|---|---|---|---|---|---|
| 10 | 100 | ~30–40 min | ~5–10 min | <1 min | ~30–45 min | **~1–1.5 h** |
| 100 | 1,000 | ~5–7 h (10× batches of 10) | ~30–60 min | ~1 min | ~30–45 min | **~6–9 h** |
| 1,000 | 10,000 | ~2–3 days (100× batches of 10) | ~5–10 h | ~5 min | ~30–45 min | **~2.5–4 days** |

Notes:
- "End-to-end (parallel)" assumes SLURM lets you run ~10 array tasks concurrently. A busier cluster will stretch the top two rows proportionally; a less busy one (or a bigger share of GPUs) can collapse them toward the single-task cost.
- `1_RfDiff.sh` sets `--time=01:30:00` per array task, `2_LigMPNN.sh` sets `--time=00:15:00`. If you increase `inference.num_designs` so that a single task runs multiple designs serially, bump script 1's wall time accordingly (30–40 min per design).
- Step 4 runs a fixed 5 AF3 predictions regardless of how many RFDiff designs you generated, so it doesn't scale with the other steps.

---

## Setup: Configure Paths and Parameters

Before submitting any job, open each script and update the following hardcoded values:

| What to edit | Script | Description |
|---|---|---|
| `#SBATCH --array=...` | 1 | Number of RFDiffusion array tasks (scaling — see "Scaling Up" below) |
| `conda activate ...` | 1 | Path to your RFDiffusion conda env (e.g. `SE3nv`) |
| `SCRIPT_DIR=...` | 1 | Path to your RFDiffusion All-Atom installation |
| `input_pdb_path=...` | 1 | Full path to your `docked.pdb` input file (base path `/quobyte/.../laccase/` is hardcoded — change to your project root) |
| `output_prefix=...` | 1 | Full path prefix for RFDiffusion output PDBs (same base path as `input_pdb_path`) |
| `inference.ligand=...` | 1 | 3-letter ligand residue code from your PDB (e.g. `ATP`, `HEM`, `4EP`) |
| `contigmap.contigs=...` | 1 | Contig string describing your protein topology and insertion |
| `inference.num_designs=...` | 1 | Number of designs per array task |
| `#SBATCH --array=...` | 2 | Must equal `NUM_RFD_TASKS * NUM_DESIGNS - 1` (e.g. `0-9`) |
| `NUM_RFD_TASKS=...` | 2 | Must match `--array` range in script 1 |
| `NUM_DESIGNS=...` | 2 | Must match `inference.num_designs` in script 1 |
| `NUM_RUNS=...` | 2 | Number of independent LigandMPNN sequences to generate per design |
| `TORCH_HOME=...` | 2 | Path to the LigandMPNN torch cache directory |
| `conda activate ...` | 2 | Path to your LigandMPNN conda environment |
| `LIGAND_MPNN_DIR=...` | 2 | Path to your LigandMPNN installation |
| `pdb_file=...` | 2 | Base path to RFDiffusion output PDBs (must match `output_prefix` in script 1) |
| `out_folder=...` | 2 | Base path for LigandMPNN output folders |
| `--redesigned_residues ...` | 2 | Space-separated residues to redesign — use `update_MPNN.py` to compute automatically |
| `--symmetry_residues ...` | 2 | Comma-separated residues to keep symmetric across chains (e.g. `A1,A2,A3`) |
| `--symmetry_weights ...` | 2 | Per-residue symmetry weights (must sum to 1, e.g. `0.33,0.33,0.33`) |
| `NUM_RFD_TASKS=...` | 3 | Number of RFDiffusion array tasks (must match `--array` in script 1) |
| `NUM_DESIGNS=...` | 3 | Must match `inference.num_designs` in script 1 |
| `NUM_RUNS=...` | 3 | Must match `NUM_RUNS` in script 2 |
| `NUM_CHAINS=...` | 3 | Number of chains for AF3 prediction (1=monomer, 2=dimer, 3=homotrimer) |
| Base path `/quobyte/.../${round}/...` | 3 | Change to wherever your `MPNN_outputs/` live on your cluster (appears in `fa_file`, `output_file`, and `output_dir`) |
| `af3_dir = ...` | 4 | Path to your AlphaFold3 installation — inside the `main()` function |
| `MAX_CONCURRENT = ...` | 4 | Max simultaneous AF3 array tasks (default `20`) |
| `#SBATCH` directives | 4 | `--partition`, `--account`, `--time`, `--mem`, `--cpus-per-task`, `--gres=gpu:1` inside the `slurm_script_content` string in `main()` |

Also update `--account` and `--partition` in every `#SBATCH` header to match your cluster.

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

- **update_MPNN.py**: use script in same directory (on your mac) as 2_LigMPNN.sh and 1_RfDiff.sh
  ```
  python3 update_MPNN.py
  ```
  - this will update the **`--redesigned_residues`** in 2_LigMPNN to match the inserts you chose in 1_RFDiff
  - we are only designing on the residues that were created from RFDiffusion
  - its common to also design a couple of residues on either side of the insert, you can adjust as needed
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

`3_Top5.sh` walks every `MPNN_outputs/{task}_{design}_run{i}/seqs/*.fa` file, parses the header, ranks all sequences by **`overall_confidence`** (descending), keeps the top 5, and writes an AlphaFold3 JSON input for each.

Configure `3_Top5.sh`:

```bash
NUM_RFD_TASKS=10   # Must match --array range in 1_RfDiff.sh (0-9 → 10 tasks)
NUM_DESIGNS=1      # Must match inference.num_designs in 1_RfDiff.sh
NUM_RUNS=10        # Must match NUM_RUNS in 2_LigMPNN.sh
NUM_CHAINS=3       # 1=monomer, 2=dimer, 3=homotrimer
```

The monomer sequence is **not** hardcoded by length. The script reads line 4 of each `.fa` file (the full designed sequence, which for a homotrimer is the monomer repeated 3×) and finds the repeat boundary by searching for the second occurrence of the first 20 residues. If that fails, it falls back to `len(full_seq) / 3`.

Run:
```bash
sbatch 3_Top5.sh
```

Output:
- `top_5_overall_confidence.txt` — ranked table: Overall Confidence, Filename, ID, T, Seed, Ligand Confidence, Seq Rec, File Path
- `top_5_af3_inputs/` — one AlphaFold3 JSON file per top design (`top_1.json` … `top_5.json`)

At the end, `3_Top5.sh` automatically runs `python 4_AF3_bulk.py top_5_af3_inputs/` to submit the AlphaFold3 predictions. If `4_AF3_bulk.py` isn't next to `3_Top5.sh`, it prints a warning and you submit it manually (see step 4).

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

Run after `3_Top5.sh` completes (it auto-runs this for you):

```bash
python 4_AF3_bulk.py /path/to/your/project/round_name/top_5_af3_inputs
```

> **Note:** The path to the AlphaFold3 installation (`af3_dir`) is hardcoded inside the `main()` function of `4_AF3_bulk.py`. Edit that variable directly before running. Default: `/quobyte/jbsiegelgrp/software/alphafold3`.

This script scans the target directory for `*.json` files, writes a file list to `logs/json_files_list.txt`, generates `af3_array_job.sbatch` with `--array=0-{N-1}%{MAX_CONCURRENT}` (default concurrency cap: 20), and submits it with `sbatch`. Each array task runs one AlphaFold3 prediction inside a Singularity container on 1 GPU, logs GPU utilization every 5 s via `nvidia-smi`, and prints a resource-usage summary (runtime, peak VRAM, average GPU utilization, and `seff`-based CPU/memory efficiency) at the end of each task log.

SLURM defaults inside the generated sbatch (edit in `4_AF3_bulk.py` to change): partition `low`, account `publicgrp`, 1 h wall time, 8 CPUs, 64 GB RAM, 1 GPU.

Output:
- `top_5_af3_inputs/top_5_af3_inputs_output/<name>/` — AF3 predictions per design (structures, pLDDT / PAE / pTM / ipTM, auxiliary files)
- `top_5_af3_inputs/logs/af3_<job_id>_<task_id>.{out,err}` — per-task SLURM logs with runtime + resource summaries
- `top_5_af3_inputs/logs/json_files_list.txt` — 1-indexed JSON file list used by the array job
- `top_5_af3_inputs/af3_array_job.sbatch` — the generated submission script (useful for debugging or re-submitting)

---

## Scaling Up

To generate more designs, update these values consistently across scripts:

| Parameter | Script | Default |
|---|---|---|
| `--array=0-9` | `1_RfDiff.sh` | 10 array tasks |
| `inference.num_designs=1` | `1_RfDiff.sh` | 1 design per task |
| `NUM_RFD_TASKS=10` | `2_LigMPNN.sh`, `3_Top5.sh` | Must match above |
| `NUM_DESIGNS=1` | `2_LigMPNN.sh`, `3_Top5.sh` | Must match above |
| `--array=0-9` | `2_LigMPNN.sh` | `NUM_RFD_TASKS * NUM_DESIGNS - 1` |
| `NUM_RUNS=10` | `2_LigMPNN.sh`, `3_Top5.sh` | Sequences per design |

Example — 4 array tasks × 25 designs × 10 runs = **1,000 total designs**:
```bash
# 1_RfDiff.sh:   --array=0-3,   inference.num_designs=25
# 2_LigMPNN.sh:  --array=0-99,  NUM_RFD_TASKS=4,  NUM_DESIGNS=25,  NUM_RUNS=10
# 3_Top5.sh:     NUM_RFD_TASKS=4,  NUM_DESIGNS=25,  NUM_RUNS=10
```
