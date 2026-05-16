#!/usr/bin/env python3
"""Validate Ansible docker_container tasks for network parameter correctness.

Checks:
  A) network_mode: container:* tasks must not have dns_opts/dns/networks/ports
  B) tailscale_sidecar container task must include TS_ACCEPT_DNS env var
  C) standalone container tasks should have networks defined (warning)
  D) Gitea Tailscale sidecar tailscale_host_ports must include loopback HTTP
     AND LAN SSH bindings
  E) gitea-runner task must NOT use network_mode: container:* (regression
     lock-in — see docs/architecture/tailscale-sidecar-modes.md)
  F) runner image Dockerfile must install a dig-providing apt package
     (network.yml's post-apply DNS verify step needs `dig` — see issue #96)
  G) tailscale_sidecar role must fail fast with an auth-aware message on an
     expired/revoked TS_AUTHKEY and assert a usable tailnet route, not just
     BackendState==Running (regression lock-in — see Gitea issue #25)

Uses only Python stdlib — no PyYAML required.
"""
import glob
import re
import sys

ROLES_DIR = "playbooks/roles"
FORBIDDEN_WITH_CONTAINER_MODE = ["dns_opts", "dns:", "dns_search", "networks", "ports"]

DOCKERFILE_PATH = "Dockerfile"
# Either name provides `dig`. `dnsutils` is conventional and still valid on
# Ubuntu 24.04 (transitional package -> bind9-dnsutils); accept both so the
# lock-in does not break if a maintainer switches to the canonical name.
DIG_PACKAGES = ("dnsutils", "bind9-dnsutils")

TAILSCALE_SIDECAR_TASKS = f"{ROLES_DIR}/tailscale_sidecar/tasks/main.yml"
# Markers that must all be present in the sidecar role for the Gitea #25
# fail-fast fix to be considered in place:
#  - "NeedsLogin"  → the auth-expired/revoked BackendState is explicitly handled
#  - "Self.Online" → readiness asserts a usable route, not just Running
#  - the runbook path → the actionable error points operators at rotation
AUTHKEY_FAILFAST_MARKERS = (
    "NeedsLogin",
    "Self.Online",
    "docs/runbooks/tailscale-authkey-rotation.md",
)

GITEA_HOST_PORTS_REQUIRED = [
    re.compile(r'^["\']?127\.0\.0\.1:.*:3000["\']?$'),
    # Container-side port must be gitea_ssh_listen_port (= 2222 by default),
    # NOT :22. Inside the shared netns, :22 is bound by Tailscale Serve on
    # the tailnet IP only — LAN traffic to :22 gets RST. Gitea's actual
    # listener is :::2222. See PR #93 / issue #92 for the full diagnosis.
    re.compile(r'^["\']?\{\{\s*gitea_lan_host\s*\}\}:\{\{\s*gitea_lan_ssh_port\s*\}\}:\{\{\s*gitea_ssh_listen_port\s*\}\}["\']?$'),
]


def split_into_task_blocks(lines):
    """Split file lines into task blocks. Each block starts with '- name:'.

    Only splits on '- name:' at indent <= 4, which covers top-level tasks
    (indent 0) and tasks inside block:/rescue:/always: (indent 2-4).
    Deeper '- name:' entries (e.g. inside networks: list) are not boundaries.
    """
    blocks = []
    current = []
    for line in lines:
        stripped = line.lstrip()
        indent = len(line) - len(line.lstrip())
        if stripped.startswith("- name:") and indent <= 4 and current:
            blocks.append(current)
            current = []
        current.append(line)
    if current:
        blocks.append(current)
    return blocks


def is_docker_container_task(block):
    """Check if this task block uses community.docker.docker_container.

    Excludes docker_container_exec, docker_container_info, etc.
    """
    for line in block:
        stripped = line.lstrip()
        # Match the fully-qualified module name (exact match, not a prefix)
        if re.search(r'community\.docker\.docker_container\s*:', stripped):
            return True
        # Match the short module name, but NOT docker_container_exec/info/etc.
        if re.search(r'(?<!\w)docker_container\s*:', stripped) and \
           not re.search(r'docker_container_\w+\s*:', stripped):
            return True
    return False


def has_container_network_mode(block):
    """Check if task block has network_mode: container:*

    Skips YAML comment lines (those starting with '#' after lstrip) so that
    historical-reference comments like `# Was: network_mode: "container:..."`
    don't trip the check. Only the live parameter should match.
    """
    for line in block:
        stripped = line.lstrip()
        if stripped.startswith("#"):
            continue
        if re.search(r'network_mode:\s*["\']?container:', line):
            return True
    return False


def has_key_in_block(block, key):
    """Check if a YAML key appears in the docker_container parameter block."""
    for line in block:
        stripped = line.lstrip()
        if stripped.startswith(f"{key}:") or stripped.startswith(f"{key} :"):
            return True
        # Also check for key as bare list parent (dns_opts:\n  - ...)
        if key == "dns_opts" and stripped.startswith("dns_opts"):
            return True
    return False


