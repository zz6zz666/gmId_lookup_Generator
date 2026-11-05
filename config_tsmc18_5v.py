"""TSMC 0.18 um Mixed-Signal GPII-A (tsmc18) 5 V I/O devices: nch_5 / pch_5.

Same model card as the 1.8 V core devices (``cmn018_gp2a_5v_v1d4.scs``,
T-018-CM-SP-012, v1.4), but the 5 V family lives in its own sections:
``tt_5`` / ``ff_5`` / ``ss_5`` / ``fs_5`` / ``sf_5``.  ``SECTIONS`` keeps the
plain corner names and appends the ``_5`` suffix, so the CORNER metadata and
the file names stay ``tt`` (not ``tt_5``); the device name carries the suffix
instead: ``tsmc18_nch_5_tt.h5``.

Bias grid: 0 ... 5 V in 50 mV (101 points) for VGS/VDS, VSB 0 ... 3.5 V in
0.5 V (8 points).  L runs from 0.6 um - the shortest channel accepted by
``nch_5`` (``pch_5`` also allows 0.5 um) - up to 5 um; the pch tables get the
0.5 / 0.55 um rows from a separate pch-only short sweep, so they carry 27 L
points against 25 for nch.  Reference device: W = 10 um in 5 fingers
(``w=2e-6 m=5``), so every table is normalised to this total width.
"""
import numpy as np

from config_common import (build_config, print_length_count,  # noqa: F401
                           write_netlist)

TAG = 'tsmc18_5v'
INFO = 'tsmc18 5V, BSIM4, 5.0V'
SECTIONS = ['{corner}_5']
CORNERS = ['tt', 'ff', 'ss', 'fs', 'sf']
TEMP = 300
VDD = 5.0
VSB_MAX = 3.5

WIDTH = 2      # um per finger
NFING = 5      # fingers -> total width 10 um

VGS_STEP = 0.05
VDS_STEP = 0.05
VSB_STEP = 0.5
LENGTH = np.concatenate([
    np.arange(60, 101, 5) / 100,          # 0.60 - 1.00 um, step 0.05 (9 pts)
    np.arange(110, 201, 10) / 100,        # 1.10 - 2.00 um, step 0.10 (10 pts)
    np.array([2.5, 3.0, 3.5, 4.0, 4.5, 5.0]),   # long channel (6 pts)
])


def get_config(corner='tt'):
    return build_config(
        corner,
        tag=TAG, info=INFO, sections=SECTIONS,
        modeln='nch_5', modelp='pch_5', temp=TEMP,
        width=WIDTH, nfing=NFING, save_prefix='tsmc18_',
        vgs_max=VDD, vgs_step=VGS_STEP,
        vds_max=VDD, vds_step=VDS_STEP,
        vsb_max=VSB_MAX, vsb_step=VSB_STEP,
        length=LENGTH, corners=CORNERS,
    )


if __name__ == '__main__':
    print_length_count(get_config)
