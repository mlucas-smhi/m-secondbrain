"""Compile domain definitions into native MCP model registries at image build time.

No HTTP proxy, tool translation, live writes, or graphiti-core modifications.
Installation replaces the image's example model registries, not user memories.
"""
import argparse
from collections import defaultdict
import json
import keyword
from pathlib import Path
import re

CATALOG = Path(__file__).with_name("ontology.json")
TYPES = {"str", "int", "float", "bool", "list[str]"}
PROTECTED = {
    "uuid", "name", "group_id", "labels", "created_at", "summary", "attributes",
    "name_embedding", "source_node_uuid", "target_node_uuid", "fact", "fact_embedding",
    "episodes", "valid_at", "invalid_at", "expired_at", "reference_time",
}


def validate(catalog):
    entities, edges = catalog["entity_types"], catalog["edge_types"]
    if not entities or not edges:
        raise ValueError("Entity and edge definitions are required")
    for definitions in (entities, edges):
        for name, definition in definitions.items():
            if not re.fullmatch(r"[A-Z][A-Za-z0-9]*", name) or name == "Entity":
                raise ValueError(f"Invalid/reserved model name: {name}")
            if not definition.get("description", "").strip():
                raise ValueError(f"Missing description: {name}")
            for field, spec in definition["fields"].items():
                if (not re.fullmatch(r"[a-z][a-z0-9_]*", field)
                        or keyword.iskeyword(field) or field in PROTECTED
                        or field.startswith("model_")):
                    raise ValueError(f"Invalid/protected attribute: {name}.{field}")
                if len(spec) != 2 or spec[0] not in TYPES or not spec[1].strip():
                    raise ValueError(f"Invalid attribute definition: {name}.{field}")
    declared = set()
    for names in catalog["family_mapping"].values():
        if not set(names) <= entities.keys():
            raise ValueError("Unknown family mapping")
        declared.update(names)
    if declared | set(catalog["extensions"]) != entities.keys():
        raise ValueError("Every entity must have a family or explicit extension")
    if catalog["family_mapping"].get("fact") != []:
        raise ValueError("Facts use native assertions, not standalone Fact entities")
    for name, edge in edges.items():
        if not edge["pairs"] or len({tuple(p) for p in edge["pairs"]}) != len(edge["pairs"]):
            raise ValueError(f"Missing/duplicate pairs: {name}")
        for pair in edge["pairs"]:
            if len(pair) != 2 or any(t not in entities and t != "Entity" for t in pair):
                raise ValueError(f"Unknown endpoint type: {name}")
    return catalog


def edge_map(catalog):
    # Native builder overwrites repeated pair entries. Aggregate all predicates
    # for a pair so PartnerOf never displaces ParentOf or ReportsTo.
    pairs = defaultdict(list)
    for name, definition in catalog["edge_types"].items():
        for pair in definition["pairs"]:
            pairs[tuple(pair)].append(name)
    return [{"source": source, "target": target, "edge_types": names}
            for (source, target), names in sorted(pairs.items())]


def model_source(definitions, registry):
    lines = ['"""Generated domain models; edit ontology.json, not this file."""',
             "from pydantic import BaseModel, Field", ""]
    for name, definition in definitions.items():
        lines.extend([f"class {name}(BaseModel):", f"    {definition['description']!r}"])
        for field, (kind, description) in definition["fields"].items():
            lines.append(f"    {field}: {kind} | None = Field(default=None, description={description!r})")
        lines.append("")
    lines.append(registry + " = {" + ", ".join(f"{n!r}: {n}" for n in definitions) + "}\n")
    return "\n".join(lines)


def apply_config(base, catalog):
    import copy
    result = copy.deepcopy(base)
    graph = result.setdefault("graphiti", {})
    for key in ("entity_types", "edge_types"):
        graph[key] = [{"name": name, "description": item["description"]}
                      for name, item in catalog[key].items()]
    graph["edge_type_map"] = edge_map(catalog)
    return result


def install(root, catalog):
    # Called only during Docker build or against a disposable test directory.
    import yaml
    if not (root / "src/graphiti_mcp_server.py").is_file():
        raise ValueError("Expected native MCP source directory")
    base = yaml.safe_load((root / "config/config.yaml").read_text())
    for key, registry in (("entity_types", "ENTITY_TYPES"), ("edge_types", "EDGE_TYPES")):
        (root / f"src/models/{key}.py").write_text(model_source(catalog[key], registry))
    (root / "config/ea-config.json").write_text(json.dumps(apply_config(base, catalog), indent=2) + "\n")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--catalog", type=Path, default=CATALOG)
    parser.add_argument("--install", type=Path, help="MCP root in disposable build/test filesystem")
    args = parser.parse_args()
    data = validate(json.loads(args.catalog.read_text()))
    if args.install:
        install(args.install, data)
    print(f"{data['version']}: {len(data['entity_types'])} entity types, "
          f"{len(data['edge_types'])} relationship types, {len(edge_map(data))} endpoint pairs")
