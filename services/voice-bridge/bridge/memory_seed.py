"""Read-only inventory of a committed Git knowledge baseline. Never writes a graph.

Run from the repository: python -m bridge.memory_seed --repo . --ref origin/main
Only metadata is printed; source content and credentials are never emitted.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import subprocess
from collections import Counter


FOLDERS = {
    "reference": "orientation",
    "people": "person",
    "pets": "animal",
    "projects": "project",
    "events": "event",
    "decisions": "historical_decision",
}


def source_kind(path: str) -> str | None:
    parts = PurePosixPath(path).parts
    if not parts or any(p.startswith(".") or p == ".." for p in parts):
        return None
    if PurePosixPath(path).suffix != ".md":
        return None
    return FOLDERS.get(parts[0])


def git(repo: Path, *args: str) -> bytes:
    return subprocess.run(
        ["git", "-C", str(repo), *args], check=True, capture_output=True
    ).stdout


def inventory(repo: Path, ref: str) -> dict:
    # Resolve once; all subsequent reads use the immutable commit, not the worktree.
    revision = git(repo, "rev-parse", "--verify", "--end-of-options", ref + "^{commit}").decode().strip()
    entries = git(repo, "ls-tree", "-rz", "--full-tree", revision).split(b"\0")
    records = []
    for entry in entries:
        if not entry:
            continue
        metadata, raw_path = entry.split(b"\t", 1)
        mode, object_type, blob = metadata.decode().split()
        path = raw_path.decode("utf-8")
        kind = source_kind(path)
        if kind is None:
            continue
        # Never follow symlinks, submodules, or filesystem paths outside the tree.
        if object_type != "blob" or mode not in ("100644", "100755"):
            raise ValueError("nonregular_knowledge_source:" + path)
        content = git(repo, "cat-file", "blob", blob).decode("utf-8")
        warnings = []
        if kind == "orientation":
            warnings.append("resolve_overlap_with_canonical_entity_notes")
        if kind == "historical_decision":
            warnings.append("historical_context_not_current_operating_instructions")
        if re.search(r"(?im)^\s*(?:[-*]\s*)?(?:Decision [AB]|TBD|TODO)\s*$", content):
            warnings.append("contains_placeholder_text")
        if "[[" in content:
            warnings.append("resolve_wikilinks_before_creating_relationships")
        if re.search(r"(?im)^#{1,6}\s+(?:Guidance|Retrieval Guidance|Examples|Instructions)\b", content):
            warnings.append("separate_authoring_guidance_from_facts")
        records.append({
            "path": path, "source_ref": "git:" + revision + ":" + path,
            "kind": kind, "source_blob": blob,
            "content_sha256": hashlib.sha256(content.encode()).hexdigest(),
            "sensitivity_level": 3, "compartment": "owner_private",
            "warnings": warnings,
        })
    return {
        "status": "preview_only", "source_revision": revision,
        "record_count": len(records), "counts": dict(Counter(r["kind"] for r in records)),
        "records": records,
        "excluded": ["_system", "_templates", "security", "services", "supabase", "docs", "uncommitted_changes"],
        "activation_requires": [
            "recognized_owner_private_session_routing", "separate_tenant_credentials",
            "cross_tenant_negative_tests", "reviewed_entity_mapping",
        ],
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", type=Path, required=True)
    parser.add_argument("--ref", default="origin/main")
    args = parser.parse_args()
    print(json.dumps(inventory(args.repo, args.ref), indent=2))


if __name__ == "__main__":
    main()
