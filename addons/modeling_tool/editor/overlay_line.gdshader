shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, fog_disabled;

uniform float line_width_pixels = 2.0;
uniform bool xray = false;

void vertex() {
	// Each edge is a quad. NORMAL stores its local-space unit direction.
	vec4 view_point = MODELVIEW_MATRIX * vec4(VERTEX, 1.0);
	vec4 view_next = MODELVIEW_MATRIX * vec4(VERTEX + NORMAL, 1.0);
	vec4 point = PROJECTION_MATRIX * view_point;
	vec4 next = PROJECTION_MATRIX * view_next;
	vec2 direction = (next.xy / max(abs(next.w), 0.00001) - point.xy / max(abs(point.w), 0.00001)) * VIEWPORT_SIZE;
	vec2 perpendicular = vec2(-direction.y, direction.x) / max(length(direction), 0.00001);
	// Move towards the camera a little to avoid z-fighting with the edited surface.
	view_point.z += max(0.0002, abs(view_point.z) * 0.00001);
	POSITION = PROJECTION_MATRIX * view_point;
	POSITION.xy += perpendicular * UV.x * line_width_pixels / VIEWPORT_SIZE * POSITION.w;
	if (xray) { POSITION.z = POSITION.w * 0.9999; }
}

void fragment() {
	ALBEDO = COLOR.rgb;
}
