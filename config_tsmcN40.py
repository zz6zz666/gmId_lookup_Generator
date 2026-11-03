"""TSMC N40 (CRN40LP) 1.1 V core devices: nch / pch, BSIM4.

Only the process-specific numbers live here; the netlist template, the
stored-variable list and the sweep assembly are shared in config_common.py.

The reference device is W = 10 um in 5 fingers (2 um per finger), i.e. the
netlist carries ``w=2e-6 m=5`` and every table is normalised to W = 10 um.
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

COARSE = {
    'VGS_step': 0.02,
    'VDS_step': 0.02,
    'VSB_step': 0.15,
    'LENGTH': np.array([0.04, 0.05, 0.06, 0.08, 0.1, 0.13, 0.18,
                        0.25, 0.35, 0.5, 0.7, 1.0, 1.5, 2.0]),
}

FINE = {
    'VGS_step': 0.02,
    'VDS_step': 0.02,
    'VSB_step': 0.1,
    'LENGTH': np.concatenate([
        np.arange(4, 15) / 100,          # 0.04 - 0.14 um, step 0.01 (11 pts)
        np.arange(16, 51, 2) / 100,      # 0.16 - 0.50 um, step 0.02 (18 pts)
        np.arange(55, 101, 5) / 100,     # 0.55 - 1.00 um, step 0.05 (10 pts)
        np.array([1.2, 1.4, 1.6, 1.8, 2.0]),  # 5 pts (grid stops at 2 um)
    ]),
}


def get_config(corner='tt', coarse=True):
    grid = COARSE if coarse else FINE
    return build_config(
        corner,
        tag=TAG, info=INFO, sections=SECTIONS,
        modeln='nch', modelp='pch', temp=TEMP,
        width=WIDTH, nfing=NFING, save_prefix='',
        vgs_max=VDD, vgs_step=grid['VGS_step'],
        vds_max=VDD, vds_step=grid['VDS_step'],
        vsb_max=VSB_MAX, vsb_step=grid['VSB_step'],
        length=grid['LENGTH'], corners=CORNERS,
    )


if __name__ == '__main__':
    print_length_count(get_config)
