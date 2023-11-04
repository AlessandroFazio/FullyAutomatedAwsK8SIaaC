from docker import DockerClient 
from utils.config_utils import get_logger
from typing import Any
from docker.errors import ImageNotFound

LOGGER = get_logger()

def get_docker_image(client: DockerClient, image_name: str) -> Any:
    """Get docker image."""
    try:
        image = client.images.get(image_name)
        LOGGER.info(f"Image with name {image_name} already exists.")
        return image
    except ImageNotFound as e:
        LOGGER.info(f"Image with name {image_name} does not exist.")
        return None
    except Exception as e:
        LOGGER.error(f"An error occurred: {e}")
        exit(1)

def build_docker_image(client: DockerClient, filepath: str, image_name: str) -> Any:
    """Build docker image."""

    image = get_docker_image(client, image_name)
    if(image is not None): return image

    LOGGER.info(f"Image with name {image_name} does not exist.")
    LOGGER.info(f"Building image with name {image_name}.")
        
    try:
        image, build_log = client.images.build(path=filepath, tag=image_name)
        LOGGER.info(f"Build image: {image}")
        LOGGER.debug(f"Build log: {build_log}")
        return image
    except Exception as e:
        LOGGER.error(f"An error occurred: {e}")
        exit(1)