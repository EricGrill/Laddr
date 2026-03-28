extends Node
## Connects to Laddr /ws/mission-control WebSocket.
## Parses JSON events and routes them to WorldState.

signal connection_state_changed(state: String)  # "connecting", "connected", "disconnected"

@export var server_url: String = "ws://localhost:8000/ws/mission-control"

var _socket: WebSocketPeer = WebSocketPeer.new()
## Increase buffer sizes for large snapshot payloads (default 64KB is too small).
const BUFFER_SIZE: int = 1048576  # 1 MB
var _connected: bool = false
var _reconnect_attempts: int = 0
var _max_reconnect_attempts: int = 10
var _reconnect_base_delay: float = 2.0
var _reconnect_max_delay: float = 30.0
var _reconnect_timer: float = 0.0
var _waiting_to_reconnect: bool = false

var connection_state: String = "disconnected"


func _ready() -> void:
	# Auto-detect WebSocket URL in web builds from browser location
	if OS.has_feature("web"):
		var js_code = """
		(function() {
			var proto = (window.location.protocol === 'https:') ? 'wss:' : 'ws:';
			var port = window.location.port ? (':' + window.location.port) : '';
			return proto + '//' + window.location.hostname + port + '/ws/mission-control';
		})()
		"""
		var result = JavaScriptBridge.eval(js_code)
		if result:
			server_url = result
	connect_to_server()


func connect_to_server() -> void:
	_set_connection_state("connecting")
	_socket.inbound_buffer_size = BUFFER_SIZE
	_socket.outbound_buffer_size = BUFFER_SIZE
	var err = _socket.connect_to_url(server_url)
	if err != OK:
		push_error("WebSocket connection failed: %s" % err)
		_schedule_reconnect()


func _process(delta: float) -> void:
	if _waiting_to_reconnect:
		_reconnect_timer -= delta
		if _reconnect_timer <= 0:
			_waiting_to_reconnect = false
			connect_to_server()
		return

	_socket.poll()
	var state = _socket.get_ready_state()

	match state:
		WebSocketPeer.STATE_OPEN:
			if not _connected:
				_connected = true
				_reconnect_attempts = 0
				_set_connection_state("connected")
			while _socket.get_available_packet_count() > 0:
				var packet = _socket.get_packet()
				var text = packet.get_string_from_utf8()
				_handle_message(text)
		WebSocketPeer.STATE_CLOSING:
			pass
		WebSocketPeer.STATE_CLOSED:
			if _connected:
				_connected = false
				_set_connection_state("disconnected")
				_schedule_reconnect()


func send_command(action: String, params: Dictionary = {}) -> void:
	if not _connected:
		return
	var msg = {"action": action}
	msg.merge(params)
	_socket.send_text(JSON.stringify(msg))


func _handle_message(text: String) -> void:
	var json = JSON.new()
	var err = json.parse(text)
	if err != OK:
		push_error("Failed to parse WebSocket message: %s" % text.left(100))
		return

	var data = json.data
	if not data is Dictionary or not data.has("type"):
		return

	match data["type"]:
		"snapshot":
			WorldState.load_snapshot(data.get("data", {}))
		"agent_updated":
			WorldState.handle_agent_updated(data["agent"])
		"job_created":
			WorldState.handle_job_created(data["job"])
		"job_updated":
			WorldState.handle_job_updated(data["job"])
		"job_completed":
			WorldState.handle_job_completed(data["jobId"])
		"job_failed":
			WorldState.handle_job_failed(data["jobId"], data.get("reason", ""))
		"station_updated":
			WorldState.handle_station_updated(data["station"])
		"metrics_updated":
			WorldState.handle_metrics_updated(data.get("metrics", {}))
		"worker_registered":
			WorldState.handle_worker_registered(data["worker"])
		"worker_deregistered":
			WorldState.handle_worker_deregistered(data["workerId"])
		"command_ack":
			pass  # Phase 3: surface to UI


func _schedule_reconnect() -> void:
	if _reconnect_attempts >= _max_reconnect_attempts:
		push_error("Max reconnect attempts reached")
		return
	_reconnect_attempts += 1
	var delay = min(_reconnect_base_delay * pow(2, _reconnect_attempts - 1), _reconnect_max_delay)
	_reconnect_timer = delay
	_waiting_to_reconnect = true
	_set_connection_state("disconnected")


func _set_connection_state(new_state: String) -> void:
	if connection_state != new_state:
		connection_state = new_state
		connection_state_changed.emit(new_state)
