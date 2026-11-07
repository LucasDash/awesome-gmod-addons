"""Run the real-source cross-addon fixture in Lua 5.1 and LuaJIT, without GMod."""
import argparse
from pathlib import Path

from lupa import lua51, luajit21

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--bridge-root", type=Path, required=True,
                    help="Agent Bridge candidate addon root containing lua/")
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
paths = (
    root / "lua/autorun/server/agent_session_profiles.lua",
    args.bridge_root / "lua/agent_bridge/capabilities.lua",
    args.bridge_root / "lua/gterm_packages/agent_bridge.lua",
)
for path in paths:
    if not path.is_file():
        raise SystemExit(f"Required actual source missing: {path}")
fixture = (root / "tests/agent_bridge_integration_test.lua").read_text(encoding="utf-8")
for vm in (lua51, luajit21):
    runtime = vm.LuaRuntime(unpack_returned_tuples=True)
    runtime.globals().arg = runtime.table_from({i: str(path).replace("\\", "/") for i, path in enumerate(paths, 1)})
    runtime.execute(fixture)
    print(f"PASS {vm.__name__}")
