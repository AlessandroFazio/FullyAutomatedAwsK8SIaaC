from utils.config_utils import (
    configure, 
    auto_configure_cloudformation, 
    get_logger
)
from utils.aws_utils import (
    get_caller_identity,
    create_s3_bucket,
    push_to_ecr,
    upload_file_to_s3,
    upload_dir_to_s3,
    create_stack,
    upload_to_secret_manager,
)
from utils.ssh_utils import generate_key
import uuid
import boto3
from docker import DockerClient
import os
from constants import *
from typing import Dict, Any

def main(config: Dict[Any, Any]) -> None:
    """Main function."""

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
    upload_file_to_s3(s3_client, bucket_name, ssh_key_path + ".pub", "ssh/client-key.pub")
    upload_dir_to_s3(s3_client, bucket_name, SCRIPTS_DIR)
    upload_dir_to_s3(s3_client, bucket_name, TEMPLATES_DIR)
    
    docker_client = DockerClient.from_env()
    ecr_client = boto3.client('ecr', region_name='us-east-1')
    repository_name = f"{project_name}/{environment_name}/lambda/dbbootstrap"
    image_uri = push_to_ecr(docker_client, ecr_client, f"{LAMBDA_DIR}/dbbootstrap", repository_name)

    secrets_manager_client = boto3.client("secretsmanager", region)
    upload_to_secret_manager(secrets_manager_client, KEYCLOAK_ADMIN_PWD_SECRET_ID, str(uuid.uuid4()))

    cf_client = boto3.client("cloudformation", region)
    kc_cache_bucket_name = f"keycloak-cache-{project_name}-{environment_name}-{region}-{account}"
    auto_configure_cloudformation(config, bucket_name, kc_cache_bucket_name, image_uri)
    create_stack(cf_client, config["cloudformation"])

if __name__ == "__main__":
    config = configure()
    LOGGER = get_logger()
    main(config)
    


