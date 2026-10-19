# Embedded Python with a ._pth file does not put the script's folder on
# sys.path the way a normal Python does.  Strata runs scripts such as
# serve\server.py and tools\*.py that import their neighbours, so restore it.
import os
import sys

if sys.argv and sys.argv[0] not in ("", "-c", "-m"):
    _script_dir = os.path.dirname(os.path.abspath(sys.argv[0]))
    if _script_dir not in sys.path:
        sys.path.insert(0, _script_dir)
