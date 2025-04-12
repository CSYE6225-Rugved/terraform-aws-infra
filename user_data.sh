#!/bin/bash
set -e

# Create log file
exec > >(tee /var/log/user-data.log) 2>&1
echo "Starting user-data script at $(date)"

cd /opt/webapp

# Set up basic environment variables
echo "PORT=8080" > /opt/webapp/.env
echo "DB_NAME=csye6225" >> /opt/webapp/.env
echo "DB_DIALECT=mysql" >> /opt/webapp/.env
echo "DB_PORT=3306" >> /opt/webapp/.env
echo "DB_USER=${DB_USER}" >> /opt/webapp/.env
echo "AWS_REGION=${AWS_REGION}" >> /opt/webapp/.env
echo "AWS_S3_BUCKET_NAME=${AWS_S3_BUCKET_NAME}" >> /opt/webapp/.env
echo "DB_HOST=${DB_HOST}" >> /opt/webapp/.env

# Install AWS CLI
echo "Installing AWS CLI..."
apt-get update -y
apt-get install -y unzip curl jq
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip -q awscliv2.zip
./aws/install
export PATH=$PATH:/usr/local/bin
rm -rf aws awscliv2.zip

# Wait for AWS services
echo "Waiting for AWS services..."
sleep 20

# Get the secret
echo "Retrieving secret with name: ${SECRET_NAME}"
set +e
SECRET_RESULT=$(aws secretsmanager get-secret-value --secret-id "${SECRET_NAME}" --region "${AWS_REGION}" 2>&1)
SECRET_STATUS=$?
set -e

if [ $SECRET_STATUS -eq 0 ]; then
    echo "Secret retrieved successfully"
    SECRET_STRING=$(echo "$SECRET_RESULT" | jq -r '.SecretString')
    DB_PASSWORD=$(echo "$SECRET_STRING" | jq -r '.password')
    echo "Password extracted successfully"
    echo "DB_PASSWORD=$DB_PASSWORD" >> /opt/webapp/.env
else
    echo "Failed to retrieve secret: $SECRET_RESULT"
    echo "DB_PASSWORD=RETRIEVAL_FAILED" >> /opt/webapp/.env
fi

# Start CloudWatch agent
echo "Starting CloudWatch agent..."
sudo /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a fetch-config -m ec2 -c file:/opt/cloudwatch_config.json -s

echo "User-data script completed at $(date)"