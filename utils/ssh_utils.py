import subprocess
from utils.config_utils import get_logger
import os

LOGGER = get_logger()

def generate_key(key_path: str) -> str:
    """Generate SSH key."""
    try:
        subprocess.run(
            ["ssh-keygen", "-t", "rsa", "-b", "2048", "-f", key_path, "-N", ""], check=True)
        LOGGER.info(f"Generated SSH key with path: {key_path}")
    except subprocess.CalledProcessError as e:
        LOGGER.error(f"An error occurred while generating SSH key: {e}")
        exit(1)