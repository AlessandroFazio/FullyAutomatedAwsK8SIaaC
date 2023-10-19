from argparse import ArgumentParser
from typing import Dict, Any
import logging
import yaml

def parse_args() -> Dict[str, str]:
    """Parse command line arguments."""
    parser = ArgumentParser(description="High Availability AWS self-managed Kubernetes cluster deployment helper") 
    parser.add_argument("-p", "--project-name", type=str, required=True, help="Project name")
    parser.add_argument("-e", "--environment", type=str, required=True, help="Project environment")
    parser.add_argument("-key-name", "--ssh-key-name", type=str, required=True, help="Verbose output")
    parser.add_argument("-lc", "--logging-config", type=str, help="Logging config file")
    parser.add_argument("-kube-conf", "--kubernetes-config", required=True, type=str, help="Kubernetes config file")
    parser.add_argument("-aws-conf", "--aws-config", type=str, required=True, help="AWS config file")
    args = parser.parse_args()
    return vars(args)

def configure_logging(filePath: str) -> None:
    """Get logging configuration."""
    if(filePath is None):
        configure_logging_default()
        return
    
    with open(filePath, "r") as f:
        logging_config = yaml.load(f, Loader=yaml.FullLoader)
    logging.basicConfig(**parse_logging_config(logging_config))
    

def parse_logging_config(config: Dict[str, str]) -> Dict[str, Any]:
    config_dict = {}
    for key,value in config.items():
        if(key == "level"):
            if(value == "DEBUG"):
                config_dict[key] = logging.DEBUG
            elif(value == "INFO"):
                config_dict[key] = locals.INFO
            elif(value == "WARNING"):
                config_dict[key] = logging.WARNING
            elif(value == "ERROR"):
                config_dict[key] = logging.ERROR
            elif(value == "CRITICAL"):
                config_dict[key] = logging.CRITICAL
            else:
                config_dict[key] = logging.INFO
        elif (key == "format"):
            config_dict[key] = value
        elif (key == "handlers"):
            config_dict[key] = []
            for handler in value:
                if(handler == "console"):
                    config_dict[key].append(logging.StreamHandler())
                elif(handler == "file"):
                    config_dict[key].append(logging.FileHandler())
                else:
                    config_dict[key].append(logging.StreamHandler())
        else:
            raise Warning("Invalid logging config key: {}".format(key))
    
    return config_dict


def configure_logging_default() -> None:
    """Configure logging with default values."""
    logging.basicConfig(level=logging.INFO,
                        format="%(asctime)s - %(levelname)s - %(message)s",
                        handlers=[logging.StreamHandler()])
    

def parse_aws_config(filePath: str) -> Dict[str, str]:
    """Parse AWS config file."""
    with open(filePath, "r") as f:
        aws_config = yaml.load(f, Loader=yaml.FullLoader)
    return aws_config
            

