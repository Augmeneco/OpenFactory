shader_type canvas_item;
render_mode unshaded;

// The night is a full-screen colour wash.  This shader keeps the wash off the
// engineer's flashlight circle, which is what makes the engineer readable in
// the dark without lighting up the interface (the wash itself lives on a
// CanvasLayer below the HUD).

uniform vec2 overlay_size = vec2(1600.0, 900.0);
uniform vec2 flashlight_screen = vec2(800.0, 450.0);
uniform float flashlight_radius = 320.0;
uniform float flashlight_softness = 260.0;
uniform float flashlight_strength = 0.92;

void fragment() {
	vec2 pixel = UV * overlay_size;
	float dist = distance(pixel, flashlight_screen);
	float lit = 1.0 - smoothstep(
		max(0.0, flashlight_radius - flashlight_softness),
		flashlight_radius, dist);
	// Keep a little ambient light at the rim so the screen is not pure black.
	COLOR.a *= 1.0 - lit * flashlight_strength;
}
