#!/bin/bash

KEY_PAIR_NAME=$1
BUCKET_NAME=$2

# Create SSH key pair with desired name
ssh-keygen -t rsa -b 2048 -f ~/.ssh/${KEY_PAIR_NAME} -N ""

# Upload public key to S3
aws s3 cp ~/.ssh/${KEY_PAIR_NAME}.pub s3://${BUCKET_NAME}/ssh/client-key.pub

