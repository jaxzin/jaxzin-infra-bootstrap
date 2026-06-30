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
  H) gitea_runner role must stay host-agnostic AND socket-mounted: the
     runner container bind-mounts /var/run/docker.sock, and the role +
     config template are free of Synology/dind/SOCKS/proxy coupling
     (network_mode: container, /volume1, daemon.json, ts-socks5,
     synology_dsm). Regression lock-in for the runner-on-a-generic-host
     rearchitecture — see docs/runbooks/gitea-runner-host.md.
  J) runner image Dockerfile must pip-install the Docker SDK (`docker`):
     gitea-deploy.yml Play 2 runs community.docker locally in this image
     (connection: local, co-located with the Gitea runner)
  K) stack_reconcile watchdog container is correctly defined: a
     docker_container task named `stack-reconcile` with restart_policy:
     always, a /var/run/docker.sock bind-mount, log_driver: json-file, and
     a command/volumes reference to the reconcile script. The watchdog must
     survive a Docker-daemon restart (restart=always) and reach the daemon
     through the mounted socket — both are load-bearing for self-healing.
  L) the reconcile SAFETY CONTRACT is intact: the reconcile script stands
     down on a maintenance lock, the backup writes+trap-releases that lock,
     docker live-restore is on, AND the two lock-path defaults (one in
     stack_reconcile, one in gitea_backup) reduce to the SAME path — a
     single source of truth that a one-sided edit must not be able to split.

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

GITEA_RUNNER_TASKS = f"{ROLES_DIR}/gitea_runner/tasks/main.yml"
GITEA_RUNNER_CONFIG_TEMPLATE = f"{ROLES_DIR}/gitea_runner/templates/config.yaml.j2"

# The runner is socket-mounted on a generic Linux host (no dind, no
# Synology, no Tailscale-sidecar/SOCKS coupling). The bind-mount of the
# host docker socket MUST be present; the markers below MUST be absent
# from BOTH the task file and the rendered config template — each is a
# fingerprint of the retired NAS/dind/SOCKS architecture. See
# docs/runbooks/gitea-runner-host.md.
GITEA_RUNNER_SOCKET_MOUNT_MARKER = "/var/run/docker.sock:/var/run/docker.sock"
GITEA_RUNNER_FORBIDDEN_MARKERS = (
    "network_mode: container",  # namespace-share with a sidecar
    "/volume1",                 # Synology DSM host path
    "daemon.json",              # dind storage-driver pin
    "ts-socks5",                # static SOCKS5 ssh helper
    "10-tailnet-proxy.conf",    # SOCKS ssh_config.d snippet
    "synology_dsm",             # DSM-only runner label
    "DOCKER_INSECURE_NO_IPTABLES_RAW",  # DSM dind workaround
)

GITEA_HOST_PORTS_REQUIRED = [
    re.compile(r'^["\']?127\.0\.0\.1:.*:3000["\']?$'),
    # Container-side port must be gitea_ssh_listen_port (= 2222 by default),
    # NOT :22. Inside the shared netns, :22 is bound by Tailscale Serve on
    # the tailnet IP only — LAN traffic to :22 gets RST. Gitea's actual
    # listener is :::2222. See PR #93 / issue #92 for the full diagnosis.
    re.compile(r'^["\']?\{\{\s*gitea_lan_host\s*\}\}:\{\{\s*gitea_lan_ssh_port\s*\}\}:\{\{\s*gitea_ssh_listen_port\s*\}\}["\']?$'),
]

# --- CHECK K / L: stack_reconcile watchdog + reconcile safety contract -------
STACK_RECONCILE_TASKS = f"{ROLES_DIR}/stack_reconcile/tasks/main.yml"
STACK_RECONCILE_SCRIPT = f"{ROLES_DIR}/stack_reconcile/templates/stack_reconcile.sh.j2"
STACK_RECONCILE_DEFAULTS = f"{ROLES_DIR}/stack_reconcile/defaults/main.yml"
GITEA_DUMP_SCRIPT = f"{ROLES_DIR}/gitea_backup/templates/gitea_dump.sh.j2"
GITEA_BACKUP_DEFAULTS = f"{ROLES_DIR}/gitea_backup/defaults/main.yml"
CM_CONFIG_DEFAULTS = f"{ROLES_DIR}/container_manager_config/defaults/main.yml"

# The watchdog container's name (the reconcile self-healer). Both CHECK K
# (the docker_container task) and the reconcile/backup coordination key off
# this single literal.
STACK_RECONCILE_CONTAINER_NAME = "stack-reconcile"

