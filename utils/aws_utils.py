from http import client
import re
from typing import Dict
import os
from typing import Dict
from requests import get
from utils.config_utils import get_logger
from constants import CLOUDFORMATION_CAPABILITIES
from docker import DockerClient
from utils.docker_utils import build_docker_image
import json
import base64
from botocore.exceptions import ClientError
import logging
import subprocess

LOGGER = logging.getLogger() #get_logger()

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
    check_cloudformation_capabilities(config["Capabilities"])
    try:
        client.create_stack(**config)
        LOGGER.info(f"Started CloudFormation with: \
                     \n -stack name: {config['StackName']} \
                     \n -from template URL: {config['TemplateURL']}")
    except Exception as e:
        
        LOGGER.error(f"An error occurred: {e}")
        exit(1)


def check_cloudformation_capabilities(capabilities) -> bool:
    """Check CloudFormation capabilities."""
    if(isinstance(capabilities, list) == False):
        return False
    for capability in capabilities:
        if(capability not in CLOUDFORMATION_CAPABILITIES):
            return False
    return True


def ecr_login(ecr_client) -> Dict[str, str]:
    # Authenticate the Docker client with AWS credentials

    auth_response = ecr_client.get_authorization_token()
    token = auth_response['authorizationData'][0]['authorizationToken']
    username, password = base64.b64decode(token).decode('utf-8').split(':')

    ecr_login_command = f'docker login -u {username} -p {password} \
        {auth_response["authorizationData"][0]["proxyEndpoint"]}'
    
    subprocess.call(ecr_login_command, shell=True)

def get_ecr_repository_uri(ecr_client, repository_name: str) -> Dict[str, str]:
    """Get ECR repository."""
    try:
        response = ecr_client.describe_repositories(repositoryNames=[repository_name])
        LOGGER.info(f"Got ECR repository with name: {repository_name}")
        return response['repositories'][0]['repositoryUri']
    except ecr_client.exceptions.RepositoryNotFoundException:
        LOGGER.info(f"ECR repository with name {repository_name} does not exist.")
        return None
    except ClientError as e:
        if e.response['Error']['Code'] == 'InvalidParameterException':
            LOGGER.error(f"InvalidParameterException: {e}")
            raise Exception(f"InvalidParameterException: {e}")
        elif e.response['Error']['Code'] == 'RepositoryNotFoundException':
            LOGGER.error(f"RepositoryNotFoundException: {e}")
            raise Exception(f"RepositoryNotFoundException: {e}")
        else:
            LOGGER.error(f"An error occurred: {e}")
            raise Exception(f"An error occurred: {e}")

def create_ecr_repository(ecr_client, repository_name: str) -> None:
    """Create ECR repository."""
    repository_uri = get_ecr_repository_uri(ecr_client, repository_name)
    if(repository_uri is not None): return repository_uri
    
    try:
        response = ecr_client.create_repository(repositoryName=repository_name)
        LOGGER.info(f"Created ECR repository with name: {repository_name}")
        return response
    except ecr_client.exceptions.RepositoryAlreadyExistsException:
        LOGGER.info(f"ECR repository with name {repository_name} already exists.")
        return None
    except ClientError as e:
        if e.response['Error']['Code'] == 'InvalidParameterException':
            LOGGER.error(f"InvalidParameterException: {e}")
            raise Exception(f"InvalidParameterException: {e}")
        elif e.response['Error']['Code'] == 'RepositoryAlreadyExistsException':
            LOGGER.error(f"RepositoryAlreadyExistsException: {e}")
            raise Exception(f"RepositoryAlreadyExistsException: {e}")
        else:
            LOGGER.error(f"An error occurred: {e}")
            raise Exception(f"An error occurred: {e}")


def push_to_ecr(docker_client: DockerClient, 
                ecr_client, 
                dockerfile: str,
                repository_name: str) -> None:
    """Push Docker image to AWS ECR.
    :return type: None
    """

    # create ECR repository if it does not exist and return repository URI
    repository_uri = create_ecr_repository(ecr_client, repository_name)

    # login to AWS ECR
    ecr_login(ecr_client)

    # build Docker image and tag directly for AWS ECR
    image = build_docker_image(docker_client, dockerfile, repository_uri + ':latest')
    
    # push image to AWS ECR
    push_log = docker_client.images.push(repository_uri, tag='latest')
    LOGGER.info(f"Pushed image to AWS ECR with tag: latest")
    LOGGER.debug(f"Push log: {push_log}")


def read_aws_credentials(filename: str='.aws_credentials.json') -> Dict[str, str]:
    """Read AWS credentials from file.
    
    :param filename: Credentials filename, defaults to '.aws_credentials.json'
    :param filename: str, optional
    :return: Dictionary of AWS credentials.
    :rtype: Dict[str, str]
    """

    try:
        with open(filename) as json_data:
            credentials = json.load(json_data)

        for variable in ('access_key_id', 'secret_access_key', 'region'):
            if variable not in credentials.keys():
                msg = '"{}" cannot be found in {}'.format(variable, filename)
                raise KeyError(msg)
                                
    except FileNotFoundError:
        try:
            credentials = {
                'access_key_id': os.environ['AWS_ACCESS_KEY_ID'],
                'secret_access_key': os.environ['AWS_SECRET_ACCESS_KEY'],
                'region': os.environ['AWS_REGION']
            }
        except KeyError:
            msg = 'no AWS credentials found in file or environment variables'
            raise RuntimeError(msg)

    return credentials

