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

## 1) Begin with RFDiffusion

1. adjust 1_RFDiffusion.sh to insert the selected amount of sequence
   * refer to [baker RFDiff All Atom](https://github.com/baker-laboratory/rf_diffusion_all_atom) github for specifics
   * adjust code to your directories and pdb
2. upload .sh file and pdb in same directory
   * this code runs an array of 4 jobs to make 250 designs each, for a total of 1000 designs generated
   * run with
   * ```
     sbatch 1_RFDiffusion.sh
     ```
3. will generate:
   * logs folder with out and error files
   * if a ROSETTA_CRASH file appears - check error file for error
   * outputs folder with generated pdbs - (0-3)_(0-249).pdb = 1000 pdbs
