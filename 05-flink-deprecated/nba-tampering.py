import os
import json
from pyflink.table import EnvironmentSettings, StreamTableEnvironment


env_settings = (
    EnvironmentSettings.new_instance().in_streaming_mode().use_blink_planner().build()
)
table_env = StreamTableEnvironment.create(environment_settings=env_settings)
statement_set = table_env.create_statement_set()

APPLICATION_PROPERTIES_FILE_PATH = "/etc/flink/application_properties.json"

is_local = (
    True if os.environ.get("IS_LOCAL") else False
)

# reference_scheme = "s3"

if is_local:
    # reference_scheme = "file"

    APPLICATION_PROPERTIES_FILE_PATH = "application_properties.json"

    CURRENT_DIR = os.path.dirname(os.path.realpath(__file__))
    table_env.get_config().get_configuration().set_string(
        "pipeline.jars",
        "file:///" + CURRENT_DIR + "/lib/flink-sql-connector-kinesis_2.12-1.13.6.jar",
    )


def get_application_properties():
    if os.path.isfile(APPLICATION_PROPERTIES_FILE_PATH):
        with open(APPLICATION_PROPERTIES_FILE_PATH, "r") as file:
            contents = file.read()
            properties = json.loads(contents)
            return properties
    else:
        print('A file at "{}" was not found'.format(APPLICATION_PROPERTIES_FILE_PATH))


def property_map(props, property_group_id):
    for prop in props:
        if prop["PropertyGroupId"] == property_group_id:
            return prop["PropertyMap"]


def create_table(table_name, stream_name, region, stream_initpos):
    return """ CREATE TABLE {0} (
                data ARRAY<ROW<`id` BIGINT, `context_annotations` ARRAY<ROW<`domain` ROW<`id` VARCHAR, `name` VARCHAR, `description` VARCHAR>,`entity` ROW<`id` VARCHAR, `name` VARCHAR, `description` VARCHAR >>>>>,
                includes ROW<`users` ARRAY<ROW<`username` VARCHAR>>>,
                event_time TIMESTAMP(3),
                WATERMARK FOR event_time AS event_time - INTERVAL '5' SECOND
              )
              WITH (
                'connector' = 'kinesis',
                'stream' = '{1}',
                'aws.region' = '{2}',
                'scan.stream.initpos' = '{3}',
                'sink.partitioner-field-delimiter' = ';',
                'sink.producer.collection-max-count' = '100',
                'format' = 'json',
                'json.timestamp-format.standard' = 'ISO-8601'
              ) """.format(
        table_name, stream_name, region, stream_initpos
    )


def create_table_output(table_name, stream_name, region, stream_initpos):
    return """ CREATE TABLE {0} (
                `event_time` TIMESTAMP(3),
                `sourceplayer` VARCHAR,
                `destinationplayer` VARCHAR,
                `total` BIGINT
              )
              WITH (
                'connector' = 'kinesis',
                'stream' = '{1}',
                'aws.region' = '{2}',
                'scan.stream.initpos' = '{3}',
                'sink.partitioner-field-delimiter' = ';',
                'sink.producer.collection-max-count' = '100',
                'format' = 'json',
                'json.timestamp-format.standard' = 'ISO-8601'
              ) """.format(
        table_name, stream_name, region, stream_initpos
    )


def create_print_table(table_name):
    return """ CREATE TABLE {0} (
                `event_time` TIMESTAMP(3),
                `sourceplayer` VARCHAR,
                `destinationplayer` VARCHAR,
                `total` BIGINT
              )
              WITH (
                'connector' = 'print'
              ) """.format(
        table_name
    )


# def create_reference_table(table_name, file, scheme):
#     return """CREATE TABLE {0} (
#                 `tweetAccount` VARCHAR,
#                 `player` VARCHAR,
#                 `team` VARCHAR
#               )
#               WITH (
#                 'connector' = 'filesystem',
#                 'path' = '{1}://{2}',
#                 'format' = 'csv',
#                 'csv.ignore-parse-errors' = 'true',
#                 'csv.allow-comments' = 'true',
#                 'csv.field-delimiter' = ';'
#               ) """.format(table_name, scheme, file)


