"""Shared argv helpers for the pipeline entry points.

run_sim.py and extract.py accept the same mix of options (``--outdir DIR``),
a two-value range (``--L-range START [END]``) and a trailing list of corner
names.  Every ``main()`` used to re-implement the same "find index, pop name,
pop value" dance; these helpers keep that behaviour in one place.

All helpers mutate the passed list in place, so the leftovers are exactly the
corner names.
"""


def pop_option(args, name, default=''):
    """Remove '--name VALUE' from *args* and return VALUE.

    A missing value (option at the end of the list) yields *default*, which
    also covers the option being absent altogether.
    """
    if name not in args:
        return default
    idx = args.index(name)
    args.pop(idx)
    return args.pop(idx) if idx < len(args) else default


def pop_int_option(args, name, default):
    """Like :func:`pop_option`, but convert the value to ``int``."""
    return int(pop_option(args, name, default))


def pop_range(args, name):
    """Remove '--name START [END]' and return ``(START, END)`` or ``None``.

    END defaults to ``START + 1`` when omitted, so the pipeline can request a
    single L point with '--L-range N'.
    """
    if name not in args:
        return None
    idx = args.index(name)
    args.pop(idx)
    if idx >= len(args):
        return None
    start = int(args.pop(idx))
    end = int(args.pop(idx)) if idx < len(args) else start + 1
    return (start, end)
