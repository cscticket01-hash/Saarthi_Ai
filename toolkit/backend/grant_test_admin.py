"""Owner-only test Firebase admin setup. Run in your own Google Cloud Shell.

Uses gcloud's owner credential in memory, not a service-account private key or
the Saarthi website's OAuth client. It never changes the active gcloud project.
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import urllib.error
import urllib.request


class SetupError(Exception):
    pass


def validate_target(project, email):
    if not re.fullmatch(r"[a-z][a-z0-9-]{4,61}[a-z0-9]", project) or not re.search(r"(^|[-_])(test|lab)([-_]|$)", project) or project == "saarthi-ai-df12b":
        raise SetupError("Use a separate test Firebase project with test or lab in its ID")
    if not re.fullmatch(r"[^\s@]+@[^\s@]+\.[^\s@]+", email) or len(email) > 255:
        raise SetupError("Enter the existing test administrator's email")


def owner_token():
    try:
        result = subprocess.run(["gcloud", "auth", "print-access-token"], capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise SetupError("Run this helper in Google Cloud Shell, signed in as the test-project owner") from error
    if result.returncode or not result.stdout.strip():
        raise SetupError("Cloud Shell owner authorization is missing; sign in to your own test-project owner account")
    return result.stdout.strip()


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def google_post(project, action, body, token):
    url = f"https://identitytoolkit.googleapis.com/v1/projects/{project}/accounts:{action}"
    request = urllib.request.Request(url, json.dumps(body, separators=(",", ":")).encode(),
                                     {"Authorization": "Bearer " + token, "Content-Type": "application/json"}, method="POST")
    try:
        with urllib.request.build_opener(NoRedirect()).open(request, timeout=30) as response:
            raw = response.read(1_000_001)
            if len(raw) > 1_000_000:
                raise SetupError("Google returned an oversized account response")
            data = json.loads(raw)
    except urllib.error.HTTPError as error:
        raise SetupError(f"Google rejected the test administrator operation (HTTP {error.code}). Check the explicit test project, Firebase Auth setup and your owner permissions") from None
    except (urllib.error.URLError, TimeoutError, ValueError) as error:
        raise SetupError("Google account operation did not complete; no verified result is available") from None
    if not isinstance(data, dict):
        raise SetupError("Google returned an invalid account response")
    return data


def grant(project, email, request=google_post, token_provider=owner_token):
    validate_target(project, email)
    token = token_provider()
    account = request(project, "lookup", {"email": [email]}, token)
    users = account.get("users", [])
    if not isinstance(users, list) or len(users) != 1 or not isinstance(users[0], dict):
        raise SetupError("Create this administrator in the test project's Authentication users first")
    user = users[0]
    if not user.get("localId") or str(user.get("email", "")).lower() != email.lower() or user.get("disabled") is True:
        raise SetupError("The returned account is not the active test administrator")
    try:
        claims = json.loads(user.get("customAttributes") or "{}")
    except (TypeError, ValueError) as error:
        raise SetupError("Existing custom claims could not be read safely") from error
    if not isinstance(claims, dict):
        raise SetupError("Existing custom claims are not an object")
    expected = {**claims, "admin": True}
    encoded = json.dumps(expected, ensure_ascii=False, separators=(",", ":"))
    if len(encoded.encode()) > 1000:
        raise SetupError("Existing custom claims leave insufficient space for the admin claim")
    if claims.get("admin") is not True:
        request(project, "update", {"localId": user["localId"], "customAttributes": encoded}, token)
    saved = request(project, "lookup", {"localId": [user["localId"]]}, token).get("users", [])
    if not isinstance(saved, list) or len(saved) != 1 or not isinstance(saved[0], dict) or saved[0].get("localId") != user["localId"]:
        raise SetupError("Google did not read back the same test administrator")
    try:
        actual = json.loads(saved[0].get("customAttributes") or "{}")
    except (ValueError, TypeError, AttributeError) as error:
        raise SetupError("Google did not return valid claim read-back") from error
    if actual != expected:
        raise SetupError("Admin claim was not verified by account read-back; do not proceed as connected")
    return {"project_id": project, "admin_claim_verified": True, "sign_in_again": True}


def main():
    parser = argparse.ArgumentParser(description="Grant and verify an existing test Firebase administrator using your own Cloud Shell owner login")
    parser.add_argument("--project", required=True)
    parser.add_argument("--email", required=True)
    args = parser.parse_args()
    try:
        result = grant(args.project.strip(), args.email.strip())
    except SetupError as error:
        parser.exit(1, "SETUP FAILED: " + str(error) + "\n")
    print("Admin claim verified for " + result["project_id"] + ". Sign in again in the toolkit, then click Check Firebase only.")


if __name__ == "__main__":
    main()
