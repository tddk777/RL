extends Node
## Global signal bus. Systems announce things here so they don't need direct
## references to each other (AI hears gunshots, the HUD hears damage, ...).

## A sound AI can hear. `radius` is how far away (m) it is audible.
signal noise_emitted(position: Vector3, radius: float, source: Node)
signal actor_damaged(victim: Node, hit: HitInfo)
signal actor_killed(victim: Node, hit: HitInfo)
signal player_spawned(player: Node)
signal player_died(player: Node)
signal level_started(level: Node)
signal settings_changed
