#!/usr/bin/env python3
"""Mock Forgejo API server for CI smoke tests.

Implements 16 Forgejo API endpoints that disinto init calls.
State stored in-memory (dicts), responds instantly.
"""

import base64
import hashlib
import json
import os
import re
import signal
import socket
import sys
import threading
import uuid
from http.server import HTTPServer, BaseHTTPRequestHandler
from socketserver import ThreadingMixIn
from urllib.parse import parse_qs, urlparse

# Global state
state = {
    "users": {},          # key: username -> user object
    "tokens": {},         # key: token_sha1 -> token object
    "repos": {},          # key: "owner/repo" -> repo object
    "orgs": {},           # key: orgname -> org object
    "labels": {},         # key: "owner/repo" -> list of labels
    "collaborators": {},  # key: "owner/repo" -> set of usernames
    "protections": {},    # key: "owner/repo" -> list of protections
    "oauth2_apps": [],    # list of oauth2 app objects
    "issues": [],         # list of issue objects
    "next_issue_number": {},  # key: "owner/repo" -> next number
}

next_ids = {"users": 1, "tokens": 1, "repos": 1, "orgs": 1, "labels": 1, "oauth2_apps": 1, "issues": 1}

SHUTDOWN_REQUESTED = False


def log_request(handler, method, path, status):
    """Log request details."""
    print(f"[{handler.log_date_time_string()}] {method} {path} {status}", file=sys.stderr)


def json_response(handler, status, data):
    """Send JSON response."""
    body = json.dumps(data).encode("utf-8")
    handler.send_response(status)
    handler.send_header("Content-Type", "application/json")
    handler.send_header("Content-Length", len(body))
    handler.end_headers()
    handler.wfile.write(body)


def basic_auth_user(handler):
    """Extract username from Basic auth header. Returns None if invalid."""
    auth_header = handler.headers.get("Authorization", "")
    if not auth_header.startswith("Basic "):
        return None
    try:
        decoded = base64.b64decode(auth_header[6:]).decode("utf-8")
        username, _ = decoded.split(":", 1)
        return username
    except Exception:
        return None


def token_auth_valid(handler):
    """Check if Authorization header contains token. Doesn't validate value."""
    auth_header = handler.headers.get("Authorization", "")
    return auth_header.startswith("token ")


def require_token(handler):
    """Require token auth. Return user or None if invalid."""
    if not token_auth_valid(handler):
        return None
    return True  # Any token is valid for mock purposes


def require_basic_auth(handler, required_user=None):
    """Require basic auth. Return username or None if invalid."""
    username = basic_auth_user(handler)
    if username is None:
        return None
    # Check user exists in state
    if username not in state["users"]:
        return None
    if required_user and username != required_user:
        return None
    return username


