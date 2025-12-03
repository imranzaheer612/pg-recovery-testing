\set id random(1, 5000000)

BEGIN;

-- Update the indexed column (PRIMARY KEY)
UPDATE waltest
   SET id = id
 WHERE id BETWEEN :id AND :id + 50;

COMMIT;
