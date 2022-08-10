CREATE EXTERNAL TABLE IF NOT EXISTS ${GLUE_DATABASE}.${GLUE_TABLE}
(year string, month string, day string, player string, total int)
  row format
    serde 'org.apache.hive.hcatalog.data.JsonSerDe'
  LOCATION '\$${INPUT}';