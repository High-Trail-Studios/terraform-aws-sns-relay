"""Test destination for the e2e run: logs authorised requests, rejects the rest.

The run script finds a delivered alert by searching this function's logs for
the unique marker it published.
"""

import base64
import hmac
import os


def handler(event, context):
    headers = {k.lower(): v for k, v in (event.get("headers") or {}).items()}
    if not hmac.compare_digest(headers.get("authorization", ""), os.environ["EXPECTED_AUTH"]):
        return {"statusCode": 401}

    body = event.get("body") or ""
    if event.get("isBase64Encoded"):
        body = base64.b64decode(body).decode()
    print(f"RECEIVED {body}")
    return {"statusCode": 204}
