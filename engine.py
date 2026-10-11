"""Thin wrapper around Stockfish using python-chess (UCI protocol)."""

import os
import shutil
from contextlib import contextmanager

import chess
import chess.engine


def find_stockfish() -> str:
    """Locate the Stockfish binary.

    Order: STOCKFISH_PATH env var, then PATH, then ./stockfish/ folder.
    """
    env_path = os.environ.get("STOCKFISH_PATH")
    if env_path and os.path.isfile(env_path):
        return env_path

    on_path = shutil.which("stockfish")
    if on_path:
        return on_path

    local_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), "stockfish")
    if os.path.isdir(local_dir):
        for name in sorted(os.listdir(local_dir)):
            full = os.path.join(local_dir, name)
            if name.lower().startswith("stockfish") and os.path.isfile(full):
                if os.access(full, os.X_OK) or name.lower().endswith(".exe"):
                    return full

    raise FileNotFoundError(
        "Stockfish not found. Install it (see README.md), then either put it on "
        "your PATH, drop the binary in ./stockfish/, or set STOCKFISH_PATH."
    )


@contextmanager
def open_engine(threads: int = 2, hash_mb: int = 256, skill_level: int | None = None):
    """Context manager that starts Stockfish and always shuts it down.

    skill_level: 0 (weakest) .. 20 (full strength), or None for full strength.
    """
    engine = chess.engine.SimpleEngine.popen_uci(find_stockfish())
    try:
        options = {"Threads": threads, "Hash": hash_mb}
        if skill_level is not None:
            options["Skill Level"] = skill_level
        engine.configure(options)
        yield engine
    finally:
        engine.quit()


def evaluate(engine, board: chess.Board, depth: int = 18):
    """Return (score string from White's view, best move, principal variation)."""
    info = engine.analyse(board, chess.engine.Limit(depth=depth))
    score = info["score"].white()
    pv = info.get("pv", [])
    return score, (pv[0] if pv else None), pv
