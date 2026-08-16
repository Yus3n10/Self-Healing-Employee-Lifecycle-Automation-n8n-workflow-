"""
One runnable check for the mock IdP. No pytest required.

    .\.venv\Scripts\python.exe test_mock_idp.py

Asserts the three behaviours the orchestrator actually depends on:
idempotent replay, injected failure, and rate-limit signalling.
"""

import os

from fastapi.testclient import TestClient

os.environ.setdefault("MOCK_IDP_API_KEY", "dev-mock-idp-key-change-me")
import main  # noqa: E402

KEY = {"X-API-Key": os.environ["MOCK_IDP_API_KEY"]}
c = TestClient(main.app)


def reset():
    assert c.post("/admin/reset", headers=KEY).status_code == 200


def make_user(email="ada.lovelace@demo-corp.test", idem="k1"):
    return c.post(
        "/v1/users",
        headers={**KEY, "Idempotency-Key": idem},
        json={
            "employee_ref": "E-001",
            "full_name": "Ada Lovelace",
            "work_email": email,
            "department": "Engineering",
            "role_code": "ENG_SENIOR",
        },
    )


def demo():
    # auth is enforced
    reset()
    assert c.get("/v1/users").status_code == 401, "missing key must 401"

    # create is idempotent on replay
    r1 = make_user()
    assert r1.status_code == 201, r1.text
    user_id = r1.json()["user_id"]
    r2 = make_user()
    assert r2.json()["user_id"] == user_id, "replay must return the same user"
    assert r2.headers.get("X-Idempotent-Replay") == "true"
    assert c.get("/v1/users", headers=KEY).json()["count"] == 1, "no duplicate user"

    # group add is idempotent in the data too, not just via the header
    for k in ("g1", "g2"):
        c.post(
            "/v1/users/ada.lovelace@demo-corp.test/groups",
            headers={**KEY, "Idempotency-Key": k},
            json={"group": "engineering"},
        )
    groups = c.get("/v1/users/ada.lovelace@demo-corp.test", headers=KEY).json()["groups"]
    assert groups == ["engineering"], f"expected one group, got {groups}"

    # injected failure fires exactly once, then clears
    c.post(
        "/admin/chaos",
        headers=KEY,
        json={"mode": "fail_action", "target_action": "assign_license", "remaining": 1},
    )
    bad = c.post(
        "/v1/users/ada.lovelace@demo-corp.test/licenses",
        headers={**KEY, "Idempotency-Key": "L1"},
        json={"sku": "IDE_PRO"},
    )
    assert bad.status_code == 500, "chaos should have failed this call"
    good = c.post(
        "/v1/users/ada.lovelace@demo-corp.test/licenses",
        headers={**KEY, "Idempotency-Key": "L2"},
        json={"sku": "IDE_PRO"},
    )
    assert good.status_code == 200, "chaos should have cleared after one call"

    # rate limit returns 429 with Retry-After so n8n can back off
    c.post("/admin/chaos", headers=KEY, json={"mode": "rate_limit", "remaining": 1})
    rl = c.post(
        "/v1/users/ada.lovelace@demo-corp.test/groups",
        headers={**KEY, "Idempotency-Key": "g3"},
        json={"group": "prod-readonly"},
    )
    assert rl.status_code == 429 and rl.headers.get("Retry-After") == "2"

    # offboarding clears entitlements
    c.delete("/v1/users/ada.lovelace@demo-corp.test", headers={**KEY, "Idempotency-Key": "d1"})
    final = c.get("/v1/users/ada.lovelace@demo-corp.test", headers=KEY).json()
    assert final["status"] == "deleted" and final["groups"] == [] and final["licenses"] == []

    reset()
    print("mock IdP self-check passed")


if __name__ == "__main__":
    demo()
