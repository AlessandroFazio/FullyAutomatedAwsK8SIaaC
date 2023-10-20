from argparse import ArgumentParser
from typing import Dict, Any
import logging
import logging.config
import yaml
import os

from constants import DEFAULT_CONFIG, TEMPLATES_DIR

def parse_args() -> Dict[str, str]:
    """Parse command line arguments."""
    parser = ArgumentParser(
        description="High Availability AWS self-managed Kubernetes cluster deployment helper", 
        add_help=True) 
    parser.add_argument("-c", "--config", help="Path to config file", default="config/default.yaml")
    args = parser.parse_args()
    return vars(args)


def parse_cloudformation_config(cloudformation_config: Dict[str, Any]) -> Dict[str, Any]:
    config_dict = {}

    for key,value in cloudformation_config.items():
        if(key == "StackName"):
            config_dict[key] = value
        elif(key == "TemplateURL"):
            config_dict[key] = value
        elif(key == "Parameters"):
            config_dict[key] = parse_cloudformation_parameters(value)
        elif(key == "Capabilities"):
            config_dict[key] = value
        else:
            print(Warning("Invalid cloudformation config key: {}".format(key)))
    
    return config_dict


def parse_cloudformation_parameters(cloudformation_parameters: Dict[str, Any]) -> Dict[str, Any]:
    cf_params = []
    i = 0
    if(cloudformation_parameters is None): return cf_params
    for key,value in cloudformation_parameters.items():
        cf_params[i] = {
            "ParameterKey": key,
            "ParameterValue": value
        }
        i += 1
    return cf_params


def generate_cloudformation_parameters(key: str, value: str) -> Dict[str, Any]:
    return {
        "ParameterKey": key,
        "ParameterValue": value
    }


def auto_configure_cloudformation(config: Dict[str, Any], bucket_name: str) -> None:
    """Auto configure cloudformation."""

    config["cloudformation"]["Parameters"].append(
        generate_cloudformation_parameters("EnvironmentName", 
                                           config["project"]["environment"]["name"]))

    config["cloudformation"]["Parameters"].append(
        generate_cloudformation_parameters("ProjectName", config["project"]["name"]))
    
    config["cloudformation"]["Parameters"].append(
        generate_cloudformation_parameters("S3BucketName", bucket_name))
    
    config["cloudformation"]["TemplateURL"] = \
        f"https://s3.amazonaws.com/{bucket_name}/{TEMPLATES_DIR}/main.yaml"


def parse_default_config() -> Dict[str, Any]:
    """Parse config file."""
    with open(DEFAULT_CONFIG, "r") as f:
        default_config = yaml.load(f, Loader=yaml.FullLoader)
    return default_config


def parse_user_config(filePath: str) -> Dict[str, Any]:
    """Parse user config file."""
    with open(filePath, "r") as f:
        user_config = yaml.load(f, Loader=yaml.FullLoader)
    return user_config


def merge_configs(default_config: Dict[str, Any], user_config: Dict[str, Any]) -> Dict[str, Any]:
    """Merge default and user configs."""
    for key,value in user_config.items():
        if(isinstance(value, dict)):
            default_config[key] = merge_configs(default_config.get(key, {}), value)
        else:
            default_config[key] = value
    return default_config


def parse_config(config_path: str) -> Dict[str, Any]:
    """Parse config file."""
    default_config = parse_default_config()
    
    if(config_path is None or config_path == "" or config_path == DEFAULT_CONFIG):
        return default_config
    
    if(os.path.exists(config_path) == False):
        raise Exception(f"Config file does not exist at path {config_path}.")
    
    user_config = parse_user_config(config_path)
    config = merge_configs(default_config, user_config)
    return config


def configure():
    """Configure the program."""
    args = parse_args()
    config = parse_config(args["config"])
    logging.config.dictConfig(config["logging"])
    config["cloudformation"] = parse_cloudformation_config(config["cloudformation"])
    return config

def get_logger():
    logger = logging.getLogger("root")
    if logger is None:
        raise Exception("Logger is None. The logging config allows only for one logger with name 'root'.")
    return logger