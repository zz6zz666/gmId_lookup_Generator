"""TSMC 65 nm LP (CRN65LP) 1.2 V core devices: nch / pch, BSIM4.

Model card ``crn65lp_2d5_lk_v1d7.scs`` (T-N65-CM-SP-007, v1.7; TSMC 65 nm
Mixed Signal RF SALICIDE Low-K IMD, 1.2 / 2.5 / 3.3 V), included as
``stat_noise`` + ``<corner>``: the corner sections reference the flicker-noise
statistics variables (``par1fn_mc`` ...), which ``stat_noise`` defines as zero
for a nominal run.

The bias grid follows ``techsweep_config_psp_65_spectre.m`` of the gm/ID book
(0 ... VDD, 100 mV VSB) with VGS/VDS tightened from 25 mV to 20 mV so the step
matches the other process tables; the L axis is the book's 0.06-1 um schedule
extended to 2 um.  The reference device is W = 10 um in 5 fingers
(``w=2e-6 m=5``) and every table is normalised to this total width.
Everything else is shared in config_common.py.
"""
import numpy as np

from config_common import (build_config, print_length_count,  # noqa: F401
                           write_netlist)

TAG = 'tsmcN65'
INFO = 'tsmcN65, BSIM4, 1.2V'
SECTIONS = ['stat_noise', '{corner}']
CORNERS = ['tt', 'ff', 'ss', 'fs', 'sf']
TEMP = 300
VDD = 1.2
VSB_MAX = 0.8

WIDTH = 2      # um per finger
NFING = 5      # fingers -> total width 10 um

VGS_STEP = 0.02
VDS_STEP = 0.02
VSB_STEP = 0.1
LENGTH = np.concatenate([
    np.arange(6, 21, 1) / 100,        # 0.06 - 0.20 um, step 0.01 (15 pts)
    np.arange(25, 101, 5) / 100,      # 0.25 - 1.00 um, step 0.05 (16 pts)
    np.arange(110, 201, 10) / 100,    # 1.10 - 2.00 um, step 0.10 (10 pts)
])


def get_config(corner='tt'):
    return build_config(
        corner,
        tag=TAG, info=INFO, sections=SECTIONS,
        modeln='nch', modelp='pch', temp=TEMP,
        width=WIDTH, nfing=NFING, save_prefix='tsmcN65_',
        vgs_max=VDD, vgs_step=VGS_STEP,
        vds_max=VDD, vds_step=VDS_STEP,
        vsb_max=VSB_MAX, vsb_step=VSB_STEP,
        length=LENGTH, corners=CORNERS,
    )


if __name__ == '__main__':
    print_length_count(get_config)
