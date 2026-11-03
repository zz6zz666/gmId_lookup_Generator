#!/bin/bash
# =============================================================================
# L-level pipeline: simulate -> extract -> delete for TSMC N40 (CRN40LP)
# 1.1V core devices (nch / pch).
#
# One L point at a time: run_sim.py simulates all corners in parallel (one
# worker per corner), extract.py extracts them in parallel, then that L's raw
# PSF data is deleted so disk usage stays bounded.  The parallelism lives in
# the Python scripts; this script only sequences the stages, keeps per-L logs
# and reports timing.
#
# All machine-specific paths come from machine.env in this directory
# (no hardcoded directories or usernames in the scripts). Raw simulation
# data and final .h5 tables live under $HOME/simulation (see machine.env).
# =============================================================================

set -euo pipefail

# ----- Config ----------------------------------------------------------------
# Project dir = where this script lives (machine.env sits next to it).
SCRIPTDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load machine config (env vars win over the file).
set -a
if [ -f "$SCRIPTDIR/machine.env" ]; then
    source "$SCRIPTDIR/machine.env"
fi
set +a

# Required settings (fail loudly if missing).
: "${RAWDIR:?machine.env must set RAWDIR (transient raw simulation output)}"
: "${MATDIR:?machine.env must set MATDIR (final .h5 output)}"
: "${PYTHON_BIN:?machine.env must set PYTHON_BIN (python>=3.10 with psf-parser)}"
: "${LOGDIR:?machine.env must set LOGDIR (pipeline logs)}"
: "${TMPDIR:?machine.env must set TMPDIR (spectre work dirs)}"

PYTHON="$PYTHON_BIN"
FINE="--fine"
# Process config module; set CONFIG_MODULE in machine.env to switch process.
CONFIG_MODULE="${CONFIG_MODULE:-config_tsmcN40}"
export CONFIG_MODULE
WORKERS=5   # corner-level parallelism inside extract.py

cleanup() {
    echo ""
    echo "[!] Interrupted. Cleaning up..."
    pkill -P $$ 2>/dev/null || true
    echo "[!] Done."
    exit 1
}
trap cleanup INT TERM

# ----- Helper: clean stale artifacts from a previous (aborted) run ----------
cleanup_stale() {
    echo "[*] Cleaning stale artifacts ..."
    mkdir -p "$LOGDIR" "$TMPDIR"
    # Leftover raw data from an aborted run
    rm -rf "$RAWDIR"/raw_* 2>/dev/null || true
    # Old pipeline logs
    rm -f "$LOGDIR"/*.log 2>/dev/null || true
    # Stale spectre work dirs (>= 1 day old)
    find "$TMPDIR" -maxdepth 1 -type d -name 'spec_work_*' -mtime +1 \
        -exec rm -rf {} + 2>/dev/null || true
}

# ----- Helper: clean one L across all corners --------------------------------
clean_l() {
    local idx=$1
    local prefix="L$(printf '%03d' $idx)_"
    for d in "$RAWDIR"/raw_*/; do
        if [ -d "$d" ]; then
            # Delete directories matching this L index
            find "$d" -maxdepth 1 -type d -name "${prefix}*" -exec rm -rf {} + 2>/dev/null || true
        fi
    done
}

# ----- Main ------------------------------------------------------------------
echo "========================================"
echo "Pipeline: process config $CONFIG_MODULE, corners x nL, fine mode"
echo "Script:  $SCRIPTDIR"
echo "Raw:     $RAWDIR"
echo "MAT:     $MATDIR"
echo "Log:     $LOGDIR"
echo "========================================"

mkdir -p "$MATDIR" "$LOGDIR" "$TMPDIR"
cleanup_stale

cd "$SCRIPTDIR"
# L count comes from the same config the simulators read (no duplicated grid).
nL=$($PYTHON "$CONFIG_MODULE.py" $FINE | tail -n1)

echo "[*] Total L count: $nL"
echo ""

t_total_start=$(date +%s)

for l in $(seq 0 $((nL - 1))); do
    l_next=$((l + 1))
    t_l_start=$(date +%s)
    echo ""
    echo "===== L=$l / $((nL - 1)) ====="

    # --- 1. Simulation (all corners in parallel inside run_sim.py) ---
    echo "[1/3] Simulating ..."
    $PYTHON run_sim.py $FINE --outdir "$RAWDIR" --L-range "$l" "$l_next" \
        2>&1 | tee "$LOGDIR/sim_L${l}.log"
    echo "      Simulation OK"

    # --- 2. Extraction (all corners in parallel inside extract.py) ---
    echo "[2/3] Extracting ..."
    $PYTHON extract.py $FINE --srcdir "$RAWDIR" --outdir "$MATDIR" \
        --L-range "$l" "$l_next" --workers "$WORKERS" \
        2>&1 | tee "$LOGDIR/ext_L${l}.log"
    echo "      Extraction OK"

    # --- 3. Clean raw for this L ---
    echo "[3/3] Cleaning raw ..."
    clean_l "$l"
    echo "      Cleaned"

    # --- Timing ---
    t_l_end=$(date +%s)
    l_elapsed=$((t_l_end - t_l_start))
    total_elapsed=$((t_l_end - t_total_start))
    avg_l_time=$((total_elapsed / (l + 1)))
    remaining=$((nL - l - 1))
    eta=$((remaining * avg_l_time))

    printf "  [TIME] L=%d took %ds | Total %ds | Avg %ds/L | ETA %ds (~%dh%02dm)\n" \
        "$l" "$l_elapsed" "$total_elapsed" "$avg_l_time" "$eta" "$((eta / 3600))" "$((eta % 3600 / 60))"
done

t_total_end=$(date +%s)
total_time=$((t_total_end - t_total_start))
echo ""
echo "========================================"
printf "ALL DONE in %ds (~%dh%02dm%02ds)\n" "$total_time" "$((total_time / 3600))" "$((total_time % 3600 / 60))" "$((total_time % 60))"
echo "========================================"
