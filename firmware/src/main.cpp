#include <Arduino.h>
#include <Wire.h>
#include <WiFi.h>
#include <WiFiManager.h>
#include <time.h>
#include <PubSubClient.h>
#include <ArduinoJson.h>
#include <Adafruit_BME280.h>
#include <Adafruit_SSD1306.h>
#include "driver/i2s.h"
#include "config.h"

// ── Display ───────────────────────────────────────────────────────────────────
#define OLED_W        128
#define OLED_H         64
#define OLED_ADDR    0x3C
#define BME_ADDR     0x76

// ── I2S ───────────────────────────────────────────────────────────────────────
#define I2S_PORT      I2S_NUM_0
#define I2S_RATE      16000
#define I2S_BUF       512     // samples per DMA read

// ── Objects ───────────────────────────────────────────────────────────────────
WiFiClient         wifiClient;
PubSubClient       mqtt(wifiClient);
Adafruit_BME280    bme;
Adafruit_SSD1306   oled(OLED_W, OLED_H, &Wire, -1);

// ── State ─────────────────────────────────────────────────────────────────────
enum DisplayState { DISP_IDLE, DISP_RECORDING, DISP_SUMMARY };

volatile bool          sessionActive    = false;
volatile unsigned long lastButtonMs     = 0;
volatile DisplayState  displayState     = DISP_IDLE;
volatile bool          displayDirty     = true;
unsigned long          lastPublishMs    = 0;
uint32_t               snoreCount       = 0;

// Continuous snore-event detection state (see pollAudio()).
volatile bool          snoreDetectedThisWindow = false;  // any event since last publish
bool                    burstActive             = false; // currently inside a loud burst
unsigned long           burstStartMs            = 0;
bool                    burstCounted            = false; // has current burst become a candidate?
unsigned long           lastCandidateMs         = 0;      // time of the previous confirmed candidate

float lastTemp = 0, lastHumid = 0, lastPressure = 0;
bool  lastSnore = false;

// ── BOOT button ISR ───────────────────────────────────────────────────────────
// Display only redraws on start/stop (see displayDirty), not every publish —
// an OLED refreshing every 30-60s next to the bed is disruptive to sleep.
void IRAM_ATTR onBootButton() {
    unsigned long now = millis();
    if (now - lastButtonMs < 300) return;   // debounce
    lastButtonMs = now;
    sessionActive = !sessionActive;
    if (sessionActive) {
        snoreCount              = 0;    // reset count when a new session starts
        snoreDetectedThisWindow = false;
        burstActive             = false;
        burstCounted            = false;
        lastCandidateMs         = 0;
        displayState = DISP_RECORDING;
    } else {
        displayState = DISP_SUMMARY;    // show last night's data until next start
    }
    displayDirty = true;
}

// ── WiFi ──────────────────────────────────────────────────────────────────────
void showWiFiSetupScreen() {
    oled.clearDisplay();
    oled.setTextSize(1); oled.setTextColor(SSD1306_WHITE);
    oled.setCursor(0, 0);  oled.println("-- WiFi Setup --");
    oled.setCursor(0, 14); oled.println("Join hotspot:");
    oled.setCursor(0, 24); oled.println("sleep-monitor-setup");
    oled.setCursor(0, 38); oled.println("Then open:");
    oled.setCursor(0, 48); oled.println("192.168.4.1");
    oled.display();
}

void connectWiFi() {
    // Hold BOOT at power-on to wipe saved credentials and re-configure
    if (digitalRead(BOOT_BUTTON_PIN) == LOW) {
        oled.clearDisplay();
        oled.setTextSize(1); oled.setTextColor(SSD1306_WHITE);
        oled.setCursor(0, 20); oled.println("Resetting WiFi...");
        oled.display();
        WiFiManager wm;
        wm.resetSettings();
        delay(1000);
    }

    WiFiManager wm;
    wm.setConfigPortalTimeout(180);
    wm.setAPCallback([](WiFiManager*) { showWiFiSetupScreen(); });

    if (!wm.autoConnect("sleep-monitor-setup")) {
        Serial.println("WiFi config timed out — restarting");
        ESP.restart();
    }
    Serial.printf("WiFi connected: %s\n", WiFi.localIP().toString().c_str());
}

