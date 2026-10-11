"""Chat-style Stockfish helper: paste a FEN, get the best move back as a FEN.

Usage:
    python bestmove.py                 # interactive: paste FENs one per line
    python bestmove.py "<FEN>"         # one-shot
Options:
    --depth N     search depth (default 20)
    --time S      search time in seconds (overrides depth)
    --threads N   engine threads (default 2)

For each FEN it prints:
    - the best move (SAN and UCI)
    - the evaluation (White's view)
    - the FEN of the position AFTER the best move is played
Type 'quit' or press Ctrl+C / Ctrl+D to exit.
"""

import argparse
import sys

import chess
import chess.engine

from engine import open_engine

def best_move_fen(engine, fen: str, limit: chess.engine.Limit) -> str:
    try:
        board = chess.Board(fen)
    except ValueError as exc:
        return f"Invalid FEN: {exc}"

    if not board.is_valid():
        return "Invalid position (illegal piece setup, kings in check, etc.)."
    if board.is_game_over():
        outcome = board.outcome()
        return f"Game is already over: {board.result()} ({outcome.termination.name})."

    info = engine.analyse(board, limit)
    pv = info.get("pv")
    if not pv:
        return "Engine returned no move."

    move = pv[0]
    san = board.san(move)
    score = info["score"].white()
    board.push(move)

    return (
        f"Best move : {san} ({move.uci()})\n"
        f"Eval (W)  : {score}\n"
        f"FEN after : {board.fen()}"
    )


def main():
    parser = argparse.ArgumentParser(description="Best move from a FEN, returned as a FEN")
    parser.add_argument("fen", nargs="?", help="FEN to analyze (omit for interactive mode)")
    parser.add_argument("--depth", type=int, default=20)
    parser.add_argument("--time", type=float, default=None)
    parser.add_argument("--threads", type=int, default=2)
    args = parser.parse_args()

    limit = (
        chess.engine.Limit(time=args.time)
        if args.time is not None
        else chess.engine.Limit(depth=args.depth)
    )

    with open_engine(threads=args.threads) as engine:
        if args.fen:
            print(best_move_fen(engine, args.fen, limit))
            return

        print("Paste a FEN and press Enter ('quit' to exit).")
        while True:
            try:
                line = input("\nFEN> ").strip()
            except (EOFError, KeyboardInterrupt):
                print()
                break
            if not line:
                continue
            if line.lower() in {"quit", "exit", "q"}:
                break
            print(best_move_fen(engine, line, limit))

if __name__ == "__main__":
    sys.exit(main())
