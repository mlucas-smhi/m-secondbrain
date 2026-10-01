"""Run inside the pinned MCP image with --network none; no API/DB calls.

Use a disposable source copy so this does not change the running image/runtime.
"""
import json
import os
from pathlib import Path
import shutil
import sys
import tempfile

DOMAIN = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(DOMAIN))
from compile_ontology import CATALOG, install, validate

with tempfile.TemporaryDirectory(prefix="ea-ontology-") as directory:
    root = Path(directory)
    upstream = Path("/opt/graphiti/mcp_server")
    shutil.copytree(upstream / "src", root / "src")
    shutil.copytree(upstream / "config", root / "config")
    catalog = validate(json.loads(CATALOG.read_text()))
    install(root, catalog)
    os.environ["CONFIG_PATH"] = str(root / "config/ea-config.json")
    os.environ["OPENAI_API_KEY"] = "synthetic-no-network"
    sys.path.insert(0, str(root / "src"))
    from config.schema import GraphitiConfig
    from utils.type_config import build_entity_types, build_edge_types, build_edge_type_map
    config = GraphitiConfig()
    entities = build_entity_types(config.graphiti.entity_types)
    edges = build_edge_types(config.graphiti.edge_types)
    mapping = build_edge_type_map(config.graphiti.edge_type_map)
    assert set(entities) == set(catalog["entity_types"])
    assert set(edges) == set(catalog["edge_types"])
    assert {"PartnerOf", "ParentOf", "ReportsTo"} <= set(mapping[("Person", "Person")])
    for name, model in {**entities, **edges}.items():
        definition = catalog["entity_types"].get(name, catalog["edge_types"].get(name))
        assert model.__doc__ == definition["description"], name
        assert set(model.model_fields) == set(definition["fields"]), name
        assert all(value is None for value in model().model_dump().values()), name
        model.model_json_schema()
    assert entities["Person"](aliases=["Cedar"]).aliases == ["Cedar"]
    assert edges["WorksFor"](role="CEO").role == "CEO"
    assert edges["PartnerOf"](anniversary_date="May 12, year unspecified").anniversary_date
    assert config.server.transport == "http"
    assert config.database.provider == "falkordb"
    print(f"PASS: native loader, {len(entities)} rich entity models, {len(edges)} rich edge models, endpoint maps; no network")
