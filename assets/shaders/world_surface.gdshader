// World surface: triplanar PBR without visible tiling, plus generative decay.
//
// - Anti-tiling: each plane samples the texture twice with offsets chosen by a
//   slowly varying noise and blends between them (Quilez, "texture repetition",
//   technique 3). Offsets only, no rotation, so normal maps stay valid.
// - Macro variation: large, soft changes in brightness and tint.
// - Decay (world space, so it lines up across meshes): grime at the base of
//   walls, water/rust runs down from the ceiling, damp patches, dust on
//   floors, stains on ceilings, rust on metal.
//
// Level geometry has no UVs: everything is projected from world position.
shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx;

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap_anisotropic, repeat_enable, hint_default_white;
uniform sampler2D normal_tex : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D roughness_tex : hint_roughness_r, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D metallic_tex : hint_default_white, filter_linear_mipmap, repeat_enable;
uniform sampler2D noise_tex : filter_linear_mipmap, repeat_enable;

uniform bool use_normal = true;
uniform bool use_metallic = false;
uniform vec4 tint : source_color = vec4(1.0);
uniform float roughness = 1.0;
uniform float metallic = 0.0;
uniform float normal_strength = 1.0;
/// Texture repeats per metre.
uniform float scale = 0.35;
/// Project in object space (props that move) instead of world space.
uniform bool object_space = false;
uniform float sharpness = 6.0;

uniform float macro_strength : hint_range(0.0, 1.0) = 0.3;
uniform float grime : hint_range(0.0, 1.0) = 0.6;
uniform float streaks : hint_range(0.0, 1.0) = 0.5;
uniform float damp : hint_range(0.0, 1.0) = 0.35;
uniform float dust : hint_range(0.0, 1.0) = 0.4;
uniform float rust : hint_range(0.0, 1.0) = 0.0;
uniform float storey_height = 4.5;
// Depth: crevices in the normal map (mortar, grout, grooves, pits) darken,
// and broad soft bumps keep walls and slabs from reading as flat cards.
uniform float cavity : hint_range(0.0, 1.0) = 0.6;
uniform float relief : hint_range(0.0, 1.0) = 0.25;
uniform vec3 grime_color : source_color = vec3(0.13, 0.115, 0.095);
uniform vec3 rust_color : source_color = vec3(0.34, 0.16, 0.075);
uniform vec3 damp_color : source_color = vec3(0.10, 0.115, 0.085);
uniform vec3 dust_color : source_color = vec3(0.44, 0.42, 0.38);

varying vec3 map_pos;
varying vec3 map_nrm;
varying vec3 world_pos;
varying vec3 world_nrm;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_nrm = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
	map_pos = object_space ? VERTEX : world_pos;
	map_nrm = object_space ? NORMAL : world_nrm;
}

// Two offset samples blended by noise. Returns albedo.rgb + blend in .a.
void sample_plane(vec2 uv, vec2 dx, vec2 dy, out vec3 alb, out vec3 tn, out float ro, out float me) {
	float k = textureGrad(noise_tex, uv * 0.13, dx * 0.13, dy * 0.13).r;
	float l = k * 8.0;
	float f = fract(l);
	float ia = floor(l);
	vec2 offa = sin(vec2(3.0, 7.0) * ia);
	vec2 offb = sin(vec2(3.0, 7.0) * (ia + 1.0));
	vec3 ca = textureGrad(albedo_tex, uv + offa, dx, dy).rgb;
	vec3 cb = textureGrad(albedo_tex, uv + offb, dx, dy).rgb;
	float b = smoothstep(0.2, 0.8, f - 0.1 * (ca.r + ca.g + ca.b - cb.r - cb.g - cb.b));
	alb = mix(ca, cb, b);
	if (use_normal) {
		// Z rebuilt from X and Y: VRAM-compressed normal maps (RGTC) keep
		// only the red and green channels.
		vec2 na = textureGrad(normal_tex, uv + offa, dx, dy).rg;
		vec2 nb = textureGrad(normal_tex, uv + offb, dx, dy).rg;
		vec2 nxy = mix(na, nb, b) * 2.0 - 1.0;
		tn = vec3(nxy * normal_strength, sqrt(max(1.0 - dot(nxy, nxy), 0.0)));
		tn = normalize(tn);
	} else {
		tn = vec3(0.0, 0.0, 1.0);
	}
	ro = mix(textureGrad(roughness_tex, uv + offa, dx, dy).r, textureGrad(roughness_tex, uv + offb, dx, dy).r, b);
	me = use_metallic ? mix(textureGrad(metallic_tex, uv + offa, dx, dy).r, textureGrad(metallic_tex, uv + offb, dx, dy).r, b) : 1.0;
}

