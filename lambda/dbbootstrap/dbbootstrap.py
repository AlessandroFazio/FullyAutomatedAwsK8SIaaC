import subprocess
import boto3
import logging
import os
import sys
from botocore.exceptions import ClientError
import json
import requests

from dbbootstrap.constants import *
from dbbootstrap.exceptions import *

logger = logging.getLogger()
logger.setLevel(logging.INFO)

DBHOST = os.environ['DBHost']
DBPORT = os.environ['DBPort']
DBNAME = os.environ['DBName']
DBUSER = os.environ['DBUser']
SECRET_ARN = os.environ['Secret_ARN']
REGION_NAME = os.environ['Region_Name'] 
SQL_SCRIPT_S3_BUCKET = os.environ['SQLScriptS3Bucket']
SQL_SCRIPT_S3_KEY = os.environ['SQLScriptS3Key']

def handler(event, context):
    try:
        responseData = {}
        if is_instance_started_event(event):
            
            try:
                DBPASS = get_secret(SECRET_ARN,REGION_NAME)
                get_global_certificates(CERTS_URL, CERTS_FILEPATH)
                get_sql_script_from_s3(SQL_SCRIPT_S3_BUCKET, SQL_SCRIPT_S3_KEY, SQL_FILEPATH)
                responseData = execute_sql(SQL_FILEPATH, DBPASS, CERTS_FILEPATH, responseData)
                return responseData
               
            except GetSecretException as e:
                logger.error('Exception: ' + str(e))
                logger.error("ERROR: Unexpected error: Couldn't retrieve secret from AWS SecretManager.")
                responseData['Data'] = "ERROR: Unexpected error: Couldn't retrieve secret from AWS SecretManager."
                sys.exit()

            except GetGlobalCertificatesException as e:
                logger.error('Exception: ' + str(e))
                logger.error("ERROR: Unexpected error: Couldn't download global certificates.")
                responseData['Data'] = "ERROR: Unexpected error: Couldn't download global certificates."
                sys.exit()
 
            except GetSQLScriptException as e:
                logger.error('Exception: ' + str(e))
                logger.error("ERROR: Unexpected error: Couldn't download SQL script from S3.")
                responseData['Data'] = "ERROR: Unexpected error: Couldn't download SQL script from S3."
                sys.exit()
            
            except ExecuteSQLScriptException as e:
                logger.error('Exception: ' + str(e))
                logger.error("ERROR: Unexpected error: Failed to execute SQL script.")
                responseData['Data'] = "ERROR: Unexpected error: Failed to execute SQL script."
                sys.exit()
        else:
            responseData['Data'] = "\n{} is unsupported event type".format(event['Records'][0]['Sns']['Message'])
    
    except Exception as e:
        logger.exception('Exception: ' + str(e))
        responseData['Data'] = "ERROR: Unexpected error: Couldn't connect to Aurora PostgreSQL instance."
        sys.exit()

def is_instance_started_event(event):
    sns_message = json.loads(event['Records'][0]['Sns']['Message'])
    
    # Extract the 'EventID' from the message attributes
    message_attributes = sns_message.get('MessageAttributes', {})
    event_id_attribute = message_attributes.get('EventID', {})

    # Extract the value from the 'EventID' message attribute
    event_id = event_id_attribute.get('Value', None)

    if event_id == INSTANCE_STARTED_EVENT_ID:
        logger.info("Received instance started event: " + str(event))
        return True
    
    logger.info("Received event: " + str(event) + " is not an instance started event")
    return False

