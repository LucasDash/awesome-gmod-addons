"""Run isolated server-profile contracts under Lua 5.1 and LuaJIT without GMod."""
from pathlib import Path
from lupa import lua51, luajit21

root = Path(__file__).resolve().parents[1]
for vm in (lua51, luajit21):
    runtime = vm.LuaRuntime(unpack_returned_tuples=True)
    runtime.globals().arg = runtime.table_from({1: root.as_posix()})
    runtime.execute((root / "tests" / "session_profiles_test.lua").read_text(encoding="utf-8"))
    print(f"PASS {vm.__name__}")
