#pragma once

// WiFi
#define WIFI_SSID ""
#define WIFI_PASSWORD ""

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

// Publish interval (ms)
#define PUBLISH_INTERVAL_MS 30000
