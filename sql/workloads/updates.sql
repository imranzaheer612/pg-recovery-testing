\set id random(1, 5000000)

BEGIN;

-- Update ~100 rows near the chosen ID
UPDATE waltest
   SET data = md5(random()::text),
       updated_at = now()
 WHERE id BETWEEN :id AND :id + 100;

-- Occasionally insert a new row
\if random(1,100) < 5
  INSERT INTO waltest (data) VALUES (md5(random()::text));
\endif

-- Occasionally delete a random row
\if random(1,100) < 3
  DELETE FROM waltest WHERE id = :id;
\endif

COMMIT;
