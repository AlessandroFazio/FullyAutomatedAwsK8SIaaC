from utils.config_utils import (
    parse_args,
    configure_logging
)
from utils.aws_utils import (
    get_caller_identity,
    create_s3_bucket,
    upload_file_to_s3,
    upload_dir_to_s3
)
from utils.ssh_utils import (
    generate_key
)
import logging
import boto3
from constants import *
from typing import List, Any


def main(args: List[Any]) -> None:
    """Main function."""
    sts_client = boto3.client("sts")

    key_path = generate_key(args["ssh_key_name"])

    caller_identity = get_caller_identity(sts_client)
    region = caller_identity["Region"]
    account = caller_identity["Account"]
    
    logging.info(f"Caller Identity -> AWS Account: {account}")
    logging.info(f"Caller Identity -> AWS Region: {region}")

    s3_client = boto3.client("s3", region=region)

    bucket_name = f"k8s-{project_name}-{environment}-{region}-{account}"
    create_s3_bucket(s3_client, bucket_name, region)

    upload_file_to_s3(s3_client, bucket_name, key_path + ".pub", "client-key.pub")
    upload_dir_to_s3(s3_client, bucket_name, SCRIPTS_DIR)
    upload_dir_to_s3(s3_client, bucket_name, TEMPLATES_DIR)
    
    cf_client = boto3.client("cloudformation", region=region)
    
    cf_client.create_stack()


if __name__ == "__main__":
    args = parse_args()
    project_name = args["project_name"]
    environment = args["environment"]
    configure_logging(args["logging_config"])
    main(args)

