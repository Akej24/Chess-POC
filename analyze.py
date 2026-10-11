"""Analyze a position with Stockfish.

Usage:
    python analyze.py                       # starting position
    python analyze.py "<FEN>" --depth 20
"""

import argparse

import chess

from engine import evaluate, open_engine


def main():
    parser = argparse.ArgumentParser(description="Analyze a position with Stockfish")
    parser.add_argument("fen", nargs="?", default=chess.STARTING_FEN)
    parser.add_argument("--depth", type=int, default=18)
    parser.add_argument("--threads", type=int, default=2)
    args = parser.parse_args()

    board = chess.Board(args.fen)
    print(board, "\n")

    with open_engine(threads=args.threads) as engine:
        score, best, pv = evaluate(engine, board, depth=args.depth)

    print(f"Evaluation (White's view): {score}")
    if best:
        print(f"Best move: {board.san(best)}")
        # Print the principal variation in SAN
        line, tmp = [], board.copy()
        for mv in pv[:8]:
            line.append(tmp.san(mv))
            tmp.push(mv)
        print("Main line:", " ".join(line))


if __name__ == "__main__":
    main()