def has_env_var(block, var_name):
    """Check if a specific env var key appears in the task's env: block."""
    text = "\n".join(block)
    return var_name in text


def check_file(filepath, errors, warnings):
    """Run all checks on a single task file."""
    with open(filepath) as f:
        lines = f.readlines()

    blocks = split_into_task_blocks(lines)

    for block in blocks:
        if not is_docker_container_task(block):
            continue

        task_name = ""
        for line in block:
            m = re.search(r'-\s*name:\s*(.+)', line)
            if m:
                task_name = m.group(1).strip()
                break

        # Check A: container network mode must not have forbidden params
        if has_container_network_mode(block):
            for key in FORBIDDEN_WITH_CONTAINER_MODE:
                clean_key = key.rstrip(":")
                if has_key_in_block(block, clean_key):
                    errors.append(
                        f"{filepath}: Task '{task_name}' uses network_mode: container: "
                        f"but also has '{clean_key}' (incompatible)"
                    )

        # Check C: standalone tasks should have networks
        if not has_container_network_mode(block):
            if not has_key_in_block(block, "networks"):
                # Only warn if it's not using network_mode at all
                has_any_network_mode = any("network_mode:" in line for line in block)
                if not has_any_network_mode:
                    warnings.append(
                        f"{filepath}: Task '{task_name}' has no 'networks' or "
                        f"'network_mode' — container may use default bridge network"
                    )


def check_d_gitea_sidecar_host_ports():
    """The Gitea Tailscale sidecar must publish loopback HTTP AND LAN SSH."""
    path = "playbooks/gitea-deploy.yml"
    try:
        with open(path) as fh:
            lines = fh.readlines()
    except FileNotFoundError:
        return [f"{path}: file not found"]

    # Find the "Deploy Tailscale sidecar for Gitea" task block
    blocks = split_into_task_blocks(lines)
    target = next(
        (b for b in blocks if any("Deploy Tailscale sidecar for Gitea" in ln for ln in b)),
        None,
    )
    if target is None:
        return [f"{path}: missing 'Deploy Tailscale sidecar for Gitea' task"]

    # Extract list items under tailscale_host_ports
    in_list = False
    items = []
    for ln in target:
        s = ln.lstrip()
        if s.startswith("tailscale_host_ports:"):
            in_list = True
            continue
        if in_list:
            if s.startswith("- "):
                items.append(s[2:].strip())
            elif s and not s.startswith("#") and not ln.startswith(("    ", "\t")):
                # de-dented out of the list
                break

    failures = []
    for required in GITEA_HOST_PORTS_REQUIRED:
        if not any(required.match(item) for item in items):
            failures.append(
                f"{path}: tailscale_host_ports for Gitea sidecar missing entry "
                f"matching {required.pattern!r}; found: {items}"
            )
    return failures


RUNNER_FORBIDDEN_NETWORK_MODE_REASON = (
    "The gitea-runner task must NOT use `network_mode: container:*`. Sharing the "
    "Tailscale sidecar's namespace collapses egress to the sidecar's view; "
    "dind-spawned job containers then can reach the tailnet but not the LAN "
    "(see docs/architecture/tailscale-sidecar-modes.md). The runner sits on "
    "gitea-net and reaches the tailnet via the sidecar's userspace HTTP/SOCKS5 "
    "proxy instead."
)


def check_e_runner_no_container_network_mode(errors):
    """Check E: gitea-runner role tasks must not use network_mode: container:*.

    Regression lock-in: if anyone re-introduces the namespace-share, this fails
    at static-check time before it ships.
    """
    filepath = f"{ROLES_DIR}/gitea_runner/tasks/main.yml"
    try:
        with open(filepath) as f:
            lines = f.readlines()
    except FileNotFoundError:
        errors.append(f"{filepath}: File not found")
        return

    blocks = split_into_task_blocks(lines)
    for block in blocks:
        if not is_docker_container_task(block):
            continue
        # Only inspect tasks that target the gitea-runner container
        if not any(re.search(r'name:\s*["\']?gitea-runner["\']?\s*$', ln) for ln in block):
            continue
        if has_container_network_mode(block):
            task_name = ""
            for line in block:
                m = re.search(r'-\s*name:\s*(.+)', line)
                if m:
                    task_name = m.group(1).strip()
                    break
            errors.append(
                f"{filepath}: Task '{task_name}' uses forbidden network_mode: "
                f"container:* on gitea-runner. {RUNNER_FORBIDDEN_NETWORK_MODE_REASON}"
            )


