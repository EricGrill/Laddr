class_name IsometricUtils
extends RefCounted
## Converts between grid coordinates and isometric screen coordinates.
## Delegates to TileMapLayer when available (preferred), falls back to manual math.
## Isometric tiles are 128x64 (2:1 ratio) following the Godot isometric demo.

var tile_map: TileMapLayer = null
var tile_half_w: float = 64.0   # 128 / 2
var tile_half_h: float = 32.0   # 64 / 2


func setup_with_tilemap(tm: TileMapLayer) -> void:
	tile_map = tm


func setup(tile_size: int) -> void:
	tile_half_w = tile_size / 2.0
	tile_half_h = tile_size / 4.0


func grid_to_screen(grid_pos: Vector2) -> Vector2:
	if tile_map:
		return tile_map.map_to_local(Vector2i(grid_pos))
	return Vector2(
		(grid_pos.x - grid_pos.y) * tile_half_w,
		(grid_pos.x + grid_pos.y) * tile_half_h
	)


func screen_to_grid(screen_pos: Vector2) -> Vector2:
	if tile_map:
		return Vector2(tile_map.local_to_map(screen_pos))
	return Vector2(
		(screen_pos.x / tile_half_w + screen_pos.y / tile_half_h) / 2.0,
		(screen_pos.y / tile_half_h - screen_pos.x / tile_half_w) / 2.0
	)
