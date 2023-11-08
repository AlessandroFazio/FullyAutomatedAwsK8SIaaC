#!/bin/bash 

# Set -e to exit on error and -x to print each command
set -xe

function check_required_args() {
    local args=("$@")

    for arg in "${args[@]}"; do
        if [ -z "${!arg}" ]; then
            echo "${arg} is required"
            exit 1
        fi
    done
}

function set_hostname() {
    local hostname=$1
    sudo hostnamectl set-hostname "${hostname}" --static
    sudo bash -c "echo -e '\n127.0.0.1 ${hostname}' >> /etc/hosts"
}

function install_and_configure_utils() {
    sudo apt update -y
    sudo apt install -y jq
    sudo apt install -y unzip
    sudo apt install -y openjdk-17-jre
    sudo apt install -y openjdk-17-jdk

    export JAVA_HOME=/usr/lib/jvm/java-1.17.0-openjdk-amd64
    export PATH=$JAVA_HOME/bin:$PATH
    java --version
    echo $JAVA_HOME

    curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
    unzip awscliv2.zip
    sudo ./aws/install

    aws --version
}

function install_ec2stack_plugins() {
    local plugin_download_path=$1

    wget https://repo1.maven.org/maven2/org/jgroups/aws/jgroups-aws/2.0.1.Final/jgroups-aws-2.0.1.Final.jar \
    -O "${plugin_download_path}/jgroups-aws-2.0.1.Final.jar"

    wget https://repo1.maven.org/maven2/com/amazonaws/aws-java-sdk-core/1.12.576/aws-java-sdk-core-1.12.576.jar \
        -O "${plugin_download_path}/aws-java-sdk-core-1.12.576.jar"

    wget https://repo1.maven.org/maven2/com/amazonaws/aws-java-sdk-s3/1.12.576/aws-java-sdk-s3-1.12.576.jar \
        -O "${plugin_download_path}/aws-java-sdk-s3-1.12.576.jar"

    wget https://repo1.maven.org/maven2/joda-time/joda-time/2.12.4/joda-time-2.12.4.jar \
        -O "${plugin_download_path}/joda-time-2.12.4.jar"
}

function install_db_iam_auth_plugins() {
    local plugin_download_path=$1
    local aws_jdbc_driver_version=$2
    local aws_sdk_version=$3
    local aws_sdk_packages=("${@:4}")

    wget https://repo1.maven.org/maven2/software/amazon/jdbc/aws-advanced-jdbc-wrapper/${aws_jdbc_driver_version}/aws-advanced-jdbc-wrapper-${aws_jdbc_driver_version}.jar \
    -O "${plugin_download_path}/aws-advanced-jdbc-wrapper-${aws_jdbc_driver_version}.jar"

    for package in "${aws_sdk_packages[@]}"; do
        local url="https://repo1.maven.org/maven2/software/amazon/awssdk/${package}/${aws_sdk_version}/${package}-${aws_sdk_version}.jar"
        local jar_file="${plugin_download_path}/${package}-${aws_sdk_version}.jar"
        wget $url -O $jar_file
    done
}   

function install_keycloak() {
    local keycloak_version=$1
    wget https://github.com/keycloak/keycloak/releases/download/${keycloak_version}/keycloak-${keycloak_version}.zip \
    -O keycloak-${keycloak_version}.zip
}

function install_packages() {
    local keycloak_version=$1
    local plugin_download_path=$2
    local aws_jdbc_driver_version=$3
    local aws_sdk_version=$4
    local aws_sdk_packages=("${@:5}")

    sudo mkdir -p ${plugin_download_path}
    sudo chown -R ubuntu:ubuntu ${plugin_download_path}

    install_and_configure_utils
    install_ec2stack_plugins "${plugin_download_path}"
    install_db_iam_auth_plugins \
        "${plugin_download_path}" \
        "${aws_jdbc_driver_version}" \
        "${aws_sdk_version}" \
        "${aws_sdk_packages[@]}"
    install_keycloak "${keycloak_version}"
}

function get_rds_glocal_cacert() {
    local certs_download_path=$1
    local aws_region=$2
    wget https://truststore.pki.rds.amazonaws.com/${aws_region}/${aws_region}-bundle.pem \
    -O "${certs_download_path}/${aws_region}-bundle.pem"
}

function create_user_and_group() {
    local user=$1
    local user_home=$2
    sudo groupadd ${user}
    sudo useradd -r -g ${user} -d ${user_home} -s /sbin/nologin keycloak
}

