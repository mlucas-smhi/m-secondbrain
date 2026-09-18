import json
import os
import sys
import unittest
from types import SimpleNamespace
from pathlib import Path
from unittest.mock import patch

from twilio.request_validator import RequestValidator


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from live_poc.app import (
    Settings,
    decode_github_content,
    execute_memory_call,
    event_type,
    function_call_from_event,
    incoming_session_id,
    incoming_event_matches_voice_api,
    inbound_twiml,
    live_session_payload,
    mcp_continuation_event,
    onboarding_response_instructions,
    onboarding_greeting_event,
    realtime_call_payload,
    realtime_function_call_from_event,
    validate_memory_path,
    twilio_dial_result,
    twilio_inbound,
)


class SettingsTests(unittest.TestCase):
    def test_requires_openai_secrets(self) -> None:
        with patch.dict(os.environ, {}, clear=True):
            with self.assertRaisesRegex(RuntimeError, "OPENAI_API_KEY"):
                Settings.from_env()

    def test_github_memory_requires_token(self) -> None:
        self.assertFalse(Settings("key", "secret").github_memory_enabled)
        self.assertTrue(Settings("key", "secret", github_token="token").github_memory_enabled)

    def test_realtime_mcp_requires_complete_configuration(self) -> None:
        partial = Settings("key", "secret", voice_api="realtime")
        self.assertFalse(partial.realtime_mcp_enabled)
        complete = Settings(
            "key",
            "secret",
            voice_api="realtime",
            mcp_server_url="https://memory.example.com/mcp",
            mcp_authorization="secret",
            mcp_allowed_tools=("memory/search",),
        )
        self.assertTrue(complete.realtime_mcp_enabled)

    def test_onboarding_requires_full_trusted_configuration(self) -> None:
        self.assertFalse(Settings("key", "secret").onboarding_enabled)
        configured = Settings(
            "key",
            "secret",
            voice_api="realtime",
            allowed_caller_number="+15550000001",
            onboarding_verify_url="https://example.supabase.co/verify",
            onboarding_api_key="onboarding-key",
            onboarding_invite_id="10000000-0000-4000-8000-000000000001",
        )
        self.assertTrue(configured.onboarding_enabled)


class MemoryBoundaryTests(unittest.TestCase):
    def test_allows_canonical_markdown_paths(self) -> None:
        self.assertEqual(validate_memory_path("people/michael.md"), "people/michael.md")
        self.assertEqual(validate_memory_path("/reference/travel.md"), "reference/travel.md")

    def test_rejects_sensitive_or_unsafe_paths(self) -> None:
        for path in (
            "_system/policy.md",
            "security/credentials.md",
            "people/../../.env",
            "people/michael.txt",
        ):
            with self.subTest(path=path):
                with self.assertRaisesRegex(ValueError, "memory_path_not_allowed"):
                    validate_memory_path(path)

    def test_decodes_github_base64_with_line_wrapping(self) -> None:
        self.assertEqual(decode_github_content("aGVs\nbG8=\n"), b"hello")

    def test_rejects_invalid_github_base64(self) -> None:
        with self.assertRaisesRegex(RuntimeError, "invalid_github_content"):
            decode_github_content("not-base64!")


class IncomingEventTests(unittest.TestCase):
    def test_reads_live_transport_event(self) -> None:
        event = {"type": "live.transport.incoming", "data": {"session_id": "live_123"}}
        self.assertEqual(event_type(event), "live.transport.incoming")
        self.assertEqual(incoming_session_id(event), "live_123")

    def test_tolerates_legacy_call_id(self) -> None:
        event = {"type": "live.call.incoming", "data": {"call_id": "call_123"}}
        self.assertEqual(incoming_session_id(event), "call_123")

    def test_realtime_mode_accepts_only_realtime_event(self) -> None:
        self.assertTrue(
            incoming_event_matches_voice_api("realtime.call.incoming", "realtime")
        )
        self.assertFalse(
            incoming_event_matches_voice_api("live.transport.incoming", "realtime")
        )

    def test_live_mode_accepts_live_events_only(self) -> None:
        self.assertTrue(incoming_event_matches_voice_api("live.transport.incoming", "live"))
        self.assertTrue(incoming_event_matches_voice_api("live.call.incoming", "live"))
        self.assertFalse(incoming_event_matches_voice_api("realtime.call.incoming", "live"))


