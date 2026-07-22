-- Run once on the Oracle Cloud VM against the sleep_monitor database.
-- psql -h localhost -U <user> -d sleep_monitor -f migrations/001_init.sql

-- ── Schemas ───────────────────────────────────────────────────────────────────

CREATE SCHEMA IF NOT EXISTS staging;
CREATE SCHEMA IF NOT EXISTS mart;

-- ── Raw table (written by the MQTT subscriber) ────────────────────────────────

CREATE TABLE IF NOT EXISTS public.raw_sensor_events (
    id             BIGSERIAL    PRIMARY KEY,
    event_ts       TIMESTAMPTZ  NOT NULL,
    received_at    TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    temperature    DOUBLE PRECISION NOT NULL,
    humidity       DOUBLE PRECISION NOT NULL,
    pressure       DOUBLE PRECISION NOT NULL,
    snore_detected SMALLINT     NOT NULL CHECK (snore_detected IN (0, 1))
);

-- Time-range index: used by every dbt model and every Grafana query
CREATE INDEX IF NOT EXISTS idx_raw_event_ts
    ON public.raw_sensor_events (event_ts DESC);

-- Covering index for snore aggregation (avoids heap fetch for snore_detected)
CREATE INDEX IF NOT EXISTS idx_raw_event_ts_snore
    ON public.raw_sensor_events (event_ts DESC, snore_detected);
