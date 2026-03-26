from laddr.core.message_bus import priority_stream_key, worker_stream_key, PRIORITY_LEVELS

class TestPriorityStreamKey:
    def test_default_priority(self):
        assert priority_stream_key("normal") == "laddr:jobs:pending:normal"

    def test_all_priority_levels(self):
        for level in PRIORITY_LEVELS:
            key = priority_stream_key(level)
            assert key == f"laddr:jobs:pending:{level}"

    def test_invalid_priority_defaults_to_normal(self):
        assert priority_stream_key("invalid") == "laddr:jobs:pending:normal"

class TestWorkerStreamKey:
    def test_worker_stream_key(self):
        assert worker_stream_key("snoke-01") == "laddr:worker:snoke-01"
