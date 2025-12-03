CREATE TABLE waltest (
    id SERIAL PRIMARY KEY,
    data TEXT,
    updated_at TIMESTAMPTZ DEFAULT now()
);
INSERT INTO waltest (data)
SELECT md5(i::text)
FROM generate_series(1, 5000000) i;