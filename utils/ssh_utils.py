import subprocess
import logging

def generate_key(key_name: str) -> str:
    """Generate SSH key."""
    key_path = "~/.ssh/" + key_name
    try:
        subprocess.run(
            ["ssh-keygen", "-t", "rsa", "-b", "2048", "-f", key_path, "-N", ""], check=True)
        logging.info(f"Generated SSH key with path: {key_path}")
        return key_path
    except Exception as e:
        logging.error(f"An error occurred: {e}")
        exit(1)