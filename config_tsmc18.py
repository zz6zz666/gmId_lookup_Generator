"""TSMC 0.18 um Mixed-Signal SALICIDE GPII-A (tsmc18) 1.8 V core: nch / pch, BSIM4.

Model card ``cmn018_gp2a_5v_v1d4.scs`` (T-018-CM-SP-012, v1.4; 1.8 V core /
5 V I/O), included as ``<corner>`` only: each corner section pulls in the
``setup`` and ``mos`` sections itself.

The four axes follow ``techsweep_config_bsim3_180_hspice.m`` of the gm/ID book
(25 mV VGS/VDS, 100 mV VSB, 32 L points); only the device size differs.  The
reference device is W = 10 um in 5 fingers (``w=2e-6 m=5``) and every table is
normalised to this total width.  Everything else is shared in config_common.py.
"""
import numpy as np

from config_common import (build_config, print_length_count,  # noqa: F401
                           write_netlist)

TAG = 'tsmc18'
INFO = 'tsmc18, BSIM4, 1.8V'
SECTIONS = ['{corner}']
CORNERS = ['tt', 'ff', 'ss', 'fs', 'sf']
TEMP = 300
VDD = 1.8
VSB_MAX = 1.0

WIDTH = 2      # um per finger
NFING = 5      # fingers -> total width 10 um

VGS_STEP = 0.025
VDS_STEP = 0.025
VSB_STEP = 0.1
LENGTH = np.concatenate([
    np.arange(18, 51, 2) / 100,      # 0.18 - 0.50 um, step 0.02 (17 pts)
    np.arange(60, 201, 10) / 100,    # 0.60 - 2.00 um, step 0.10 (15 pts)
])


def get_config(corner='tt'):
    return build_config(
        corner,
        tag=TAG, info=INFO, sections=SECTIONS,
        modeln='nch', modelp='pch', temp=TEMP,
        width=WIDTH, nfing=NFING, save_prefix='tsmc18_',
        vgs_max=VDD, vgs_step=VGS_STEP,
        vds_max=VDD, vds_step=VDS_STEP,
        vsb_max=VSB_MAX, vsb_step=VSB_STEP,
        length=LENGTH, corners=CORNERS,
    )


if __name__ == '__main__':
    print_length_count(get_config)
