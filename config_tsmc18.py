"""TSMC 0.18 um (tsmc18) devices: nch / pch, BSIM4.

The four sweep axes follow the reference 180 nm characterization setup
(``techsweep_config_bsim3_180_hspice.m`` from the gm/ID book; only the axes
are taken from it -- the device model used here is BSIM4):

    VGS   0 .. 1.8 V, 25 mV step                     ->  73 points
    VDS   0 .. 1.8 V, 25 mV step                     ->  73 points
    VSB   0 .. 1.0 V, 100 mV step                    ->  11 points
    L     0.18 .. 0.50 um, 20 nm step                ->  17 points
          0.60 .. 2.00 um, 100 nm step               ->  15 points
    --------------------------------------------------------------
    32 x 73 x 73 x 11 = 1,875,808 points per device/corner

The only deviation from that setup is the device size: the reference uses
W = 5 um with a single finger, this table keeps the project's 10 um in
5 fingers (``w=2e-6 m=5``).

Everything else -- netlist template, stored variables, corner handling,
file naming -- is the shared code in config_common.py.
"""
import numpy as np

from config_common import (build_config, print_length_count,  # noqa: F401
                           write_netlist)

TAG = 'tsmc18'
INFO = 'tsmc18, BSIM4, 1.8V'
# Spectre include lines.  This reuses the TSMC-style split
# (stat / global / corner sections); for a single-section model card use
# SECTIONS = [] instead.
SECTIONS = ['stat', 'global', '{corner}']
CORNERS = ['tt', 'ff', 'ss', 'fs', 'sf']
TEMP = 300
VDD = 1.8
VSB_MAX = 1.0

WIDTH = 2      # um per finger
NFING = 5      # fingers -> total width 10 um

# Quick preview grid (not from the book): keep it small for smoke tests.
COARSE = {
    'VGS_step': 0.1,
    'VDS_step': 0.1,
    'VSB_step': 0.2,
    'LENGTH': np.array([0.18, 0.25, 0.35, 0.5, 0.7, 1.0, 1.5, 2.0]),
}

# Reference grid, see the module docstring.
FINE = {
    'VGS_step': 0.025,
    'VDS_step': 0.025,
    'VSB_step': 0.1,
    'LENGTH': np.concatenate([
        np.arange(18, 51, 2) / 100,      # 0.18 - 0.50 um, step 0.02 (17 pts)
        np.arange(60, 201, 10) / 100,    # 0.60 - 2.00 um, step 0.10 (15 pts)
    ]),
}


def get_config(corner='tt', coarse=True):
    grid = COARSE if coarse else FINE
    return build_config(
        corner,
        tag=TAG, info=INFO, sections=SECTIONS,
        modeln='nch', modelp='pch', temp=TEMP,
        width=WIDTH, nfing=NFING, save_prefix='tsmc18_',
        vgs_max=VDD, vgs_step=grid['VGS_step'],
        vds_max=VDD, vds_step=grid['VDS_step'],
        vsb_max=VSB_MAX, vsb_step=grid['VSB_step'],
        length=grid['LENGTH'], corners=CORNERS,
    )


if __name__ == '__main__':
    print_length_count(get_config)
