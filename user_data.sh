#!/bin/bash
    set -e

    cd /opt/webapp

    sudo cat .env

    echo "PORT=8080" >> /opt/webapp/.env
    echo "DB_NAME=csye6225" >> /opt/webapp/.env
    echo "DB_DIALECT=mysql" >> /opt/webapp/.env
    echo "DB_PORT=3306" >> /opt/webapp/.env
    echo "DB_USER=${DB_USER}" >> /opt/webapp/.env
    echo "DB_PASSWORD=${DB_PASSWORD}" >> /opt/webapp/.env
    echo "AWS_REGION=${AWS_REGION}" >> /opt/webapp/.env
    echo "AWS_S3_BUCKET_NAME=${AWS_S3_BUCKET_NAME}" >> /opt/webapp/.env
    echo "DB_HOST=${DB_HOST}" >> /opt/webapp/.env

    #run cloudwatch agent
    sudo /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a fetch-config -m ec2 -c file:/opt/cloudwatch_config.json -s