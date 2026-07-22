import logging
import os
import sys
from datetime import date, timedelta

import anthropic
import psycopg2
import requests
from dotenv import load_dotenv

load_dotenv()

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
    datefmt="%Y-%m-%dT%H:%M:%S",
)
log = logging.getLogger(__name__)

ANTHROPIC_API_KEY = os.environ["ANTHROPIC_API_KEY"]
TELEGRAM_BOT_TOKEN = os.environ["TELEGRAM_BOT_TOKEN"]
TELEGRAM_CHAT_ID = os.environ["TELEGRAM_CHAT_ID"]
DB_DSN = os.environ["DB_DSN"]

MODEL = "claude-opus-4-8"

QUERY = """
SELECT
    sleep_date,
    avg_temperature,
    min_temperature,
    max_temperature,
    avg_humidity,
    avg_pressure,
    total_snore_events,
    snore_rate,
    session_duration_minutes
FROM mart.mart_sleep_summary
WHERE sleep_date = %s
"""

SYSTEM_PROMPT = (
    "You are a friendly sleep health assistant. "
    "Analyse the previous night's bedroom environment data and generate a concise morning summary. "
    "Keep it under 200 words and use plain text (no markdown — this will be sent via Telegram)."
)


def fetch_row(sleep_date: date) -> dict | None:
    with psycopg2.connect(dsn=DB_DSN) as conn:
        with conn.cursor() as cur:
            cur.execute(QUERY, (sleep_date,))
            row = cur.fetchone()
            if row is None:
                return None
            return dict(zip([desc[0] for desc in cur.description], row))


def generate_digest(data: dict) -> str:
    client = anthropic.Anthropic(api_key=ANTHROPIC_API_KEY)

    user_content = (
        f"Here is last night's sleep environment data for {data['sleep_date']}:\n\n"
        f"Session duration: {int(data['session_duration_minutes'])} minutes\n"
        f"Temperature: avg {data['avg_temperature']:.1f}°C "
        f"(min {data['min_temperature']:.1f}, max {data['max_temperature']:.1f})\n"
        f"Humidity: avg {data['avg_humidity']:.1f}%\n"
        f"Pressure: avg {data['avg_pressure']:.1f} hPa\n"
        f"Snore events: {data['total_snore_events']} "
        f"({data['snore_rate'] * 100:.1f}% of readings)\n\n"
        "Provide: a brief assessment of the sleep environment quality, "
        "any notable patterns, a snoring summary, and one actionable tip for tonight."
    )

    message = client.messages.create(
        model=MODEL,
        max_tokens=400,
        system=SYSTEM_PROMPT,
        messages=[{"role": "user", "content": user_content}],
    )
    return message.content[0].text


def send_telegram(text: str) -> None:
    url = f"https://api.telegram.org/bot{TELEGRAM_BOT_TOKEN}/sendMessage"
    resp = requests.post(
        url,
        json={"chat_id": TELEGRAM_CHAT_ID, "text": text},
        timeout=10,
    )
    resp.raise_for_status()
    log.info("Telegram message sent (message_id=%s)", resp.json()["result"]["message_id"])


def main() -> None:
    # Cron fires at 23:00 UTC = 07:00 SGT the next calendar day.
    # "Last night" in SGT is therefore yesterday in UTC.
    last_night = date.today() - timedelta(days=1)
    log.info("Generating morning summary for %s", last_night)

    data = fetch_row(last_night)
    if data is None:
        log.warning("No mart data for %s — skipping", last_night)
        sys.exit(0)

    digest = generate_digest(data)
    log.info("Digest:\n%s", digest)

    send_telegram(digest)
    log.info("Done")


if __name__ == "__main__":
    main()