class SessionPayloadTests(unittest.TestCase):
    def test_pins_requested_live_model_and_voice(self) -> None:
        payload = live_session_payload(Settings("key", "secret"))
        session = payload["session"]
        self.assertEqual(session["type"], "live")
        self.assertEqual(session["model"], "gpt-live-1")
        self.assertEqual(session["audio"]["output"]["voice"], "coral")
        self.assertIn("read-only", session["instructions"])

    def test_adds_only_read_memory_when_github_is_enabled(self) -> None:
        payload = live_session_payload(Settings("key", "secret", github_token="token"))
        instructions = payload["session"]["instructions"]
        responses = payload["session"]["delegation"]["responses"]
        self.assertIn("Delegation policy:", instructions)
        self.assertIn("reference/preferences.md", instructions)
        self.assertIn("reference/preferences.md", responses["instructions"])
        self.assertEqual(responses["tools"][0]["name"], "read_memory")
        self.assertFalse(responses["parallel_tool_calls"])

    def test_realtime_mcp_is_token_authenticated_and_read_only(self) -> None:
        settings = Settings(
            "key",
            "secret",
            voice_api="realtime",
            mcp_server_url="https://memory.example.com/mcp",
            mcp_authorization="secret",
            mcp_allowed_tools=("memory/search", "memory/get"),
        )
        payload = realtime_call_payload(settings)
        self.assertEqual(payload["type"], "realtime")
        self.assertIn("You are 2", payload["instructions"])
        self.assertIn("LiteGraph is the canonical", payload["instructions"])
        self.assertIn("slightly snooty edge", payload["instructions"])
        self.assertIn("proactively capture information", payload["instructions"])
        self.assertIn("If no write tool is available", payload["instructions"])
        self.assertNotIn("GitHub memory", payload["instructions"])
        tool = payload["tools"][0]
        self.assertEqual(tool["server_url"], "https://memory.example.com/mcp")
        self.assertTrue(tool["defer_loading"])
        self.assertEqual(tool["authorization"], "secret")
        self.assertEqual(
            tool["allowed_tools"],
            {"tool_names": ["memory/search", "memory/get"]},
        )
        self.assertEqual(tool["require_approval"], "never")

    def test_realtime_payload_omits_incomplete_mcp_configuration(self) -> None:
        payload = realtime_call_payload(Settings("key", "secret", voice_api="realtime"))
        self.assertNotIn("tools", payload)

    def test_onboarding_withholds_memory_until_backend_confirmation(self) -> None:
        settings = Settings(
            "key",
            "secret",
            voice_api="realtime",
            allowed_caller_number="+15550000001",
            mcp_server_url="https://memory.example.com/mcp",
            mcp_authorization="memory-token",
            mcp_allowed_tools=("memory_search", "memory_get"),
            onboarding_verify_url="https://example.supabase.co/verify",
            onboarding_api_key="onboarding-key",
            onboarding_invite_id="10000000-0000-4000-8000-000000000001",
        )
        payload = realtime_call_payload(settings)
        self.assertIn("First-Run Onboarding", payload["instructions"])
        self.assertIn("authentication_status: unverified", payload["instructions"])
        self.assertEqual([tool["name"] for tool in payload["tools"]], ["validate_onboarding_code"])
        self.assertNotIn("mcp", {tool["type"] for tool in payload["tools"]})


