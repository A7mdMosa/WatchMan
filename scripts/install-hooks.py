#!/usr/bin/env python3
"""Add (or remove) WatchMan's hooks in ~/.claude/settings.json.

Keeps every other hook and the file's key order, never escapes slashes,
and writes a dated backup first. Safe to run again: old WatchMan entries are replaced.

    install-hooks.py --hook /path/to/watchman-hook [--settings PATH] [--remove]
    install-hooks.py --hook /path/to/watchman-hook --statusline on|off [--settings PATH]

--statusline only touches the status line: "on" wraps your status line command so watchman-hook passes
Claude Code's status line data (plan usage, how full the context is) to WatchMan, then runs your command
and prints exactly what it prints; "off" puts your command back.
"""
import argparse
import datetime
import json
import os
import shlex
import shutil
import sys

EVENTS = {
    "SessionStart": 10, "SessionEnd": 10, "UserPromptSubmit": 10,
    "PreToolUse": 10, "PostToolUse": 10, "PostToolUseFailure": 10,
    "PermissionRequest": 600, "Notification": 10,
    "Stop": 10, "StopFailure": 10, "SubagentStart": 10, "SubagentStop": 10,
}
MARKER = "watchman-hook"


def is_watchman(hook):
    return MARKER in hook.get("command", "")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--hook", required=True, help="path to the watchman-hook binary")
    parser.add_argument("--settings", default=os.path.expanduser("~/.claude/settings.json"))
    parser.add_argument("--remove", action="store_true")
    parser.add_argument("--statusline", choices=["on", "off"])
    args = parser.parse_args()

    settings = {}
    if os.path.exists(args.settings):
        with open(args.settings) as f:
            settings = json.load(f)
        stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
        backup = f"{args.settings}.bak-watchman-{stamp}"
        shutil.copy2(args.settings, backup)
        print(f"backup: {backup}")

    if args.statusline:
        return status_line(settings, args)

    hooks = settings.setdefault("hooks", {})
    # Drop old WatchMan entries everywhere, keeping everything else as it was
    for event in list(hooks):
        groups = []
        for group in hooks[event]:
            kept = [h for h in group.get("hooks", []) if not is_watchman(h)]
            if kept:
                group["hooks"] = kept
                groups.append(group)
        if groups:
            hooks[event] = groups
        else:
            del hooks[event]

    if not args.remove:
        command = '"' + args.hook.replace('"', '\\"') + '"'
        for event, timeout in EVENTS.items():
            hooks.setdefault(event, []).append(
                {"hooks": [{"type": "command", "command": command, "timeout": timeout}]}
            )
    if not hooks:
        del settings["hooks"]

    os.makedirs(os.path.dirname(args.settings), exist_ok=True)
    tmp = args.settings + ".watchman-tmp"
    with open(tmp, "w") as f:
        json.dump(settings, f, indent=2, ensure_ascii=False)
        f.write("\n")
    os.replace(tmp, args.settings)
    print("removed" if args.remove else "installed")


def unwrapped(command):
    """Your own status line command, from WatchMan's wrapper (None when there wasn't one)."""
    if MARKER not in command or "--statusline" not in command:
        return command or None
    parts = shlex.split(command)
    return parts[2] if len(parts) > 2 else None


def status_line(settings, args):
    line = settings.get("statusLine") or {}
    original = unwrapped(line.get("command", ""))
    if args.statusline == "on":
        command = shlex.quote(args.hook) + " --statusline"
        if original:
            command += " " + shlex.quote(original)
        line = {**line, "type": "command", "command": command}
        settings["statusLine"] = line
    elif original:
        settings["statusLine"] = {**line, "command": original}
    else:
        settings.pop("statusLine", None)
    write(settings, args.settings)
    print("status line " + ("connected" if args.statusline == "on" else "restored"))


def write(settings, path):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".watchman-tmp"
    with open(tmp, "w") as f:
        json.dump(settings, f, indent=2, ensure_ascii=False)
        f.write("\n")
    os.replace(tmp, path)


if __name__ == "__main__":
    sys.exit(main())
