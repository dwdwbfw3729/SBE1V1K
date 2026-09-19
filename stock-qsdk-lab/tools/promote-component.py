#!/usr/bin/env python3
"""Copy freshly built bytes only when they match independent release locks."""
import argparse
import json
from pathlib import Path
from build_release import LAB, stage_plan, stage_artifacts

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("stage")
parser.add_argument("directory", type=Path)
args = parser.parse_args()
directory = args.directory.resolve().relative_to(LAB)
if args.stage == "dnsmasq-binary":
    item = json.loads((LAB / "sources/component-build-inputs.json").read_text())["dnsmasq"]
    stage = {"name": args.stage, "artifacts": {item["path"]: item["sha256"]}}
else:
    stage = next(s for s in stage_plan() if s["name"] == args.stage)
stage["artifact_directories"] = [str(directory)]
stage_artifacts(stage)