class SidebandToolTests(unittest.IsolatedAsyncioTestCase):
    def test_onboarding_greeting_speaks_first_and_disables_tools(self) -> None:
        event = onboarding_greeting_event()
        self.assertEqual(event["type"], "response.create")
        self.assertEqual(event["response"]["tool_choice"], "none")
        self.assertIn("Speak first", event["response"]["instructions"])
        self.assertIn("Hello, I'm 2", event["response"]["instructions"])

    def test_mcp_continuation_forces_a_spoken_answer_without_another_tool(self) -> None:
        event = mcp_continuation_event()
        self.assertEqual(event["type"], "response.create")
        self.assertEqual(event["response"]["tool_choice"], "none")
        self.assertIn("Immediately answer", event["response"]["instructions"])

    def test_extracts_completed_function_call(self) -> None:
        event = {
            "type": "response.event",
            "event": {
                "type": "response.output_item.done",
                "item": {
                    "type": "function_call",
                    "name": "read_memory",
                    "call_id": "call_123",
                    "arguments": '{"path":"people/michael.md"}',
                },
            },
        }
        self.assertEqual(function_call_from_event(event)["call_id"], "call_123")

    def test_extracts_realtime_onboarding_function_call(self) -> None:
        event = {
            "type": "response.function_call_arguments.done",
            "name": "validate_onboarding_code",
            "call_id": "call_validate_1",
            "arguments": '{"code":"123456"}',
        }
        self.assertEqual(
            realtime_function_call_from_event(event),
            {
                "name": "validate_onboarding_code",
                "call_id": "call_validate_1",
                "arguments": '{"code":"123456"}',
            },
        )

    def test_confirmed_onboarding_result_starts_topic_one(self) -> None:
        instructions = onboarding_response_instructions("confirmed")
        self.assertIn("Code confirmed", instructions)
        self.assertIn("begin topic 1", instructions)

    async def test_rejects_unknown_tool_without_calling_github(self) -> None:
        output = await execute_memory_call(
            Settings("key", "secret", github_token="token"),
            {"name": "write_memory", "call_id": "call_123", "arguments": "{}"},
        )
        self.assertEqual(json.loads(output), {"ok": False, "error": "tool_not_allowed"})


class TwilioCallbackTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self) -> None:
        self.settings = Settings(
            "key",
            "secret",
            twilio_auth_token="twilio-secret",
            allowed_caller_number="+15550000001",
            public_base_url="https://voice.example.com",
            openai_sip_uri="sip:proj_test@sip.api.openai.com;secure=true",
        )

    def test_routes_only_allowed_caller_to_openai_sip(self) -> None:
        twiml = inbound_twiml(self.settings, "+15550000001")
        self.assertIn("sip:proj_test@sip.api.openai.com;secure=true", twiml)
        self.assertIn("https://voice.example.com/twilio/dial-result", twiml)

    def test_rejects_other_callers_without_exposing_sip_uri(self) -> None:
        twiml = inbound_twiml(self.settings, "+15550000002")
        self.assertIn('<Reject reason="rejected"/>', twiml)
        self.assertNotIn("sip.api.openai.com", twiml)

    async def test_requires_valid_twilio_signature(self) -> None:
        form = {"From": "+15550000001", "To": "+15550000003"}
        url = "https://voice.example.com/twilio/inbound"
        signature = RequestValidator("twilio-secret").compute_signature(url, form)

        async def post() -> dict[str, str]:
            return form

        request = SimpleNamespace(
            app={"settings": self.settings},
            headers={"X-Twilio-Signature": signature},
            post=post,
        )
        response = await twilio_inbound(request)
        self.assertEqual(response.status, 200)
        self.assertIn("sip.api.openai.com", response.text)

        request.headers["X-Twilio-Signature"] = "invalid"
        response = await twilio_inbound(request)
        self.assertEqual(response.status, 403)

    async def test_returns_terminal_twiml_without_echoing_callback_data(self) -> None:
        async def post() -> dict[str, str]:
            return {"DialCallStatus": "failed", "DialSipResponseCode": "503"}

        response = await twilio_dial_result(SimpleNamespace(post=post))
        self.assertEqual(response.status, 200)
        self.assertIn("<Hangup/>", response.text)
        self.assertNotIn("503", response.text)


if __name__ == "__main__":
    unittest.main()
