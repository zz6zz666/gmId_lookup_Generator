"""TSMC N40 (CRN40LP) 1.1 V core devices: nch / pch, BSIM4.

Model card ``crn40lp_2d5_v2d0_2.scs`` (T-N40-CM-SP-001, v2.0_2), included as
``stat`` + ``global`` + ``<corner>``.

Reference device: W = 10 um in 5 fingers (``w=2e-6 m=5``); every table is
normalised to this total width.  The netlist template, the stored-variable
list and the sweep assembly are shared in config_common.py.
"""
import numpy as np

from config_common import (build_config, print_length_count,  # noqa: F401
                           write_netlist)

TAG = 'tsmcN40'
INFO = 'tsmcN40, BSIM4, 1.1V'
SECTIONS = ['stat', 'global', '{corner}']
CORNERS = ['tt', 'ff', 'ss', 'fs', 'sf']
TEMP = 300
VDD = 1.1
VSB_MAX = 0.8

WIDTH = 2      # um per finger
NFING = 5      # fingers -> total width 10 um

VGS_STEP = 0.02
VDS_STEP = 0.02
VSB_STEP = 0.1
LENGTH = np.concatenate([
    np.arange(4, 15) / 100,               # 0.04 - 0.14 um, step 0.01 (11 pts)
    np.arange(16, 51, 2) / 100,           # 0.16 - 0.50 um, step 0.02 (18 pts)
    np.arange(55, 101, 5) / 100,          # 0.55 - 1.00 um, step 0.05 (10 pts)
    np.array([1.2, 1.4, 1.6, 1.8, 2.0]),  # 5 pts (grid stops at 2 um)
])


def get_config(corner='tt'):
    return build_config(
        corner,
        tag=TAG, info=INFO, sections=SECTIONS,
        modeln='nch', modelp='pch', temp=TEMP,
        width=WIDTH, nfing=NFING, save_prefix='tsmcN40_',
        vgs_max=VDD, vgs_step=VGS_STEP,
        vds_max=VDD, vds_step=VDS_STEP,
        vsb_max=VSB_MAX, vsb_step=VSB_STEP,
        length=LENGTH, corners=CORNERS,
    )


if __name__ == '__main__':
    print_length_count(get_config)
