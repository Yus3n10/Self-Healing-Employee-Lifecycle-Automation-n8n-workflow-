"""
Mock Identity Provider for the JML Orchestrator.

This is a SIMULATOR, not a real IdP. It exists so the orchestration workflow can
be built, demonstrated and failure-tested against a system that behaves like a
real vendor API: API-key auth, idempotency keys, rate limits, and injectable
faults.

Run:
    py -3.11 -m venv .venv
    .\.venv\Scripts\Activate.ps1
    pip install -r requirements.txt
    uvicorn main:app --host 127.0.0.1 --port 8100

Interactive docs: http://127.0.0.1:8100/docs
"""

from __future__ import annotations

import os
import time
import uuid
from datetime import datetime, timezone
from threading import RLock
from typing import Any, Literal

from fastapi import Body, FastAPI, Header, HTTPException, Path, Response
from pydantic import BaseModel, Field

API_KEY = os.getenv("MOCK_IDP_API_KEY", "dev-mock-idp-key-change-me")

app = FastAPI(
    title="Mock IdP",
    version="1.0.0",
    description="Simulated identity provider. Not a real system. Demo data only.",
)

_lock = RLock()

# In-memory state. Restarting the process resets everything, which is exactly
# what you want between failure-test runs.
USERS: dict[str, dict[str, Any]] = {}          # keyed by work_email (lowercased)
IDEMPOTENCY: dict[str, dict[str, Any]] = {}    # idempotency-key -> stored response
CALL_LOG: list[dict[str, Any]] = []

CHAOS: dict[str, Any] = {
    "mode": "off",            # off | rate_limit | fail_action | slow | flaky
    "target_action": None,    # only used by fail_action
    "remaining": 0,           # how many more calls the fault applies to
    "slow_seconds": 3.0,
}

ACTIONS = {
    "create_account",
    "add_group",
    "assign_license",
    "remove_group",
    "revoke_license",
    "suspend_account",
    "revoke_sessions",
    "delete_account",
}


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


def _check_key(x_api_key: str | None) -> None:
    if x_api_key != API_KEY:
        raise HTTPException(status_code=401, detail="invalid or missing X-API-Key")


def _apply_chaos(action: str) -> None:
    """Raise the injected fault, if one is armed for this call."""
    with _lock:
        mode = CHAOS["mode"]
        if mode == "off" or CHAOS["remaining"] <= 0:
            return
        if mode == "fail_action" and CHAOS["target_action"] not in (None, action):
            return
        CHAOS["remaining"] -= 1
        if CHAOS["remaining"] <= 0 and mode != "off":
            CHAOS["mode"] = "off"
            CHAOS["target_action"] = None

    if mode == "rate_limit":
        raise HTTPException(
            status_code=429,
            detail="rate limit exceeded",
            headers={"Retry-After": "2"},
        )
    if mode == "fail_action":
        raise HTTPException(status_code=500, detail=f"injected failure on {action}")
    if mode == "flaky":
        raise HTTPException(status_code=502, detail="upstream unavailable")
    if mode == "slow":
        time.sleep(float(CHAOS["slow_seconds"]))


def _log(action: str, email: str, idem: str | None, status: int) -> None:
    with _lock:
        CALL_LOG.append(
            {
                "at": _now(),
                "action": action,
                "work_email": email,
                "idempotency_key": idem,
                "status": status,
            }
        )


def _idem_lookup(key: str | None) -> dict[str, Any] | None:
    if not key:
        return None
    with _lock:
        return IDEMPOTENCY.get(key)


def _idem_store(key: str | None, payload: dict[str, Any]) -> None:
    if not key:
        return
    with _lock:
        IDEMPOTENCY[key] = payload


def _get_user_or_404(work_email: str) -> dict[str, Any]:
    user = USERS.get(work_email.lower())
    if not user:
        raise HTTPException(status_code=404, detail=f"user {work_email} not found")
    return user


# ---------------------------------------------------------------------------
# Request models
# ---------------------------------------------------------------------------
class CreateUser(BaseModel):
    employee_ref: str = Field(min_length=1)
    full_name: str = Field(min_length=1)
    work_email: str = Field(min_length=3)
    department: str
    role_code: str


class GroupBody(BaseModel):
    group: str = Field(min_length=1)


class LicenseBody(BaseModel):
    sku: str = Field(min_length=1)


class ChaosBody(BaseModel):
    mode: Literal["off", "rate_limit", "fail_action", "slow", "flaky"] = "off"
    target_action: str | None = None
    remaining: int = 1
    slow_seconds: float = 3.0