void fragment() {
	vec3 n = normalize(map_nrm);
	vec3 w = pow(abs(n), vec3(sharpness));
	w /= (w.x + w.y + w.z);
	vec3 p = map_pos * scale;
	vec2 uvx = p.zy;
	vec2 uvy = p.xz;
	vec2 uvz = p.xy;
	// Explicit gradients: sampling happens inside branches below.
	vec2 dxx = dFdx(uvx), dyx = dFdy(uvx);
	vec2 dxy = dFdx(uvy), dyy = dFdy(uvy);
	vec2 dxz = dFdx(uvz), dyz = dFdy(uvz);

	vec3 alb = vec3(0.0);
	vec3 nsum = vec3(0.0);
	float ro = 0.0;
	float me = 0.0;
	vec3 a; vec3 t; float r; float m;
	float cav = 0.0;
	if (w.x > 0.01) {
		sample_plane(uvx, dxx, dyx, a, t, r, m);
		alb += a * w.x; ro += r * w.x; me += m * w.x;
		cav += clamp((1.0 - t.z) * 3.5, 0.0, 1.0) * w.x;
		t = vec3(t.xy + n.zy, abs(t.z) * n.x);
		nsum += t.zyx * w.x;
	}
	if (w.y > 0.01) {
		sample_plane(uvy, dxy, dyy, a, t, r, m);
		alb += a * w.y; ro += r * w.y; me += m * w.y;
		cav += clamp((1.0 - t.z) * 3.5, 0.0, 1.0) * w.y;
		t = vec3(t.xy + n.xz, abs(t.z) * n.y);
		nsum += t.xzy * w.y;
	}
	if (w.z > 0.01) {
		sample_plane(uvz, dxz, dyz, a, t, r, m);
		alb += a * w.z; ro += r * w.z; me += m * w.z;
		cav += clamp((1.0 - t.z) * 3.5, 0.0, 1.0) * w.z;
		t = vec3(t.xy + n.xy, abs(t.z) * n.z);
		nsum += t.xyz * w.z;
	}
	vec3 nmap = normalize(nsum);
	if (object_space) {
		nmap = normalize((MODEL_MATRIX * vec4(nmap, 0.0)).xyz);
	}
	alb *= tint.rgb;
	ro *= roughness;
	me *= metallic;

	// --- Decay, in world metres -------------------------------------------------
	vec3 wn = normalize(world_nrm);
	vec3 aw = abs(wn);
	// Planar coordinates on the dominant axis, in metres.
	vec2 q = aw.y > 0.6 ? world_pos.xz : (aw.x > aw.z ? world_pos.zy : world_pos.xy);
	float along = aw.x > aw.z ? world_pos.z : world_pos.x;
	vec4 nz_macro = texture(noise_tex, q * 0.021);
	vec4 nz_mid = texture(noise_tex, q * 0.083 + vec2(0.37, 0.11));
	float h = mod(world_pos.y + 0.02, storey_height);

	// Broad soft bumps: tilt the normal along the noise slope, in metres.
	if (relief > 0.0 && !object_space) {
		float e = 0.06;
		float c0 = texture(noise_tex, q * 0.11).g;
		float cx = texture(noise_tex, (q + vec2(e, 0.0)) * 0.11).g;
		float cy = texture(noise_tex, (q + vec2(0.0, e)) * 0.11).g;
		vec2 slope = vec2(cx - c0, cy - c0) / e * relief * 0.35;
		vec3 t1 = aw.y > 0.6 ? vec3(1.0, 0.0, 0.0) : (aw.x > aw.z ? vec3(0.0, 0.0, 1.0) : vec3(1.0, 0.0, 0.0));
		vec3 t2 = aw.y > 0.6 ? vec3(0.0, 0.0, 1.0) : vec3(0.0, 1.0, 0.0);
		nmap = normalize(nmap - (t1 * slope.x + t2 * slope.y));
	}
	float occl = 1.0 - cav * cavity;
	alb *= mix(1.0, occl, 0.55);

	// Large soft variation in brightness and warmth.
	float macro = nz_macro.g;
	alb *= mix(1.0 - macro_strength, 1.0 + macro_strength * 0.45, macro);
	alb = mix(alb, alb * vec3(1.06, 0.98, 0.88), smoothstep(0.45, 0.85, nz_macro.r) * macro_strength);

	// Patchy grime everywhere.
	float patch = smoothstep(0.52, 0.82, nz_mid.r) * grime;
	alb = mix(alb, grime_color * (0.7 + 0.6 * nz_mid.g), patch * 0.55);
	ro = mix(ro, 0.95, patch * 0.4);

	if (aw.y < 0.6) {
		// Walls: dirt kicked up along the bottom.
		float edge = 0.55 + 0.9 * nz_mid.b;
		float base_dirt = (1.0 - smoothstep(0.0, edge, h)) * grime;
		alb = mix(alb, grime_color * 0.8, base_dirt * 0.7);
		// Runs of water and rust from the top of the wall.
		float s = texture(noise_tex, vec2(along * 0.29, world_pos.y * 0.03)).b;
		float from_top = smoothstep(storey_height * 0.15, storey_height * 0.95, h);
		float run = smoothstep(0.56, 0.86, s) * mix(0.25, 1.0, from_top) * streaks;
		vec3 run_col = mix(grime_color * 0.85, rust_color, rust * 0.8 + 0.15);
		alb = mix(alb, run_col, run * 0.65);
		ro = mix(ro, 0.55, run * 0.3);
		// Rising damp and mould.
		float d = smoothstep(0.58, 0.82, nz_macro.a) * (1.0 - smoothstep(0.4, 2.6, h)) * damp;
		alb = mix(alb, damp_color, d * 0.75);
		ro = mix(ro, 0.45, d * 0.6);
	} else if (wn.y > 0.0) {
		// Floors: dust drifts, darker worn paths.
		float dd = smoothstep(0.35, 0.8, nz_macro.a) * dust;
		alb = mix(alb, dust_color * (0.8 + 0.4 * nz_mid.r), dd * 0.45);
		ro = mix(ro, 1.0, dd * 0.5);
		float worn = smoothstep(0.6, 0.9, nz_mid.g) * grime;
		alb *= 1.0 - worn * 0.25;
	} else {
		// Ceilings: tide-marked water stains.
		float st = nz_mid.a;
		float ring = (smoothstep(0.6, 0.64, st) - smoothstep(0.66, 0.74, st)) * damp;
		float inner = smoothstep(0.64, 0.7, st) * damp;
		alb = mix(alb, rust_color * 0.7, ring * 0.7);
		alb = mix(alb, grime_color, inner * 0.45);
	}

	// Rust blooms on metal.
	if (rust > 0.0) {
		float rm = smoothstep(0.75 - rust * 0.45, 0.95 - rust * 0.45, nz_mid.a * 0.7 + nz_macro.r * 0.3);
		alb = mix(alb, rust_color * (0.6 + 0.8 * nz_mid.r), rm);
		me = mix(me, 0.0, rm);
		ro = mix(ro, 0.92, rm);
	}

	ALBEDO = alb;
	AO = occl;
	AO_LIGHT_AFFECT = 0.35;
	ROUGHNESS = clamp(ro, 0.04, 1.0);
	METALLIC = clamp(me, 0.0, 1.0);
	NORMAL = normalize((VIEW_MATRIX * vec4(nmap, 0.0)).xyz);
}
