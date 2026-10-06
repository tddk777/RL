shader_type canvas_item;
// Red edge vignette for damage and low health.
uniform float intensity : hint_range(0.0, 1.0) = 0.0;

void fragment() {
	vec2 uv = UV - 0.5;
	float d = length(uv * vec2(1.6, 1.0));
	float edge = smoothstep(0.35, 0.95, d);
	COLOR = vec4(0.35, 0.02, 0.01, edge * intensity * 0.85);
}
