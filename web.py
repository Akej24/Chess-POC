"""Flask server: send a FEN over HTTP, see Stockfish's best move as an arrow.

Start the server:
    python web.py
Open http://127.0.0.1:8000 in your browser, then send a FEN from any terminal:

    # JSON body
    curl -X POST http://127.0.0.1:8000/api/fen \
         -H "Content-Type: application/json" \
         -d '{"fen": "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"}'

    # form field
    curl -X POST http://127.0.0.1:8000/api/fen \
         --data-urlencode "fen=rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"

    # query string (also works pasted into a browser's address bar)
    curl -G http://127.0.0.1:8000/api/fen \
         --data-urlencode "fen=rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"

The JSON reply contains the best move and the FEN after it. The open browser
page updates by itself and shows the position you sent with an arrow from the
square the suggested piece stands on to the square it should move to.
Use fen=start for the initial position.

Options:
    --depth N          search depth (default 18)
    --time S           search time in seconds (overrides depth)
    --threads N        engine threads (default 2)
    --host H           bind address (default 127.0.0.1)
    --port P           port (default 8000; macOS uses 5000 for AirPlay)
    --orientation O    white | black | turn  (default white)
"""

import argparse
import threading

import chess
import chess.engine
import chess.svg
from flask import Flask, Response, jsonify, request

from engine import open_engine

app = Flask(__name__)

_lock = threading.Lock()          # guards _state (shared with the page's polling)
_engine_lock = threading.Lock()   # one analysis at a time on the single engine
_state = {"ready": False, "version": 0}

# Fields returned to API callers (the SVGs are only for the page).
PUBLIC_KEYS = ("fen", "best_fen", "san", "uci", "eval", "depth", "turn")

PAGE = """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Stockfish FEN viewer</title>
<style>
  :root {
    --bg: #f6f5f2; --card: #ffffff; --text: #1f2328; --muted: #6a7078;
    --accent: #2f7d4f; --border: #dcdad4;
  }
  @media (prefers-color-scheme: dark) {
    :root {
      --bg: #161a17; --card: #1f2421; --text: #e8ebe9; --muted: #9aa39d;
      --accent: #6fcf97; --border: #323a35;
    }
  }
  * { box-sizing: border-box; }
  body {
    margin: 0; padding: 24px 16px; background: var(--bg); color: var(--text);
    font: 16px/1.5 system-ui, -apple-system, "Segoe UI", sans-serif;
  }
  h1 { font-size: 1.25rem; margin: 0 0 4px; text-align: center; }
  .status { text-align: center; color: var(--muted); margin: 0 0 20px; min-height: 1.5em; }
  code { font: 13px ui-monospace, Menlo, Consolas, monospace; }
  .boards {
    display: flex; flex-wrap: wrap; gap: 24px; justify-content: center;
    max-width: 1100px; margin: 0 auto;
  }
  .card {
    flex: 1 1 320px; max-width: 520px; background: var(--card);
    border: 1px solid var(--border); border-radius: 12px; padding: 16px;
  }
  .card h2 { font-size: 1rem; margin: 0 0 12px; }
  .board svg { display: block; width: 100%; height: auto; }
  .fen {
    margin-top: 12px; color: var(--muted); word-break: break-all;
    font: 13px/1.4 ui-monospace, Menlo, Consolas, monospace;
  }
  .move { color: var(--accent); }
</style>
</head>
<body>
  <h1>Stockfish FEN viewer</h1>
  <p class="status" id="status">Waiting for a FEN &mdash; send one to <code>/api/fen</code>.</p>
  <div class="boards" id="boards" hidden>
    <section class="card">
      <h2>Suggested move: <span class="move" id="move-san"></span></h2>
      <div class="board" id="board-current"></div>
      <div class="fen" id="fen-current"></div>
    </section>
  </div>
<script>
  let version = -1;

  function render(s) {
    document.getElementById("boards").hidden = false;
    // SVG is generated server-side by python-chess from a validated position.
    document.getElementById("board-current").innerHTML = s.board_svg;
    document.getElementById("fen-current").textContent = s.fen;
    document.getElementById("move-san").textContent = s.san + " (" + s.uci + ")";
    document.getElementById("status").textContent =
      s.turn + " to move · eval " + s.eval + " (White's view)" +
      (s.depth ? " · depth " + s.depth : "");
  }

  async function poll() {
    try {
      const r = await fetch("/api/state", { cache: "no-store" });
      const s = await r.json();
      if (s.ready && s.version !== version) {
        version = s.version;
        render(s);
      }
    } catch (e) { /* server restarting or unreachable; keep trying */ }
  }

  poll();
  setInterval(poll, 1000);
</script>
</body>
</html>
"""


