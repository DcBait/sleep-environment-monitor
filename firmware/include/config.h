#pragma once

// WiFi — credentials managed by WiFiManager, no hardcoding needed.
// First boot: ESP32 creates hotspot "sleep-monitor-setup".
// Connect with your phone → open 192.168.4.1 → enter WiFi password.
// To switch networks (e.g. going on exchange): hold BOOT button while powering on.

// MQTT
#define MQTT_BROKER ""
#define MQTT_PORT 1883
#define MQTT_TOPIC "sleep/sensors"
#define MQTT_CLIENT_ID "esp32-sleep-monitor"

// I2C pins (ESP32 WROOM-32D defaults)
#define I2C_SDA 21
#define I2C_SCL 22

// I2S pins (INMP441)
#define I2S_WS  15
#define I2S_SCK 14
#define I2S_SD  32

// Session toggle button (BOOT button on most ESP32 dev boards)
#define BOOT_BUTTON_PIN 0

// Publish interval (ms)
#define PUBLISH_INTERVAL_MS 30000

// NTP
#define NTP_SERVER "pool.ntp.org"

// Snore detection — RMS energy threshold (24-bit audio scale).
// Print raw RMS values to Serial on first use and tune this.
#define SNORE_RMS_THRESHOLD 300000

// A burst must stay above threshold this long to count as a candidate —
// filters out brief transient noise (taps, clicks).
#define SNORE_MIN_BURST_MS 300

// A candidate only becomes a confirmed snore event if another candidate
// happened within this many ms — snoring repeats every breath, so a real
// snore pattern satisfies this while a one-off noise (door, cough) doesn't.
#define SNORE_PATTERN_WINDOW_MS 15000
