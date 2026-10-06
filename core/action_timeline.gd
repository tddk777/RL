class_name ActionTimeline
extends RefCounted
## Runs callbacks at set times, ticked manually. Used for reload and bolt
## sequences so sounds and ammo changes land at the right moment and the whole
## sequence can be cancelled.

var _events: Array = []  # [time: float, callback: Callable], sorted by time
var _time: float = 0.0
var duration: float = 0.0


func at(time: float, callback: Callable) -> ActionTimeline:
	_events.append([time, callback])
	_events.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])
	duration = maxf(duration, time)
	return self


func tick(delta: float) -> bool:
	## Advances time; returns true once every event has fired.
	_time += delta
	while not _events.is_empty() and _events[0][0] <= _time:
		var event: Array = _events.pop_front()
		(event[1] as Callable).call()
	return _events.is_empty() and _time >= duration


func progress() -> float:
	return clampf(_time / duration, 0.0, 1.0) if duration > 0.0 else 1.0
