WITH base AS (
    SELECT * FROM {{ ref('stg_sensor_events') }}
),

bucketed AS (
    SELECT
        -- floor event_ts down to the nearest 5-minute boundary (UTC)
        to_timestamp(
            floor(extract(EPOCH FROM event_ts) / 300) * 300
        )                                        AS bucket_ts,
        -- sleep_date uses UTC date; a Singapore session (23:00–07:00 SGT)
        -- falls entirely within one UTC date so no offset is needed
        (event_ts AT TIME ZONE 'UTC')::DATE      AS sleep_date,
        temperature,
        humidity,
        pressure,
        snore_detected::INT                      AS snore_flag
    FROM base
)

SELECT
    bucket_ts,
    sleep_date,
    AVG(temperature)        AS avg_temperature,
    AVG(humidity)           AS avg_humidity,
    AVG(pressure)           AS avg_pressure,
    SUM(snore_flag)         AS snore_events_in_bucket,
    AVG(snore_flag::FLOAT)  AS snore_rate,
    COUNT(*)                AS reading_count
FROM bucketed
GROUP BY bucket_ts, sleep_date
