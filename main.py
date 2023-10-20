from utils.config_utils import (
    configure, 
    auto_configure_cloudformation, 
    get_logger
)
from utils.aws_utils import (
    get_caller_identity,
    create_s3_bucket,
    upload_file_to_s3,
    upload_dir_to_s3,
    create_stack
)
from utils.ssh_utils import generate_key
import boto3
import os
from constants import *
from typing import Dict, Any

def main(config: Dict[Any, Any]) -> None:
    """Main function."""
    LOGGER = get_logger()

    project_name = config["project"]["name"]
    environment_name = config["project"]["environment"]["name"]
    region = config["project"]["environment"]["region"]

    ssh_key_name =  project_name + "-" + environment_name
    ssh_key_path = os.path.expanduser("~/.ssh/" + ssh_key_name)
    generate_key(ssh_key_name)

    sts_client = boto3.client("sts")
    caller_identity = get_caller_identity(sts_client)
    account = caller_identity["Account"]
    
    LOGGER.info(f"Caller Identity -> AWS Account: {account}")
    LOGGER.info(f"Caller Identity -> AWS Region: {region}")

    s3_client = boto3.client("s3", region)
    bucket_name = f"k8s-{project_name}-{environment_name}-{region}-{account}"

    create_s3_bucket(s3_client, bucket_name, region)
    upload_file_to_s3(s3_client, bucket_name, ssh_key_path + ".pub", "client-key.pub")
    upload_dir_to_s3(s3_client, bucket_name, SCRIPTS_DIR)
    upload_dir_to_s3(s3_client, bucket_name, TEMPLATES_DIR)
    
    cf_client = boto3.client("cloudformation", region)
    auto_configure_cloudformation(config, bucket_name)
    create_stack(cf_client, config["cloudformation"])

if __name__ == "__main__":
    config = configure()
    LOGGER = get_logger()
    main(config)

