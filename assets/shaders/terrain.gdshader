shader_type spatial;
// Landscape round the site: dry scrub on the flats, dirt and gravel on the
// slopes, mapped from world XZ (no UVs). Textures are packed the Terrain3D
// way (albedo + height, normal + roughness), see dev/asset_gen/terrain_textures.py.

uniform sampler2D flat_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D flat_normal : filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D slope_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D slope_normal : filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D noise_tex : filter_linear_mipmap, repeat_enable;
uniform float scale = 0.12;  // texture repeats per metre
uniform float slope_start = 0.06;  // 1 - normal.y where dirt starts
uniform float slope_end = 0.22;
uniform vec4 tint : source_color = vec4(0.82, 0.8, 0.76, 1.0);
uniform float normal_strength = 0.8;

varying vec3 world_pos;
varying vec3 world_normal;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
	TANGENT = normalize(vec3(1.0, 0.0, 0.0) - NORMAL * NORMAL.x);
	BINORMAL = normalize(cross(TANGENT, NORMAL));
}

// Two scales, the larger one rotated, so the tile doesn't read from a distance.
vec4 sample2(sampler2D t, vec2 p) {
	vec2 q = mat2(vec2(0.8, 0.6), vec2(-0.6, 0.8)) * p * 0.27;
	return mix(texture(t, p), texture(t, q), 0.35);
}

void fragment() {
	vec2 p = world_pos.xz * scale;
	vec4 macro = texture(noise_tex, world_pos.xz * 0.004);
	float slope = 1.0 - world_normal.y;
	float dirt = smoothstep(slope_start, slope_end, slope + (macro.r - 0.5) * 0.18);
	// Worn patches and tracks on the flats too.
	dirt = max(dirt, smoothstep(0.62, 0.78, macro.g) * 0.85);
	vec4 a = mix(sample2(flat_albedo, p), sample2(slope_albedo, p * 1.3), dirt);
	vec4 n = mix(sample2(flat_normal, p), sample2(slope_normal, p * 1.3), dirt);
	ALBEDO = a.rgb * tint.rgb * mix(0.82, 1.08, macro.b);
	NORMAL_MAP = n.rgb;
	NORMAL_MAP_DEPTH = normal_strength;
	ROUGHNESS = n.a;
	AO = mix(0.7, 1.0, a.a);
	AO_LIGHT_AFFECT = 0.3;
}
