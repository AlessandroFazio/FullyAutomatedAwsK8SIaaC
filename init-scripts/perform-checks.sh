#!/bin/bash

PROJECT_NAME=$1
ENVIRONMENT_NAME=$2
REGION=$3
SSH_KEY_PAIR_NAME=$4

if [ -z "$PROJECT_NAME" ]; then
   echo "Project name not provided, exiting ..."
   exit 1
fi

if [ -z "$ENVIRONMENT_NAME" ]; then
   echo "Environment name not provided, exiting ..."
   exit 1
fi

if [ -z "$REGION" ]; then
   echo "AWS region not provided, exiting ..."
   exit 1
fi

if [ -z "$SSH_KEY_PAIR_NAME" ]; then
   echo "SSH key pair name not provided, exiting ..."
   exit 1
fi

if [ -z "$(aws --version)" ]; then
   echo "AWS CLI not found, you need to install it first. Exiting ..."
   exit 1
fi