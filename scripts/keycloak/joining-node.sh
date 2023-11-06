#!/bin/bash 

KEYCLOAK_VERSION=${1}
FRONTEND_PROXY_DNS=${2}
DB_SCHEMA=${3}
DB_NAME=${4}
DB_HOST=${5}
DB_PORT=${6}
DB_USER=${7}
AWS_REGION=${8}
S3_BUCKET_NAME=${9}

if [ -z "$KEYCLOAK_VERSION" ]; then
    echo "KEYCLOAK_VERSION is empty"
    exit 1
fi

if [ -z "$FRONTEND_PROXY_DNS" ]; then
    echo "FRONTEND_PROXY_DNS is empty"
    exit 1
fi

if [ -z "$DB_SCHEMA" ]; then
    echo "DB_SCHEMA is empty"
    exit 1
fi

if [ -z "$DB_NAME" ]; then
    echo "DB_NAME is empty"
    exit 1
fi

if [ -z "$DB_HOST" ]; then
    echo "DB_HOST is empty"
    exit 1
fi

if [ -z "$DB_PORT" ]; then
    echo "DB_PORT is empty"
    exit 1
fi

if [ -z "$DB_USER" ]; then
    echo "DB_USER is empty"
    exit 1
fi

if [ -z "$AWS_REGION" ]; then
    echo "AWS_REGION is empty"
    exit 1
fi

if [ -z "$S3_BUCKET_NAME" ]; then
    echo "S3_BUCKET_NAME is empty"
    exit 1
fi

sudo hostnamectl set-hostname keycloak
sudo hostnamectl set-hostname --transient keycloak
sudo bash -c "echo -e '\n127.0.0.1 keycloak' >> /etc/hosts"

sudo apt update -y
sudo apt install -y jq
sudo apt install -y unzip
sudo apt install -y openjdk-17-jre
sudo apt install -y openjdk-17-jdk

export JAVA_HOME=/usr/lib/jvm/java-1.17.0-openjdk-amd64
export PATH=$JAVA_HOME/bin:$PATH
java --version
echo $JAVA_HOME

DOWNLOAD_PATH="/tmp/keycloak"
sudo mkdir -p ${DOWNLOAD_PATH}
sudo chown -R ubuntu:ubuntu ${DOWNLOAD_PATH}

wget https://repo1.maven.org/maven2/org/jgroups/aws/jgroups-aws/2.0.1.Final/jgroups-aws-2.0.1.Final.jar \
    -O "${DOWNLOAD_PATH}/jgroups-aws-2.0.1.Final.jar"

wget https://repo1.maven.org/maven2/com/amazonaws/aws-java-sdk-core/1.12.576/aws-java-sdk-core-1.12.576.jar \
    -O "${DOWNLOAD_PATH}/aws-java-sdk-core-1.12.576.jar"

wget https://repo1.maven.org/maven2/com/amazonaws/aws-java-sdk-s3/1.12.576/aws-java-sdk-s3-1.12.576.jar \
    -O "${DOWNLOAD_PATH}/aws-java-sdk-s3-1.12.576.jar"

wget https://repo1.maven.org/maven2/joda-time/joda-time/2.12.4/joda-time-2.12.4.jar \
    -O "${DOWNLOAD_PATH}/joda-time-2.12.4.jar"

AWS_JDBC_DRIVER_VERSION="2.2.2"
wget https://repo1.maven.org/maven2/software/amazon/jdbc/aws-advanced-jdbc-wrapper/${AWS_JDBC_DRIVER_VERSION}/aws-advanced-jdbc-wrapper-${AWS_JDBC_DRIVER_VERSION}.jar \
    -O "${DOWNLOAD_PATH}/aws-advanced-jdbc-wrapper-${AWS_JDBC_DRIVER_VERSION}.jar"

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

for PACKAGE in "${AWS_SDK_PACKAGES[@]}"; do

    URL="https://repo1.maven.org/maven2/software/amazon/awssdk/${PACKAGE}/${AWS_SDK_VERSION}/${PACKAGE}-${AWS_SDK_VERSION}.jar"

    JAR_FILE="${DOWNLOAD_PATH}/${PACKAGE}-${AWS_SDK_VERSION}.jar"

    wget $URL -O $JAR_FILE
done

curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
sudo ./aws/install

aws --version

wget https://truststore.pki.rds.amazonaws.com/${AWS_REGION}/${AWS_REGION}-bundle.pem \
    -O "${DOWNLOAD_PATH}/${AWS_REGION}-bundle.pem"

sudo keytool -importcert -file "${DOWNLOAD_PATH}/${AWS_REGION}-bundle.pem" \
    -keystore rds-${AWS_REGION}-truststore.jks -storepass changeit -alias rds -noprompt

wget https://github.com/keycloak/keycloak/releases/download/${KEYCLOAK_VERSION}/keycloak-${KEYCLOAK_VERSION}.zip \
    -O keycloak-${KEYCLOAK_VERSION}.zip

