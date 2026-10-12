from fastapi.testclient import TestClient

import main

client = TestClient(main.app)


def test_index_reports_identity():
    body = client.get("/").json()
    assert body == {"service": main.SERVICE_NAME, "environment": main.ENVIRONMENT, "version": main.VERSION}


def test_health_is_always_ok():
    assert client.get("/health").status_code == 200


def test_ready_turns_false_while_draining():
    assert client.get("/ready").status_code == 200
    main.state["draining"] = True
    try:
        assert client.get("/ready").status_code == 503
        # Liveness must stay green while draining, or Kubernetes would restart the pod mid-drain.
        assert client.get("/health").status_code == 200
    finally:
        main.state["draining"] = False


def test_ready_waits_for_startup_delay(monkeypatch):
    monkeypatch.setattr(main, "STARTUP_DELAY_SECONDS", 3600)
    assert client.get("/ready").status_code == 503


def test_metrics_use_route_templates_not_raw_paths():
    client.get("/")
    client.get("/does-not-exist-12345")
    text = client.get("/metrics").text
    assert 'path="/"' in text
    assert "does-not-exist-12345" not in text
    assert 'path="unmatched"' in text
