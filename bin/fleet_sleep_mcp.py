"""Renamed fleet_agent_mcp.py (T545, EPIC T542 C7): it serves every agent, not only sleep.

This name forwards for one version — an older session or caller may still load it.
"""
# compat-1v: 下一批删
import runpy as _runpy
from pathlib import Path as _Path

globals().update({_k: _v for _k, _v in _runpy.run_path(str(_Path(__file__).absolute().with_name('fleet_agent_mcp.py'))).items()
                  if not _k.startswith('__')})
