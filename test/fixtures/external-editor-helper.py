#!/usr/bin/env python3
"""Harmless local editor fixture: mutate only the prompt path provided by the caller."""
import json
import os
from pathlib import Path
import signal
import sys
import time

mode = sys.argv[1]
path = Path(sys.argv[-1])
if mode == "edited":
    path.write_text("\ufeffedited α draft\n\n", encoding="utf-8")
elif mode == "unchanged":
    pass
elif mode == "nonzero":
    path.write_text("must not replace draft", encoding="utf-8")
    sys.exit(7)
elif mode == "signal":
    os.kill(os.getpid(), signal.SIGTERM)
elif mode == "argv":
    path.write_text(json.dumps(sys.argv[2:-1]), encoding="utf-8")
elif mode == "cwd":
    path.write_text(Path.cwd().name, encoding="utf-8")
elif mode == "invalid":
    path.write_bytes(b"\xff\xfe")
elif mode == "oversized":
    path.write_text("x" * 4096, encoding="utf-8")
elif mode == "removed":
    path.unlink()
elif mode == "hang":
    print("EXTERNAL_EDITOR_STARTED", flush=True)
    time.sleep(30)
elif mode == "tty":
    assert os.isatty(0) and os.isatty(1)
    print("EXTERNAL_EDITOR_TTY_READY", flush=True)
    line = sys.stdin.readline()
    path.write_text("edited through tty: " + line, encoding="utf-8")
else:
    sys.exit(9)
