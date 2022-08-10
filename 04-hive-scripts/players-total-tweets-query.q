INSERT INTO TABLE ${GLUE_DATABASE}.${GLUE_TABLE}
SELECT year, month, day, context.entity.name, count(*) as total
FROM twitter_nba_db.tweets
    LATERAL VIEW explode(context_annotations) t AS context
WHERE context.domain.id = '60'
GROUP BY context.entity.name,year, month, day
HAVING year = '$${YEAR}'
   AND month = '$${MONTH}'
   AND day = '$${DAY}';



INSERT INTO TABLE twitter_nba_db.playerstotaltweets
SELECT year, month, day, context.entity.name, count(*) as total
FROM twitter_nba_db.tweets
         LATERAL VIEW explode(context_annotations) t AS context
WHERE context.domain.id = '60'
GROUP BY context.entity.name,year, month, day
HAVING year = '2022'
   AND month = '08'
   AND day = '03';