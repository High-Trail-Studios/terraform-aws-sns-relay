import json
import os
import sys
import unittest
from unittest import mock

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "src"))

from relay import handler, transport  # noqa: E402
from relay.adapters.slack import MAX_TEXT, SlackAdapter  # noqa: E402
from relay.adapters.webhook import WebhookAdapter  # noqa: E402
from relay.alert import Alert  # noqa: E402
from relay.config import Config  # noqa: E402
from relay.secrets import MissingSecret, SecretStore  # noqa: E402

SLACK_ARN = "arn:aws:sns:us-east-1:111111111111:relay-ops-slack"
HOOK_ARN = "arn:aws:sns:us-east-1:111111111111:relay-hook"


class FakeSsm:
    class exceptions:
        class ParameterNotFound(Exception):
            pass

    def __init__(self, values):
        self.values = values
        self.calls = 0

    def get_parameter(self, Name, WithDecryption):
        self.calls += 1
        if Name not in self.values:
            raise self.exceptions.ParameterNotFound(Name)
        return {"Parameter": {"Value": self.values[Name]}}


def make_config(heartbeat=False):
    env = {
        "RELAY_ROUTES": json.dumps({
            SLACK_ARN: {"name": "ops-slack", "adapter": "slack"},
            HOOK_ARN: {"name": "hook", "adapter": "webhook", "auth_token": True,
                       "auth_header": "Authorization", "auth_scheme": "Bearer"},
        }),
        "RELAY_SSM_PREFIX": "/relay/",
        "RELAY_HEARTBEAT": "true" if heartbeat else "false",
    }
    return Config.from_env(env)


def make_secrets(**overrides):
    values = {
        "/relay/ops-slack/url": "https://hooks.slack.test/T/B/secret",
        "/relay/hook/url": "https://example.test/alerts",
        "/relay/hook/token": "tok123",
        "/relay/_heartbeat/url": "https://uptime.test/hb/abc",
    }
    values.update(overrides)
    return SecretStore(client=FakeSsm({k: v for k, v in values.items() if v is not None}))


def sns_event(topic_arn, message="disk full", subject="Disk", message_id="m-1"):
    return {"Records": [{
        "EventSource": "aws:sns",
        "Sns": {"TopicArn": topic_arn, "MessageId": message_id, "Message": message,
                "Subject": subject, "Timestamp": "2026-09-28T00:00:00Z",
                "MessageAttributes": {"env": {"Type": "String", "Value": "prod"}}},
    }]}


