#!/usr/bin/env python3
"""
Parses contigmap.contigs from 1_RfDiff.sh to find all inserted (gap) residues,
calculates their output PDB residue numbers accounting for cumulative insertions,
and overwrites --redesigned_residues in 2_LigMPNN.sh with the result.

use:
python3 update_MPNN.py

Output numbering logic (per chain):
  - Fixed segments keep their original PDB numbers, but are SHIFTED upward
    by the cumulative number of inserted residues seen so far on that chain.
  - Inserted residues are assigned new numbers that immediately follow the
    last output residue of the preceding segment.
  - Only residues from insertions go into --redesigned_residues.
"""

import re
import sys
from pathlib import Path


def parse_contigs(contig_str):
    """
    Given a contig string like:
      A1-151,12-12,A155-183,1-1,A185-262,B1-262,C1-262
    Return a list of dicts, each describing one segment:
      { 'type': 'fixed'|'insertion',
        'chain': 'A'|'B'|...|None,
        'pdb_start': int|None, 'pdb_end': int|None,
        'length': int }
    """
    segments = []
    for token in contig_str.split(','):
        token = token.strip()
        # Fixed segment: optional chain letter(s) then start-end
        fixed_match = re.match(r'^([A-Za-z]+)(\d+)-(\d+)$', token)
        # Insertion: digits-digits (no leading letter)
        insert_match = re.match(r'^(\d+)-(\d+)$', token)

        if fixed_match:
            chain = fixed_match.group(1)
            start = int(fixed_match.group(2))
            end   = int(fixed_match.group(3))
            segments.append({
                'type': 'fixed',
                'chain': chain,
                'pdb_start': start,
                'pdb_end': end,
                'length': end - start + 1,
            })
        elif insert_match:
            length = int(insert_match.group(1))   # e.g. 12 from "12-12"
            segments.append({
                'type': 'insertion',
                'chain': None,
                'pdb_start': None,
                'pdb_end': None,
                'length': length,
            })
        else:
            print(f"Warning: unrecognised contig token '{token}', skipping.")

    return segments


def compute_redesigned_residues(segments):
    """
    Walk through segments in order, tracking:
      - current output residue number for the active chain
      - cumulative insertion offset

    Returns a list of strings like ['A152', 'A153', ..., 'A196']
    """
    redesigned = []

    # We need to track the next output residue number.
    # Output number = pdb_number + cumulative_insertions_so_far (for fixed segs)
    # For insertions we just continue numbering from where we left off.

    current_output_num = 0   # last output residue number assigned
    current_chain = None

    for seg in segments:
        if seg['type'] == 'fixed':
            chain = seg['chain']

            if chain != current_chain:
                # Switching to a new chain — reset tracking
                # Output numbers for the new chain start from pdb_start
                # (no prior insertions on this chain)
                current_chain = chain
                current_output_num = seg['pdb_start'] - 1  # will be incremented below

            # For fixed segments the output numbers are:
            #   current_output_num+1 .. current_output_num + length
            # but they must align with where we left off (insertions shift things)
            # Actually the rule is simpler: output numbers run contiguously.
            # After any insertion the next fixed segment resumes immediately after.
            # So we just advance by the segment length.
            current_output_num += seg['length']

        else:  # insertion
            # Inserted residues: assign consecutive numbers following last output
            for _ in range(seg['length']):
                current_output_num += 1
                redesigned.append(f"{current_chain}{current_output_num}")

    return redesigned


def extract_contig_string(rfdiff_path):
    """Read 1_RfDiff.sh and extract the contig list string."""
    text = Path(rfdiff_path).read_text()
    # Match contigmap.contigs="['...']"  (single or double quotes around the list)
    match = re.search(r"contigmap\.contigs=['\"]?\[['\"](.*?)['\"]\]['\"]?", text)
    if not match:
        sys.exit(f"Error: could not find contigmap.contigs in {rfdiff_path}")
    return match.group(1)


def update_ligmpnn(ligmpnn_path, residues):
    """Overwrite the --redesigned_residues line in 2_LigMPNN.sh."""
    text = Path(ligmpnn_path).read_text()
    residue_str = ' '.join(residues)
    new_line = f'        --redesigned_residues "{residue_str}"'

    # Replace the existing --redesigned_residues line (with any indentation/quoting)
    updated, count = re.subn(
        r'[ \t]*--redesigned_residues\s+"[^"]*"',
        new_line,
        text
    )
    if count == 0:
        sys.exit(f"Error: could not find --redesigned_residues in {ligmpnn_path}")

    Path(ligmpnn_path).write_text(updated)
    print(f"Updated {ligmpnn_path} with {len(residues)} redesigned residues.")


def main():
    script_dir = Path(__file__).parent

    rfdiff_path  = script_dir / '1_RfDiff.sh'
    ligmpnn_path = script_dir / '2_LigMPNN.sh'

    for p in (rfdiff_path, ligmpnn_path):
        if not p.exists():
            sys.exit(f"Error: {p} not found. Make sure this script is in the same "
                     "directory as 1_RfDiff.sh and 2_LigMPNN.sh.")

    contig_str = extract_contig_string(rfdiff_path)
    print(f"Found contigs: {contig_str}")

    segments = parse_contigs(contig_str)
    print("\nParsed segments:")
    for s in segments:
        if s['type'] == 'fixed':
            print(f"  Fixed   {s['chain']}{s['pdb_start']}-{s['pdb_end']}  (len {s['length']})")
        else:
            print(f"  Insert  {s['length']} residues")

    redesigned = compute_redesigned_residues(segments)
    print(f"\nRedesigned residues ({len(redesigned)}): {' '.join(redesigned)}")

    update_ligmpnn(ligmpnn_path, redesigned)


if __name__ == '__main__':
    main()
