#!/usr/bin/python3
import argparse
import pathlib
import re
import sys

VERSION = re.compile(r"^\d{8}-\d{4}$")
HEADING = re.compile(r"^## \[(.+?)\]")
LINK = re.compile(r"^\[[^\]]+\]: \S+$")


def check_version(version):
    if not VERSION.match(version):
        raise ValueError(f"{version} is not YYYYMMDD-HHMM")


def split(text):
    lines = text.rstrip("\n").split("\n")
    while lines and LINK.match(lines[-1]):
        lines.pop()
    sections = {}
    order = []
    head = []
    current = None
    for line in lines:
        match = HEADING.match(line)
        if match:
            current = match.group(1)
            order.append(current)
            sections[current] = []
        elif current is None:
            head.append(line)
        else:
            sections[current].append(line)
    body = {name: "\n".join(content).strip() for name, content in sections.items()}
    return "\n".join(head).rstrip(), order, body


def has_entries(body):
    return any(line.startswith("- ") for line in body.split("\n"))


def has_unreleased(text):
    _, _, body = split(text)
    return has_entries(body.get("Unreleased", ""))


def links(repo, versions):
    base = f"https://github.com/{repo}"
    if not versions:
        return [f"[Unreleased]: {base}/commits/main"]
    lines = [f"[Unreleased]: {base}/compare/{versions[0]}...HEAD"]
    for index, version in enumerate(versions):
        if index + 1 < len(versions):
            lines.append(f"[{version}]: {base}/compare/{versions[index + 1]}...{version}")
        else:
            lines.append(f"[{version}]: {base}/releases/tag/{version}")
    return lines


def release(text, version, repo):
    check_version(version)
    head, order, body = split(text)
    if version in order:
        raise ValueError(f"{version} already released")
    if not has_entries(body.get("Unreleased", "")):
        raise ValueError("nothing under [Unreleased]")
    released = [name for name in order if name != "Unreleased"]
    date = f"{version[:4]}-{version[4:6]}-{version[6:8]}"
    parts = [head, "## [Unreleased]", f"## [{version}] - {date}\n\n{body['Unreleased']}"]
    for name in released:
        heading = next(
            line for line in text.split("\n") if line.startswith(f"## [{name}]")
        )
        parts.append(f"{heading}\n\n{body[name]}" if body[name] else heading)
    return "\n\n".join(parts) + "\n\n" + "\n".join(links(repo, [version] + released)) + "\n"


def notes(text, version):
    check_version(version)
    _, order, body = split(text)
    if version not in order:
        raise ValueError(f"{version} not found")
    return body[version]


def main(argv):
    parser = argparse.ArgumentParser()
    commands = parser.add_subparsers(dest="command", required=True)
    for name in ("release", "notes", "check-unreleased"):
        command = commands.add_parser(name)
        if name != "check-unreleased":
            command.add_argument("version")
        if name == "release":
            command.add_argument("--repo", required=True)
        command.add_argument("--file", default="CHANGELOG.md")
    args = parser.parse_args(argv)
    path = pathlib.Path(args.file)
    text = path.read_text()
    try:
        if args.command == "release":
            path.write_text(release(text, args.version, args.repo))
        elif args.command == "notes":
            print(notes(text, args.version))
        elif not has_unreleased(text):
            raise ValueError("nothing under [Unreleased]")
    except ValueError as error:
        print(f"changelog: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