sudo groupadd keycloak
sudo useradd -r -g keycloak -d /opt/keycloak -s /sbin/nologin keycloak

unzip keycloak-${KEYCLOAK_VERSION}.zip -d /opt/

sudo mkdir -p /opt/keycloak-${KEYCLOAK_VERSION}/data/import/

for JAR_FILE in $(ls ${DOWNLOAD_PATH}/*.jar); do
    sudo cp $JAR_FILE /opt/keycloak-${KEYCLOAK_VERSION}/providers/
done

sudo chown -R keycloak:keycloak /opt/keycloak-${KEYCLOAK_VERSION}
sudo chmod -R o+rwx /opt/keycloak-${KEYCLOAK_VERSION}

sudo mkdir -p /opt/keycloak/log/
sudo touch /opt/keycloak/log/keycloak.log

sudo mkdir -p /opt/keycloak/export/

sudo mkdir -p /opt/keycloak/certs/
sudo mv ${DOWNLOAD_PATH}/${AWS_REGION}-bundle.pem /opt/keycloak/certs/
sudo chmod 644 /opt/keycloak/certs/${AWS_REGION}-bundle.pem

sudo mkdir -p /opt/keycloak/keystores/
sudo mv rds-${AWS_REGION}-truststore.jks /opt/keycloak/keystores/
sudo chmod 600 /opt/keycloak/keystores/rds-${AWS_REGION}-truststore.jks
sudo chown -R keycloak:keycloak /opt/keycloak/

sudo mkdir -p /etc/keycloak-${KEYCLOAK_VERSION}
sudo chown -R keycloak:keycloak /etc/keycloak-${KEYCLOAK_VERSION}

KEYCLOAK_ADMIN_PASSWORD=$(aws secretsmanager get-secret-value \
    --secret-id keycloak/admin/password \
    --query SecretString \
    --output text)

if [ $? -eq 0 || "$KEYCLOAK_ADMIN_PASSWORD" != "" ]; then
  echo "Secret keycloak/admin/password found."
else
  echo "Secret keycloak/admin/password not found. Exiting..."
  exit 1
fi

DB_URL_PROPERTIES="wrapperPlugins=iam&ssl=true&sslmode=verify-ca&sslrootcert=/opt/keycloak/certs/${AWS_REGION}-bundle.pem"

cat <<EOF | sudo tee "/etc/keycloak-${KEYCLOAK_VERSION}/keycloak.env"
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
KC_HOSTNAME_URL=https://${FRONTEND_PROXY_DNS}
KEYCLOAK_ADMIN=admin
KEYCLOAK_ADMIN_PASSWORD=${KEYCLOAK_ADMIN_PASSWORD}
KC_HOSTNAME_ADMIN_URL=https://${FRONTEND_PROXY_DNS}
DB_NAME=${DB_NAME} 
DB_HOST=${DB_HOST}
DB_PORT=${DB_PORT}
DB_URL_PROPERTIES=${DB_URL_PROPERTIES}
KC_DB_URL=jdbc:aws-wrapper:postgresql://${DB_HOST}:${DB_PORT}/${DB_NAME}?${DB_URL_PROPERTIES}
KC_DB=postgres
KC_DB_DRIVER=software.amazon.jdbc.Driver
KC_DB_SCHEMA=${DB_SCHEMA}
#KC_DB_USERNAME=${DB_USER}
KC_TRANSACTION_XA_ENABLED=false
JAVA_OPTS_APPEND=-Djgroups.s3.region_name=${AWS_REGION} -Djgroups.s3.bucket_name=${S3_BUCKET_NAME} -Djgroups.s3.bucket_prefix=keycloak/cache
KC_LOG=console,file
KC_LOG_CONSOLE_COLOR=true
KC_LOG_FILE=/opt/keycloak/log/keycloak.log
KC_LOG_LEVEL=info
EOF

sudo -u keycloak aws s3 cp s3://${S3_BUCKET_NAME}/keycloak/realms/ /opt/keycloak-${KEYCLOAK_VERSION}/data/import/ --recursive

cat <<EOF | sudo tee /etc/systemd/system/keycloak.service
[Unit]
Description=Keycloak Authorization Server
After=network.target

[Service]
User=keycloak
Group=keycloak
EnvironmentFile=/etc/keycloak-${KEYCLOAK_VERSION}/keycloak.env
ExecStart=/opt/keycloak-${KEYCLOAK_VERSION}/bin/kc.sh start \
            --spi-truststore-file-file=/opt/keycloak/keystores/rds-${AWS_REGION}-truststore.jks \
            --spi-truststore-file-password=changeit \
            --spi-truststore-file-hostname-verification-policy=WILDCARD \
            --import-realm 
Restart=always
RestartSec=5
LimitNOFILE=102642
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable keycloak
sudo systemctl start keycloak