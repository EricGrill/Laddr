extends Node
## Global signal hub for decoupled communication between systems.
## Visual layer events that don't belong in WorldState (which is pure data).

# Entity selection
signal entity_selected(entity_type: String, entity_id: String)
signal entity_deselected()
signal entity_hovered(entity_type: String, entity_id: String)
signal entity_unhovered()

# Camera
signal camera_focus_requested(world_position: Vector2)
signal camera_follow_requested(entity_type: String, entity_id: String)
signal camera_follow_stopped()
signal camera_reset_requested()

# UI
signal inspector_open_requested(entity_type: String, entity_id: String)
signal inspector_close_requested()
signal alert_posted(message: String, severity: String)

# Playback
signal playback_speed_changed(speed: float)
