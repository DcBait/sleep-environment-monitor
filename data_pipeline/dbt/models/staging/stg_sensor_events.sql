WITH source AS (
    SELECT * FROM {{ source('raw', 'raw_sensor_events') }}
)

SELECT
    id,
    event_ts,
    received_at,
    CAST(temperature AS NUMERIC(5, 2)) AS temperature,
    CAST(humidity    AS NUMERIC(5, 2)) AS humidity,
    CAST(pressure    AS NUMERIC(7, 2)) AS pressure,
    snore_detected::BOOLEAN            AS snore_detected
FROM source
WHERE
    temperature  BETWEEN -10  AND 60
    AND humidity BETWEEN 0    AND 100
    AND pressure BETWEEN 800  AND 1200
    AND snore_detected IN (0, 1)