// ── MQTT ──────────────────────────────────────────────────────────────────────
void connectMQTT() {
    int tries = 0;
    while (!mqtt.connected() && tries < 5) {
        Serial.print("MQTT...");
        if (mqtt.connect(MQTT_CLIENT_ID)) {
            Serial.println(" ok");
        } else {
            Serial.printf(" fail (rc=%d)\n", mqtt.state());
            delay(3000);
        }
        tries++;
    }
}

// ── I2S / INMP441 ────────────────────────────────────────────────────────────
void initI2S() {
    i2s_config_t cfg = {
        .mode                 = (i2s_mode_t)(I2S_MODE_MASTER | I2S_MODE_RX),
        .sample_rate          = I2S_RATE,
        .bits_per_sample      = I2S_BITS_PER_SAMPLE_32BIT,
        .channel_format       = I2S_CHANNEL_FMT_ONLY_LEFT,
        .communication_format = I2S_COMM_FORMAT_STAND_I2S,
        .intr_alloc_flags     = ESP_INTR_FLAG_LEVEL1,
        .dma_buf_count        = 8,
        .dma_buf_len          = I2S_BUF,
        .use_apll             = false,
    };
    i2s_pin_config_t pins = {
        .bck_io_num    = I2S_SCK,
        .ws_io_num     = I2S_WS,
        .data_out_num  = I2S_PIN_NO_CHANGE,
        .data_in_num   = I2S_SD,
    };
    i2s_driver_install(I2S_PORT, &cfg, 0, NULL);
    i2s_set_pin(I2S_PORT, &pins);
}

// Continuous snore-event detection — called every loop() iteration while a
// session is active. Reads one short audio chunk (~32ms at 16kHz) and looks
// for a repeating pattern of sustained loud bursts, rather than treating any
// single threshold crossing as a snore:
//   1. A burst must stay above threshold for SNORE_MIN_BURST_MS before it
//      counts as a candidate at all — filters brief transient noise (taps,
//      clicks) that spike and vanish in milliseconds.
//   2. A candidate only becomes a confirmed event if another candidate
//      happened within SNORE_PATTERN_WINDOW_MS — snoring repeats every
//      breath, so a real pattern satisfies this while a one-off noise
//      (door, cough, aircon kicking on) doesn't, even if it's loud and
//      sustained.
//
// On first deployment: watch Serial for "Audio RMS:" values and set
// SNORE_RMS_THRESHOLD to sit above your quiet-room baseline noise floor.
void pollAudio() {
    static unsigned long lastPrintMs = 0;

    int32_t buf[I2S_BUF];
    size_t  bytesRead = 0;
    i2s_read(I2S_PORT, buf, sizeof(buf), &bytesRead, pdMS_TO_TICKS(50));
    int n = bytesRead / sizeof(int32_t);
    if (n == 0) return;

    int64_t sumSq = 0;
    for (int i = 0; i < n; i++) {
        // INMP441 puts 24-bit audio in the upper bits of a 32-bit frame
        int32_t s = buf[i] >> 8;
        sumSq += (int64_t)s * s;
    }
    double rms = sqrt((double)sumSq / n);

    if (millis() - lastPrintMs >= 1000) {
        Serial.printf("Audio RMS: %.0f  threshold: %d\n", rms, SNORE_RMS_THRESHOLD);
        lastPrintMs = millis();
    }

    unsigned long now = millis();
    if (rms > SNORE_RMS_THRESHOLD) {
        if (!burstActive) {
            burstActive  = true;
            burstStartMs = now;
            burstCounted = false;
        } else if (!burstCounted && now - burstStartMs >= SNORE_MIN_BURST_MS) {
            burstCounted = true;   // sustained long enough to be a real candidate
            if (lastCandidateMs != 0 && now - lastCandidateMs <= SNORE_PATTERN_WINDOW_MS) {
                // a previous candidate happened recently too — a repeating
                // rhythm, consistent with snoring rather than a one-off noise
                snoreDetectedThisWindow = true;
                snoreCount++;
            }
            lastCandidateMs = now;
        }
    } else {
        burstActive = false;   // dropped quiet — next loud burst starts fresh
    }
}

