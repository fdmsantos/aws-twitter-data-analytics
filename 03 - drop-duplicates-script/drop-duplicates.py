import sys
from awsglue.transforms import *
from awsglue.utils import getResolvedOptions
from pyspark.context import SparkContext
from awsglue.context import GlueContext
from awsglue.job import Job
from awsglue.dynamicframe import DynamicFrame
from pyspark.sql import functions as SqlFuncs

args = getResolvedOptions(sys.argv, ["JOB_NAME"])
sc = SparkContext()
glueContext = GlueContext(sc)
spark = glueContext.spark_session
job = Job(glueContext)
job.init(args["JOB_NAME"], args)

# Script generated for node S3 bucket
S3bucket_node1 = glueContext.create_dynamic_frame.from_options(
    format_options={"multiline": False},
    connection_type="s3",
    format="json",
    connection_options={"paths": ["${S3_INPUT_BUCKET_URI}"], "recurse": True},
    transformation_ctx="S3bucket_node1",
)

# Script generated for node DropDuplicates
DropDuplicates_node2 = DynamicFrame.fromDF(
    S3bucket_node1.toDF().dropDuplicates(["id"]), glueContext, "DropDuplicates_node2"
)

# Script generated for node S3 bucket
S3bucket_node3 = glueContext.write_dynamic_frame.from_options(
    frame=DropDuplicates_node2,
    connection_type="s3",
    format="json",
    connection_options={
        "path": "${S3_OUTPUT_BUCKET_URI}",
        "partitionKeys": ["year", "month", "day"],
    },
    transformation_ctx="S3bucket_node3",
)

job.commit()
