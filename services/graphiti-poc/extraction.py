"""Build native add_memory arguments; no network, queue or graph rewriting."""

import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent


def extraction_instructions():
    catalog = json.loads((ROOT / "ontology.json").read_text())
    return catalog["extraction_rules"] + "\n\n" + (ROOT / "extraction-guidance.txt").read_text()


def memory_arguments(*, name, episode_body, group_id, reference_time, source_description):
    """Caller supplies scope and source, never evaluation answers or a new UUID.

    This helper is for the isolated evaluation caller. It is not installed in
    the native server and does not enable global guidance on other writes.
    """
    return {
        "name": name,
        "episode_body": episode_body,
        "group_id": group_id,
        "source": "text",
        "source_description": source_description,
        "reference_time": reference_time,
        "custom_extraction_instructions": extraction_instructions(),
    }
