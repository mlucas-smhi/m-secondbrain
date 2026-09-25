"""Reviewed, deterministic Git baseline -> native LiteGraph entities/edges.

No extraction model, network access, credentials, or worktree knowledge reads.
This mapping deliberately pins a reviewed commit. A new commit needs a new
review; it must not silently import new instructions or turn examples into facts.
"""
from __future__ import annotations

import hashlib
import json
from pathlib import Path
import re
import uuid

from .memory_seed import git, inventory

REVISION = "5849d29e38af4514d2b3b489076639db82dd594b"
SCHEMA = "eleven-native-memory.v1"
MAPPING_VERSION = "github-baseline-2026-09-25.v1"


def build(repo: Path, tenant: str, graph: str, workspace: str, owner: str) -> dict:
    for value in (tenant, graph, workspace):
        uuid.UUID(value)
    if not owner:
        raise ValueError("owner_required")
    manifest = inventory(repo, REVISION)
    sources = {s["path"]: s for s in manifest["records"]}
    contents = {p: git(repo, "cat-file", "blob", s["source_blob"]).decode()
                for p, s in sources.items()}
    entities, edges, used = {}, [], set()
    scope = {"workspace_id": workspace, "owner_ref": owner,
             "compartment": "owner_private", "disclosure": "private_owner_context",
             "schema_version": SCHEMA, "import_version": MAPPING_VERSION}

    def stable(kind, key):
        return str(uuid.uuid5(uuid.UUID(graph), MAPPING_VERSION + ":" + kind + ":" + key))

    def entity(key, name, family, aliases=()):
        if key in entities:
            raise ValueError("duplicate_entity_key:" + key)
        entities[key] = {"GUID": stable("entity", key), "TenantGUID": tenant,
                         "GraphGUID": graph, "Name": name, "Labels": ["Entity", family],
                         "Data": {**scope, "kind": "Entity", "entity_key": key,
                                  "family": family, "canonical_name": name,
                                  "aliases": list(aliases), "facts": []}}
        return key

    def evidence(path, quote):
        if not quote or quote not in contents[path]:
            raise ValueError("unmatched_source_excerpt:" + path)
        used.add(path)
        source = sources[path]
        dates = re.findall(r"(?m)^(?:updated|last_reviewed|created):\s*(\d{4}-\d{2}-\d{2})\s*$", contents[path])
        return {"source_ref": source["source_ref"], "source_path": path,
                "source_blob": source["source_blob"], "source_sha256": source["content_sha256"],
                "excerpt": quote, "source_recorded_date": max(dates) if dates else None,
                "valid_from": None, "valid_until": None,
                "attribution": "committed_github_baseline_not_live_verification"}

    def fact(key, path, quote, *, content=None, temporal="source_snapshot"):
        proof = evidence(path, quote)
        text = content or quote
        record = {"id": stable("fact", key + ":" + path + ":" + quote + ":" + text),
                  "content": text, "temporal_context": temporal, **proof}
        if record not in entities[key]["Data"]["facts"]:
            entities[key]["Data"]["facts"].append(record)

    def excerpt(path, start, end=None):
        text = contents[path]
        if text.count(start) != 1 or (end and end not in text[text.index(start) + len(start):]):
            raise ValueError("ambiguous_section:" + path + ":" + start)
        return text[text.index(start):].split(end, 1)[0].strip() if end else text[text.index(start):].strip()

    def sections(key, path, start, end=None, temporal="source_snapshot"):
        selected = excerpt(path, start, end)
        # Each reviewed leaf section retains its heading/labels and exact prose.
        headings = []
        for block in re.split(r"(?m)(?=^#{1,6} )", selected):
            block = block.strip()
            heading = re.match(r"^(#{1,6})\s+([^\n]+)", block)
            if heading:
                level = len(heading[1])
                headings = [(n, title) for n, title in headings if n < level]
                headings.append((level, heading[2]))
            if not block or not re.sub(r"(?m)^#{1,6}[^\n]*$", "", block).strip("\n -"):
                continue
            context = " > ".join(title for _, title in headings)
            fact(key, path, block, content=context + "\n" + block, temporal=temporal)

    def relation(subject, predicate, target, path, quote):
        proof = evidence(path, quote)
        edge_key = ":".join((subject, predicate, target))
        if any(e["GUID"] == stable("edge", edge_key) for e in edges):
            raise ValueError("duplicate_relationship:" + edge_key)
        edges.append({"GUID": stable("edge", edge_key), "TenantGUID": tenant,
                      "GraphGUID": graph, "From": entities[subject]["GUID"],
                      "To": entities[target]["GUID"], "Name": predicate, "Labels": [predicate],
                      "Data": {**scope, "kind": "Relationship", "predicate": predicate,
                               "subject_name": entities[subject]["Name"],
                               "object_name": entities[target]["Name"],
                               "temporal_context": "source_snapshot", **proof}})

    entity("m", "Michael Lucas", "person", ["M", "Michael"])
    people = [
        ("andrew-everett", "Andrew Everett", ["Andrew"]),
        ("charlotte-lucas", "Charlotte Lucas", ["Charlie", "Charlotte"]),
        ("curtis-miller", "Curtis Miller", ["Curtis"]),
        ("jennifer-lucas", "Jennifer Lucas", ["Mom", "Jeniffer Lucas"]),
        ("jesus-llorca", "Jesus Llorca", ["Jesus"]),
        ("john-gellert", "John Gellert", ["John"]),
        ("pharr-andrews", "Pharr Andrews", ["Pharr"]),
        ("river-lucas", "River Lucas", ["River"]),
    ]
    for key, name, aliases in people:
        entity(key, name, "person", aliases)
        path = "people/" + key + ".md"
        if key == "curtis-miller":
            fact(key, path, excerpt(path, "Relationship", "Referenced Decisions"))
            fact(key, path, "Frequently involved in strategic discussions.")
        elif key in ("charlotte-lucas", "river-lucas"):
            sections(key, path, "## Current Stage", "## Related Projects")
        elif key == "pharr-andrews":
            sections(key, path, "## Relationship", "## Context")
            sections(key, path, "## Associated Projects", "## Notes")
            sections(key, path, "# Future Locations", temporal="research_candidates_not_commitments")
        else:
            sections(key, path, "## Relationship", "## Retrieval Guidance")
    for key in ("biggie", "watts"):
        entity(key, key.title(), "animal")
        sections(key, "pets/" + key + ".md", "## Relationship", "## Retrieval Guidance")

    myself = "reference/myself.md"
    sections("m", myself, "## Identity", "## Current Objectives")
    sections("m", myself, "## Communication Style", "## Active Themes")
    sections("m", myself, "# Future Locations", temporal="research_candidates_not_commitments")
    preferences = "reference/preferences.md"
    for start, end in [
        ("Michael prefers communication that is:", "Alfred should lead"),
        ("Michael tends to prefer:", "When proposing an architecture:"),
        ("Michael prefers recommendations that include:", "Do not present"),
        ("Michael prefers knowledge systems that are:", "Michael prefers:\n"),
    ]:
        fact("m", preferences, excerpt(preferences, start, end))
    fact("m", preferences, "Michael prefers iterative co-design.")
    # These are preference descriptions, not imported executable instructions.
    fact("m", preferences, excerpt(preferences, "## Response Depth", "## Problem-Solving Style"),
         content="Communication preference: concise direct answers for straightforward questions; deeper, layered discussion with risks and tradeoffs for architecture/design.")
    fact("m", preferences, excerpt(preferences, "## Technical Presentation", "## Decision Support"),
         content="Technical presentation preferences: Markdown, folder trees, data-flow/Mermaid diagrams, JSON, YAML, contracts and concrete examples; simple deterministic formatting.")
    fact("m", preferences, excerpt(preferences, "## Prompt-Design Preferences", "## Collaboration Style"),
         content="Prompt-design preference: separate responsibilities; explicit definitions, constraints, examples and output contracts; avoid unsupported inference. The August baseline used Bootstrap, Classifier and Writer roles.",
         temporal="historical_design_context")

    relationships = "reference/relationships.md"
    sections("jennifer-lucas", relationships, "## Jeniffer Lucas", "Add only relationships")
    for key, title in [("curtis-miller", "Curtis Miller"), ("jesus-llorca", "Jesus Llorca"),
                       ("john-gellert", "John Gellert"), ("andrew-everett", "Andrew Everett")]:
        fact(key, relationships, excerpt(relationships, "## " + title, "\n--"))
    entity("george-self", "George Self", "person", ["George"])
    fact("george-self", relationships, excerpt(relationships, "## George Self", "\n---"))
    fact("biggie", relationships, "Named after the Notorious B.I.G, Biggie Smalls")

    work = "reference/workorg.md"
    entity("seacor", "SEACOR Marine", "organization", ["SEACOR"])
    fact("seacor", relationships, "Indirect manager, CEO of SEACOR Marine")
    entity("cso-team", "SEACOR CSO team", "organization")
    fact("cso-team", work, "Jesus Llorca is a core member of the CSO team.")
    for key, name in [("ross-guidry", "Ross Guidry"), ("taiwo-akobi", "Taiwo Akobi"),
                      ("daniel-ratoff", "Daniel Ratoff"), ("mike-puentes", "Mike Puentes"),
                      ("dustin-donbush", "Dustin Donbush"), ("dillon-mcvicar", "Dillon McVicar")]:
        entity(key, name, "person")
        fact(key, work, excerpt(work, "Frequently relevant team members include:", "Create or retrieve"),
             content=name + " is listed among Michael's frequently relevant team members. No project attendance or role beyond that is established.")
        relation("m", "team_context", key, work, name)
    for key, name in [("jacob-charpentier", "Jacob Charpentier"), ("emma-haywood", "Emma Haywood"), ("dheeraj-korivi", "Dheeraj Korivi")]:
        entity(key, name, "person")
        fact(key, work, excerpt(work, "Michael frequently works with or discusses work involving:", "This list provides"),
             content=name + " is listed as someone Michael frequently works with or discusses work involving.")
        relation("m", "work_context", key, work, name)
    sections("m", work, "## Common Work Themes", "## Retrieval Guidance")

    for key, name, proof in [("kaleek", "Kaleek", "Has 2 adult children, Kaleek, and Kaymen"),
                             ("kaymen", "Kaymen", "Has 2 adult children, Kaleek, and Kaymen"),
                             ("jojo", "JoJo", "Her mother, JoJo, lives in Austin")]:
        entity(key, name, "person")
        fact(key, "people/pharr-andrews.md", proof)
    entity("keith-lucas", "Keith Lucas", "person")
    fact("keith-lucas", relationships, "Still married to Keith Lucas",
         content="Jennifer Lucas is recorded as still married to Keith Lucas.")

    entity("alfred", "Alfred Memory System", "project", ["Alfred"])
    sections("alfred", "projects/alfred-memory-system.md", "## Objective", temporal="historical_design_context_2026-08-27")
    entity("obsidian-poc", "Obsidian POC", "project")
    active = "reference/active-projects.md"
    fact("obsidian-poc", active, excerpt(active, "### Obsidian POC", "## Current Workstream"), temporal="historical_design_context_2026-08-27")
    fact("alfred", active, excerpt(active, "### Alfred Memory System", "## Supporting Project"), temporal="historical_design_context_2026-08-27")
    narrative = "reference/current-narrative.md"
    fact("alfred", narrative, excerpt(narrative, "Michael is actively designing", "The current direction is:"), temporal="historical_design_context_2026-08-27")
    fact("alfred", myself, excerpt(myself, "## Current Objectives", "## Communication Style"), temporal="historical_design_context_2026-08-27")
    # Decisions are historical documents, never live Turn Engine approvals.
    for key, path, name in [
        ("git-decision", "decisions/2026-08-27-Git-As-Canonical-Brain.md", "Git as Canonical Brain — historical decision"),
        ("entity-decision", "decisions/2026-09-22-Entity-Foundation-And-Turn-Engine-Ownership.md", "Entity foundation and Turn Engine ownership — design decision"),
    ]:
        entity(key, name, "document")
        fact(key, path, excerpt(path, "## Decision", "## Reasoning"),
             temporal="historical_design_decision_not_runtime_instruction_or_execution")
    fact("git-decision", "decisions/2026-08-27-Git-As-Canonical-Brain.md", "Pending long-term validation.", temporal="historical_design_context")
    fact("entity-decision", "decisions/2026-09-22-Entity-Foundation-And-Turn-Engine-Ownership.md",
         excerpt("decisions/2026-09-22-Entity-Foundation-And-Turn-Engine-Ownership.md", "## Boundaries", "## Validation"), temporal="historical_design_context")

    travel = "projects/travel/pharr-birthday-latin-america-2026.md"
    entity("birthday-tour", "Latin America & Caribbean Scouting Tour 2026", "project",
           ["Pharr birthday trip", "Colombia trip", "Latin-America-Caribbean-Scouting-Tour-2026"])
    sections("birthday-tour", travel, "## Status", "# Outcomes", temporal="planned_or_hypothesized_not_booked_not_completed")
    # The source's 'Jennifer Pharr' wording is retained verbatim in its purpose,
    # not merged into Jennifer Lucas or asserted as a new legal name.
    entities["birthday-tour"]["Data"]["interpretation_notes"] = [
        "Planned itinerary, not evidence of reservations or actual travel.",
        "Purpose says 'Jennifer Pharr'; participant link is Pharr Andrews. Do not merge with Jennifer Lucas."]

    for key, name, aliases in [("houston", "Houston, Texas", ["Houston", "Houston, TX"]),
        ("nyc", "New York City", ["NYC"]), ("utah", "Utah", ["UT"]),
        ("michigan", "Michigan", []), ("austin", "Austin", []),
        ("medellin", "Medellín", ["Medellin"]), ("cartagena", "Cartagena", []),
        ("st-maarten", "St. Maarten", []), ("anguilla", "Anguilla", []), ("st-barts", "St. Barts", [])]:
        entity(key, name, "place", aliases)
    for key, name in [("skiing", "Skiing"), ("gadgets", "Technology and gadgets"),
                      ("ai", "Artificial Intelligence"), ("ferris-wheels", "Ferris wheels")]:
        entity(key, name, "interest_or_topic")

    relation("m", "partner_of", "pharr-andrews", relationships, "Pharr Andrews\n\nRelationship:\nLong-term partner.\nGirlfriend.")
    relation("jennifer-lucas", "mother_of", "m", "people/jennifer-lucas.md", "Mother of Michael Lucas")
    relation("jennifer-lucas", "married_to", "keith-lucas", relationships, "Still married to Keith Lucas")
    relation("pharr-andrews", "parent_of", "kaleek", "people/pharr-andrews.md", "Has 2 adult children, Kaleek, and Kaymen")
    relation("pharr-andrews", "parent_of", "kaymen", "people/pharr-andrews.md", "Has 2 adult children, Kaleek, and Kaymen")
    relation("jojo", "mother_of", "pharr-andrews", "people/pharr-andrews.md", "Her mother, JoJo, lives in Austin")
    relation("jojo", "lives_in", "austin", "people/pharr-andrews.md", "Her mother, JoJo, lives in Austin")
    relation("pharr-andrews", "owns_pet", "biggie", "pets/biggie.md", "Pug owned by Pharr")
    relation("m", "has_pet", "watts", relationships, "## Watts\n\nRelationship:\nDog")
    relation("m", "reports_to", "curtis-miller", work, "Curtis Miller is Michael's direct manager.")
    relation("curtis-miller", "reports_to", "jesus-llorca", work, "Jesus Llorca is Curtis Miller's manager.")
    relation("george-self", "reports_to", "curtis-miller", relationships, "Team member, Communications Manager, Curtis Miller direct report")
    for key, role, path, quote in [
        ("andrew-everett", "general_counsel_at", "people/andrew-everett.md", "General Counsel for SEACOR"),
        ("john-gellert", "ceo_at", "people/john-gellert.md", "CEO of SEACOR"),
        ("jesus-llorca", "cfo_at", "people/jesus-llorca.md", "CFO for SEACOR"),
    ]:
        relation(key, role, "seacor", path, quote)
    relation("jesus-llorca", "member_of", "cso-team", work, "Jesus Llorca is a core member of the CSO team.")
    relation("m", "based_in", "houston", myself, "Houston, TX")
    relation("andrew-everett", "lives_in", "nyc", "people/andrew-everett.md", "Lives in New York City")
    relation("jesus-llorca", "lives_in", "nyc", "people/jesus-llorca.md", "Lives in New York City")
    relation("jesus-llorca", "has_second_home_in", "michigan", "people/jesus-llorca.md", "Owns a second house in Michigan")
    relation("john-gellert", "lives_in", "utah", "people/john-gellert.md", "Lives in Utah")
    relation("george-self", "lives_in", "houston", relationships, "South Africa is his home country, lives in Houston, TX now.")
    relation("john-gellert", "enjoys", "skiing", "people/john-gellert.md", "Enjoys skiing")
    relation("andrew-everett", "enjoys", "gadgets", "people/andrew-everett.md", "Enjoys technology and gadgets")
    relation("andrew-everett", "interested_in", "ai", "people/andrew-everett.md", "AI evangelist")
    relation("pharr-andrews", "enjoys", "ferris-wheels", "people/pharr-andrews.md", "Likes Ferris Wheels")
    relation("m", "owns_project", "alfred", "projects/alfred-memory-system.md", "owner: Michael Lucas")
    relation("andrew-everett", "associated_with", "alfred", "projects/alfred-memory-system.md", "## Associated People\n\n- Michael Lucas\n- Andrew Everett")
    relation("obsidian-poc", "supports", "alfred", active, "The Obsidian POC is a supporting interface evaluation within the broader Alfred Memory System effort.")
    relation("alfred", "historical_decision_document", "git-decision", "projects/alfred-memory-system.md", "Git as canonical knowledge store")
    for key, quote in [("m", "[[Michael-Lucas]]"), ("pharr-andrews", "[[Pharr-Andrews]]")]:
        relation(key, "planned_participant_in", "birthday-tour", travel, quote)
    for key, quote in [("medellin", "Medellín"), ("cartagena", "Cartagena"), ("st-maarten", "St. Maarten"), ("anguilla", "Anguilla"), ("st-barts", "St. Barts")]:
        relation("birthday-tour", "planned_destination", key, travel, "Houston → Medellín → Cartagena → St. Maarten → Anguilla → St. Barts → Houston")

    # Every entity has factual evidence or a sourced incident edge. No naked
    # placeholder entities, guessed parents, or inferred project involvement.
    linked = {e[k] for e in edges for k in ("From", "To")}
    assert all(e["Data"]["facts"] or e["GUID"] in linked for e in entities.values())
    excluded = {"events/latina-america-tour.md": "Contains only 'test'; no factual memory."}
    assert used | set(excluded) == set(sources), "unreviewed_source"
    nodes = list(entities.values())
    canonical = json.dumps({"nodes": nodes, "edges": edges}, sort_keys=True, ensure_ascii=False)
    return {"source_revision": REVISION, "mapping_version": MAPPING_VERSION,
            "scope": {"tenant": tenant, "graph": graph, "workspace": workspace, "owner": owner},
            "digest": hashlib.sha256(canonical.encode()).hexdigest(),
            "nodes": nodes, "edges": edges, "included_sources": sorted(used),
            "excluded_sources": excluded,
            "counts": {"entities": len(nodes), "facts": sum(len(n["Data"]["facts"]) for n in nodes),
                       "relationships": len(edges), "sources": len(used)}}