function setup_keycloak_dirs() {
    local user=$1
    local group=$user
    local keycloak_version=$2
    local aws_region=$3
    local plugin_download_path=$4
    local certs_download_path=$5

    # Set directory paths
    local keycloak_dir="/opt/keycloak-${keycloak_version}"
    local keycloak_log_dir="${keycloak_dir}/log"
    local keycloak_data_dir="${keycloak_dir}/data"
    local keycloak_export_dir="${keycloak_dir}/export"
    local keycloak_import_dir="${keycloak_dir}/import"
    local keycloak_certs_dir="${keycloak_dir}/certs"
    local keycloak_keystores_dir="${keycloak_dir}/keystores"
    local keycloak_keys_dir="${keycloak_dir}/keys"
    local keycloak_config_dir="/etc/keycloak-${keycloak_version}"

    # unzip keycloak
    unzip keycloak-${keycloak_version}.zip -d /opt/

    # Create and set permissions for directories
    sudo chown -R ${user}:${group} "${keycloak_dir}"

    sudo mkdir -p ${keycloak_log_dir}
    sudo touch "${keycloak_log_dir}/keycloak.log"

    sudo mkdir -p "${keycloak_export_dir}"
    sudo mkdir -p "${keycloak_import_dir}"

    sudo mkdir -p "${keycloak_certs_dir}"
    sudo mv "${certs_download_path}/${aws_region}-bundle.pem" "${keycloak_certs_dir}/"
    sudo chmod 644 "${keycloak_certs_dir}/${aws_region}-bundle.pem"

    sudo mkdir -p "${keycloak_keystores_dir}"
    sudo mkdir -p "${keycloak_keys_dir}"

    sudo mkdir -p "${keycloak_config_dir}"
    sudo chown -R ${user}:${group} "${keycloak_config_dir}"

    for jar_file in $(ls ${plugin_download_path}/*.jar); do
        sudo cp $jar_file "${keycloak_dir}/providers/"
    done
}

function get_keycloak_admin_password() {
    local keycloak_admin_password_secret_id=$1
    local keycloak_admin_password=$(aws secretsmanager get-secret-value \
        --secret-id ${keycloak_admin_password_secret_id} \
        --query SecretString \
        --output text)

    if [ -z "$keycloak_admin_password" ]; then
        echo "keycloak_admin_password is empty. Exiting..."
        exit 1
    fi

    echo $keycloak_admin_password
}

function create_keycloak_service_envfile() {
    local keycloak_version=$1
    local frontend_proxy_dns=$2
    local db_schema=$3
    local db_name=$4
    local db_host=$5
    local db_port=$6
    local db_user=$7
    local db_url_properties=$8
    local aws_region=$9
    local s3_bucket_name=${10}
    local keycloak_admin_password_secret_id=${11}
    local keycloak_admin_password=$(get_keycloak_admin_password ${keycloak_admin_password_secret_id})

    cat <<EOF | sudo tee "/etc/keycloak-${keycloak_version}/keycloak.env"
KC_CACHE_STACK=ec2
KC_HTTPS_CLIENT_AUTH=None
KC_HTTP_RELATIVE_PATH=/
KC_HTTPS_PORT=8443
KC_HTTP_ENABLED=true
KC_HTTP_HOST=$(hostname -I | awk '{print $1}')
KC_HTTP_PORT=8080
KC_HEALTH_ENABLED=true
KC_METRICS_ENABLED=true
KC_PROXY=edge
PROXY_ADDRESS_FORWARDING=true
KC_DIR="/opt/keycloak/export"
KC_HOSTNAME_STRICT=true
KC_HOSTNAME_URL=https://${frontend_proxy_dns}
KEYCLOAK_ADMIN=admin
KEYCLOAK_ADMIN_PASSWORD=${keycloak_admin_password}
KC_HOSTNAME_ADMIN_URL=https://${frontend_proxy_dns}
DB_NAME=${db_name} 
DB_HOST=${db_host}
DB_PORT=${db_port}
DB_URL_PROPERTIES=${db_url_properties}
KC_DB_URL=jdbc:aws-wrapper:postgresql://${db_host}:${db_port}/${db_name}?${db_url_properties}
KC_DB=postgres
KC_DB_DRIVER=software.amazon.jdbc.Driver
KC_DB_SCHEMA=${db_schema}
#KC_DB_USERNAME=${db_user}
KC_TRANSACTION_XA_ENABLED=false
JAVA_OPTS_APPEND=-Djgroups.s3.region_name=${aws_region} -Djgroups.s3.bucket_name=${s3_bucket_name}
KC_LOG=console,file
KC_LOG_CONSOLE_COLOR=true
KC_LOG_FILE=/opt/keycloak/log/keycloak.log
KC_LOG_LEVEL=info
EOF
}

function get_realms_from_s3() {
    local s3_bucket_name=$1
    local import_dir=$2
    local user=$3
    sudo -u ${user} aws s3 cp s3://${s3_bucket_name}/keycloak/realms/ ${import_dir} --recursive
}

function create_keycloak_service() {
    local keycloak_version=$1
    local aws_region=$2

    cat <<EOF | sudo tee /etc/systemd/system/keycloak.service
[Unit]
Description=Keycloak Authorization Server
After=network.target

[Service]
User=keycloak
Group=keycloak
EnvironmentFile=/etc/keycloak-${keycloak_version}/keycloak.env
ExecStart=/opt/keycloak-${keycloak_version}/bin/kc.sh start --import-realm 
Restart=always
RestartSec=5
LimitNOFILE=102642
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
}

function start_keycloak_service() {
    sudo systemctl daemon-reload
    sudo systemctl enable keycloak
    sudo systemctl start keycloak
}

# Function to wait for resources to become available
function wait_for_resources() {
  local timeout="$1"
  local message="$2"
  local check_command="$3"
  
  timeout "${timeout}" bash -c \
    "until ${check_command}; do printf '.'; sleep 5; done"
}

function create_privkey() {
    local key_filename=$1
    local user=$2
    openssl genpkey -algorithm RSA -out ${key_filename}
    sudo chmod 600 ${key_filename}
    sudo chown ${user}:${user} ${key_filename}
}

function upload_privkey_to_realm() {
    local user=$1
    local keycloak_dir=$2
    local privkey_filename=$3
    local realm_name=$4
    local frontend_proxy_dns=$5
    local keycloak_admin_password_secret_id=$6
    local keycloak_admin_password=$(get_keycloak_admin_password ${keycloak_admin_password_secret_id})
    
    create_privkey ${privkey_filename} ${user}
    local privkey=$(sudo -u ${user} cat ${privkey_filename})
    frmt_privkey=$(awk '/-----BEGIN PRIVATE KEY-----/{p=1; next} /-----END PRIVATE KEY-----/{p=0} p' ${privkey} | tr -d '\n')

    sudo -u ${user} ${keycloak_dir}/bin/kcadm.sh create components \
        -r ${realm_name} \
        -s name=rsa \
        -s providerId=rsa \
        -s providerType=org.keycloak.keys.KeyProvider \
        -s config.privateKey=[\"${frmt_privkey}\"] \
        -s config.priority=["150"] \
        --server "${frontend_proxy_dns}:443" \
        --user admin \
        --password "${keycloak_admin_password}"
}

function upload_privkey_to_sm() {
    local user=$1
    local privkey_filename=$2
    local secret_id=$3

    sudo -u ${user} aws secretsmanager create-secret \
        --name "${secret_id}" \
        --secret-string file://${privkey_filename}

    if [ $? -eq 0 ]; then
        echo "Private key uploaded successfully."
    else
        echo "Command encountered an error. Exiting..."
        exit 1
    fi
}

function create_privkey_and_upload_to_sm() {
    local user=$1
    local keycloak_dir=$2
    local privkey_filename=$3
    local realm_name=$4
    local frontend_proxy_dns=$5
    local secret_id=$6
    local keycloak_admin_password_secret_id=$7
    local keycloak_admin_password=$(get_keycloak_admin_password ${keycloak_admin_password_secret_id})

    upload_privkey_to_realm \
        ${user} \
        ${keycloak_dir} \
        ${privkey_filename} \
        ${realm_name} \
        ${frontend_proxy_dns} \
        ${keycloak_admin_password_secret_id}

    upload_privkey_to_sm \
        ${user} \
        ${privkey_filename} \
        ${secret_id}

    sudo rm -f ${privkey_filename}
}

function scale_keycloak_asg() {
    local keycloak_asg_name=$1
    local keycloak_asg_desired_capacity=$2

    aws autoscaling set-desired-capacity \
        --auto-scaling-group-name ${keycloak_asg_name} \
        --desired-capacity ${keycloak_asg_desired_capacity}

    if [ $? -eq 0 ]; then
        echo "Keycloak ASG scaled successfully."
    else
        echo "Command encountered an error. Exiting..."
        exit 1
    fi
}

### MAIN ###
# Usage: ./first-node.sh <KEYCLOAK_VERSION> <FRONTEND_PROXY_DNS> <DB_SCHEMA> <DB_NAME> <DB_HOST> <DB_PORT> <DB_USER> <AWS_REGION> <S3_BUCKET_NAME> <KEYCLOAK_ASG_NAME> <KEYCLOAK_ASG_DESIRED_CAPACITY> <KEYCLOAK_ADMIN_PASSWORD_SECRET_ID> <K8S_KEY_SECRET_ID>
KEYCLOAK_VERSION=${1}
FRONTEND_PROXY_DNS=${2}
DB_SCHEMA=${3}
DB_NAME=${4}
DB_HOST=${5}
DB_PORT=${6}
DB_USER=${7}
AWS_REGION=${8}
S3_BUCKET_NAME=${9}
KEYCLOAK_ASG_NAME=${10}
KEYCLOAK_ASG_DESIRED_CAPACITY=${11}
KEYCLOAK_ADMIN_PASSWORD_SECRET_ID=${12}
K8S_KEY_SECRET_ID=${13}

required_args=(
    KEYCLOAK_VERSION
    FRONTEND_PROXY_DNS
    DB_SCHEMA
    DB_NAME
    DB_HOST
    DB_PORT
    DB_USER
    AWS_REGION
    S3_BUCKET_NAME
    KEYCLOAK_ASG_NAME
    KEYCLOAK_ASG_DESIRED_CAPACITY
    KEYCLOAK_ADMIN_PASSWORD_SECRET_ID
    K8S_KEY_SECRET_ID
)

# Constants
HOSTNAME="keycloak"
USER="keycloak"
USER_HOME="/opt/keycloak"
KEYCLOAK_DIR="/opt/keycloak-${KEYCLOAK_VERSION}"
CERTS_DOWNLOAD_PATH="/tmp/certs"
PLUGIN_DOWNLOAD_PATH="/tmp/keycloak"
AWS_JDBC_DRIVER_VERSION="2.2.2"
AWS_SDK_VERSION="2.20.107"
AWS_SDK_PACKAGES=(
    "apache-client"
    "auth"
    "aws-core"
    "aws-json-protocol"
    "aws-query-protocol"
    "endpoints-spi"
    "http-client-spi"
    "json-utils"
    "metrics-spi"
    "profiles"
    "protocol-core"
    "rds"
    "regions"
    "sdk-core"
    "sts"
    "third-party-jackson-core"
    "utils"
)
DB_URL_PROPERTIES="wrapperPlugins=iam&ssl=true&sslmode=verify-ca&sslrootcert=${KEYCLOAK_DIR}/certs/${AWS_REGION}-bundle.pem"
KUBERNETES_REALM_NAME="kubernetes"


check_required_args "${required_args[@]}"
set_hostname "${HOSTNAME}"

install_packages \
    "${KEYCLOAK_VERSION}" \
    "${PLUGIN_DOWNLOAD_PATH}" \
    "${AWS_JDBC_DRIVER_VERSION}" \
    "${AWS_SDK_VERSION}" \
    "${AWS_SDK_PACKAGES[@]}"

get_rds_glocal_cacert "${CERTS_DOWNLOAD_PATH}" "${AWS_REGION}"
create_user_and_group "${USER}" "${USER_HOME}"

setup_keycloak_dirs \
    "${USER}" \
    "${KEYCLOAK_VERSION}" \
    "${AWS_REGION}" \
    "${PLUGIN_DOWNLOAD_PATH}" \
    "${CERTS_DOWNLOAD_PATH}"

create_keycloak_service_envfile \
    "${KEYCLOAK_VERSION}" \
    "${FRONTEND_PROXY_DNS}" \
    "${DB_SCHEMA}" \
    "${DB_NAME}" \
    "${DB_HOST}" \
    "${DB_PORT}" \
    "${DB_USER}" \
    "${DB_URL_PROPERTIES}" \
    "${AWS_REGION}" \
    "${S3_BUCKET_NAME}" \
    "${KEYCLOAK_ADMIN_PASSWORD_SECRET_ID}"

get_realms_from_s3 \
    "${S3_BUCKET_NAME}" \
    "${KEYCLOAK_DIR}/data/import" \
    "${USER}"

create_keycloak_service "${KEYCLOAK_VERSION}" "${AWS_REGION}"

start_keycloak_service

wait_for_resources \
    300 \
    "Keycloak is not ready yet." \
    "curl --output /dev/null --silent --head --fail https://${FRONTEND_PROXY_DNS}/auth/realms/master"

create_privkey_and_upload_to_sm \
    "${USER}" \
    "${KEYCLOAK_DIR}" \
    "${KEYCLOAK_DIR}/keys/kube-rsa.pem" \
    "${KUBERNETES_REALM_NAME}" \
    "${FRONTEND_PROXY_DNS}" \
    "${K8S_KEY_SECRET_ID}" \
    "${KEYCLOAK_ADMIN_PASSWORD_SECRET_ID}"

scale_keycloak_asg \
    "${KEYCLOAK_ASG_NAME}" \
    "${KEYCLOAK_ASG_DESIRED_CAPACITY}"

# TODO: Create Lambda function for Revoking permissions to ASG after having the first node up and running
