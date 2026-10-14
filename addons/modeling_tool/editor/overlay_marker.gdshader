shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, fog_disabled;
uniform float size_pixels = 7.0;
uniform bool xray = false;
void vertex() {
	vec4 point = MODELVIEW_MATRIX * vec4(VERTEX, 1.0);
	point.z += max(0.0003, abs(point.z) * 0.00002);
	POSITION = PROJECTION_MATRIX * point;
	POSITION.xy += UV * size_pixels / VIEWPORT_SIZE * POSITION.w;
	if (xray) { POSITION.z = POSITION.w * 0.99995; }
}
void fragment() {
	ALBEDO = COLOR.rgb;
}