class ForgejoHandler(BaseHTTPRequestHandler):
    """HTTP request handler for mock Forgejo API."""

    def log_message(self, format, *args):
        """Override to use our logging."""
        pass  # We log in do_request

    def do_request(self, method):
        """Route request to appropriate handler."""
        parsed = urlparse(self.path)
        path = parsed.path
        query = parse_qs(parsed.query)

        log_request(self, method, self.path, "PENDING")

        # Strip /api/v1/ prefix for routing (or leading slash for other routes)
        route_path = path
        if route_path.startswith("/api/v1/"):
            route_path = route_path[8:]
        elif route_path.startswith("/"):
            route_path = route_path.lstrip("/")

        # Route to handler
        try:
            # First try exact match (with / replaced by _)
            handler_path = route_path.replace("/", "_")
            handler_name = f"handle_{method}_{handler_path}"
            handler = getattr(self, handler_name, None)

            if handler:
                handler(query)
            else:
                # Try pattern matching for routes with dynamic segments
                self._handle_patterned_route(method, route_path, query)
        except Exception as e:
            log_request(self, method, self.path, 500)
            json_response(self, 500, {"message": str(e)})

    def _handle_patterned_route(self, method, route_path, query):
        """Handle routes with dynamic segments using pattern matching."""
        # Define patterns: (regex, handler_name)
        patterns = [
            # Users patterns
            (r"^users/([^/]+)$", f"handle_{method}_users_username"),
            (r"^users/([^/]+)/tokens$", f"handle_{method}_users_username_tokens"),
            (r"^users/([^/]+)/tokens/([^/]+)$", f"handle_{method}_users_username_tokens_token_id"),
            (r"^users/([^/]+)/repos$", f"handle_{method}_users_username_repos"),
            # Repos patterns
            (r"^repos/([^/]+)/([^/]+)$", f"handle_{method}_repos_owner_repo"),
            (r"^repos/([^/]+)/([^/]+)/labels$", f"handle_{method}_repos_owner_repo_labels"),
            (r"^repos/([^/]+)/([^/]+)/branch_protections$", f"handle_{method}_repos_owner_repo_branch_protections"),
            (r"^repos/([^/]+)/([^/]+)/collaborators/([^/]+)$", f"handle_{method}_repos_owner_repo_collaborators_collaborator"),
            (r"^repos/([^/]+)/([^/]+)/issues$", f"handle_{method}_repos_owner_repo_issues"),
            (r"^repos/([^/]+)/([^/]+)/issues/([^/]+)$", f"handle_{method}_repos_owner_repo_issues_issue_id"),
            # Org patterns
            (r"^orgs/([^/]+)/repos$", f"handle_{method}_orgs_org_repos"),
            # User patterns
            (r"^user/repos$", f"handle_{method}_user_repos"),
            (r"^user/applications/oauth2$", f"handle_{method}_user_applications_oauth2"),
            # Admin patterns
            (r"^admin/users$", f"handle_{method}_admin_users"),
            (r"^admin/users/([^/]+)$", f"handle_{method}_admin_users_username"),
            (r"^admin/users/([^/]+)/repos$", f"handle_{method}_admin_users_username_repos"),
            # Org patterns
            (r"^orgs$", f"handle_{method}_orgs"),
        ]

        for pattern, handler_name in patterns:
            if re.match(pattern, route_path):
                handler = getattr(self, handler_name, None)
                if handler:
                    handler(query)
                    return

        self.handle_404()

    def do_GET(self):
        self.do_request("GET")

    def do_POST(self):
        self.do_request("POST")

    def do_PATCH(self):
        self.do_request("PATCH")

    def do_PUT(self):
        self.do_request("PUT")

    def handle_GET_version(self, query):
        """GET /api/v1/version"""
        json_response(self, 200, {"version": "11.0.0-mock"})

    def handle_GET_users_username(self, query):
        """GET /api/v1/users/{username}"""
        # Extract username from path
        parts = self.path.split("/")
        if len(parts) >= 5:
            username = parts[4]
        else:
            json_response(self, 404, {"message": "user does not exist"})
            return

        if username in state["users"]:
            json_response(self, 200, state["users"][username])
        else:
            json_response(self, 404, {"message": "user does not exist"})

    def handle_GET_users_username_repos(self, query):
        """GET /api/v1/users/{username}/repos"""
        if not require_token(self):
            json_response(self, 401, {"message": "invalid authentication"})
            return

        parts = self.path.split("/")
        if len(parts) >= 5:
            username = parts[4]
        else:
            json_response(self, 404, {"message": "user not found"})
            return

        if username not in state["users"]:
            json_response(self, 404, {"message": "user not found"})
            return

        # Return repos owned by this user
        user_repos = [r for r in state["repos"].values() if r["owner"]["login"] == username]
        json_response(self, 200, user_repos)

    def handle_GET_repos_owner_repo(self, query):
        """GET /api/v1/repos/{owner}/{repo}"""
        parts = self.path.split("/")
        if len(parts) >= 6:
            owner = parts[4]
            repo = parts[5]
        else:
            json_response(self, 404, {"message": "repository not found"})
            return

        key = f"{owner}/{repo}"
        if key in state["repos"]:
            json_response(self, 200, state["repos"][key])
        else:
            json_response(self, 404, {"message": "repository not found"})

    def handle_GET_repos_owner_repo_labels(self, query):
        """GET /api/v1/repos/{owner}/{repo}/labels"""
        parts = self.path.split("/")
        if len(parts) >= 6:
            owner = parts[4]
            repo = parts[5]
        else:
            json_response(self, 404, {"message": "repository not found"})
            return

        require_token(self)

        key = f"{owner}/{repo}"
        if key in state["labels"]:
            json_response(self, 200, state["labels"][key])
        else:
            json_response(self, 200, [])

    def handle_GET_user_applications_oauth2(self, query):
        """GET /api/v1/user/applications/oauth2"""
        require_token(self)
        json_response(self, 200, state["oauth2_apps"])

    def handle_GET_mock_shutdown(self, query):
        """GET /mock/shutdown"""
        global SHUTDOWN_REQUESTED
        SHUTDOWN_REQUESTED = True
        json_response(self, 200, {"status": "shutdown"})

    def handle_POST_admin_users(self, query):
        """POST /api/v1/admin/users"""
        require_token(self)

        content_length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(content_length).decode("utf-8")
        data = json.loads(body) if body else {}

        username = data.get("username")
        email = data.get("email")

        if not username or not email:
            json_response(self, 400, {"message": "username and email are required"})
            return

        user_id = next_ids["users"]
        next_ids["users"] += 1

        user = {
            "id": user_id,
            "login": username,
            "email": email,
            "full_name": data.get("full_name", ""),
            "is_admin": data.get("admin", False),
            "must_change_password": data.get("must_change_password", False),
            "login_name": data.get("login_name", username),
            "visibility": data.get("visibility", "public"),
            "avatar_url": f"https://seccdn.libravatar.org/avatar/{hashlib.md5(email.encode()).hexdigest()}",
        }

        state["users"][username] = user
        json_response(self, 201, user)

    def handle_GET_users_username_tokens(self, query):
        """GET /api/v1/users/{username}/tokens"""
        # Support both token auth (for listing own tokens) and basic auth (for admin listing)
        username = require_token(self)
        if not username:
            username = require_basic_auth(self)
        if not username:
            json_response(self, 401, {"message": "invalid authentication"})
            return

        # Return list of tokens for this user
        tokens = [t for t in state["tokens"].values() if t.get("username") == username]
        json_response(self, 200, tokens)

    def handle_DELETE_users_username_tokens_token_id(self, query):
        """DELETE /api/v1/users/{username}/tokens/{id}"""
        # Support both token auth and basic auth
        username = require_token(self)
        if not username:
            username = require_basic_auth(self)
        if not username:
            json_response(self, 401, {"message": "invalid authentication"})
            return

        parts = self.path.split("/")
        if len(parts) >= 8:
            token_id_str = parts[7]
        else:
            json_response(self, 404, {"message": "token not found"})
            return

        # Find and delete token by ID
        deleted = False
        for tok_sha1, tok in list(state["tokens"].items()):
            if tok.get("id") == int(token_id_str) and tok.get("username") == username:
                del state["tokens"][tok_sha1]
                deleted = True
                break

        if deleted:
            self.send_response(204)
            self.send_header("Content-Length", 0)
            self.end_headers()
        else:
            json_response(self, 404, {"message": "token not found"})

    def handle_POST_users_username_tokens(self, query):
        """POST /api/v1/users/{username}/tokens"""
        username = require_basic_auth(self)
        if not username:
            json_response(self, 401, {"message": "invalid authentication"})
            return

        content_length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(content_length).decode("utf-8")
        data = json.loads(body) if body else {}

        token_name = data.get("name")
        if not token_name:
            json_response(self, 400, {"message": "name is required"})
            return

        token_id = next_ids["tokens"]
        next_ids["tokens"] += 1

        # Deterministic token: sha256(username + name)[:40]
        token_str = hashlib.sha256(f"{username}{token_name}".encode()).hexdigest()[:40]

        token = {
            "id": token_id,
            "name": token_name,
            "sha1": token_str,
            "scopes": data.get("scopes", ["all"]),
            "created_at": "2026-04-01T00:00:00Z",
            "expires_at": None,
            "username": username,  # Store username for lookup
        }

        state["tokens"][token_str] = token
        json_response(self, 201, token)

    def handle_GET_orgs(self, query):
        """GET /api/v1/orgs"""
        if not require_token(self):
            json_response(self, 401, {"message": "invalid authentication"})
            return
        json_response(self, 200, list(state["orgs"].values()))

    def handle_POST_orgs(self, query):
        """POST /api/v1/orgs"""
        require_token(self)

        content_length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(content_length).decode("utf-8")
        data = json.loads(body) if body else {}

        username = data.get("username")
        if not username:
            json_response(self, 400, {"message": "username is required"})
            return

        org_id = next_ids["orgs"]
        next_ids["orgs"] += 1

        org = {
            "id": org_id,
            "username": username,
            "full_name": username,
            "avatar_url": f"https://seccdn.libravatar.org/avatar/{hashlib.md5(username.encode()).hexdigest()}",
            "visibility": data.get("visibility", "public"),
        }

        state["orgs"][username] = org
        json_response(self, 201, org)

    def handle_POST_orgs_org_repos(self, query):
        """POST /api/v1/orgs/{org}/repos"""
        require_token(self)

        parts = self.path.split("/")
        if len(parts) >= 6:
            org = parts[4]
        else:
            json_response(self, 404, {"message": "organization not found"})
            return

        content_length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(content_length).decode("utf-8")
        data = json.loads(body) if body else {}

        repo_name = data.get("name")
        if not repo_name:
            json_response(self, 400, {"message": "name is required"})
            return

        repo_id = next_ids["repos"]
        next_ids["repos"] += 1

        key = f"{org}/{repo_name}"
        repo = {
            "id": repo_id,
            "full_name": key,
            "name": repo_name,
            "owner": {"id": state["orgs"][org]["id"], "login": org},
            "empty": False,
            "default_branch": data.get("default_branch", "main"),
            "description": data.get("description", ""),
            "private": data.get("private", False),
            "html_url": f"https://example.com/{key}",
            "ssh_url": f"git@example.com:{key}.git",
            "clone_url": f"https://example.com/{key}.git",
            "created_at": "2026-04-01T00:00:00Z",
        }

        state["repos"][key] = repo
        json_response(self, 201, repo)

    def handle_POST_users_username_repos(self, query):
        """POST /api/v1/users/{username}/repos"""
        require_token(self)

        parts = self.path.split("/")
        if len(parts) >= 5:
            username = parts[4]
        else:
            json_response(self, 400, {"message": "username required"})
            return

        if username not in state["users"]:
            json_response(self, 404, {"message": "user not found"})
            return

        content_length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(content_length).decode("utf-8")
        data = json.loads(body) if body else {}

        repo_name = data.get("name")
        if not repo_name:
            json_response(self, 400, {"message": "name is required"})
            return

        repo_id = next_ids["repos"]
        next_ids["repos"] += 1

        key = f"{username}/{repo_name}"
        repo = {
            "id": repo_id,
            "full_name": key,
            "name": repo_name,
            "owner": {"id": state["users"][username]["id"], "login": username},
            "empty": not data.get("auto_init", False),
            "default_branch": data.get("default_branch", "main"),
            "description": data.get("description", ""),
            "private": data.get("private", False),
            "html_url": f"https://example.com/{key}",
            "ssh_url": f"git@example.com:{key}.git",
            "clone_url": f"https://example.com/{key}.git",
            "created_at": "2026-04-01T00:00:00Z",
        }

        state["repos"][key] = repo
        json_response(self, 201, repo)

    def handle_POST_admin_users_username_repos(self, query):
        """POST /api/v1/admin/users/{username}/repos
        Admin API to create a repo under a specific user namespace.
        This allows creating repos in any user's namespace when authenticated as admin.
        """
        require_token(self)

        parts = self.path.split("/")
        # /api/v1/admin/users/{username}/repos → parts[5] is the username
        if len(parts) >= 7:
            target_user = parts[5]
        else:
            json_response(self, 400, {"message": "username required"})
            return

        if target_user not in state["users"]:
            json_response(self, 404, {"message": "user not found"})
            return

        content_length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(content_length).decode("utf-8")
        data = json.loads(body) if body else {}

        repo_name = data.get("name")
        if not repo_name:
            json_response(self, 400, {"message": "name is required"})
            return

        repo_id = next_ids["repos"]
        next_ids["repos"] += 1

        key = f"{target_user}/{repo_name}"
        repo = {
            "id": repo_id,
            "full_name": key,
            "name": repo_name,
            "owner": {"id": state["users"][target_user]["id"], "login": target_user},
            "empty": not data.get("auto_init", False),
            "default_branch": data.get("default_branch", "main"),
            "description": data.get("description", ""),
            "private": data.get("private", False),
            "html_url": f"https://example.com/{key}",
            "ssh_url": f"git@example.com:{key}.git",
            "clone_url": f"https://example.com/{key}.git",
            "created_at": "2026-04-01T00:00:00Z",
        }

        state["repos"][key] = repo
        json_response(self, 201, repo)

    def handle_POST_user_repos(self, query):
        """POST /api/v1/user/repos"""
        require_token(self)

        content_length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(content_length).decode("utf-8")
        data = json.loads(body) if body else {}

        repo_name = data.get("name")
        if not repo_name:
            json_response(self, 400, {"message": "name is required"})
            return

        # Get authenticated user from token
        auth_header = self.headers.get("Authorization", "")
        token = auth_header.split(" ", 1)[1] if " " in auth_header else ""

        # Find user by token (use stored username field)
        owner = None
        for tok_sha1, tok in state["tokens"].items():
            if tok_sha1 == token:
                owner = tok.get("username")
                break

        if not owner:
            json_response(self, 401, {"message": "invalid token"})
            return

        repo_id = next_ids["repos"]
        next_ids["repos"] += 1

        key = f"{owner}/{repo_name}"
        repo = {
            "id": repo_id,
            "full_name": key,
            "name": repo_name,
            "owner": {"id": state["users"].get(owner, {}).get("id", 0), "login": owner},
            "empty": False,
            "default_branch": data.get("default_branch", "main"),
            "description": data.get("description", ""),
            "private": data.get("private", False),
            "html_url": f"https://example.com/{key}",
            "ssh_url": f"git@example.com:{key}.git",
            "clone_url": f"https://example.com/{key}.git",
            "created_at": "2026-04-01T00:00:00Z",
        }

        state["repos"][key] = repo
        json_response(self, 201, repo)

    def handle_POST_repos_owner_repo_labels(self, query):
        """POST /api/v1/repos/{owner}/{repo}/labels"""
        require_token(self)

        parts = self.path.split("/")
        if len(parts) >= 6:
            owner = parts[4]
            repo = parts[5]
        else:
            json_response(self, 404, {"message": "repository not found"})
            return

        content_length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(content_length).decode("utf-8")
        data = json.loads(body) if body else {}

        label_name = data.get("name")
        label_color = data.get("color")

        if not label_name or not label_color:
            json_response(self, 400, {"message": "name and color are required"})
            return

        label_id = next_ids["labels"]
        next_ids["labels"] += 1

        key = f"{owner}/{repo}"
        label = {
            "id": label_id,
            "name": label_name,
            "color": label_color,
            "description": data.get("description", ""),
            "url": f"https://example.com/api/v1/repos/{key}/labels/{label_id}",
        }

        if key not in state["labels"]:
            state["labels"][key] = []
        state["labels"][key].append(label)
        json_response(self, 201, label)

    def handle_POST_repos_owner_repo_branch_protections(self, query):
        """POST /api/v1/repos/{owner}/{repo}/branch_protections"""
        require_token(self)

        parts = self.path.split("/")
        if len(parts) >= 6:
            owner = parts[4]
            repo = parts[5]
        else:
            json_response(self, 404, {"message": "repository not found"})
            return

        content_length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(content_length).decode("utf-8")
        data = json.loads(body) if body else {}

        branch_name = data.get("branch_name", "main")
        key = f"{owner}/{repo}"

        # Generate unique ID for protection
        if key in state["protections"]:
            protection_id = len(state["protections"][key]) + 1
        else:
            protection_id = 1

        protection = {
            "id": protection_id,
            "repo_id": state["repos"].get(key, {}).get("id", 0),
            "branch_name": branch_name,
            "rule_name": data.get("rule_name", branch_name),
            "enable_push": data.get("enable_push", False),
            "enable_merge_whitelist": data.get("enable_merge_whitelist", True),
            "merge_whitelist_usernames": data.get("merge_whitelist_usernames", ["admin"]),
            "required_approvals": data.get("required_approvals", 1),
            "apply_to_admins": data.get("apply_to_admins", True),
        }

        if key not in state["protections"]:
            state["protections"][key] = []
        state["protections"][key].append(protection)
        json_response(self, 201, protection)

    def handle_POST_user_applications_oauth2(self, query):
        """POST /api/v1/user/applications/oauth2"""
        require_token(self)

        content_length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(content_length).decode("utf-8")
        data = json.loads(body) if body else {}

        app_name = data.get("name")
        if not app_name:
            json_response(self, 400, {"message": "name is required"})
            return

        app_id = next_ids["oauth2_apps"]
        next_ids["oauth2_apps"] += 1

        app = {
            "id": app_id,
            "name": app_name,
            "client_id": str(uuid.uuid4()),
            "client_secret": hashlib.sha256(str(uuid.uuid4()).encode()).hexdigest(),
            "redirect_uris": data.get("redirect_uris", []),
            "confidential_client": data.get("confidential_client", True),
            "created_at": "2026-04-01T00:00:00Z",
        }

        state["oauth2_apps"].append(app)
        json_response(self, 201, app)

    def handle_PATCH_admin_users_username(self, query):
        """PATCH /api/v1/admin/users/{username}"""
        if not require_token(self):
            json_response(self, 401, {"message": "invalid authentication"})
            return

        parts = self.path.split("/")
        if len(parts) >= 6:
            username = parts[5]
        else:
            json_response(self, 404, {"message": "user does not exist"})
            return

        if username not in state["users"]:
            json_response(self, 404, {"message": "user does not exist"})
            return

        content_length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(content_length).decode("utf-8")
        data = json.loads(body) if body else {}

        user = state["users"][username]
        for key, value in data.items():
            # Map 'admin' to 'is_admin' for consistency
            update_key = 'is_admin' if key == 'admin' else key
            if update_key in user:
                user[update_key] = value

        json_response(self, 200, user)

    def handle_PUT_repos_owner_repo_collaborators_collaborator(self, query):
        """PUT /api/v1/repos/{owner}/{repo}/collaborators/{collaborator}"""
        require_token(self)

        parts = self.path.split("/")
        if len(parts) >= 8:
            owner = parts[4]
            repo = parts[5]
            collaborator = parts[7]
        else:
            json_response(self, 404, {"message": "repository not found"})
            return

        content_length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(content_length).decode("utf-8")
        data = json.loads(body) if body else {}

        key = f"{owner}/{repo}"
        if key not in state["collaborators"]:
            state["collaborators"][key] = set()
        state["collaborators"][key].add(collaborator)

        self.send_response(204)
        self.send_header("Content-Length", 0)
        self.end_headers()

    def handle_GET_repos_owner_repo_collaborators_collaborator(self, query):
        """GET /api/v1/repos/{owner}/{repo}/collaborators/{collaborator}"""
        require_token(self)

        parts = self.path.split("/")
        if len(parts) >= 8:
            owner = parts[4]
            repo = parts[5]
            collaborator = parts[7]
        else:
            json_response(self, 404, {"message": "repository not found"})
            return

        key = f"{owner}/{repo}"
        if key in state["collaborators"] and collaborator in state["collaborators"][key]:
            self.send_response(204)
            self.send_header("Content-Length", 0)
            self.end_headers()
        else:
            json_response(self, 404, {"message": "collaborator not found"})

    def _issue_repo_key(self):
        """Extract owner/repo from /api/v1/repos/{owner}/{repo}/issues... path."""
        parts = self.path.split("/")
        if len(parts) >= 6:
            return parts[4], parts[5]
        return None, None

    def _find_issue(self, owner, repo, issue_num):
        """Find an issue by number. Returns (index, issue) or (None, None)."""
        key = f"{owner}/{repo}"
        for idx, issue in enumerate(state["issues"]):
            if issue.get("repo_key") == key and issue.get("number") == int(issue_num):
                return idx, issue
        return None, None

    def handle_GET_repos_owner_repo_issues(self, query):
        """GET /api/v1/repos/{owner}/{repo}/issues"""
        owner, repo = self._issue_repo_key()
        if not owner or not repo:
            json_response(self, 404, {"message": "repository not found"})
            return
        require_token(self)
        key = f"{owner}/{repo}"
        state_filter = query.get("state", ["open"])[0]
        type_filter = query.get("type", ["issues"])[0]
        limit = int(query.get("limit", ["30"])[0])
        page = int(query.get("page", ["1"])[0])
        results = [
            i for i in state["issues"]
            if i.get("repo_key") == key
            and i.get("state") == state_filter
            and (type_filter != "issues" or i.get("is_pull_request") is False)
        ]
        start = (page - 1) * limit
        page_items = results[start:start + limit]
        json_response(self, 200, page_items)

    def handle_GET_repos_owner_repo_issues_issue_id(self, query):
        """GET /api/v1/repos/{owner}/{repo}/issues/{issue_id}"""
        owner, repo = self._issue_repo_key()
        if not owner or not repo:
            json_response(self, 404, {"message": "repository not found"})
            return
        parts = self.path.split("/")
        if len(parts) >= 8:
            issue_num = parts[7]
        else:
            json_response(self, 404, {"message": "issue not found"})
            return
        idx, issue = self._find_issue(owner, repo, issue_num)
        if issue is None:
            json_response(self, 404, {"message": "issue not found"})
        else:
            json_response(self, 200, issue)

    def handle_POST_repos_owner_repo_issues(self, query):
        """POST /api/v1/repos/{owner}/{repo}/issues"""
        owner, repo = self._issue_repo_key()
        if not owner or not repo:
            json_response(self, 404, {"message": "repository not found"})
            return
        require_token(self)
        content_length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(content_length).decode("utf-8")
        data = json.loads(body) if body else {}
        key = f"{owner}/{repo}"
        if key not in state["next_issue_number"]:
            state["next_issue_number"][key] = 1
        issue_num = state["next_issue_number"][key]
        state["next_issue_number"][key] += 1
        # Resolve label IDs to names
        label_ids = data.get("labels", [])
        label_names = []
        if key in state["labels"]:
            for lid in label_ids:
                for lbl in state["labels"][key]:
                    if lbl.get("id") == lid:
                        label_names.append(lbl.get("name", ""))
                        break
        issue = {
            "id": next_ids["issues"],
            "number": issue_num,
            "title": data.get("title", ""),
            "body": data.get("body", ""),
            "state": data.get("state", "open"),
            "labels": [{"id": lid, "name": n} for lid, n in zip(label_ids, label_names)],
            "repo_key": key,
            "is_pull_request": False,
            "created_at": "2026-04-01T00:00:00Z",
            "updated_at": "2026-04-01T00:00:00Z",
        }
        next_ids["issues"] += 1
        state["issues"].append(issue)
        json_response(self, 201, issue)

    def handle_PATCH_repos_owner_repo_issues_issue_id(self, query):
        """PATCH /api/v1/repos/{owner}/{repo}/issues/{issue_id}"""
        owner, repo = self._issue_repo_key()
        if not owner or not repo:
            json_response(self, 404, {"message": "repository not found"})
            return
        require_token(self)
        parts = self.path.split("/")
        if len(parts) >= 8:
            issue_num = parts[7]
        else:
            json_response(self, 404, {"message": "issue not found"})
            return
        content_length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(content_length).decode("utf-8")
        data = json.loads(body) if body else {}
        idx, issue = self._find_issue(owner, repo, issue_num)
        if issue is None:
            json_response(self, 404, {"message": "issue not found"})
            return
        for key, value in data.items():
            issue[key] = value
        json_response(self, 200, issue)

    def handle_404(self):
        """Return 404 for unknown routes."""
        json_response(self, 404, {"message": "route not found"})


class ThreadingHTTPServer(ThreadingMixIn, HTTPServer):
    """Threaded HTTP server for handling concurrent requests."""
    daemon_threads = True


def main():
    """Start the mock server."""
    global SHUTDOWN_REQUESTED

    port = int(os.environ.get("MOCK_FORGE_PORT", 3000))
    try:
        server = ThreadingHTTPServer(("0.0.0.0", port), ForgejoHandler)
        try:
            server.socket.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        except OSError:
            pass  # Not all platforms support this
    except OSError as e:
        print(f"Error: Failed to start server on port {port}: {e}", file=sys.stderr)
        sys.exit(1)

    print(f"Mock Forgejo server starting on port {port}", file=sys.stderr)
    sys.stderr.flush()

    def shutdown_handler(signum, frame):
        global SHUTDOWN_REQUESTED
        SHUTDOWN_REQUESTED = True
        # Can't call server.shutdown() directly from signal handler in threaded server
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, shutdown_handler)
    signal.signal(signal.SIGINT, shutdown_handler)

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.shutdown()
        print("Mock Forgejo server stopped", file=sys.stderr)


if __name__ == "__main__":
    main()
