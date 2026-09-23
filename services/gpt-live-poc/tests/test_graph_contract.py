"""Deployment contract regression tests; no OpenAI or database calls."""
import os
import unittest
from unittest.mock import patch

from live_poc.app import Settings, memory_contract_instructions, realtime_call_payload


class GraphContractTests(unittest.TestCase):
    def settings(self, **extra):
        return Settings("synthetic", "synthetic", voice_api="realtime",
                        memory_schema_mode="entity-memory.v1",
                        mcp_server_url="https://memory.example/mcp", mcp_authorization="synthetic",
                        mcp_allowed_tools=("memory_search", "memory_get", "memory_store"), **extra)

    def test_graph_contract_replaces_legacy_save_instructions(self):
        payload = realtime_call_payload(self.settings(), {
            "status": "recognized", "actor_ref": "user:synthetic", "workspace_id": "workspace",
            "thread_id": "thread", "onboarding_state": "in_progress"}, "call-123")
        instructions = payload["instructions"]
        self.assertIn("Active memory tool contract: entity-memory.v1", instructions)
        self.assertIn("source_ref for memory writes: call-123", instructions)
        self.assertIn("source_session_ref for memory writes: call-123", instructions)
        self.assertIn("source_thread_ref for memory writes: thread", instructions)
        self.assertNotIn("Active memory tool contract: legacy", instructions)
        self.assertNotIn("Store one atomic fact per tool call", instructions)
        self.assertIn("memory_store", str(payload["tools"]))

    def test_unverified_graph_session_has_only_validation_tool(self):
        settings = self.settings(allowed_caller_number="+15550000001",
            onboarding_verify_url="https://example/verify", onboarding_api_key="synthetic",
            onboarding_invite_id="synthetic-invite")
        payload = realtime_call_payload(settings)
        self.assertEqual([t["name"] for t in payload["tools"]], ["validate_onboarding_code"])
        self.assertNotIn("Active memory tool contract: entity-memory.v1", payload["instructions"])

    def test_graph_context_requires_identity_and_source_references(self):
        context = {"status": "recognized", "actor_ref": "user:synthetic", "workspace_id": "workspace", "thread_id": "thread"}
        for missing in ("actor_ref", "workspace_id", "thread_id"):
            incomplete = {k: v for k, v in context.items() if k != missing}
            self.assertEqual(realtime_call_payload(self.settings(), incomplete, "call")["tools"], [])
        self.assertEqual(realtime_call_payload(self.settings(), context, "")["tools"], [])

    def test_graph_without_trusted_onboarding_context_withholds_mcp(self):
        self.assertFalse(realtime_call_payload(self.settings()).get("tools"))

    def test_legacy_default_is_unchanged(self):
        self.assertIn("Active memory tool contract: legacy", memory_contract_instructions(Settings("key", "secret")))

    def test_invalid_schema_mode_is_rejected(self):
        with patch.dict(os.environ, {"OPENAI_API_KEY": "synthetic", "OPENAI_WEBHOOK_SECRET": "synthetic",
                                    "MEMORY_SCHEMA_MODE": "typo"}, clear=True):
            with self.assertRaisesRegex(RuntimeError, "MEMORY_SCHEMA_MODE"):
                Settings.from_env()