@app.get("/")
def index():
    return Response(PAGE, mimetype="text/html")


@app.get("/api/state")
def api_state():
    """Latest result, polled by the page."""
    with _lock:
        return jsonify(dict(_state))


def extract_fen() -> str:
    """Pull the FEN from a JSON body, a form field, or a ?fen= query parameter."""
    data = request.get_json(silent=True)
    if isinstance(data, dict) and isinstance(data.get("fen"), str):
        return data["fen"].strip()
    return (request.values.get("fen") or "").strip()


@app.route("/api/fen", methods=["GET", "POST"])
def api_fen():
    """Analyze a FEN. Updates the page and returns the best move as JSON."""
    fen = extract_fen()
    if not fen:
        return (
            jsonify(error="Missing 'fen' (send a JSON body, a form field or a ?fen= parameter)."),
            400,
        )
    if fen.lower() == "start":
        fen = chess.STARTING_FEN

    try:
        with _engine_lock:
            result = analyze(
                app.config["ENGINE"], fen, app.config["LIMIT"], app.config["ORIENTATION"]
            )
    except ValueError as exc:
        return jsonify(error=str(exc)), 400
    except chess.engine.EngineError as exc:
        return jsonify(error=f"Engine error: {exc}"), 500

    publish(result)
    return jsonify({key: result[key] for key in PUBLIC_KEYS})


def format_eval(score) -> str:
    """Format a White-POV score: '+0.35' for centipawns, '#3' for mate."""
    if score.is_mate():
        return f"#{score.mate()}"
    return f"{score.score() / 100:+.2f}"


def analyze(engine, fen: str, limit: chess.engine.Limit, orientation: str) -> dict:
    """Return everything the page and API need. Raises ValueError for unusable input."""
    board = chess.Board(fen)  # raises ValueError on a malformed FEN
    if not board.is_valid():
        raise ValueError("Invalid position (illegal piece setup, kings in check, etc.).")
    if board.is_game_over():
        raise ValueError(
            f"Game is already over: {board.result()} ({board.outcome().termination.name})."
        )

    info = engine.analyse(board, limit)
    pv = info.get("pv")
    if not pv:
        raise ValueError("Engine returned no move.")

    move = pv[0]
    san = board.san(move)
    score = info["score"].white()
    turn_name = "White" if board.turn == chess.WHITE else "Black"

    after = board.copy()
    after.push(move)

    if orientation == "turn":
        side = board.turn
    else:
        side = chess.WHITE if orientation == "white" else chess.BLACK

    check_square = board.king(board.turn) if board.is_check() else None
    arrow = chess.svg.Arrow(move.from_square, move.to_square)

    return {
        "fen": board.fen(),
        "best_fen": after.fen(),
        "board_svg": chess.svg.board(
            board, orientation=side, check=check_square, arrows=[arrow]
        ),
        "san": san,
        "uci": move.uci(),
        "eval": format_eval(score),
        "depth": info.get("depth"),
        "turn": turn_name,
    }


def publish(result: dict) -> None:
    with _lock:
        _state.update(result)
        _state["ready"] = True
        _state["version"] += 1


def main():
    parser = argparse.ArgumentParser(description="Send a FEN over HTTP, see the best move as an arrow")
    parser.add_argument("--depth", type=int, default=18)
    parser.add_argument("--time", type=float, default=None)
    parser.add_argument("--threads", type=int, default=2)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8000)
    parser.add_argument("--orientation", choices=["white", "black", "turn"], default="white")
    args = parser.parse_args()

    app.config["LIMIT"] = (
        chess.engine.Limit(time=args.time)
        if args.time is not None
        else chess.engine.Limit(depth=args.depth)
    )
    app.config["ORIENTATION"] = args.orientation

    base = f"http://{args.host}:{args.port}"
    with open_engine(threads=args.threads) as engine:
        app.config["ENGINE"] = engine
        print(f"Viewer  : {base}")
        print(f'Send FEN: curl -G {base}/api/fen --data-urlencode "fen=<FEN>"')
        app.run(host=args.host, port=args.port, threaded=True, use_reloader=False)


if __name__ == "__main__":
    main()
