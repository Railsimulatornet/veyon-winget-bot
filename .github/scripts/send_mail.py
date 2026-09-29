#!/usr/bin/env python3
import os
import smtplib
import ssl
from email.message import EmailMessage
from email.utils import getaddresses, parseaddr


def require_env(name: str) -> str:
    value = os.environ.get(name, "").strip()
    if not value:
        raise SystemExit(f"Required environment variable is missing: {name}")
    return value


def recipient_headers_and_envelope(value: str) -> tuple[list[str], list[str]]:
    headers = [part.strip() for part in value.replace(";", ",").split(",") if part.strip()]
    parsed = [(name, address) for name, address in getaddresses(headers) if address]
    if not parsed:
        raise SystemExit("MAIL_TO does not contain a valid recipient")
    envelope = [address for _, address in parsed]
    return headers, envelope


host = require_env("MAIL_SERVER")
port = int(require_env("MAIL_PORT"))
username = os.environ.get("MAIL_USERNAME", "").strip()
password = os.environ.get("MAIL_PASSWORD", "")
sender = require_env("MAIL_FROM")
_, sender_address = parseaddr(sender)
if not sender_address:
    raise SystemExit("MAIL_FROM does not contain a valid sender address")
to_headers, to_envelope = recipient_headers_and_envelope(require_env("MAIL_TO"))
subject = require_env("MAIL_SUBJECT")
body = os.environ.get("MAIL_BODY", "")
mode = os.environ.get("MAIL_TLS_MODE", "auto").strip().lower()

if bool(username) != bool(password):
    raise SystemExit("MAIL_USERNAME and MAIL_PASSWORD must either both be set or both be empty")

if mode == "auto":
    mode = "ssl" if port == 465 else "starttls"
if mode not in {"ssl", "starttls"}:
    raise SystemExit("MAIL_TLS_MODE must be auto, ssl or starttls")

message = EmailMessage()
message["Subject"] = subject
message["From"] = sender
message["To"] = ", ".join(to_headers)
message.set_content(body)

context = ssl.create_default_context()

if mode == "ssl":
    with smtplib.SMTP_SSL(host, port, timeout=30, context=context) as smtp:
        if username:
            smtp.login(username, password)
        smtp.send_message(message, from_addr=sender_address, to_addrs=to_envelope)
else:
    with smtplib.SMTP(host, port, timeout=30) as smtp:
        smtp.ehlo()
        smtp.starttls(context=context)
        smtp.ehlo()
        if username:
            smtp.login(username, password)
        smtp.send_message(message, from_addr=sender_address, to_addrs=to_envelope)

print("Mail sent successfully using verified TLS.")
