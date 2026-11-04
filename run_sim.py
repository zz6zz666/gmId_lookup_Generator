#!/usr/bin/env python3
"""Spectre simulation runner (no data extraction)."""
import importlib
import os, shutil, subprocess, sys, tempfile, time
from multiprocessing import Pool

from cli import pop_option, pop_range
from paths import PATHS

# Process config, selected with CONFIG_MODULE (exported from machine.env by
# pipeline.sh).  The child processes of the Pool inherit the environment, so
# they resolve the same module.
_cfg = importlib.import_module(os.environ.get('CONFIG_MODULE', 'config_tsmcN65'))
get_config = _cfg.get_config
write_netlist = _cfg.write_netlist


def run_sim_corner(args):
    corner, outdir, l_range = args
    os.makedirs(PATHS['TMPDIR'], exist_ok=True)
    workdir = tempfile.mkdtemp(prefix='spec_work_', dir=PATHS['TMPDIR'])
    cwd0 = os.getcwd()
    os.chdir(workdir)
    try:
        return _run_sim_corner(corner, outdir, l_range)
    finally:
        os.chdir(cwd0)
        shutil.rmtree(workdir, ignore_errors=True)


def _run_sim_corner(corner, outdir, l_range):
    c = get_config(corner)

    nL = len(c['LENGTH'])
    nVSB = len(c['VSB'])
    l_start, l_end = l_range
    l_start = max(0, l_start)
    l_end = min(nL, l_end)

    c['rundir_base'] = os.path.join(outdir, c['rundir_base'])
    os.makedirs(c['rundir_base'], exist_ok=True)

    n_jobs = (l_end - l_start) * nVSB
    print()
    print("===== Corner: " + corner + " =====")
    print("  L range %d..%d (%.3f..%.3f um) x %d VSB = %d jobs" %
          (l_start, l_end - 1, c['LENGTH'][l_start], c['LENGTH'][l_end - 1],
           nVSB, n_jobs))

    t_start = time.time()
    skipped = []
    for i in range(l_start, l_end):
        for j in range(nVSB):
            raw_dir = "%s/L%03d_%.3fum_VSB%03d_%+.2fV.raw" % (
                c['rundir_base'], i, c['LENGTH'][i], j, c['VSB'][j])

            write_netlist(c, raw_dir)

            with open(c['paramfile'], 'w') as f:
                f.write('parameters length = %.10g\n' % c['LENGTH'][i])
                f.write('parameters sb = %.10g\n' % c['VSB'][j])

            t0 = time.time()
            print(' [%s] L=%.3fum VSB=%+.2fV ... ' %
                  (c['corner'], c['LENGTH'][i], c['VSB'][j]),
                  end='', flush=True)

            result = subprocess.run(c['simcmd'], shell=True,
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                    timeout=300)
            if result.returncode != 0:
                print('SKIPPED (crash)')
                skipped.append('L=%.3fum VSB=%+.2fV' % (c['LENGTH'][i], c['VSB'][j]))
                continue
            print('OK (%.1fs)' % (time.time() - t0))
    if skipped:
        os.makedirs(PATHS['LOGDIR'], exist_ok=True)
        with open(os.path.join(PATHS['LOGDIR'], 'sim_skipped.log'), 'a') as fsk:
            for s in skipped:
                fsk.write('%s  %s\n' % (c['corner'], s))
        print("  [%s] SKIPPED %d VSB points: %s" % (c['corner'], len(skipped), skipped))
    print("  [%s] done in %.0fs" % (c['corner'], time.time() - t_start))
    return True


def main():
    args = sys.argv[1:]
    outdir = pop_option(args, '--outdir')
    l_range = pop_range(args, '--L-range')
    corners = args if args else get_config('tt')['corners']

    if l_range is None:
        c = get_config(corners[0])
        l_range = (0, len(c['LENGTH']))

    if outdir:
        print('Output dir:', outdir)
    t0 = time.time()
    with Pool(len(corners)) as pool:
        results = pool.map(run_sim_corner, [(c, outdir, l_range) for c in corners])
    failed = [corners[i] for i, r in enumerate(results) if not r]
    if failed:
        print('FAILED corners:', failed)
    print('Total: %.0fs' % (time.time() - t0))


if __name__ == '__main__':
    main()
