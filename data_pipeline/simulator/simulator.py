import argparse
import json
import logging
import math
import os
import random
import signal
import sys
import time

import paho.mqtt.client as mqtt

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
    datefmt="%Y-%m-%dT%H:%M:%S",
)
log = logging.getLogger(__name__)

MQTT_TOPIC = "sleep/sensors"
NIGHT_PERIOD_S = 8 * 3600
ULTRADIAN_PERIOD_S = 90 * 60


def env_readings(elapsed: float) -> tuple[float, float, float]:
    phase = (2 * math.pi * elapsed) / NIGHT_PERIOD_S
    temp = 26.5 + 1.0 * math.sin(phase) + random.gauss(0, 0.05)
    humid = 79.0 - 3.0 * math.sin(phase) + random.gauss(0, 0.2)  # inverse of temp
    pressure = 1012.0 + 0.8 * math.sin(phase * 0.5) + random.gauss(0, 0.05)
    return round(temp, 2), round(humid, 2), round(pressure, 2)


def snore_probability(elapsed: float) -> float:
    # Two snoring peaks per 90-min ultradian cycle: N3 (~0.25) and REM (~0.75)
    cycle_phase = (elapsed % ULTRADIAN_PERIOD_S) / ULTRADIAN_PERIOD_S
    return 0.5 * (
        math.exp(-((cycle_phase - 0.25) ** 2) / 0.008)
        + math.exp(-((cycle_phase - 0.75) ** 2) / 0.008)
    )


def build_payload(elapsed: float) -> dict:
    temp, humid, pressure = env_readings(elapsed)
    return {
        "temperature": temp,
        "humidity": humid,
        "pressure": pressure,
        "snore_detected": int(random.random() < snore_probability(elapsed)),
        "timestamp": round(time.time(), 3),
    }


def main() -> None:
    parser = argparse.ArgumentParser(description="Sleep sensor simulator")
    parser.add_argument("--broker", default=os.getenv("MQTT_BROKER", "localhost"))
    parser.add_argument("--port", type=int, default=int(os.getenv("MQTT_PORT", "1883")))
    parser.add_argument("--interval", type=float, default=float(os.getenv("PUBLISH_INTERVAL", "30")),
                        help="publish interval in seconds")
    parser.add_argument("--speed", type=float, default=1.0,
                        help="simulation speed multiplier (e.g. 60 = 1 min real → 1 hr simulated)")
    args = parser.parse_args()

    client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2, client_id="sleep-simulator")

    def on_connect(client, userdata, flags, reason_code, properties):
        if reason_code.value != 0:
            log.error("Connection refused: %s", reason_code)
            sys.exit(1)
        log.info("Connected to %s:%d", args.broker, args.port)

    def on_disconnect(client, userdata, disconnect_flags, reason_code, properties):
        if reason_code.value != 0:
            log.warning("Unexpected disconnect: %s", reason_code)

    client.on_connect = on_connect
    client.on_disconnect = on_disconnect

    def shutdown(sig, frame):
        log.info("Shutting down")
        client.disconnect()
        sys.exit(0)

    signal.signal(signal.SIGINT, shutdown)
    signal.signal(signal.SIGTERM, shutdown)

    client.connect(args.broker, args.port, keepalive=60)
    client.loop_start()

    real_start = time.time()
    while True:
        elapsed = (time.time() - real_start) * args.speed
        payload = build_payload(elapsed)
        client.publish(MQTT_TOPIC, json.dumps(payload), qos=1)
        log.info(
            "t=%ds  temp=%.2f  hum=%.2f  pres=%.2f  snore=%d",
            int(elapsed),
            payload["temperature"],
            payload["humidity"],
            payload["pressure"],
            payload["snore_detected"],
        )
        time.sleep(args.interval)


if __name__ == "__main__":
    main()