# def perform_sliding_window_aggregation(table_name, input_table_name, window_in_seconds, every_in_seconds):
#
#     return """CREATE VIEW {0} AS
#               SELECT HOP_END(event_time, INTERVAL '{3}' SECOND, INTERVAL '{2}' SECOND) AS winend, includes.users[1].username as sourcePlayer, entity.name as destinationPlayer
#               FROM {1}
#               CROSS JOIN UNNEST(input_table.data[1].context_annotations) AS ContextTable (domain, entity)
#               WHERE domain.id = '60'
#               GROUP BY HOP(event_time, INTERVAL '{3}' SECOND, INTERVAL '{2}' SECOND), includes.users[1].username, entity.name
#              """.format(
#         table_name, input_table_name, window_in_seconds, every_in_seconds)


def main():
    # Application Property Keys
    input_property_group_key = "consumer.config.0"
    producer_property_group_key = "producer.config.0"
    reference_property_group_key = "reference.config.0"

    input_stream_key = "input.stream.name"
    input_region_key = "aws.region"
    input_starting_position_key = "flink.stream.initpos"

    output_stream_key = "output.stream.name"
    output_region_key = "aws.region"

    # reference_s3_bucket_name = "s3.bucket.name"
    # reference_s3_bucket_file = "s3.bucket.file"

    # tables
    input_table_name = "input_table"
    output_table_name = "output_table"
    reference_table_name = "NbaPlayers"

    # get application properties
    props = get_application_properties()

    input_property_map = property_map(props, input_property_group_key)
    output_property_map = property_map(props, producer_property_group_key)
    # reference_property_map = property_map(props, reference_property_group_key)

    input_stream = input_property_map[input_stream_key]
    input_region = input_property_map[input_region_key]
    stream_initpos = input_property_map[input_starting_position_key]

    output_stream = output_property_map[output_stream_key]
    output_region = output_property_map[output_region_key]

    # reference_s3_bucket = reference_property_map[reference_s3_bucket_name]
    # reference_s3_file = reference_property_map[reference_s3_bucket_file]
    
    table_env.execute_sql(
        create_table(input_table_name, input_stream, input_region, stream_initpos)
    )

    # table_env.execute_sql(
    #     perform_sliding_window_aggregation("SlindingWindowTable", input_table_name, 20, 10)
    # )

    if is_local:
        table_env.execute_sql(
            create_print_table(output_table_name)
        )
    else:
        table_env.execute_sql(
            create_table_output(output_table_name, output_stream, output_region, stream_initpos)
        )

    # file = reference_s3_bucket + "/" + reference_s3_file
    # if is_local:
    #     file = os.getcwd() + "/nba-players-tweet-accounts.csv"
    #
    # table_env.execute_sql(
    #     create_reference_table(reference_table_name, file, reference_scheme)
    # )


    table_result = table_env.execute_sql("""
        INSERT INTO {0}
        SELECT HOP_END(event_time, INTERVAL '10' SECOND, INTERVAL '20' SECOND) AS winend, includes.users[1].username, entity.name, COUNT(*)
        FROM {1}
        CROSS JOIN UNNEST(input_table.data[1].context_annotations) AS ContextTable (domain, entity)
        WHERE domain.id = '60'
        GROUP BY HOP(event_time, INTERVAL '10' SECOND, INTERVAL '20' SECOND), includes.users[1].username, entity.name
        HAVING COUNT(*) > 1""".format(output_table_name, input_table_name)
    )

    if is_local:
        table_result.wait()
    else:
        # get job status through TableResult
        print(table_result.get_job_client().get_job_status())


if __name__ == "__main__":
    main()