// ── OLED ──────────────────────────────────────────────────────────────────────
void updateDisplay() {
    oled.clearDisplay();
    oled.setTextColor(SSD1306_WHITE);

    switch (displayState) {
        case DISP_IDLE:
            oled.setTextSize(2);
            oled.setCursor(18, 8);  oled.println("SLEEP");
            oled.setCursor(8,  32); oled.println("MONITOR");
            oled.setTextSize(1);
            oled.setCursor(4, 56);  oled.println("BOOT = start session");
            break;

        case DISP_RECORDING:
            oled.setTextSize(2);
            oled.setCursor(4, 20);  oled.println("RECORDING");
            oled.setTextSize(1);
            oled.setCursor(0, 52);  oled.println("BOOT = stop session");
            break;

        case DISP_SUMMARY:
            oled.setTextSize(1);
            oled.setCursor(0, 0);  oled.printf("Last Temp   %.1f C\n",   lastTemp);
            oled.setCursor(0, 12); oled.printf("Last Humid  %.1f %%\n",  lastHumid);
            oled.setCursor(0, 24); oled.printf("Last Press  %.0f hPa\n", lastPressure);
            oled.setCursor(0, 36); oled.printf("Snores      %lu\n",      snoreCount);
            oled.setCursor(0, 52); oled.println("BOOT = new session");
            break;
    }
    oled.display();
}

// ── Publish ───────────────────────────────────────────────────────────────────
void publishReading() {
    lastTemp     = bme.readTemperature();
    lastHumid    = bme.readHumidity();
    lastPressure = bme.readPressure() / 100.0f;
    lastSnore    = snoreDetectedThisWindow;   // any event since the last publish
    snoreDetectedThisWindow = false;          // reset for the next interval

    StaticJsonDocument<128> doc;
    doc["temperature"]    = round(lastTemp     * 100.0f) / 100.0f;
    doc["humidity"]       = round(lastHumid    * 100.0f) / 100.0f;
    doc["pressure"]       = round(lastPressure * 100.0f) / 100.0f;
    doc["snore_detected"] = lastSnore ? 1 : 0;
    doc["timestamp"]      = (double)time(nullptr);   // Unix epoch UTC from NTP

    char payload[128];
    serializeJson(doc, payload, sizeof(payload));
    mqtt.publish(MQTT_TOPIC, payload, false);
    Serial.printf("Published: %s\n", payload);
}

// ── Setup ─────────────────────────────────────────────────────────────────────
void setup() {
    Serial.begin(115200);
    Wire.begin(I2C_SDA, I2C_SCL);

    // OLED — show splash while everything else inits
    if (!oled.begin(SSD1306_SWITCHCAPVCC, OLED_ADDR))
        Serial.println("[WARN] SSD1306 not found");
    oled.clearDisplay();
    oled.setTextSize(1); oled.setTextColor(SSD1306_WHITE);
    oled.setCursor(0, 0); oled.println("Initialising...");
    oled.display();

    // BME280
    if (!bme.begin(BME_ADDR))
        Serial.println("[WARN] BME280 not found — check wiring");

    // INMP441
    initI2S();

    // BOOT button
    pinMode(BOOT_BUTTON_PIN, INPUT_PULLUP);
    attachInterrupt(digitalPinToInterrupt(BOOT_BUTTON_PIN), onBootButton, FALLING);

    // WiFi + NTP
    connectWiFi();
    if (WiFi.status() == WL_CONNECTED) {
        configTime(0, 0, NTP_SERVER);   // UTC
        Serial.print("NTP sync");
        time_t now = 0;
        while (now < 1000000000UL) {   // wait for valid epoch
            delay(200); Serial.print("."); now = time(nullptr);
        }
        Serial.println(" ok");
    }

    // MQTT
    mqtt.setServer(MQTT_BROKER, MQTT_PORT);
    connectMQTT();

    updateDisplay();
    Serial.println("Ready. Press BOOT to start/stop session.");
}

// ── Loop ──────────────────────────────────────────────────────────────────────
void loop() {
    if (WiFi.status() != WL_CONNECTED) { WiFi.reconnect(); delay(500); }
    if (!mqtt.connected()) connectMQTT();
    mqtt.loop();

    if (sessionActive) pollAudio();

    if (sessionActive && millis() - lastPublishMs >= PUBLISH_INTERVAL_MS) {
        publishReading();
        lastPublishMs = millis();
    }

    if (displayDirty) {
        updateDisplay();
        displayDirty = false;
    }

    delay(10);
}