# ---------------------------------------------------------------------------
# User lifecycle
# ---------------------------------------------------------------------------
@app.post("/v1/users", status_code=201)
def create_user(
    response: Response,
    body: CreateUser,
    x_api_key: str | None = Header(default=None, alias="X-API-Key"),
    idempotency_key: str | None = Header(default=None, alias="Idempotency-Key"),
):
    _check_key(x_api_key)
    cached = _idem_lookup(idempotency_key)
    if cached is not None:
        response.headers["X-Idempotent-Replay"] = "true"
        _log("create_account", body.work_email, idempotency_key, 201)
        return cached

    _apply_chaos("create_account")
    email = body.work_email.lower()

    with _lock:
        if email in USERS:
            # A real IdP would 409. We return the existing record so that a
            # replay without an idempotency key is still safe.
            result = dict(USERS[email])
            response.headers["X-Existing-Resource"] = "true"
        else:
            USERS[email] = {
                "user_id": str(uuid.uuid4()),
                "employee_ref": body.employee_ref,
                "full_name": body.full_name,
                "work_email": email,
                "department": body.department,
                "role_code": body.role_code,
                "status": "active",
                "groups": [],
                "licenses": [],
                "sessions_revoked_at": None,
                "created_at": _now(),
                "updated_at": _now(),
            }
            result = dict(USERS[email])

    _idem_store(idempotency_key, result)
    _log("create_account", email, idempotency_key, 201)
    return result


@app.get("/v1/users/{work_email}")
def get_user(
    work_email: str = Path(...),
    x_api_key: str | None = Header(default=None, alias="X-API-Key"),
):
    _check_key(x_api_key)
    return _get_user_or_404(work_email)


@app.get("/v1/users")
def list_users(x_api_key: str | None = Header(default=None, alias="X-API-Key")):
    _check_key(x_api_key)
    return {"users": list(USERS.values()), "count": len(USERS)}


# ---------------------------------------------------------------------------
# Groups
# ---------------------------------------------------------------------------
@app.post("/v1/users/{work_email}/groups")
def add_group(
    response: Response,
    work_email: str,
    body: GroupBody,
    x_api_key: str | None = Header(default=None, alias="X-API-Key"),
    idempotency_key: str | None = Header(default=None, alias="Idempotency-Key"),
):
    _check_key(x_api_key)
    cached = _idem_lookup(idempotency_key)
    if cached is not None:
        response.headers["X-Idempotent-Replay"] = "true"
        _log("add_group", work_email, idempotency_key, 200)
        return cached

    _apply_chaos("add_group")
    user = _get_user_or_404(work_email)
    with _lock:
        if body.group not in user["groups"]:
            user["groups"].append(body.group)
        user["updated_at"] = _now()
        result = {"work_email": user["work_email"], "groups": list(user["groups"])}

    _idem_store(idempotency_key, result)
    _log("add_group", work_email, idempotency_key, 200)
    return result


@app.delete("/v1/users/{work_email}/groups/{group}")
def remove_group(
    response: Response,
    work_email: str,
    group: str,
    x_api_key: str | None = Header(default=None, alias="X-API-Key"),
    idempotency_key: str | None = Header(default=None, alias="Idempotency-Key"),
):
    _check_key(x_api_key)
    cached = _idem_lookup(idempotency_key)
    if cached is not None:
        response.headers["X-Idempotent-Replay"] = "true"
        return cached

    _apply_chaos("remove_group")
    user = _get_user_or_404(work_email)
    with _lock:
        user["groups"] = [g for g in user["groups"] if g != group]
        user["updated_at"] = _now()
        result = {"work_email": user["work_email"], "groups": list(user["groups"])}

    _idem_store(idempotency_key, result)
    _log("remove_group", work_email, idempotency_key, 200)
    return result


# ---------------------------------------------------------------------------
# Licences
# ---------------------------------------------------------------------------
@app.post("/v1/users/{work_email}/licenses")
def assign_license(
    response: Response,
    work_email: str,
    body: LicenseBody,
    x_api_key: str | None = Header(default=None, alias="X-API-Key"),
    idempotency_key: str | None = Header(default=None, alias="Idempotency-Key"),
):
    _check_key(x_api_key)
    cached = _idem_lookup(idempotency_key)
    if cached is not None:
        response.headers["X-Idempotent-Replay"] = "true"
        return cached

    _apply_chaos("assign_license")
    user = _get_user_or_404(work_email)
    with _lock:
        if body.sku not in user["licenses"]:
            user["licenses"].append(body.sku)
        user["updated_at"] = _now()
        result = {"work_email": user["work_email"], "licenses": list(user["licenses"])}

    _idem_store(idempotency_key, result)
    _log("assign_license", work_email, idempotency_key, 200)
    return result


