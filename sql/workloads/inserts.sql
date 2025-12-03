INSERT INTO waltest (data)
SELECT md5(random()::text)
FROM generate_series(1,100);