def get_secret(secret_arn,region_name):

    # Create a Secrets Manager client
    session = boto3.session.Session()
    client = session.client(
        service_name='secretsmanager',
        region_name=region_name
    )
    logger.info("Retrieving secret from AWS SecretManager")
    try:
        get_secret_value_response = client.get_secret_value(
            SecretId=secret_arn
        )
    except ClientError as e:
        if e.response['Error']['Code'] == 'DecryptionFailureException':
            logger.error("Secrets Manager can't decrypt the protected secret text using the provided KMS key")
        elif e.response['Error']['Code'] == 'InternalServiceErrorException':
            logger.error("An error occurred on the server side")
        elif e.response['Error']['Code'] == 'InvalidParameterException':
            logger.error("You provided an invalid value for a parameter")
        elif e.response['Error']['Code'] == 'InvalidRequestException':
            logger.error("You provided a parameter value that is not valid for the current state of the resource")
        elif e.response['Error']['Code'] == 'ResourceNotFoundException':
            logger.error("We can't find the resource that you asked for")
        raise GetSecretException("ERROR: Unexpected error: Couldn't retrieve secret from AWS SecretManager. Exception: " + str(e))
    else:
        # Decrypts secret using the associated KMS CMK.
        secret = json.loads(get_secret_value_response['SecretString'])['password']
        logger.info("Retrieved secret from AWS SecretManager successfully")
        return secret

def get_sql_script_from_s3(sql_script_s3_bucket, sql_script_s3_key, local_sql_filepath):
    s3 = boto3.client('s3')
    try:
        s3.download_file(sql_script_s3_bucket, sql_script_s3_key, local_sql_filepath)
        logger.info("Downloaded SQL script successfully from S3 bucket: " + sql_script_s3_bucket + " and key: " 
                    + sql_script_s3_key)
        os.chmod(SQL_FILEPATH, 0o600) # Change file permissions to make it readable only by the owner
    
    except ClientError as e:
        logger.error('Exception: ' + str(e))
        logger.error("ERROR: Unexpected error: Failed to download SQL script from S3 bucket: " 
                     + sql_script_s3_bucket + " and key: " + sql_script_s3_key)
        raise GetSQLScriptException("ERROR: Unexpected error: Failed to download SQL script from S3 bucket: " 
                                    + sql_script_s3_bucket + " and key: " + sql_script_s3_key + ". Exception: " + str(e))

def get_global_certificates(certs_url, certs_filepath):
    
    try:
        logger.info("Downloading global certificates from: " + certs_url)
        response = requests.get(certs_url)
        response.raise_for_status()  # Raise an error for HTTP errors

        with open(certs_filepath, 'wb') as cert_file:
            cert_file.write(response.content)

        # Change file permissions to make it readable by everyone
        os.chmod(certs_filepath, 0o644)

        logger.info("Downloaded global certificates successfully")
    except requests.exceptions.RequestException as e:
        logger.error('Exception: ' + str(e))
        logger.error("ERROR: Unexpected error: Failed to download global certificates from: " + certs_url)
        raise GetGlobalCertificatesException("ERROR: Unexpected error: Failed to download global certificates from: " 
                                             + certs_url + ". Exception: " + str(e))   
    
def execute_sql(sql, dbpass, certs_filepath, responseData):
    try:
        psql_command = [
            '/usr/bin/psql',
            '-h', DBHOST,
            '-p', DBPORT,
            '-U', DBUSER,
            '-d', DBNAME,
            '-f', sql,
            '-v', 
            'ON_ERROR_STOP=1', 
            '--set=sslmode=verify-ca',
            '--set=sslrootcert=' + certs_filepath
        ]

        env = {
            'PGPASSWORD': dbpass
        }

        logger.info("Executing psql command: " + str(psql_command))
        logger.info("with env: " + str(env))

        result = subprocess.run(psql_command, env=env, check=True, capture_output=True, text=True)
        
        logger.info("Executed SQL script successfully.")
        logger.info("result in stdout: " + result.stdout)
        responseData['Data'] = f"\n{result.stdout}"

    except subprocess.CalledProcessError as e:
        logger.error('Exception: ' + str(e))
        logger.error("ERROR: Unexpected error: Failed to execute psql command.")
        responseData['Data'] += f"\nERROR: Unexpected error: Failed to execute psql command."
        raise ExecuteSQLScriptException("ERROR: Unexpected error: Failed to execute psql command. Exception: " + str(e))
    return responseData