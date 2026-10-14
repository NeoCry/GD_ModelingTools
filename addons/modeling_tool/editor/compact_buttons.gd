@tool
extends RefCounted

static func apply(button: Button) -> void:
	for state in ["normal","hover","pressed","hover_pressed","disabled","focus"]:
		var style: StyleBox=button.get_theme_stylebox(state).duplicate()
		style.content_margin_top=0
		style.content_margin_bottom=0
		style.content_margin_left=4
		style.content_margin_right=4
		button.add_theme_stylebox_override(state,style)
	if button.text.is_empty():
		button.expand_icon=true
		button.add_theme_constant_override("icon_max_width",20)
		button.custom_minimum_size=Vector2(20,20)

static func apply_tree(node: Node) -> void:
	if node is Button: apply(node)
	for child in node.get_children(): apply_tree(child)
