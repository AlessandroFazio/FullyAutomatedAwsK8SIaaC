#!/bin/bash

PROJECT_NAME=$1
ENVIRONMENT_NAME=$2
REGION=$3
SSH_KEY_PAIR_NAME=$4

./init-scripts/perform-checks.sh $PROJECT_NAME $ENVIRONMENT_NAME $REGION $SSH_KEY_PAIR_NAME

if [ $? -ne 0 ]; then
   echo "Checks failed, exited."
   exit 1
fi

AWS_ACCOUNT=$(aws sts get-caller-identity | jq -r '.Account')
BUCKET_NAME="K8S-${PROJECT_NAME}-${ENVIRONMENT_NAME}-${AWS_ACCOUNT}"

# aws s3 mb s3://$BUCKET_NAME --region $REGION
./init-scripts/set-up-ssh.sh $SSH_KEY_PAIR_NAME $BUCKET_NAME

SCRIPTS_DIR="$(pwd)/scripts"
./init-scripts/set-up-bootstrap-scripts.sh "$BUCKET_NAME" $REGION $SCRIPTS_DIR







