// RL: the asset download didn't include this file (a copy of Godot's
// servers/rendering/renderer_rd/shaders/scene_data_inc.glsl). Only the leading
// fields are declared: their layout has been stable across Godot 4.x, and
// lens_flares.glsl now reads nothing after them (the resolution comes from
// the colour image, the ray jitter no longer uses scene time).
struct SceneData {
	mat4 projection_matrix;
	mat4 inv_projection_matrix;
	mat4 inv_view_matrix;
	mat4 view_matrix;
};
