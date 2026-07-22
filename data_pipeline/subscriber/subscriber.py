import json
import logging
import os
import signal
import sys

import paho.mqtt.client as mqtt
import psycopg2.pool
from dotenv import load_dotenv

load_dotenv()

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
    datefmt="%Y-%m-%dT%H:%M:%S",
)
log = logging.getLogger(__name__)

MQTT_BROKER = os.environ["MQTT_BROKER"]
MQTT_PORT = int(os.getenv("MQTT_PORT", "1883"))
MQTT_TOPIC = "sleep/sensors"
DB_DSN = os.environ["DB_DSN"]  # postgresql://user:pass@host:5432/dbname

NUMERIC_RANGES = {
    "temperature": (-10.0, 60.0),
    "humidity": (0.0, 100.0),
    "pressure": (800.0, 1200.0),
    "timestamp": (0.0, float("inf")),
}
REQUIRED_FIELDS = {*NUMERIC_RANGES.keys(), "snore_detected"}

INSERT_SQL = """
    INSERT INTO raw_sensor_events
        (event_ts, received_at, temperature, humidity, pressure, snore_detected)
    VALUES
        (to_timestamp(%s), NOW(), %s, %s, %s, %s)
"""


def validate(payload: dict) -> bool:
    if missing := REQUIRED_FIELDS - payload.keys():
        log.warning("Dropping message — missing fields: %s", missing)
        return False
    for field, (lo, hi) in NUMERIC_RANGES.items():
        val = payload[field]
        if not isinstance(val, (int, float)) or not (lo <= val <= hi):
            log.warning("Dropping message — %s out of range: %r", field, val)
            return False
    if payload["snore_detected"] not in (0, 1):
        log.warning("Dropping message — snore_detected must be 0 or 1, got: %r", payload["snore_detected"])
        return False
    return True


def main() -> None:
    db_pool = psycopg2.pool.ThreadedConnectionPool(1, 5, dsn=DB_DSN)
    log.info("DB pool ready")

    def on_connect(client, userdata, flags, reason_code, properties):
        if reason_code.value != 0:
            log.error("MQTT connection refused: %s", reason_code)
            sys.exit(1)
        log.info("Connected to %s:%d — subscribing to %s", MQTT_BROKER, MQTT_PORT, MQTT_TOPIC)
        client.subscribe(MQTT_TOPIC, qos=1)

    def on_disconnect(client, userdata, disconnect_flags, reason_code, properties):
        if reason_code.value != 0:
            log.warning("Unexpected disconnect: %s — will reconnect", reason_code)

    def on_message(client, userdata, msg):
        try:
            payload = json.loads(msg.payload)
        except json.JSONDecodeError as e:
            log.warning("Dropping message — invalid JSON: %s", e)
            return

        if not validate(payload):
            return

        conn = db_pool.getconn()
        try:
            with conn.cursor() as cur:
                cur.execute(INSERT_SQL, (
                    payload["timestamp"],
                    payload["temperature"],
                    payload["humidity"],
                    payload["pressure"],
                    payload["snore_detected"],
                ))
            conn.commit()
            log.info(
                "Inserted: temp=%.2f  hum=%.2f  pres=%.2f  snore=%d",
                payload["temperature"],
                payload["humidity"],
                payload["pressure"],
                payload["snore_detected"],
            )
        except Exception as e:
            conn.rollback()
            log.error("DB insert failed: %s", e)
        finally:
            db_pool.putconn(conn)

    client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2, client_id="sleep-subscriber")
    client.on_connect = on_connect
    client.on_disconnect = on_disconnect
    client.on_message = on_message

    def shutdown(sig, frame):
        log.info("Shutting down")
        client.disconnect()
        db_pool.closeall()
        sys.exit(0)

    signal.signal(signal.SIGINT, shutdown)
    signal.signal(signal.SIGTERM, shutdown)

    client.connect(MQTT_BROKER, MQTT_PORT, keepalive=60)
    client.loop_forever(retry_first_connection=True)


if __name__ == "__main__":
    main()
