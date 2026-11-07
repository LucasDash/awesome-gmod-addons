# Agent Session Profiles

This optional server-only GMod addon is a small coordination layer for development
sessions. It starts with `active = "none"`; it changes no user groups, player
models, loadouts, permissions, spawn behavior, movement, server settings or
Workshop content on startup. This source has not yet been validated in a live GMod session.

`AgentSessionProfiles.GetStatus()` returns a fresh table with `active` (`none`,
`observer` or `npc_experiment`), `npcKills`, `observerReady` and
`experimentReady`. Agent Bridge
may query this server API after independently checking that it exists and is a
function. It is a status report, not a control endpoint or proof of ghosting.

The server-console command is `agent_session_profile status|none|observer|npc_experiment`.
`status` is read-only. Console/RCON can change profiles. A player may change
profiles only if CAMI grants the registered **Agent Session Profiles** privilege
(default `superadmin`); CAMI decisions are handled by callback and stale pending
requests are discarded. If CAMI is absent, the fallback is superadmin, listen
host, or the singleplayer host. A partially present or failing CAMI fails closed.
No group is changed to grant or deny these actions.

Profiles:

- `none`: removes this candidate's active experiment hook.
- `npc_experiment`: starts a bounded in-memory count of `OnNPCKilled` events for
  native NPC victims. `GetStatus().npcKills` resets on activation and is not
  persistent. This is a narrow outcome counter, not a survival metric or a
  NextBot kill tracker; actual use depends on the gamemode emitting the hook.
- `observer`: selects an observer-oriented status only when Dash Reality's
  server Ghost component exists and `noclip_ghost_enabled` is already true.
  Configure Ghost separately through Dash Reality; this profile never changes its
  convar or any player. `observerReady` tracks that configuration while active,
  and becomes false if the dependency disappears or is disabled. Ghost still
  requires the player's existing Dash conditions, including noclip and any
  admin-only restriction; custom NPC/NextBot AI can still detect the observer.

Changing or disabling a profile removes its own hook only if it still owns that
hook. Hot reload shuts down the old instance first, removes its command only if
it still owns it, and refuses to replace another addon's command or lifecycle
hooks. `experimentReady` becomes false if its experiment hook was replaced.
The command and lifecycle-hook registrations are checked after creation; a
silently rejected registration tears down only registrations this instance owns.
The latest **authorized** valid command supersedes earlier pending CAMI replies,
even if it was a no-op; unapproved and denied requests cannot supersede them.
Up to 16 checks may be pending per player, with a 15-second expiry for genuinely
asynchronous checks; synchronous CAMI decisions schedule no timer. Callbacks are
also invalidated by provider replacement, disconnect and shutdown. CAMI is
registered lazily if the provider loads later. The callback honors the provider's
decision but cannot independently guarantee how that provider handles a
permission change while its own request is in flight. Status is also available
to ordinary players, since it contains no identity or authorization data.

The earlier First Gordon and Citizen session are **not included**: their model,
armor, suit, loadout, first-authenticated-player and vendor-convar behavior is
scenario-specific, and the Citizen policy forcibly changes groups. Reusing them
requires a separately opt-in design, dependency checks, multiplayer and
permission tests, and explicit ownership/restoration. This candidate never
changes a user's group to simulate a role.

Run `python tests/run_tests.py` with `lupa` available for Lua 5.1 and LuaJIT
fixtures.
They use mocked GMod and CAMI APIs and cover initial inertness, native NPC event
counting, Ghost prerequisites and status, no convar mutations, admin fallback,
asynchronous permission grants/denials/stale callbacks, disconnect, provider
replacement, fail-closed partial CAMI and reload/shutdown. These fixtures do not
prove live GMod, ULX, multiplayer, Agent Bridge, Ghost visibility or gameplay.
The [CAMI API](https://github.com/glua/CAMI/blob/master/README.md),
[OnNPCKilled hook](https://wiki.facepunch.com/gmod/GM:OnNPCKilled) and
[ConVar callback limitations](https://wiki.facepunch.com/gmod/cvars.AddChangeCallback)
informed this design. In particular, it does not rely on Lua server-convar
change callbacks to decide whether it owns a shared Ghost setting.

To test this candidate together with an explicit Agent Bridge candidate:

```powershell
python tests/run_agent_bridge_integration.py --bridge-root 'C:\path\to\agent_bridge_candidate'
```

The cross-addon fixture loads the real session module, the provided candidate's
`lua/agent_bridge/capabilities.lua`, and its `lua/gterm_packages/agent_bridge.lua`
in isolated Lua runtimes. It exercises the actual package callback across
profile transitions and mocks engine APIs, so it is not live transport or
permission validation.