class HandlerTest(unittest.TestCase):
    def setUp(self):
        self.sent = []
        patcher = mock.patch.object(transport, "request", side_effect=self._record)
        patcher.start()
        self.addCleanup(patcher.stop)
        self.fail_urls = set()

    def _record(self, method, url, **kwargs):
        self.sent.append((method, url, kwargs))
        if url in self.fail_urls:
            raise transport.DeliveryError("boom")
        return 200

    def run_handler(self, event, config, secrets):
        with mock.patch.object(handler, "_deps", return_value=(config, secrets)):
            return handler.handler(event)

    def test_routes_by_topic_arn_to_slack(self):
        self.run_handler(sns_event(SLACK_ARN), make_config(), make_secrets())
        method, url, kwargs = self.sent[0]
        self.assertEqual((method, url), ("POST", "https://hooks.slack.test/T/B/secret"))
        self.assertEqual(json.loads(kwargs["body"]), {"text": "*Disk*\ndisk full"})
        self.assertNotIn("Authorization", kwargs["headers"])

    def test_webhook_sends_bearer_token_and_message_id(self):
        self.run_handler(sns_event(HOOK_ARN), make_config(), make_secrets())
        _, url, kwargs = self.sent[0]
        self.assertEqual(url, "https://example.test/alerts")
        self.assertEqual(kwargs["headers"]["Authorization"], "Bearer tok123")
        self.assertEqual(json.loads(kwargs["body"])["id"], "m-1")

    def test_unknown_topic_raises_so_event_reaches_dlq(self):
        with self.assertRaises(handler.UnknownTopic):
            self.run_handler(sns_event("arn:aws:sns:us-east-1:1:other"), make_config(), make_secrets())

    def test_delivery_failure_raises(self):
        self.fail_urls.add("https://example.test/alerts")
        with self.assertRaises(transport.DeliveryError):
            self.run_handler(sns_event(HOOK_ARN), make_config(), make_secrets())

    def test_missing_url_raises(self):
        with self.assertRaises(MissingSecret):
            self.run_handler(sns_event(SLACK_ARN), make_config(),
                             make_secrets(**{"/relay/ops-slack/url": None}))

    def test_heartbeat_pinged_after_delivery(self):
        self.run_handler(sns_event(SLACK_ARN), make_config(heartbeat=True), make_secrets())
        self.assertEqual(self.sent[-1][:2], ("GET", "https://uptime.test/hb/abc"))

    def test_heartbeat_failure_never_fails_delivered_alert(self):
        self.fail_urls.add("https://uptime.test/hb/abc")
        result = self.run_handler(sns_event(SLACK_ARN), make_config(heartbeat=True), make_secrets())
        self.assertEqual(result, {"relayed": 1})

    def test_no_heartbeat_when_disabled(self):
        self.run_handler(sns_event(SLACK_ARN), make_config(), make_secrets())
        self.assertEqual([s[0] for s in self.sent], ["POST"])

    def test_scheduled_heartbeat_checks_secrets_without_contacting_destinations(self):
        result = self.run_handler({"relay_heartbeat": True}, make_config(heartbeat=True), make_secrets())
        self.assertEqual(result, {"heartbeat": "sent"})
        self.assertEqual([s[:2] for s in self.sent], [("GET", "https://uptime.test/hb/abc")])

    def test_scheduled_heartbeat_withheld_when_a_route_is_misconfigured(self):
        result = self.run_handler({"relay_heartbeat": True}, make_config(heartbeat=True),
                                  make_secrets(**{"/relay/hook/token": None}))
        self.assertEqual(result, {"heartbeat": "withheld"})
        self.assertEqual(self.sent, [])


class AdapterTest(unittest.TestCase):
    def alert(self, message, subject=None):
        return Alert(topic_arn=SLACK_ARN, message_id="m", message=message, timestamp="t", subject=subject)

    def test_slack_formats_cloudwatch_alarm(self):
        msg = json.dumps({"AlarmName": "cpu<high>", "NewStateValue": "ALARM",
                          "NewStateReason": "Threshold crossed", "Region": "US East"})
        text = SlackAdapter().render(self.alert(msg))["text"]
        self.assertTrue(text.startswith(":red_circle: *cpu&lt;high&gt;* is ALARM"))
        self.assertIn("Threshold crossed", text)

    def test_slack_truncates_long_messages(self):
        text = SlackAdapter().render(self.alert("x" * 10000))["text"]
        self.assertLessEqual(len(text), MAX_TEXT)
        self.assertTrue(text.endswith("(truncated)"))

    def test_webhook_passes_attributes(self):
        record = sns_event(HOOK_ARN)["Records"][0]
        body = WebhookAdapter().render(Alert.from_sns_record(record))
        self.assertEqual(body["attributes"], {"env": "prod"})


class SecretStoreTest(unittest.TestCase):
    def test_caches_within_ttl_and_refreshes_after(self):
        now = [0.0]
        ssm = FakeSsm({"/a": "1"})
        store = SecretStore(client=ssm, ttl=300, clock=lambda: now[0])
        store.get("/a")
        store.get("/a")
        self.assertEqual(ssm.calls, 1)
        now[0] = 301
        store.get("/a")
        self.assertEqual(ssm.calls, 2)


class TransportTest(unittest.TestCase):
    def test_rejects_plain_http(self):
        with self.assertRaises(transport.DeliveryError):
            transport.request("POST", "http://example.test/x")

    def test_error_does_not_leak_url_path(self):
        try:
            transport.request("POST", "http://example.test/secret-token")
        except transport.DeliveryError as exc:
            self.assertNotIn("secret-token", str(exc))


class ConfigTest(unittest.TestCase):
    def test_unknown_adapter_fails_at_load(self):
        env = {"RELAY_ROUTES": json.dumps({SLACK_ARN: {"name": "x", "adapter": "pagerduty"}}),
               "RELAY_SSM_PREFIX": "/relay"}
        with self.assertRaises(ValueError):
            Config.from_env(env)


if __name__ == "__main__":
    unittest.main()
