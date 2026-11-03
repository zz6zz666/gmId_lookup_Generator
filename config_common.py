"""Process-independent lookup-table configuration.

Everything in this module is shared by the per-process config modules
(``config_tsmcN40.py``, ``config_180nm.py``, ...):

* the stored variable list and the Spectre signal -> variable mapping,
* the Spectre netlist template,
* the assembly of the dict returned by ``get_config()``,
* the netlist writer.

A process module only supplies its own numbers (model card, sweep axes,
device size, corners) and calls :func:`build_config`; nothing that the
pipeline or the lookup API depends on is duplicated per process.

Semantics of the sweep axes (same as the reference flow): VGS and VDS are
swept from 0 V in equal steps, VSB likewise, and the L grid is given
explicitly (typically denser at short channel).
"""
import numpy as np

from paths import require

# Stored 4-D variables (L, VGS, VDS, VSB) written to the .h5 tables.
# Only genuinely independent quantities are kept: VDSAT is a model output,
# while FT / GM_ID / GAIN / ID_W are ratios recombined by the lookup API.
OUTVARS = [
    'ID', 'VT', 'IGD', 'IGS', 'GM', 'GMB', 'GDS',
    'CGG', 'CGS', 'CSG', 'CGD', 'CDG', 'CGB', 'CDD', 'CSS',
    'VDSAT',
]

OUTVARS_NOISE = ['STH', 'SFL']

