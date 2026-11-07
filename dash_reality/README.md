# Dash Reality

Dash Reality is a Garry's Mod Sandbox toolkit for configuring sessions and
interacting with players, NPCs and physics objects. Open the **Dash Reality**
tab in the Q menu to find its tools and settings.

## NPC Camera

Select **Dash Reality → NPC → NPC Camera** with the Tool Gun. Left-click an
NPC or NextBot for its eye view; right-click for a trailing view. In trailing
view, hold the context-menu key (normally C) and drag the middle mouse button
to orbit. Reload, switching tools, or `dash_npc_camera_exit` returns to your
player's view. `dash_npc_camera_orbit_reset` resets the orbit angle.

The player remains in the world and retains their own movement and sound.
Entities outside the client's network visibility may be unavailable. Some
custom models or other camera addons can affect the resulting view.

## Observer and speed readout

Ghost Mode can reduce interference while observing in noclip. Run
`noclip_ghost_status` to inspect its current state; custom NPC or NextBot AI
may still notice an observer.

Enable the optional speed display with `rt_ups_enabled 1`. Choose UPS, km/h or
km/min in the Player settings, and choose horizontal-only or full 3D speed.
World-position sampling includes movement inherited from a platform; the
alternate entity-velocity source uses the engine's reported velocity without
smoothing. Both sources track the player, occupied vehicle or driven entity. Teleports and abrupt direction changes can briefly affect the estimate.

Server-authoritative settings and interactions follow the server's normal
permissions. Test multiplayer, custom NPC frameworks and other camera or
physics addons in the environment where they will be used.
