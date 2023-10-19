from utils.config_utils import configure, auto_configure_cloudformation
from utils.aws_utils import (
    get_caller_identity,
    create_s3_bucket,
    upload_file_to_s3,
    upload_dir_to_s3,
    create_stack
)
from utils.ssh_utils import (
    generate_key
)
import logging
import boto3
from constants import *
from typing import Dict, Any

def main(config: Dict[Any, Any]) -> None:
    """Main function."""
    project_name = config["project_name"]
    environment = config["environment"]

    ssh_key_name = project_name + "-" + environment
    key_path = generate_key(ssh_key_name)

    sts_client = boto3.client("sts")
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
    auto_configure_cloudformation(config, bucket_name)
    create_stack(cf_client, config["cloudformation"])

if __name__ == "__main__":
    config = configure()
    main(config)