# The host docker socket the watchdog talks to. Without this bind-mount the
# watchdog cannot reach the daemon to revive orphaned containers.
STACK_RECONCILE_SOCKET_MOUNT = "/var/run/docker.sock:/var/run/docker.sock"

# The reconcile script filename — the watchdog command/volumes must reference
# it (it is mounted in and run on every loop).
STACK_RECONCILE_SCRIPT_BASENAME = "stack_reconcile.sh"

# The stable, host-neutral tail every reconcile lock path must reduce to. The
# leading directory ({{ gitea_data_path }}) varies per host, but the suffix is
# the single source of truth shared by stack_reconcile and gitea_backup.
RECONCILE_LOCK_SUFFIX = "/run/.reconcile-pause"


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
    "The gitea-runner task must NOT use `network_mode: container:*`. The runner "
    "now runs on a generic Linux host with host-level Tailscale and reaches the "
    "tailnet through the host (plain `network_mode: bridge`); sharing another "
    "container's namespace is a fingerprint of the retired NAS Tailscale-sidecar "
    "architecture. See docs/runbooks/gitea-runner-host.md."
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


def check_j_dockerfile_docker_sdk(errors):
    """Check J: the runner image must pip-install the Docker SDK
    (`docker`).

    Kept as a lock-in: the Docker SDK is cheap insurance in the runner
    image. NOTE the primary consumer moved — gitea_runner now deploys over
    SSH to a remote target, so the TARGET needs the SDK (installed by the
    runner_host_seed role). This check guards the image-side copy from being
    dropped accidentally. See docs/runbooks/gitea-runner-host.md.
    """
    try:
        with open(DOCKERFILE_PATH) as fh:
            text = fh.read()
    except FileNotFoundError:
        errors.append(f"{DOCKERFILE_PATH}: File not found")
        return

    # Same scoping trick as Check F: collapse `\`-newline continuations,
    # then pull the args of each pip/pip3 install command (up to the next
    # `&&` or newline) so a `docker` mention elsewhere can't false-pass.
    joined = text.replace("\\\n", " ")
    pip_args = " ".join(re.findall(r"pip3?\s+install\b([^&\n]*)", joined))
    if not pip_args.strip():
        errors.append(
            f"{DOCKERFILE_PATH}: expected a `pip install` layer; none found"
        )
        return

    # Token's distribution name is the part before any version specifier.
    names = {re.split(r"[=<>!~]", tok)[0] for tok in pip_args.split()}
    if "docker" not in names:
        errors.append(
            f"{DOCKERFILE_PATH}: the Docker SDK for Python (`docker`) is "
            f"not pip-installed; community.docker.docker_container needs it "
            f"because gitea-deploy.yml Play 2 runs locally in this image "
            f"(connection: local, co-located with the Gitea runner) and "
            f"manages the host Docker daemon. See "
            f"docs/runbooks/gitea-runner-host.md."
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


def check_h_gitea_runner_socket_mount(errors):
    """Check H: the gitea_runner role must stay host-agnostic and
    socket-mounted.

    The rearchitecture moved the runner off the Synology NAS onto a
    generic Linux Docker host: a single plain (non-dind) act_runner that
    bind-mounts the host's /var/run/docker.sock and reaches the tailnet
    through the host's own Tailscale (no sidecar). This check is the
    regression lock-in for that decision — it fails if the socket-mount
    is dropped, or if any fingerprint of the retired NAS/dind/SOCKS
    architecture (network_mode: container, /volume1, daemon.json,
    ts-socks5, the SOCKS ssh_config.d snippet, the synology_dsm label,
    the DSM dind iptables workaround) reappears in either the task file
    or the rendered config template. See
    docs/runbooks/gitea-runner-host.md.
    """
    texts = {}
    for path in (GITEA_RUNNER_TASKS, GITEA_RUNNER_CONFIG_TEMPLATE):
        try:
            with open(path) as fh:
                texts[path] = fh.read()
        except FileNotFoundError:
            errors.append(f"{path}: File not found")
            texts[path] = ""

    if GITEA_RUNNER_SOCKET_MOUNT_MARKER not in texts.get(GITEA_RUNNER_TASKS, ""):
        errors.append(
            f"{GITEA_RUNNER_TASKS}: missing the host docker socket bind-mount "
            f"({GITEA_RUNNER_SOCKET_MOUNT_MARKER}); the runner is socket-mounted "
            f"on a generic host, not dind. See docs/runbooks/gitea-runner-host.md."
        )

    for path, text in texts.items():
        for marker in GITEA_RUNNER_FORBIDDEN_MARKERS:
            if marker in text:
                errors.append(
                    f"{path}: contains retired NAS/dind/SOCKS marker "
                    f"{marker!r}; the runner now runs on a generic Linux host "
                    f"(socket-mount, host-level Tailscale, no sidecar). See "
                    f"docs/runbooks/gitea-runner-host.md."
                )


def check_k_stack_reconcile(errors):
    """Check K: the stack_reconcile watchdog container is correctly defined.

    The watchdog is the fast (~30s) self-healer that revives Gitea-stack
    containers orphaned by an out-of-band Container Manager / Docker daemon
    restart. For it to do that job it MUST:
      * be a docker_container task named `stack-reconcile`;
      * carry restart_policy: always — so the watchdog itself survives the
        very daemon restart it is meant to recover from (otherwise the thing
        that revives orphans is itself left dead);
      * bind-mount /var/run/docker.sock:/var/run/docker.sock — its only
        channel to the daemon; without the socket it can inspect/start
        nothing;
      * pin log_driver: json-file — the `db` log-driver default has
        repeatedly wedged the whole stack (autoheal can't recover
        db-driver containers), so every new container pins json-file; and
      * reference the reconcile script (stack_reconcile.sh) in its
        command/volumes — the watchdog loop runs that script every tick.

    Regression lock-in: if a refactor drops any of these, the daemon-restart
    self-heal silently stops working. See docs/runbooks/gitea-stack-reconcile.md.
    """
    try:
        with open(STACK_RECONCILE_TASKS) as fh:
            lines = fh.readlines()
    except FileNotFoundError:
        errors.append(
            f"{STACK_RECONCILE_TASKS}: File not found — the stack_reconcile "
            f"watchdog role is missing entirely; the Gitea stack will NOT "
            f"self-heal after a Docker-daemon restart. See "
            f"docs/runbooks/gitea-stack-reconcile.md."
        )
        return

    blocks = split_into_task_blocks(lines)

    # Find the docker_container task whose name: is `stack-reconcile`. The
    # name can be quoted or a {{ var }}, so accept both the bare literal and a
    # var whose value is the literal (the role default).
    watchdog = None
    name_re = re.compile(
        r'^\s*name:\s*["\']?(?:'
        + re.escape(STACK_RECONCILE_CONTAINER_NAME)
        + r'|\{\{\s*stack_reconcile_container_name\s*\}\})["\']?\s*$'
    )
    for block in blocks:
        if not is_docker_container_task(block):
            continue
        if any(name_re.match(ln) for ln in block):
            watchdog = block
            break

    if watchdog is None:
        errors.append(
            f"{STACK_RECONCILE_TASKS}: no docker_container task named "
            f"'{STACK_RECONCILE_CONTAINER_NAME}' found; the reconcile watchdog "
            f"container must exist for the stack to self-heal after a "
            f"daemon restart. See docs/runbooks/gitea-stack-reconcile.md."
        )
        return

    text = "".join(watchdog)

    # restart_policy: always — the watchdog must come back after the daemon
    # restart it exists to recover from.
    if not re.search(r'restart_policy:\s*always\b', text):
        errors.append(
            f"{STACK_RECONCILE_TASKS}: watchdog '{STACK_RECONCILE_CONTAINER_NAME}' "
            f"is missing 'restart_policy: always'; without it the self-healer "
            f"is itself left dead by the very daemon restart it must survive."
        )

    # docker.sock bind-mount — the watchdog's only channel to the daemon.
    if STACK_RECONCILE_SOCKET_MOUNT not in text:
        errors.append(
            f"{STACK_RECONCILE_TASKS}: watchdog '{STACK_RECONCILE_CONTAINER_NAME}' "
            f"does not bind-mount the docker socket "
            f"({STACK_RECONCILE_SOCKET_MOUNT}); without it the watchdog cannot "
            f"talk to the daemon to inspect or start orphaned containers."
        )

    # json-file log driver — never the `db` driver that wedges the stack.
    if not re.search(r'log_driver:\s*json-file\b', text):
        errors.append(
            f"{STACK_RECONCILE_TASKS}: watchdog '{STACK_RECONCILE_CONTAINER_NAME}' "
            f"is missing 'log_driver: json-file'; the daemon-default `db` driver "
            f"has repeatedly wedged the whole stack, so every container pins "
            f"json-file."
        )

    # The watchdog must actually run the reconcile script — reference it in
    # the command and/or the volume mount.
    if STACK_RECONCILE_SCRIPT_BASENAME not in text:
        errors.append(
            f"{STACK_RECONCILE_TASKS}: watchdog '{STACK_RECONCILE_CONTAINER_NAME}' "
            f"does not reference the reconcile script "
            f"('{STACK_RECONCILE_SCRIPT_BASENAME}') in its command/volumes; the "
            f"watchdog loop must run that script every tick."
        )


def _effective_reconcile_lock_path(text):
    """Reduce a defaults file's reconcile lock path to its effective value.

    stdlib-only (no Jinja engine): we resolve at most ONE level of role-local
    var indirection. stack_reconcile factors its lock path through an
    intermediate var:

        stack_reconcile_lock_dir:  "{{ gitea_data_path }}/run"
        stack_reconcile_lock_path: "{{ stack_reconcile_lock_dir }}/.reconcile-pause"

    so the literal '/run/.reconcile-pause' is SPLIT across two lines. We
    substitute the `*_lock_dir` value into the `*_lock_path` value to
    reconstruct the effective path. gitea_backup writes it contiguously
    ({{ gitea_data_path }}/run/.reconcile-pause), so no substitution is
    needed there — but the same logic handles it unchanged.

    Returns the reduced *_lock_path string (with `{{ gitea_data_path }}`
    left as-is — it is the same per-host prefix on both sides), or None if no
    lock-path assignment is found.
    """
    # Collect every `*_lock_dir: "..."` assignment so we can inline it.
    dir_vars = dict(
        re.findall(r'^(\w*lock_dir)\s*:\s*["\'](.+?)["\']\s*$', text, re.MULTILINE)
    )
    # The lock-path assignment we actually compare on.
    m = re.search(
        r'^\w*(?:reconcile_lock_path|lock_path)\s*:\s*["\'](.+?)["\']\s*$',
        text,
        re.MULTILINE,
    )
    if not m:
        return None
    value = m.group(1)
    # Inline a one-level `{{ some_lock_dir }}` reference if present.
    for var_name, var_value in dir_vars.items():
        value = value.replace("{{ " + var_name + " }}", var_value)
        value = value.replace("{{" + var_name + "}}", var_value)
    return value


def check_l_reconcile_safety(errors):
    """Check L: the reconcile SAFETY CONTRACT is intact.

    Four interlocking guarantees keep the reconcile watchdog from corrupting
    a backup and keep the stack alive across a daemon restart:

      1. The reconcile script (stack_reconcile.sh.j2) STANDS DOWN while a
         maintenance lock is present — it tests `[ -f "$LOCK" ]` and exits.
         Without this, the watchdog would `docker start` the very containers
         gitea_dump.sh intentionally stopped, racing the dump and producing
         an inconsistent/corrupt backup.
      2. gitea_dump.sh.j2 WRITES that lock and RELEASES it via a trap (so the
         lock is cleared on EVERY exit path, even a crash — otherwise a
         failed dump would wedge reconcile off forever).
      3. container_manager_config sets `cm_config_live_restore: true` — the
         daemon-restart *prevention* half of the design.
      4. LOCK-PATH AGREEMENT: the two lock-path defaults — one in
         stack_reconcile, one in gitea_backup — are a SINGLE SOURCE OF TRUTH
         and must reduce to the SAME path. They are spelled differently
         (stack_reconcile factors a `lock_dir` intermediate var; gitea_backup
         writes it contiguously), so we resolve the indirection and compare
         the effective values. A one-sided edit that moves either lock path
         must trip this check — otherwise the backup writes one file while
         the watchdog watches another, and the stand-down silently breaks.
    """
    # --- 1. reconcile script stands down on the maintenance lock ----------
    try:
        with open(STACK_RECONCILE_SCRIPT) as fh:
            script = fh.read()
    except FileNotFoundError:
        errors.append(f"{STACK_RECONCILE_SCRIPT}: File not found")
        script = ""
    if script and '-f "$LOCK"' not in script:
        errors.append(
            f"{STACK_RECONCILE_SCRIPT}: missing the maintenance-lock stand-down "
            f"branch (`[ -f \"$LOCK\" ]`); without it the watchdog would revive "
            f"the containers gitea_dump.sh intentionally stopped and race the "
            f"backup, corrupting the dump."
        )

    # --- 2. backup writes the lock AND releases it via a trap -------------
    try:
        with open(GITEA_DUMP_SCRIPT) as fh:
            dump = fh.read()
    except FileNotFoundError:
        errors.append(f"{GITEA_DUMP_SCRIPT}: File not found")
        dump = ""
    if dump:
        if "RECONCILE_LOCK" not in dump:
            errors.append(
                f"{GITEA_DUMP_SCRIPT}: does not reference RECONCILE_LOCK; the "
                f"backup must hold the maintenance lock while it stops the stack "
                f"so reconcile stands down and never races the dump."
            )
        if "trap " not in dump:
            errors.append(
                f"{GITEA_DUMP_SCRIPT}: has no `trap ... EXIT` to release the "
                f"maintenance lock; without a trap a failed dump would leave the "
                f"lock in place and wedge reconcile off forever."
            )

    # --- 3. live-restore is enabled (daemon-restart prevention) -----------
    try:
        with open(CM_CONFIG_DEFAULTS) as fh:
            cm = fh.read()
    except FileNotFoundError:
        errors.append(f"{CM_CONFIG_DEFAULTS}: File not found")
        cm = ""
    if cm and not re.search(r'^cm_config_live_restore:\s*true\b', cm, re.MULTILINE):
        errors.append(
            f"{CM_CONFIG_DEFAULTS}: cm_config_live_restore is not set to true; "
            f"docker live-restore is the daemon-restart *prevention* half of the "
            f"design (keep containers running across a dockerd restart)."
        )

    # --- 4. lock-path agreement (the single source of truth) --------------
    try:
        with open(STACK_RECONCILE_DEFAULTS) as fh:
            sr_defaults = fh.read()
    except FileNotFoundError:
        errors.append(f"{STACK_RECONCILE_DEFAULTS}: File not found")
        sr_defaults = ""
    try:
        with open(GITEA_BACKUP_DEFAULTS) as fh:
            gb_defaults = fh.read()
    except FileNotFoundError:
        errors.append(f"{GITEA_BACKUP_DEFAULTS}: File not found")
        gb_defaults = ""

    sr_path = _effective_reconcile_lock_path(sr_defaults) if sr_defaults else None
    gb_path = _effective_reconcile_lock_path(gb_defaults) if gb_defaults else None

    if sr_defaults and sr_path is None:
        errors.append(
            f"{STACK_RECONCILE_DEFAULTS}: could not find a reconcile lock-path "
            f"default (stack_reconcile_lock_path); the lock path is the single "
            f"source of truth shared with gitea_backup and must be present."
        )
    if gb_defaults and gb_path is None:
        errors.append(
            f"{GITEA_BACKUP_DEFAULTS}: could not find a reconcile lock-path "
            f"default (gitea_backup_reconcile_lock_path); the lock path is the "
            f"single source of truth shared with stack_reconcile and must be "
            f"present."
        )

    if sr_path is not None and gb_path is not None:
        # (a) each effective path must end in the stable, host-neutral suffix.
        for path_label, eff in (
            (STACK_RECONCILE_DEFAULTS, sr_path),
            (GITEA_BACKUP_DEFAULTS, gb_path),
        ):
            if not eff.endswith(RECONCILE_LOCK_SUFFIX):
                errors.append(
                    f"{path_label}: effective reconcile lock path {eff!r} does "
                    f"not end in the stable suffix {RECONCILE_LOCK_SUFFIX!r}; the "
                    f"two lock paths (stack_reconcile + gitea_backup) are a "
                    f"SINGLE SOURCE OF TRUTH — a one-sided move that changes "
                    f"this suffix must trip this check, because the watchdog and "
                    f"the backup would then point at different files and the "
                    f"maintenance-lock stand-down would silently break."
                )
        # (b) the two reduced paths must be byte-identical.
        if sr_path != gb_path:
            errors.append(
                f"reconcile lock-path MISMATCH: stack_reconcile resolves to "
                f"{sr_path!r} but gitea_backup resolves to {gb_path!r}. These "
                f"two defaults are a single source of truth and MUST agree "
                f"byte-for-byte — if they diverge, gitea_dump.sh writes one "
                f"lock file while the watchdog watches another, so reconcile no "
                f"longer stands down during a backup and races the dump. Move "
                f"BOTH together (they default to "
                f"'{{{{ gitea_data_path }}}}{RECONCILE_LOCK_SUFFIX}'), never one."
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

    # Run check H: gitea_runner must stay host-agnostic + socket-mounted
    # (runner-on-a-generic-host rearchitecture lock-in)
    check_h_gitea_runner_socket_mount(errors)

    # Run check J: runner image must pip-install the Docker SDK (Play 2
    # runs community.docker locally in this image)
    check_j_dockerfile_docker_sdk(errors)

    # Run check K: stack_reconcile watchdog container is correctly defined
    # (restart=always + docker.sock + json-file + runs the reconcile script)
    check_k_stack_reconcile(errors)

    # Run check L: the reconcile safety contract is intact (lock stand-down,
    # trap-released backup lock, live-restore, and lock-path single-source)
    check_l_reconcile_safety(errors)

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
