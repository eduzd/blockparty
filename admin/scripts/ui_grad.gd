class_name AdminGrad
extends PanelContainer
## A panel filled with one of the file's linear gradients (top-left to bottom-right, like
## Compose's Brush.linearGradient), clipped to the panel's rounded corners.

const SHADER := """
shader_type canvas_item;
uniform vec4 c0 : source_color;
uniform vec4 c1 : source_color;
uniform vec2 size = vec2(100.0, 100.0);
varying vec2 lp;
void vertex() { lp = VERTEX; }
void fragment() {
	float t = clamp(dot(lp, size) / max(dot(size, size), 1.0), 0.0, 1.0);
	COLOR = vec4(mix(c0.rgb, c1.rgb, t), COLOR.a * mix(c0.a, c1.a, t));
}
"""

static var _shader: Shader
var _mat: ShaderMaterial


func _init(from: Color = Color("37B1FF"), to: Color = Color("009CFF"), radius := 24.0, pad := 0.0) -> void:
	if _shader == null:
		_shader = Shader.new()
		_shader.code = SHADER
	_mat = ShaderMaterial.new()
	_mat.shader = _shader
	_mat.set_shader_parameter("c0", from)
	_mat.set_shader_parameter("c1", to)
	material = _mat
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color.WHITE
	sb.set_corner_radius_all(int(radius))
	sb.corner_detail = 12
	sb.anti_aliasing = true
	sb.content_margin_left = pad
	sb.content_margin_right = pad
	sb.content_margin_top = pad
	sb.content_margin_bottom = pad
	add_theme_stylebox_override("panel", sb)
	resized.connect(func(): _mat.set_shader_parameter("size", size))
	mouse_filter = Control.MOUSE_FILTER_IGNORE
