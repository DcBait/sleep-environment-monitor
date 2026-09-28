use std::env;
use std::time::Duration;

use anyhow::{Context, Result};
use deadpool_postgres::{Manager, ManagerConfig, Pool, RecyclingMethod};
use rumqttc::{AsyncClient, Event, MqttOptions, Packet, QoS};
use serde_json::Value;
use tokio_postgres::NoTls;
use tracing::{error, info, warn};

const MQTT_TOPIC: &str = "sleep/sensors";

const INSERT_SQL: &str = "
    INSERT INTO raw_sensor_events
        (event_ts, received_at, temperature, humidity, pressure, snore_detected)
    VALUES
        (to_timestamp($1), NOW(), $2, $3, $4, $5)
";

struct Range {
    field: &'static str,
    lo: f64,
    hi: f64,
}

const NUMERIC_RANGES: &[Range] = &[
    Range { field: "temperature", lo: -10.0, hi: 60.0 },
    Range { field: "humidity", lo: 0.0, hi: 100.0 },
    Range { field: "pressure", lo: 800.0, hi: 1200.0 },
    Range { field: "timestamp", lo: 0.0, hi: f64::INFINITY },
];

struct SensorEvent {
    timestamp: f64,
    temperature: f64,
    humidity: f64,
    pressure: f64,
    snore_detected: i32,
}

fn validate(payload: &Value) -> Option<SensorEvent> {
    let obj = payload.as_object()?;

    for field in NUMERIC_RANGES.iter().map(|r| r.field).chain(["snore_detected"]) {
        if !obj.contains_key(field) {
            warn!("Dropping message — missing field: {field}");
            return None;
        }
    }

    let mut values = std::collections::HashMap::new();
    for range in NUMERIC_RANGES {
        let val = obj.get(range.field).and_then(Value::as_f64);
        match val {
            Some(v) if v >= range.lo && v <= range.hi => {
                values.insert(range.field, v);
            }
            other => {
                warn!("Dropping message — {} out of range: {:?}", range.field, other);
                return None;
            }
        }
    }

    let snore_detected = match obj.get("snore_detected").and_then(Value::as_i64) {
        Some(v @ (0 | 1)) => v as i32,
        other => {
            warn!("Dropping message — snore_detected must be 0 or 1, got: {:?}", other);
            return None;
        }
    };

    Some(SensorEvent {
        timestamp: values["timestamp"],
        temperature: values["temperature"],
        humidity: values["humidity"],
        pressure: values["pressure"],
        snore_detected,
    })
}

async fn handle_message(pool: &Pool, payload_bytes: &[u8]) {
    let payload: Value = match serde_json::from_slice(payload_bytes) {
        Ok(v) => v,
        Err(e) => {
            warn!("Dropping message — invalid JSON: {e}");
            return;
        }
    };

    let event = match validate(&payload) {
        Some(e) => e,
        None => return,
    };

    let conn = match pool.get().await {
        Ok(c) => c,
        Err(e) => {
            error!("DB pool exhausted: {e}");
            return;
        }
    };

    let result = conn
        .execute(
            INSERT_SQL,
            &[
                &event.timestamp,
                &event.temperature,
                &event.humidity,
                &event.pressure,
                &event.snore_detected,
            ],
        )
        .await;

    match result {
        Ok(_) => info!(
            "Inserted: temp={:.2}  hum={:.2}  pres={:.2}  snore={}",
            event.temperature, event.humidity, event.pressure, event.snore_detected
        ),
        Err(e) => error!("DB insert failed: {e}"),
    }
}

fn build_pool(dsn: &str) -> Result<Pool> {
    let pg_config: tokio_postgres::Config = dsn.parse().context("invalid DB_DSN")?;
    let mgr_config = ManagerConfig {
        recycling_method: RecyclingMethod::Fast,
    };
    let manager = Manager::from_config(pg_config, NoTls, mgr_config);
    Pool::builder(manager)
        .max_size(5)
        .build()
        .context("failed to build DB pool")
}

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(tracing_subscriber::EnvFilter::from_default_env().add_directive("info".parse()?))
        .with_target(false)
        .init();

    dotenvy::dotenv().ok();

    let mqtt_broker = env::var("MQTT_BROKER").context("MQTT_BROKER not set")?;
    let mqtt_port: u16 = env::var("MQTT_PORT")
        .unwrap_or_else(|_| "1883".to_string())
        .parse()
        .context("MQTT_PORT must be a number")?;
    let db_dsn = env::var("DB_DSN").context("DB_DSN not set")?;

    let pool = build_pool(&db_dsn)?;
    info!("DB pool ready");

    let mut mqtt_options = MqttOptions::new("sleep-subscriber", &mqtt_broker, mqtt_port);
    mqtt_options.set_keep_alive(Duration::from_secs(60));

    let (client, mut event_loop) = AsyncClient::new(mqtt_options, 10);

    let shutdown = shutdown_signal();
    tokio::pin!(shutdown);

    loop {
        tokio::select! {
            _ = &mut shutdown => {
                info!("Shutting down");
                let _ = client.disconnect().await;
                break;
            }
            event = event_loop.poll() => {
                match event {
                    Ok(Event::Incoming(Packet::ConnAck(_))) => {
                        info!("Connected to {}:{} — subscribing to {}", mqtt_broker, mqtt_port, MQTT_TOPIC);
                        if let Err(e) = client.subscribe(MQTT_TOPIC, QoS::AtLeastOnce).await {
                            error!("Failed to subscribe: {e}");
                        }
                    }
                    Ok(Event::Incoming(Packet::Publish(publish))) => {
                        handle_message(&pool, &publish.payload).await;
                    }
                    Ok(Event::Incoming(Packet::Disconnect)) => {
                        warn!("Broker sent disconnect — will reconnect");
                    }
                    Ok(_) => {}
                    Err(e) => {
                        warn!("Unexpected disconnect: {e} — will reconnect");
                        tokio::time::sleep(Duration::from_secs(1)).await;
                    }
                }
            }
        }
    }

    Ok(())
}

#[cfg(unix)]
async fn shutdown_signal() {
    use tokio::signal::unix::{signal, SignalKind};
    let mut sigterm = signal(SignalKind::terminate()).expect("failed to register SIGTERM handler");
    tokio::select! {
        _ = tokio::signal::ctrl_c() => {}
        _ = sigterm.recv() => {}
    }
}

#[cfg(not(unix))]
async fn shutdown_signal() {
    let _ = tokio::signal::ctrl_c().await;
}