def check_tailscale_sidecar(errors):
    """Check B: tailscale_sidecar must have TS_ACCEPT_DNS in env."""
    filepath = f"{ROLES_DIR}/tailscale_sidecar/tasks/main.yml"
    try:
        with open(filepath) as f:
            lines = f.readlines()
    except FileNotFoundError:
        errors.append(f"{filepath}: File not found")
        return

    blocks = split_into_task_blocks(lines)
    found_sidecar_task = False

    for block in blocks:
        if not is_docker_container_task(block):
            continue
        found_sidecar_task = True
        if not has_env_var(block, "TS_ACCEPT_DNS"):
            errors.append(
                f"{filepath}: Tailscale sidecar docker_container task is missing "
                f"TS_ACCEPT_DNS in env (MagicDNS will be disabled)"
            )

    if not found_sidecar_task:
        errors.append(f"{filepath}: No docker_container task found in tailscale_sidecar role")


def check_f_dockerfile_dns_tools(errors):
    """Check F: the runner image must install a `dig`-providing apt package.

    network.yml's "Verify DNS resolution after apply" step shells out to
    `dig`. The base image does not ship it, so that step fails with exit
    127 once the workflow reaches it. Lock the dependency in here so a
    future Dockerfile edit cannot silently drop it (see issue #96).
    """
    try:
        with open(DOCKERFILE_PATH) as fh:
            text = fh.read()
    except FileNotFoundError:
        errors.append(f"{DOCKERFILE_PATH}: File not found")
        return

    # Collapse `\`-newline continuations so a multi-line RUN is one logical
    # line, then pull the argument list of each `apt-get install` command
    # (up to the next `&&` or newline). Scoping to the install command means
    # a package name elsewhere (an ENV value, a comment) cannot false-pass.
    joined = text.replace("\\\n", " ")
    install_args = " ".join(re.findall(r"apt-get install\b([^&\n]*)", joined))
    if not install_args.strip():
        errors.append(
            f"{DOCKERFILE_PATH}: expected an `apt-get install` layer; none found"
        )
        return

    # Exact whitespace-delimited token match so `dnsutils` is its own apt
    # argument, not a substring of e.g. `dnsutils-dev`.
    installed = set(install_args.split())
    if not any(pkg in installed for pkg in DIG_PACKAGES):
        errors.append(
            f"{DOCKERFILE_PATH}: no dig-providing apt package installed "
            f"(expected one of: {', '.join(DIG_PACKAGES)}); the network.yml "
            f"'Verify DNS resolution after apply' step needs `dig`. "
            f"See issue #96."
        )


def check_g_tailscale_authkey_failfast(errors):
    """Check G: the tailscale_sidecar role must fail fast on an
    expired/revoked TS_AUTHKEY with an actionable message AND assert a
    usable tailnet route (not just BackendState==Running).

    Without this, an expired persistent TS_AUTHKEY surfaces as an opaque
    60s Ansible `until` timeout, and a "registered but not routing"
    sidecar ships silently — downstream consumer deploys then fail with
    ENETUNREACH plays later. Lock the fix in so a refactor can't regress
    it (see Gitea issue #25).
    """
    try:
        with open(TAILSCALE_SIDECAR_TASKS) as fh:
            text = fh.read()
    except FileNotFoundError:
        errors.append(f"{TAILSCALE_SIDECAR_TASKS}: File not found")
        return

    missing = [m for m in AUTHKEY_FAILFAST_MARKERS if m not in text]
    if missing:
        errors.append(
            f"{TAILSCALE_SIDECAR_TASKS}: missing TS_AUTHKEY fail-fast / route "
            f"assertion marker(s) {missing}; the sidecar must detect an "
            f"expired/revoked key (NeedsLogin) with an actionable rotation "
            f"message and assert a usable route (Self.Online), not just "
            f"BackendState==Running. See Gitea issue #25 and "
            f"docs/runbooks/tailscale-authkey-rotation.md."
        )


def main():
    errors = []
    warnings = []

    # Find all role task files
    task_files = glob.glob(f"{ROLES_DIR}/*/tasks/main.yml")
    if not task_files:
        print(f"ERROR: No task files found in {ROLES_DIR}/*/tasks/main.yml")
        sys.exit(1)

    # Run checks A and C on all roles
    for filepath in task_files:
        check_file(filepath, errors, warnings)

    # Run check B on tailscale_sidecar specifically
    check_tailscale_sidecar(errors)

    # Run check D on the Gitea deploy playbook
    errors.extend(check_d_gitea_sidecar_host_ports())

    # Run check E: gitea-runner must not regress to network_mode: container:*
    check_e_runner_no_container_network_mode(errors)

    # Run check F: runner image must ship a dig-providing package (#96)
    check_f_dockerfile_dns_tools(errors)

    # Run check G: tailscale_sidecar must fail fast on a dead TS_AUTHKEY (#25)
    check_g_tailscale_authkey_failfast(errors)

    # Report results
    for w in warnings:
        print(f"WARN:  {w}")
    for e in errors:
        print(f"ERROR: {e}")

    if errors:
        print(f"\nFAILED: {len(errors)} error(s), {len(warnings)} warning(s)")
        sys.exit(1)
    else:
        print(f"\nPASSED: 0 errors, {len(warnings)} warning(s)")
        sys.exit(0)


if __name__ == "__main__":
    main()
