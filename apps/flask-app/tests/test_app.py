"""
Unit tests for the Flask monolith placeholder app.
"""

import pytest
from app import app


@pytest.fixture
def client():
    app.config["TESTING"] = True
    with app.test_client() as client:
        yield client


def test_index_returns_service_info(client):
    resp = client.get("/")
    assert resp.status_code == 200
    data = resp.get_json()
    assert data["service"] == "flask-app"
    assert data["status"] == "running"


def test_health_endpoint_returns_200(client):
    resp = client.get("/health")
    assert resp.status_code == 200
    data = resp.get_json()
    assert "service" in data
    assert "sns" in data
    assert "sqs" in data
    assert "database" in data


def test_publish_event_without_sns_returns_503(client):
    # Without SNS configured, should return 503
    resp = client.post("/events", json={"message": "test"})
    # 503 because SNS_TOPIC_ARN is empty in test env
    assert resp.status_code == 503


def test_receive_tasks_without_sqs_returns_503(client):
    resp = client.get("/tasks")
    assert resp.status_code == 503


def test_index_content_type_is_json(client):
    resp = client.get("/")
    assert resp.content_type == "application/json"
