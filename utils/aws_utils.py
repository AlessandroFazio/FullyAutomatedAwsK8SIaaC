from typing import Dict
import os
from typing import Dict
from utils.config_utils import get_logger

LOGGER = get_logger()

def create_s3_bucket(client, bucket_name: str, region: str) -> None:
    """Create S3 bucket."""
    try:
        if(region == "us-east-1"):
            client.create_bucket(Bucket=bucket_name)
        else:
            client.create_bucket(Bucket=bucket_name, 
                                CreateBucketConfiguration={'LocationConstraint': region})
        LOGGER.info(f"Created S3 Bucket with name: {bucket_name}")
    except Exception as e:
        LOGGER.error(f"An error occurred: {e}")
        exit(1)


def upload_file_to_s3(client, bucket_name: str, file_path: str, file_key: str) -> None:
    """Upload file to S3 bucket."""
    try:
        client.upload_file(file_path, bucket_name, file_key)
        LOGGER.info(f"Uploaded file to S3 Bucket ({bucket_name}) with key: {file_key}")
    except Exception as e:
        LOGGER.error(f"An error occurred: {e}")
        exit(1)


def upload_dir_to_s3(client, bucket_name: str, base_dir: str) -> None:
    """Upload directory to S3 bucket recursively."""
    for elem in os.listdir(base_dir):
        if(os.path.isdir(os.path.join(base_dir, elem)) == False):
            file_path = os.path.join(base_dir, elem)
            upload_file_to_s3(client, bucket_name, file_path, file_path)
        else:
            upload_dir_to_s3(client, bucket_name, os.path.join(base_dir, elem))


def get_caller_identity(client) -> Dict[str, str]:
    """Get caller identity."""
    try:
        response = client.get_caller_identity()
        if(response is None):
            LOGGER.error("Response from aws sts caller identity is None.")
            raise Exception("Response is None.")
        return response
    except Exception as e:
        LOGGER.error(f"An error occurred: {e}")
        raise Exception(f"An error occurred: {e}")
    

def create_stack(client, config) -> None:
    """Start CloudFormation."""
    try:
        client.create_stack(StackName=config["StackName"],
                            TemplateURL=config["TemplateURL"],
                            Parameters=config["Parameters"])
        LOGGER.info(f"Started CloudFormation with: \
                     \n -stack name: {config['StackName']} \
                     \n -from template URL: {config['TemplateURL']}")
    except Exception as e:
        
        LOGGER.error(f"An error occurred: {e}")
        exit(1)
