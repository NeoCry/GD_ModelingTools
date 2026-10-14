shader_type spatial;
render_mode unshaded, cull_disabled, blend_mix, depth_draw_never, fog_disabled;

uniform bool xray = false;

void vertex() {
	vec4 view_point = MODELVIEW_MATRIX * vec4(VERTEX, 1.0);
	view_point.z += max(0.0001, abs(view_point.z) * 0.000005);
	POSITION = PROJECTION_MATRIX * view_point;
	if (xray) { POSITION.z = POSITION.w * 0.9998; }
}

void fragment() {
	ALBEDO = COLOR.rgb;
	ALPHA = COLOR.a;
}