@app.delete("/v1/users/{work_email}/licenses/{sku}")
def revoke_license(
    response: Response,
    work_email: str,
    sku: str,
    x_api_key: str | None = Header(default=None, alias="X-API-Key"),
    idempotency_key: str | None = Header(default=None, alias="Idempotency-Key"),
):
    _check_key(x_api_key)
    cached = _idem_lookup(idempotency_key)
    if cached is not None:
        response.headers["X-Idempotent-Replay"] = "true"
        return cached

    _apply_chaos("revoke_license")
    user = _get_user_or_404(work_email)
    with _lock:
        user["licenses"] = [s for s in user["licenses"] if s != sku]
        user["updated_at"] = _now()
        result = {"work_email": user["work_email"], "licenses": list(user["licenses"])}

    _idem_store(idempotency_key, result)
    _log("revoke_license", work_email, idempotency_key, 200)
    return result


# ---------------------------------------------------------------------------
# Offboarding actions
# ---------------------------------------------------------------------------
@app.post("/v1/users/{work_email}/sessions/revoke")
def revoke_sessions(
    response: Response,
    work_email: str,
    x_api_key: str | None = Header(default=None, alias="X-API-Key"),
    idempotency_key: str | None = Header(default=None, alias="Idempotency-Key"),
):
    _check_key(x_api_key)
    cached = _idem_lookup(idempotency_key)
    if cached is not None:
        response.headers["X-Idempotent-Replay"] = "true"
        return cached

    _apply_chaos("revoke_sessions")
    user = _get_user_or_404(work_email)
    with _lock:
        user["sessions_revoked_at"] = _now()
        user["updated_at"] = _now()
        result = {
            "work_email": user["work_email"],
            "sessions_revoked_at": user["sessions_revoked_at"],
        }

    _idem_store(idempotency_key, result)
    _log("revoke_sessions", work_email, idempotency_key, 200)
    return result


@app.post("/v1/users/{work_email}/suspend")
def suspend_account(
    response: Response,
    work_email: str,
    x_api_key: str | None = Header(default=None, alias="X-API-Key"),
    idempotency_key: str | None = Header(default=None, alias="Idempotency-Key"),
):
    _check_key(x_api_key)
    cached = _idem_lookup(idempotency_key)
    if cached is not None:
        response.headers["X-Idempotent-Replay"] = "true"
        return cached

    _apply_chaos("suspend_account")
    user = _get_user_or_404(work_email)
    with _lock:
        user["status"] = "suspended"
        user["updated_at"] = _now()
        result = {"work_email": user["work_email"], "status": user["status"]}

    _idem_store(idempotency_key, result)
    _log("suspend_account", work_email, idempotency_key, 200)
    return result


@app.delete("/v1/users/{work_email}")
def delete_account(
    response: Response,
    work_email: str,
    x_api_key: str | None = Header(default=None, alias="X-API-Key"),
    idempotency_key: str | None = Header(default=None, alias="Idempotency-Key"),
):
    """Soft delete. A real IdP would keep the object for a retention window too."""
    _check_key(x_api_key)
    cached = _idem_lookup(idempotency_key)
    if cached is not None:
        response.headers["X-Idempotent-Replay"] = "true"
        return cached

    _apply_chaos("delete_account")
    user = _get_user_or_404(work_email)
    with _lock:
        user["status"] = "deleted"
        user["groups"] = []
        user["licenses"] = []
        user["updated_at"] = _now()
        result = {"work_email": user["work_email"], "status": user["status"]}

    _idem_store(idempotency_key, result)
    _log("delete_account", work_email, idempotency_key, 200)
    return result


# ---------------------------------------------------------------------------
# Admin / test-harness endpoints. A real vendor would not expose these.
# ---------------------------------------------------------------------------
@app.post("/admin/chaos")
def set_chaos(
    body: ChaosBody,
    x_api_key: str | None = Header(default=None, alias="X-API-Key"),
):
    _check_key(x_api_key)
    if body.target_action and body.target_action not in ACTIONS:
        raise HTTPException(400, f"target_action must be one of {sorted(ACTIONS)}")
    with _lock:
        CHAOS.update(
            mode=body.mode,
            target_action=body.target_action,
            remaining=body.remaining if body.mode != "off" else 0,
            slow_seconds=body.slow_seconds,
        )
        return dict(CHAOS)


@app.get("/admin/state")
def get_state(x_api_key: str | None = Header(default=None, alias="X-API-Key")):
    _check_key(x_api_key)
    return {
        "users": USERS,
        "chaos": CHAOS,
        "idempotency_keys": sorted(IDEMPOTENCY.keys()),
        "call_log": CALL_LOG[-100:],
    }


@app.post("/admin/reset")
def reset(x_api_key: str | None = Header(default=None, alias="X-API-Key")):
    _check_key(x_api_key)
    with _lock:
        USERS.clear()
        IDEMPOTENCY.clear()
        CALL_LOG.clear()
        CHAOS.update(mode="off", target_action=None, remaining=0, slow_seconds=3.0)
    return {"reset": True, "at": _now()}


@app.get("/health")
def health():
    return {"status": "ok", "users": len(USERS), "chaos_mode": CHAOS["mode"]}
