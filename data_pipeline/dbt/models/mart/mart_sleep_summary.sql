WITH agg AS (
    SELECT * FROM {{ ref('int_5min_agg') }}
)

SELECT
    sleep_date,
    ROUND(AVG(avg_temperature),         2) AS avg_temperature,
    ROUND(MIN(avg_temperature),         2) AS min_temperature,
    ROUND(MAX(avg_temperature),         2) AS max_temperature,
    ROUND(AVG(avg_humidity),            2) AS avg_humidity,
    ROUND(AVG(avg_pressure),            2) AS avg_pressure,
    SUM(snore_events_in_bucket)::INT       AS total_snore_events,
    ROUND(AVG(snore_rate)::NUMERIC,     4) AS snore_rate,
    -- each raw reading covers 30 s; total readings × 30 s ÷ 60 = minutes
    ROUND((SUM(reading_count) * 30.0 / 60.0)::NUMERIC, 1) AS session_duration_minutes
FROM agg
GROUP BY sleep_date
