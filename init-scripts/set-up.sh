#!/bin/bash

if [ -z "$(aws --version)" ]; then
   echo "AWS CLI not found, you need to install it first. Exiting ..."
   exit 1
fi

S3_BUCKET=$1
REGION=$2

if [ -z "$S3_BUCKET" ]; then
   echo "S3 bucket name not provided, exiting ..."
   exit 1
fi

if [ -z "$REGION" ]; then
   echo "AWS region not provided, exiting ..."
   exit 1
fi

if [ "$REGION" == "us-east-1" ]; then
   aws s3api create-bucket --bucket "$S3_BUCKET" --region "$REGION"
else
   aws s3api create-bucket --bucket "$S3_BUCKET" --region "$REGION" --create-bucket-configuration LocationConstraint="$REGION"
fi

aws s3api put-bucket-versioning --bucket "$S3_BUCKET" --versioning-configuration Status=Enabled
aws s3 




