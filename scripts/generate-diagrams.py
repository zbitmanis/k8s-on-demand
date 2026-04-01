#!/usr/bin/env python3
"""
Generate SVG diagrams from PlantUML source files.

Finds all *.puml files under docs/diagrams/ and renders each to
docs/images/<name>.svg using the official PlantUML Docker image.

Usage:
    python3 scripts/generate-diagrams.py              # render all changed
    python3 scripts/generate-diagrams.py --all        # force re-render all
    python3 scripts/generate-diagrams.py --file docs/diagrams/foo.puml

Requirements:
    Docker running locally  (docker pull plantuml/plantuml is automatic)

Output:
    docs/images/<stem>.svg  for each docs/diagrams/<stem>.puml
"""

import argparse
import os
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
DIAGRAMS_DIR = REPO_ROOT / "docs" / "diagrams"
IMAGES_DIR = REPO_ROOT / "docs" / "images"
PLANTUML_IMAGE = "plantuml/plantuml:latest"


def docker_available() -> bool:
    try:
        subprocess.run(
            ["docker", "info"],
            check=True,
            capture_output=True,
        )
        return True
    except (subprocess.CalledProcessError, FileNotFoundError):
        return False


def render_puml(puml_path: Path, force: bool = False) -> bool:
    """Render a single .puml file to docs/images/<stem>.svg.

    Returns True if a new SVG was written, False if skipped.
    """
    svg_path = IMAGES_DIR / f"{puml_path.stem}.svg"

    if not force and svg_path.exists():
        puml_mtime = puml_path.stat().st_mtime
        svg_mtime = svg_path.stat().st_mtime
        if svg_mtime >= puml_mtime:
            print(f"  skip  {puml_path.name}  (SVG is up to date)")
            return False

    print(f"  render  {puml_path.name}  →  {svg_path.relative_to(REPO_ROOT)}")

    # Mount only the single .puml file; output goes to /output inside the container
    cmd = [
        "docker", "run", "--rm",
        "-v", f"{puml_path.parent}:/data:ro",
        "-v", f"{IMAGES_DIR}:/output",
        PLANTUML_IMAGE,
        "-tsvg",
        "-o", "/output",
        f"/data/{puml_path.name}",
    ]

    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        print(f"  ERROR: plantuml exited {result.returncode}", file=sys.stderr)
        print(result.stderr, file=sys.stderr)
        return False

    return True


def main():
    parser = argparse.ArgumentParser(description="Render PlantUML diagrams to SVG.")
    parser.add_argument("--all", action="store_true", help="Force re-render all diagrams.")
    parser.add_argument("--file", type=Path, help="Render a single .puml file.")
    args = parser.parse_args()

    if not docker_available():
        print("ERROR: Docker is not running. Start Docker Desktop and retry.", file=sys.stderr)
        sys.exit(1)

    IMAGES_DIR.mkdir(parents=True, exist_ok=True)

    if args.file:
        files = [args.file.resolve()]
    else:
        files = sorted(DIAGRAMS_DIR.glob("**/*.puml"))

    if not files:
        print("No .puml files found.")
        sys.exit(0)

    rendered = 0
    for puml_path in files:
        if render_puml(puml_path, force=args.all):
            rendered += 1

    total = len(files)
    skipped = total - rendered
    print(f"\nDone: {rendered} rendered, {skipped} skipped (up to date).")

    if rendered > 0:
        print("\nCommit the updated SVGs:")
        print("  git add docs/images/")
        print("  git commit -m 'docs: regenerate PlantUML diagrams'")


if __name__ == "__main__":
    main()