# Spectre operating-point signal -> (unit, coefficients over OUTVARS).
# Coeffs: ID,VT,IGD,IGS,GM,GMB,GDS,CGG,CGS,CSG,CGD,CDG,CGB,CDD,CSS,VDSAT
N_SIGNALS = [
    ('mn:ids', 'A',        [1,0,0,0,0,0,0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
    ('mn:vth', 'V',        [0,1,0,0,0,0,0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
    ('mn:igd', 'A',        [0,0,1,0,0,0,0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
    ('mn:igs', 'A',        [0,0,0,1,0,0,0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
    ('mn:gm', 'S',         [0,0,0,0,1,0,0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
    ('mn:gmbs', 'S',       [0,0,0,0,0,1,0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
    ('mn:gds', 'S',        [0,0,0,0,0,0,1, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
    ('mn:cgg', 'F',        [0,0,0,0,0,0,0, 1, 0, 0, 0, 0, 0, 0, 0, 0]),
    ('mn:cgs', 'F',        [0,0,0,0,0,0,0, 0,-1, 0, 0, 0, 0, 0, 0, 0]),
    ('mn:cgd', 'F',        [0,0,0,0,0,0,0, 0, 0, 0,-1, 0, 0, 0, 0, 0]),
    ('mn:cgb', 'F',        [0,0,0,0,0,0,0, 0, 0, 0, 0, 0,-1, 0, 0, 0]),
    ('mn:cdd', 'F',        [0,0,0,0,0,0,0, 0, 0, 0, 0, 0, 0, 1, 0, 0]),
    ('mn:cdg', 'F',        [0,0,0,0,0,0,0, 0, 0, 0, 0,-1, 0, 0, 0, 0]),
    ('mn:css', 'F',        [0,0,0,0,0,0,0, 0, 0, 0, 0, 0, 0, 0, 1, 0]),
    ('mn:csg', 'F',        [0,0,0,0,0,0,0, 0, 0,-1, 0, 0, 0, 0, 0, 0]),
    ('mn:cjd', 'F',        [0,0,0,0,0,0,0, 0, 0, 0, 0, 0, 0, 1, 0, 0]),
    ('mn:cjs', 'F',        [0,0,0,0,0,0,0, 0, 0, 0, 0, 0, 0, 0, 1, 0]),
    ('mn:vdsat', 'V',      [0,0,0,0,0,0,0, 0, 0, 0, 0, 0, 0, 0, 0, 1]),
]

P_SIGNALS = [
    ('mp:ids', 'A',        [-1,0, 0, 0,0,0,0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
    ('mp:vth', 'V',        [0,-1, 0, 0,0,0,0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
    ('mp:igd', 'A',        [0, 0,-1, 0,0,0,0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
    ('mp:igs', 'A',        [0, 0, 0,-1,0,0,0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
    ('mp:gm', 'S',         [0, 0, 0, 0,1,0,0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
    ('mp:gmbs', 'S',       [0, 0, 0, 0,0,1,0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
    ('mp:gds', 'S',        [0, 0, 0, 0,0,0,1, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
    ('mp:cgg', 'F',        [0, 0, 0, 0,0,0,0, 1, 0, 0, 0, 0, 0, 0, 0, 0]),
    ('mp:cgs', 'F',        [0, 0, 0, 0,0,0,0, 0,-1, 0, 0, 0, 0, 0, 0, 0]),
    ('mp:cgd', 'F',        [0, 0, 0, 0,0,0,0, 0, 0, 0,-1, 0, 0, 0, 0, 0]),
    ('mp:cgb', 'F',        [0, 0, 0, 0,0,0,0, 0, 0, 0, 0, 0,-1, 0, 0, 0]),
    ('mp:cdd', 'F',        [0, 0, 0, 0,0,0,0, 0, 0, 0, 0, 0, 0, 1, 0, 0]),
    ('mp:cdg', 'F',        [0, 0, 0, 0,0,0,0, 0, 0, 0, 0,-1, 0, 0, 0, 0]),
    ('mp:css', 'F',        [0, 0, 0, 0,0,0,0, 0, 0, 0, 0, 0, 0, 0, 1, 0]),
    ('mp:csg', 'F',        [0, 0, 0, 0,0,0,0, 0, 0,-1, 0, 0, 0, 0, 0, 0]),
    ('mp:cjd', 'F',        [0, 0, 0, 0,0,0,0, 0, 0, 0, 0, 0, 0, 1, 0, 0]),
    ('mp:cjs', 'F',        [0, 0, 0, 0,0,0,0, 0, 0, 0, 0, 0, 0, 0, 1, 0]),
    ('mp:vdsat', 'V',      [0, 0, 0, 0,0,0,0, 0, 0, 0, 0, 0, 0, 0, 0, 1]),
]

N_NOISE = [('mn:id', ''), ('mn:fn', '')]
P_NOISE = [('mp:id', ''), ('mp:fn', '')]


def _netlist_template(tag, corner, paramfile):
    """Spectre netlist with placeholders filled in by :func:`write_netlist`.

    One nch and one pch device share the netlist: the pch source is driven
    with the negated bias voltages so a single sweep fills both devices.
    """
    return (
        f'//techsweep_{tag}_{corner}.scs' '\n'
        '%s'
        f'include "{paramfile}"' '\n'
        'save mn:ids mn:vth mn:igd mn:igs mn:gm mn:gmbs mn:gds '
        'mn:cgg mn:cgs mn:cgd mn:cgb mn:cdd mn:cdg mn:css mn:csg mn:cjd mn:cjs '
        'mn:vdsat\n'
        'save mp:ids mp:vth mp:igd mp:igs mp:gm mp:gmbs mp:gds '
        'mp:cgg mp:cgs mp:cgd mp:cgb mp:cdd mp:cdg mp:css mp:csg mp:cjd mp:cjs '
        'mp:vdsat\n'
        'parameters gs=0 ds=0 \n'
        'vnoi     (vx  0)         vsource dc=0  \n'
        'vdsn     (vdn vx)        vsource dc=ds  \n'
        'vgsn     (vgn 0)         vsource dc=gs  \n'
        'vbsn     (vbn 0)         vsource dc=-sb \n'
        'vdsp     (vdp vx)        vsource dc=-ds \n'
        'vgsp     (vgp 0)         vsource dc=-gs \n'
        'vbsp     (vbp 0)         vsource dc=sb  \n'
        '\n'
        'mn       (vdn vgn 0 vbn) %s  l=length*1e-6 w=%de-6 m=%d \n'
        'mp       (vdp vgp 0 vbp) %s  l=length*1e-6 w=%de-6 m=%d \n'
        '\n'
        'simOptions options gmin=1e-13 reltol=1e-4 vabstol=1e-6 iabstol=1e-10 '
        'temp=%d tnom=27 rawfmt=psfbin rawfile="%s" \n'
        'sweepvds sweep param=ds start=0 stop=%.10g step=%.10g { \n'
        '   sweepvgs dc param=gs start=0 stop=%.10g step=%.10g \n'
        '}\n'
        'sweepvds_noise sweep param=ds start=0 stop=%.10g step=%.10g { \n'
        '   sweepvgs_noise noise freq=1 oprobe=vnoi param=gs start=0 stop=%.10g step=%.10g \n'
        '}\n'
    )


def build_config(corner, *, tag, info, sections, modeln, modelp, temp,
                 width, nfing, save_prefix,
                 vgs_max, vgs_step, vds_max, vds_step, vsb_max, vsb_step,
                 length, corners):
    """Assemble the config dict for one device/corner of one process.

    Parameters
    ----------
    corner : str
        Corner label, also used in file names (``nch_tt.h5``).
    tag : str
        Short process tag used in transient file names
        (``techsweep_<tag>_<corner>.scs``, ``raw_<tag>_<corner>``).
    info : str
        Human-readable process description stored in the ``INFO`` metadata.
    sections : list of str
        Spectre ``include ... section=`` list. Empty means a plain include;
        the string ``{corner}`` is replaced by *corner*.
    modeln, modelp : str
        Model names used in the netlist for the n / p device.
    temp : float
        Simulation temperature in K.
    width, nfing : float, int
        Per-finger width in um and finger count (``w=`` and ``m=``).
    save_prefix : str
        Prefix for the ``.h5`` file names; keeps processes from overwriting
        each other when they share the output directory.
    vgs_max, vgs_step, vds_max, vds_step, vsb_max, vsb_step : float
        Sweep ranges/steps in V.
    length : array_like
        L grid in um.
    corners : list of str
        All corners available for this process.
    """
    if corner not in corners:
        raise ValueError(f"unknown corner {corner!r} (choose from {corners})")

    c = {}
    c['corner'] = corner
    c['corners'] = list(corners)
    c['tag'] = tag

    base = require('PDK_MODEL_FILE')
    c['modelfile'] = ''.join(
        f'include "{base}"' + (f' section={s.format(corner=corner)}' if s else '')
        + '\n'
        for s in sections
    )
    c['modelinfo'] = info
    c['temp'] = temp
    c['modeln'] = modeln
    c['modelp'] = modelp

    c['simcmd'] = (require('SPECTRE_BIN') + ' -64 '
                   f'techsweep_{tag}_{corner}.scs '
                   f'+log techsweep_{tag}_{corner}.out')
    c['rundir_base'] = f'raw_{tag}_{corner}'
    c['paramfile'] = f'techsweep_params_{tag}_{corner}.scs'
    c['savefilen'] = f'{save_prefix}{modeln}_{corner}'
    c['savefilep'] = f'{save_prefix}{modelp}_{corner}'

    c['VGS_max'] = vgs_max
    c['VGS_step'] = vgs_step
    c['VDS_max'] = vds_max
    c['VDS_step'] = vds_step
    c['VSB_max'] = vsb_max
    c['VSB_step'] = vsb_step
    c['LENGTH'] = np.asarray(length, dtype=float)

    c['VGS'] = np.arange(0, vgs_max + vgs_step / 2, vgs_step)
    c['VDS'] = np.arange(0, vds_max + vds_step / 2, vds_step)
    c['VSB'] = np.arange(0, vsb_max + vsb_step / 2, vsb_step)

    c['WIDTH'] = width   # um per finger, used in the netlist (w=)
    c['NFING'] = nfing   # finger count (m=); total width = WIDTH*NFING

    c['outvars'] = list(OUTVARS)
    c['n'] = N_SIGNALS
    c['p'] = P_SIGNALS
    c['outvars_noise'] = list(OUTVARS_NOISE)
    c['n_noise'] = list(N_NOISE)
    c['p_noise'] = list(P_NOISE)

    c['_netlist_tmpl'] = _netlist_template(tag, corner, c['paramfile'])
    return c


def write_netlist(c, raw_dir):
    netlist = c['_netlist_tmpl'] % (
        c['modelfile'],
        c['modeln'], c['WIDTH'], c['NFING'],
        c['modelp'], c['WIDTH'], c['NFING'],
        c['temp'] - 273, raw_dir,
        c['VDS_max'], c['VDS_step'],
        c['VGS_max'], c['VGS_step'],
        c['VDS_max'], c['VDS_step'],
        c['VGS_max'], c['VGS_step'],
    )
    netlist_file = f'techsweep_{c["tag"]}_{c["corner"]}.scs'
    with open(netlist_file, 'w') as fid:
        fid.write(netlist)
    return netlist_file


def print_length_count(get_config, argv=None):
    """Print the number of L points; ``python config_<proc>.py [--fine]``."""
    import sys

    argv = sys.argv[1:] if argv is None else list(argv)
    args = [a for a in argv if a != '--fine']
    print(len(get_config(args[0] if args else 'tt',
                         coarse='--fine' not in argv)['LENGTH']))
