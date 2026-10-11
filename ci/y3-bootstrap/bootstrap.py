#!/usr/bin/env python3
"""One manually dispatched, owner-authorized preparation for this public app.

Only the age-encrypted, exact-run transport manifest is a workflow artifact. OAuth
credentials, runner credentials and restored signing assets never leave the
temporary machine except as encrypted GitHub repository Secrets.
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import pathlib
import re
import shutil
import secrets
import signal
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request


PUBLIC_REPO = "444yttt/Y3POSClient"
BOOTSTRAP_REPO = "444yttt/astro-blog-starter-template"
BOOTSTRAP_REPO_ID = 1216010419
PRIVATE_REPO = "444yttt/Y3FloorGuide"
PRIVATE_BRANCH = "y3-pos-client"
PRIVATE_WORKFLOW = "migrate-client-signing.yml"
OWNER_ID = 267067583
AUTH_DIR = pathlib.Path("/workspace/scratch/y3-github-ci-auth")
AGE_URL = "https://github.com/FiloSottile/age/releases/download/v1.3.2/age-v1.3.2-linux-amd64.tar.gz"
AGE_SHA256 = "cbe24006683f8eb669266162894b9a522a1af52f2665fbc63a4bb032ed26ac10"
RUNNER_URL = "https://github.com/actions/runner/releases/download/v2.338.0/actions-runner-linux-x64-2.338.0.tar.gz"
RUNNER_SHA256 = "af4b794c1bc41d73d40535e3fe092a39f9679cd8d965954c2aca25a05ca41d32"


class BootstrapError(Exception):
    """A message that never contains a remote response or credential value."""


class PendingHandoff(Exception):
    """The genuine publisher is still completing its bounded job."""


def require(condition, message):
    if not condition:
        raise BootstrapError(message)


def paths():
    root = pathlib.Path(os.environ["RUNNER_TEMP"]).resolve()
    return root / "y3-public-signing-bootstrap", root / "y3-signing-challenge"


def protected_write(path, data):
    require(not path.is_symlink(), "Refusing a symlink for a protected temporary file.")
    descriptor, temporary = tempfile.mkstemp(prefix=".protected-", dir=path.parent)
    try:
        with os.fdopen(descriptor, "wb") as file:
            file.write(data if isinstance(data, bytes) else data.encode())
            file.flush()
            os.fsync(file.fileno())
        os.replace(temporary, path)
    finally:
        pathlib.Path(temporary).unlink(missing_ok=True)


def guard():
    require(os.environ.get("GITHUB_REPOSITORY") == BOOTSTRAP_REPO
            and os.environ.get("GITHUB_EVENT_NAME") == "workflow_dispatch"
            and os.environ.get("GITHUB_REF") == "refs/heads/main",
            "Only the approved public app's manually dispatched main branch may prepare signing.")
    event = json.loads(pathlib.Path(os.environ["GITHUB_EVENT_PATH"]).read_text())
    repo = event.get("repository", {})
    require(repo.get("full_name") == BOOTSTRAP_REPO and repo.get("id") == BOOTSTRAP_REPO_ID
            and repo.get("private") is False,
            "The preparation source must be the public repository hosting this iOS subproject.")
    sha = os.environ.get("GITHUB_SHA", "")
    require(re.fullmatch(r"[0-9a-f]{40}", sha), "The dispatched source SHA is invalid.")
    result = subprocess.run(["git", "rev-parse", "HEAD"], capture_output=True, check=False)
    require(result.returncode == 0 and result.stdout.decode().strip() == sha,
            "Checkout must match the exact dispatched public source SHA.")
    require(os.environ.get("Y3_EXPECTED_BOOTSTRAP_SHA") == sha,
            "The dispatch must explicitly name the reviewed bootstrap commit.")
    require(pathlib.Path("Clients/Y3POSClient/Y3Client.xcodeproj/project.pbxproj").is_file(),
            "The public repository must contain the actual Y3 POS Client software project.")
    require(re.fullmatch(r"[0-9a-f]{40}", os.environ.get("Y3_PRIVATE_SOURCE_SHA", ""))
            and os.environ["Y3_PRIVATE_SOURCE_SHA"] != "0" * 40,
            "The reviewed private migration commit must be pinned before dispatch.")


def api(path, token, method="GET", body=None, missing_ok=False):
    require(path.startswith("/"), "The GitHub API request path is invalid.")
    data = None if body is None else json.dumps(body).encode()
    request = urllib.request.Request("https://api.github.com" + path, data=data, method=method,
                                    headers={"Authorization": "Bearer " + token,
                                             "Accept": "application/vnd.github+json",
                                             "X-GitHub-Api-Version": "2022-11-28",
                                             "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(request, timeout=45) as response:
            content = response.read()
            return json.loads(content) if content else None
    except urllib.error.HTTPError as error:
        if missing_ok and error.code == 404:
            return None
        raise BootstrapError(f"GitHub API access failed (HTTP {error.code}); owner repository Administration, Actions and Secrets access is required.") from None
    except (urllib.error.URLError, TimeoutError, ValueError):
        raise BootstrapError("The canonical GitHub API request could not be completed.") from None


def download_extract(url, digest, directory):
    archive = directory / "download.tar.gz"
    hasher = hashlib.sha256()
    try:
        with urllib.request.urlopen(url, timeout=120) as response, archive.open("wb") as output:
            while block := response.read(1024 * 1024):
                output.write(block)
                hasher.update(block)
        require(hasher.hexdigest() == digest, "An official release archive failed its pinned SHA-256 check.")
        with tarfile.open(archive) as file:
            file.extractall(directory, filter="data")
    except (urllib.error.URLError, TimeoutError, tarfile.TarError):
        raise BootstrapError("A pinned official release could not be downloaded or extracted.") from None
    finally:
        archive.unlink(missing_ok=True)


def request_challenge():
    guard()
    state, challenge = paths()
    require(not state.exists() and not challenge.exists(), "Temporary preparation directories already exist.")
    state.mkdir(mode=0o700)
    challenge.mkdir(mode=0o700)
    age_directory = state / "age-tool"
    age_directory.mkdir(mode=0o700)
    download_extract(AGE_URL, AGE_SHA256, age_directory)
    recipient = pathlib.Path("Clients/Y3POSClient/delivery-recipient.txt").read_text().strip()
    require(re.fullmatch(r"age1[qpzry9x8gf2tvdw0s3jn54khce6mua7l]{58}", recipient),
            "The committed public age recipient is invalid.")
    identity = state / "transport-identity.txt"
    generated = subprocess.run([str(age_directory / "age" / "age-keygen"), "--output", str(identity)], capture_output=True)
    require(generated.returncode == 0, "The ephemeral transport identity could not be generated.")
    identity.chmod(0o600)
    public = subprocess.run([str(age_directory / "age" / "age-keygen"), "-y", str(identity)], capture_output=True)
    ephemeral_recipient = public.stdout.decode().strip()
    require(public.returncode == 0 and re.fullmatch(r"age1[qpzry9x8gf2tvdw0s3jn54khce6mua7l]{58}", ephemeral_recipient),
            "The ephemeral transport recipient is invalid.")
    transport = {"bootstrap_repository": BOOTSTRAP_REPO, "destination_repository": PUBLIC_REPO,
                 "run_id": os.environ["GITHUB_RUN_ID"], "run_attempt": os.environ["GITHUB_RUN_ATTEMPT"],
                 "source_sha": os.environ["GITHUB_SHA"], "recipient": ephemeral_recipient,
                 "handoff_nonce": secrets.token_urlsafe(32), "expires_at": time.time() + 600,
                 "transfer_workflow": "transfer-y3-signing.yml"}
    protected_write(state / "transport-state.json", json.dumps(transport))
    human_challenge = json.dumps(transport).encode()
    result = subprocess.run([str(age_directory / "age" / "age"), "--encrypt", "--recipient", recipient,
                             "--output", str(challenge / "challenge.json.age")],
                            input=human_challenge, capture_output=True, check=False)
    require(result.returncode == 0, "The human authorization challenge could not be encrypted.")
    # The runtime can read canonical GitHub Checks while its artifact CDN may
    # be unavailable. This duplicate contains ciphertext only, never the
    # plaintext manifest, handoff nonce or credential.
    encrypted_challenge = (challenge / "challenge.json.age").read_bytes()
    require(len(encrypted_challenge) <= 16384, "The encrypted transport manifest exceeds its bounded size.")
    check_token = os.environ.get("Y3_CHECK_TOKEN", "")
    require(check_token, "The request step needs its bounded GitHub Checks write credential.")
    run_id, attempt = os.environ["GITHUB_RUN_ID"], os.environ["GITHUB_RUN_ATTEMPT"]
    api(f"/repos/{BOOTSTRAP_REPO}/check-runs", check_token, "POST", {
        "name": "Y3 encrypted signing challenge " + run_id + "-" + attempt,
        "head_sha": os.environ["GITHUB_SHA"], "status": "completed", "conclusion": "neutral",
        "completed_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "details_url": f"https://github.com/{BOOTSTRAP_REPO}/actions/runs/{run_id}/attempts/{attempt}",
        "output": {"title": "Encrypted transport manifest for this exact run and attempt",
                   "summary": base64.b64encode(encrypted_challenge).decode("ascii")}})
    print("The encrypted, exact-run transport manifest is ready; no credential is in the artifact.")


def cli_environment():
    env = dict(os.environ)
    for key in ("GH_TOKEN", "GITHUB_TOKEN", "GH_DEBUG", "GH_API_DEBUG"):
        env.pop(key, None)
    env.update(GH_HOST="github.com", GH_CONFIG_DIR=str(AUTH_DIR))
    return env


def verify_owner_token(token):
    require(isinstance(token, str) and re.fullmatch(r"gho_[A-Za-z0-9]{36,}", token),
            "The received credential must be the previously approved GitHub CLI OAuth credential.")
    request = urllib.request.Request("https://api.github.com/user", headers={"Authorization": "Bearer " + token,
                   "Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28"})
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            scopes = set(response.headers.get("X-OAuth-Scopes", "").replace(" ", "").split(","))
            owner = json.load(response)
    except (urllib.error.URLError, TimeoutError, ValueError):
        raise BootstrapError("The owner credential could not be verified on the canonical GitHub API.") from None
    require(owner.get("login") == "444yttt" and owner.get("id") == OWNER_ID
            and owner.get("type") == "User" and {"repo", "workflow"}.issubset(scopes),
            "The credential must belong to 444yttt and have the approved repo/workflow scopes.")


def publish_handoff():
    guard()
    parent_run = os.environ.get("Y3_PARENT_RUN_ID", "")
    parent_attempt = os.environ.get("Y3_PARENT_ATTEMPT", "")
    require(re.fullmatch(r"[1-9][0-9]{0,19}", parent_run)
            and re.fullmatch(r"[1-9][0-9]{0,3}", parent_attempt),
            "The encrypted handoff must identify its exact parent run and attempt.")
    encoded = os.environ.get("Y3_ENCRYPTED_PAYLOAD", "")
    require(0 < len(encoded) <= 22000, "The encrypted workflow input exceeds its bounded size.")
    try:
        encrypted = base64.b64decode(encoded, validate=True)
    except ValueError:
        raise BootstrapError("The handoff input must be Base64 age ciphertext.") from None
    require(0 < len(encrypted) <= 16384 and encrypted.startswith(b"age-encryption.org/v1\n"),
            "The handoff input must be a bounded age ciphertext, never plaintext credentials.")
    check_token = os.environ.get("Y3_CHECK_TOKEN", "")
    require(check_token, "The transfer step requires its bounded GitHub Checks write credential.")
    parent = api(f"/repos/{BOOTSTRAP_REPO}/actions/runs/{parent_run}", check_token)
    require(parent.get("head_sha") == os.environ["GITHUB_SHA"]
            and parent.get("path") == ".github/workflows/prepare-y3-pos.yml"
            and parent.get("event") == "workflow_dispatch" and parent.get("head_branch") == "main"
            and str(parent.get("run_attempt")) == parent_attempt and parent.get("status") == "in_progress",
            "The encrypted handoff must target the active reviewed parent preparation run.")
    run_id, attempt = os.environ["GITHUB_RUN_ID"], os.environ["GITHUB_RUN_ATTEMPT"]
    api(f"/repos/{BOOTSTRAP_REPO}/check-runs", check_token, "POST", {
        "name": "Y3 encrypted credential handoff " + parent_run + "-" + parent_attempt,
        "head_sha": os.environ["GITHUB_SHA"], "status": "completed", "conclusion": "neutral",
        "completed_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "details_url": f"https://github.com/{BOOTSTRAP_REPO}/actions/runs/{run_id}/attempts/{attempt}",
        "output": {"title": "Y3 transfer " + run_id + "-" + attempt,
                   "summary": encoded}})
    print("The bounded encrypted handoff was published to its exact parent run.")


def accept_handoff_check(check, transport, state, check_token):
    require(check.get("name") == "Y3 encrypted credential handoff " + transport["run_id"] + "-" + transport["run_attempt"]
            and check.get("head_sha") == transport["source_sha"] and check.get("app", {}).get("slug") == "github-actions"
            and check.get("app", {}).get("id") == 15368
            and check.get("status") == "completed" and check.get("conclusion") == "neutral",
            "The handoff check does not match the trusted GitHub Actions producer and parent source.")
    details = re.fullmatch(r"Y3 transfer ([1-9][0-9]*)-([1-9][0-9]*)",
                           check.get("output", {}).get("title", ""))
    require(details, "The handoff check must identify the exact native transfer run.")
    require(check.get("details_url") in (
                f"https://github.com/{BOOTSTRAP_REPO}/actions/runs/{details[1]}/attempts/{details[2]}",
                f"https://github.com/{BOOTSTRAP_REPO}/runs/{check.get('id')}"),
            "The handoff check must use its canonical GitHub check or transfer run URL.")
    run = api(f"/repos/{BOOTSTRAP_REPO}/actions/runs/{details[1]}", check_token)
    require(run.get("path") == ".github/workflows/transfer-y3-signing.yml"
            and run.get("head_sha") == transport["source_sha"] and run.get("head_branch") == "main"
            and run.get("event") == "workflow_dispatch" and str(run.get("run_attempt")) == details[2]
            and run.get("actor", {}).get("login") == "444yttt" and run.get("actor", {}).get("id") == OWNER_ID,
            "The handoff producer must be the exact reviewed, owner-dispatched transfer workflow and suite.")
    parent = api(f"/repos/{BOOTSTRAP_REPO}/actions/runs/{transport['run_id']}", check_token)
    require(parent.get("head_sha") == transport["source_sha"]
            and parent.get("path") == ".github/workflows/prepare-y3-pos.yml"
            and parent.get("event") == "workflow_dispatch" and parent.get("head_branch") == "main"
            and str(parent.get("run_attempt")) == transport["run_attempt"],
            "The transfer must bind the original reviewed parent run and attempt.")
    suite_id = check.get("check_suite", {}).get("id")
    require(suite_id in (parent.get("check_suite_id"), run.get("check_suite_id")) and isinstance(suite_id, int),
            "The handoff check must belong to a recognized parent or publisher suite.")
    suite = api(f"/repos/{BOOTSTRAP_REPO}/check-suites/{suite_id}", check_token)
    require(suite.get("id") == suite_id and suite.get("head_sha") == transport["source_sha"]
            and suite.get("app", {}).get("id") == 15368 and suite.get("app", {}).get("slug") == "github-actions"
            and suite.get("repository", {}).get("id") == BOOTSTRAP_REPO_ID
            and suite.get("repository", {}).get("full_name") == BOOTSTRAP_REPO
            and suite.get("repository", {}).get("owner", {}).get("id") == OWNER_ID,
            "The recognized check suite must match the actual repository, source and GitHub Actions app.")
    if run.get("status") != "completed":
        raise PendingHandoff()
    require(run.get("conclusion") == "success", "The native transfer workflow did not complete successfully.")
    jobs = api(f"/repos/{BOOTSTRAP_REPO}/actions/runs/{details[1]}/jobs", check_token).get("jobs", [])
    publishers = [job for job in jobs if job.get("name") == "transfer-ciphertext"]
    if not publishers:
        raise PendingHandoff()
    require(len(publishers) == 1, "The transfer must have exactly one consistent publisher job.")
    publisher = publishers[0]
    if publisher.get("status") != "completed":
        raise PendingHandoff()
    require(publisher.get("conclusion") == "success", "The exact publisher job did not complete successfully.")
    steps = [step for step in publisher.get("steps", [])
             if step.get("name") == "Publish only the encrypted handoff for the exact parent"]
    if not steps:
        raise PendingHandoff()
    require(len(steps) == 1, "The transfer must have exactly one consistent handoff step.")
    if steps[0].get("status") != "completed":
        raise PendingHandoff()
    require(steps[0].get("conclusion") == "success", "The exact handoff step did not complete successfully.")
    encoded = check.get("output", {}).get("summary", "")
    require(isinstance(encoded, str) and 0 < len(encoded) <= 22000,
            "The encrypted handoff check exceeds its bounded size.")
    encrypted = base64.b64decode(encoded, validate=True)
    require(0 < len(encrypted) <= 16384 and encrypted.startswith(b"age-encryption.org/v1\n"),
            "The encrypted handoff check is not a bounded age ciphertext.")
    result = subprocess.run([str(state / "age-tool" / "age" / "age"), "--decrypt", "--identity",
                            str(state / "transport-identity.txt")], input=encrypted, capture_output=True, timeout=15)
    require(result.returncode == 0, "The encrypted handoff could not be authenticated.")
    payload = json.loads(result.stdout)
    require(isinstance(payload, dict), "The encrypted handoff must contain a bounded credential object.")
    require(time.time() < transport["expires_at"] and all(payload.get(key) == transport[key]
            for key in ("bootstrap_repository", "destination_repository", "run_id", "run_attempt", "source_sha", "recipient", "handoff_nonce")),
            "The encrypted credential does not match this exact reviewed challenge.")
    token = payload.get("oauth_token")
    require(isinstance(token, str) and re.fullmatch(r"gho_[A-Za-z0-9]{36,}", token),
            "The encrypted input did not contain the previously approved OAuth credential.")
    print("::add-mask::" + token, flush=True)
    verify_owner_token(token)
    protected_write(state / "owner-token", token)


def authorize(state):
    transport = json.loads((state / "transport-state.json").read_text())
    print("Waiting for the exact-run encrypted GitHub handoff check.", flush=True)
    check_token = os.environ.get("Y3_CHECK_TOKEN", "")
    require(check_token, "The parent requires its bounded GitHub Checks read credential.")
    name = "Y3 encrypted credential handoff " + transport["run_id"] + "-" + transport["run_attempt"]
    seen = set()
    while time.time() < transport["expires_at"] and not (state / "owner-token").is_file():
        query = urllib.parse.urlencode({"check_name": name, "filter": "all", "per_page": 100})
        checks = api(f"/repos/{BOOTSTRAP_REPO}/commits/{transport['source_sha']}/check-runs?{query}", check_token).get("check_runs", [])
        for check in checks:
            if check.get("id") in seen:
                continue
            try:
                accept_handoff_check(check, transport, state, check_token)
                if (state / "owner-token").is_file():
                    break
            except PendingHandoff:
                continue
            except (BootstrapError, ValueError, OSError, subprocess.SubprocessError):
                seen.add(check.get("id"))
                print("An invalid encrypted handoff was ignored; the original challenge remains active.", flush=True)
        if not (state / "owner-token").is_file():
            time.sleep(3)
    require((state / "owner-token").is_file(), "The one-time encrypted credential transfer timed out.")
    token = (state / "owner-token").read_text()
    require(not AUTH_DIR.exists(), "The fixed owner authentication directory already exists.")
    create = subprocess.run(["sudo", "install", "-d", "-m", "700", "-o", str(os.getuid()), "-g", str(os.getgid()), str(AUTH_DIR)], capture_output=True)
    require(create.returncode == 0, "The protected owner authentication directory could not be created.")
    login = subprocess.run(["gh", "auth", "login", "--hostname", "github.com", "--with-token"],
                           input=token.encode(), env=cli_environment(), capture_output=True)
    require(login.returncode == 0 and (AUTH_DIR / "hosts.yml").is_file(),
            "The owner credential could not be bound to the protected GitHub CLI configuration.")
    (AUTH_DIR / "hosts.yml").chmod(0o600)
    (state / "transport-identity.txt").unlink(missing_ok=True)
    return token


def worker_environment():
    return {key: value for key, value in os.environ.items()
            if not key.startswith(("GITHUB_", "ACTIONS_", "RUNNER_"))
            and key not in ("GH_TOKEN", "GH_DEBUG", "GH_API_DEBUG", "GH_CONFIG_DIR", "GH_HOST", "Y3_CHECK_TOKEN")}


def migrate():
    guard()
    state, _ = paths()
    token = authorize(state)
    # This source repository contains the actual public iOS subproject. Create
    # its dedicated public destination with the same owner-approved credential.
    found = api("/repos/" + PUBLIC_REPO, token, missing_ok=True)
    if found is None:
        api("/user/repos", token, "POST", {"name": "Y3POSClient", "private": False,
                "description": "iPhone client for the authorized Y3 POS service", "auto_init": False})
    public = api("/repos/" + PUBLIC_REPO, token)
    private = api("/repos/" + PRIVATE_REPO, token)
    require(public.get("full_name") == PUBLIC_REPO and public.get("private") is False
            and public.get("owner", {}).get("id") == OWNER_ID
            and private.get("full_name") == PRIVATE_REPO and private.get("private") is True
            and private.get("owner", {}).get("id") == OWNER_ID,
            "The approved public destination and private signing source do not match.")
    expected_sha = os.environ["Y3_PRIVATE_SOURCE_SHA"]
    branch = api(f"/repos/{PRIVATE_REPO}/git/ref/heads/{PRIVATE_BRANCH}", token)
    require(branch.get("object", {}).get("sha") == expected_sha,
            "The private migration branch moved; review and pin its new commit before another dispatch.")
    api(f"/repos/{PUBLIC_REPO}/actions/secrets/public-key", token)
    workflow = api(f"/repos/{PRIVATE_REPO}/actions/workflows/{PRIVATE_WORKFLOW}", token)
    require(workflow.get("path") == ".github/workflows/" + PRIVATE_WORKFLOW and workflow.get("state") == "active",
            "The reviewed private migration workflow must be registered and active.")
    runs_path = f"/repos/{PRIVATE_REPO}/actions/workflows/{PRIVATE_WORKFLOW}/runs?event=workflow_dispatch&per_page=30"
    previous_ids = {run["id"] for run in api(runs_path, token).get("workflow_runs", [])}
    runner_directory = state / "runner"
    runner_directory.mkdir(mode=0o700)
    download_extract(RUNNER_URL, RUNNER_SHA256, runner_directory)
    name = "y3-public-signing-" + os.environ["GITHUB_RUN_ID"] + "-" + os.environ["GITHUB_RUN_ATTEMPT"]
    label = "y3-signing-migration-" + os.environ["GITHUB_RUN_ID"] + "-" + secrets.token_hex(16)
    protected_write(state / "runner-name", name)
    registration = api(f"/repos/{PRIVATE_REPO}/actions/runners/registration-token", token, "POST")
    registration_token = registration.get("token", "")
    require(isinstance(registration_token, str) and registration_token, "GitHub did not provide the authorized runner registration.")
    print("::add-mask::" + registration_token, flush=True)
    configure_env = worker_environment()
    configure_env["ACTIONS_RUNNER_INPUT_TOKEN"] = registration_token
    configured = subprocess.run(["./config.sh", "--unattended", "--ephemeral", "--disableupdate",
                    "--url", "https://github.com/" + PRIVATE_REPO, "--name", name,
                    "--no-default-labels", "--labels", label, "--work", "_work"], cwd=runner_directory,
                    env=configure_env, capture_output=True, timeout=120)
    require(configured.returncode == 0, "The one-job private runner could not be registered.")
    log = (state / "runner-output.log").open("wb")
    process = None
    selected_run = None
    try:
        # Recheck immediately before dispatch; checkout is pinned to that run's SHA.
        require(api(f"/repos/{PRIVATE_REPO}/git/ref/heads/{PRIVATE_BRANCH}", token).get("object", {}).get("sha") == expected_sha,
                "The private migration branch changed before dispatch.")
        api(f"/repos/{PRIVATE_REPO}/actions/workflows/{PRIVATE_WORKFLOW}/dispatches", token, "POST",
            {"ref": PRIVATE_BRANCH, "inputs": {"runner_label": label}})
        print("The reviewed private migration is preparing this public app's signing Secrets.", flush=True)
        deadline = time.time() + 600
        while time.time() < deadline:
            candidates = [run for run in api(runs_path, token).get("workflow_runs", [])
                          if run["id"] not in previous_ids and run.get("head_sha") == expected_sha
                          and run.get("head_branch") == PRIVATE_BRANCH and run.get("actor", {}).get("login") == "444yttt"]
            require(len(candidates) <= 1, "Multiple private migration dispatches appeared; refusing ambiguous runner work.")
            if candidates:
                selected_run = candidates[0]
                if process is None:
                    require(selected_run.get("workflow_id") == workflow.get("id")
                            and selected_run.get("event") == "workflow_dispatch",
                            "The queued migration does not match the exact reviewed workflow.")
                    queued_jobs = api(f"/repos/{PRIVATE_REPO}/actions/runs/{selected_run['id']}/jobs", token).get("jobs", [])
                    if not queued_jobs:
                        time.sleep(2)
                        continue
                    require(len(queued_jobs) == 1 and queued_jobs[0].get("labels") == [label],
                            "The queued migration must request only this fresh one-job runner label.")
                    protected_write(state / "migration-run", str(selected_run["id"]))
                    process = subprocess.Popen(["./run.sh"], cwd=runner_directory, env=worker_environment(),
                            stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
                    protected_write(state / "runner-process", str(process.pid))
                if selected_run.get("status") == "completed":
                    require(selected_run.get("conclusion") == "success",
                            "The private signing migration failed; inspect its private, sanitized job result.")
                    jobs = api(f"/repos/{PRIVATE_REPO}/actions/runs/{selected_run['id']}/jobs", token).get("jobs", [])
                    require(len(jobs) == 1 and jobs[0].get("runner_name") == name and jobs[0].get("conclusion") == "success",
                            "The signing migration did not run on the exact one-job preparation runner.")
                    print("The dedicated public client signing Secrets are registered; the signed build can now run.")
                    return
            require(process is None or process.poll() is None or selected_run is not None,
                    "The one-job runner stopped before receiving its reviewed migration.")
            time.sleep(5)
        raise BootstrapError("The private signing migration timed out.")
    finally:
        if process is not None and process.poll() is None:
            os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=15)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait(timeout=5)
        log.close()


def stop_private_processes(state, names=("runner",)):
    for name in names:
        pid_path = state / (name + "-process")
        if not pid_path.is_file():
            continue
        try:
            pid = int(pid_path.read_text())
            # The PID is generated by this exact job; only stop its own group.
            require(os.getpgid(pid) == pid, "The temporary worker process group changed.")
            os.killpg(pid, signal.SIGTERM)
            deadline = time.time() + 3
            while time.time() < deadline:
                try:
                    os.kill(pid, 0)
                except ProcessLookupError:
                    break
                time.sleep(0.1)
            else:
                os.killpg(pid, signal.SIGKILL)
        except (ProcessLookupError, BootstrapError, ValueError):
            pass
        pid_path.unlink(missing_ok=True)


def cleanup():
    state, challenge = paths()
    if state.exists() and not state.is_symlink():
        stop_private_processes(state)
        token_path = state / "owner-token"
        if token_path.is_file() and not token_path.is_symlink():
            token = token_path.read_text()
            try:
                run_path = state / "migration-run"
                if run_path.is_file():
                    run = api(f"/repos/{PRIVATE_REPO}/actions/runs/{int(run_path.read_text())}", token)
                    if run.get("status") != "completed":
                        api(f"/repos/{PRIVATE_REPO}/actions/runs/{run['id']}/cancel", token, "POST")
                name_path = state / "runner-name"
                if name_path.is_file():
                    name = name_path.read_text()
                    runners = api(f"/repos/{PRIVATE_REPO}/actions/runners?per_page=100", token).get("runners", [])
                    for runner in runners:
                        if runner.get("name") == name:
                            api(f"/repos/{PRIVATE_REPO}/actions/runners/{runner['id']}", token, "DELETE")
            except (BootstrapError, ValueError):
                print("Temporary runner cleanup could not be confirmed by GitHub; inspect the private runner settings.", file=sys.stderr)
        shutil.rmtree(state)
    if challenge.exists() and not challenge.is_symlink():
        shutil.rmtree(challenge)
    if AUTH_DIR.exists() and not AUTH_DIR.is_symlink():
        shutil.rmtree(AUTH_DIR)


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("request", "authorize-and-migrate", "publish-handoff", "cleanup"))
    args = parser.parse_args()
    try:
        if args.mode == "request":
            request_challenge()
        elif args.mode == "publish-handoff":
            publish_handoff()
        elif args.mode == "authorize-and-migrate":
            def interrupted(_signum, _frame):
                raise BootstrapError("The one-time signing preparation was interrupted.")
            for number in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
                signal.signal(number, interrupted)
            try:
                migrate()
            finally:
                cleanup()
        else:
            cleanup()
    except (BootstrapError, OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        print("Signing preparation failed: " + (str(error) if isinstance(error, BootstrapError)
              else "A protected temporary input or required runner operation was unavailable."), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
