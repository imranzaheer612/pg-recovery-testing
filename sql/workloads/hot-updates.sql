BEGIN;

UPDATE waltest
   SET data = md5(random()::text),  -- same fixed size -> always HOT
       updated_at = clock_timestamp()  -- small fixed-size column
 WHERE id = :id;

COMMIT;
