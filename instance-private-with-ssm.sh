#!/bin/bash
set -e

## Execution example:
## bash instance-private-with-ssm.sh --private-subnet-id=subnet-0b2f7f5a1efe17975 --public-subnet-id=subnet-0d269f0ffdc058b36
## bash instance-private-with-ssm.sh --private-subnet-id=subnet-0b2f7f5a1efe17975 --public-subnet-id=subnet-0d269f0ffdc058b36 --delete

ROLE_NAME=MSP-SSM-Instance-Role
INSTANCE_PROFILE_NAME=MSP-SSM-Instance-Profile
SECURITY_GROUP_NAME=MSP-vpc-endpoint-sg
INSTANCE_NAME=MSP-Dinocloud-Instance
VPC_ENDPOINT_SSM=MSP-ssm-vpc-endpoint
VPC_ENDPOINT_SSMMESSAGES=MSP-ssm-messages-vpc-endpoint
VPC_ENDPOINT_EC2MESSAGES=MSP-ec2-messages-vpc-endpoint
VPC_ENDPOINT_S3=MSP-s3-vpc-endpoint
NAT_GATEWAY_NAME=MSP-NATGW
ELASTIC_IP_NAME="MSP-elastic-ip"

PRIVATE_SUBNET_ID=""
PUBLIC_SUBNET_ID=""
for arg in "$@"; do
    if [[ "$arg" == --private-subnet-id=* ]]; then
        PRIVATE_SUBNET_ID="${arg#*=}"
        #echo "--private-subnet-id: $PRIVATE_SUBNET_ID"
    fi
    if [[ "$arg" == --public-subnet-id=* ]]; then
        PUBLIC_SUBNET_ID="${arg#*=}"
        #echo "--public-subnet-id: $PUBLIC_SUBNET_ID"
    fi
done

if [ "$PRIVATE_SUBNET_ID" = "" ] || [ "$PUBLIC_SUBNET_ID" = "" ]; then
    echo -e "A value for --private-subnet-id and --public-subnet-id must be provided as follows:\n\tbash $0 --private-subnet-id=subnet-xxxxxxxxxxxxxxxxx --public-subnet-id=subnet-yyyyyyyyyyyyyyyyy"
    echo -e "If you want to delete the resources previously created by this same script you must use --delete as follows:\n\tbash $0 --private-subnet-id=subnet-xxxxxxxxxxxxxxxxx --public-subnet-id=subnet-yyyyyyyyyyyyyyyyy --delete"
    exit 1
fi

VPC_ID=$(aws ec2 describe-subnets --subnet-ids $PRIVATE_SUBNET_ID --query 'Subnets[0].VpcId' --output text)

if [[ "$*" == *"--delete"* ]]; then
    echo "Deleting resources"

    echo " - VPC Endpoint Gateway"
    VPC_ENDPOINT_S3_ID=$(aws ec2 describe-vpc-endpoints \
        --query "VpcEndpoints[?Tags[?Key=='Name' && Value=='$VPC_ENDPOINT_S3']].VpcEndpointId" \
        --output text)
    aws ec2 delete-vpc-endpoints --vpc-endpoint-ids "$VPC_ENDPOINT_S3_ID" \
        2>&1 >/dev/null

    echo " - VPC Endpoints Interface"
    VPC_ENDPOINT_SSM_ID=$(aws ec2 describe-vpc-endpoints \
        --query "VpcEndpoints[?Tags[?Key=='Name' && Value=='$VPC_ENDPOINT_SSM']].VpcEndpointId" \
        --output text)
    aws ec2 delete-vpc-endpoints --vpc-endpoint-ids "$VPC_ENDPOINT_SSM_ID" \
        2>&1 >/dev/null
    VPC_ENDPOINT_SSMMESSAGES_ID=$(aws ec2 describe-vpc-endpoints \
        --query "VpcEndpoints[?Tags[?Key=='Name' && Value=='$VPC_ENDPOINT_SSMMESSAGES']].VpcEndpointId" \
        --output text)
    aws ec2 delete-vpc-endpoints --vpc-endpoint-ids "$VPC_ENDPOINT_SSMMESSAGES_ID" \
        2>&1 >/dev/null
    VPC_ENDPOINT_EC2MESSAGES_ID=$(aws ec2 describe-vpc-endpoints \
        --query "VpcEndpoints[?Tags[?Key=='Name' && Value=='$VPC_ENDPOINT_EC2MESSAGES']].VpcEndpointId" \
        --output text)
    aws ec2 delete-vpc-endpoints --vpc-endpoint-ids "$VPC_ENDPOINT_EC2MESSAGES_ID" \
        2>&1 >/dev/null

    echo " - NAT Gateway"
    ROUTE_TABLE_ID=$(aws ec2 describe-route-tables \
        --filters "Name=association.subnet-id,Values=$PRIVATE_SUBNET_ID" \
        --query "RouteTables[].RouteTableId" \
        --output text)
    aws ec2 delete-route \
        --route-table-id $ROUTE_TABLE_ID \
        --destination-cidr-block 0.0.0.0/0
    NAT_GATEWAY_ID=$(aws ec2 describe-nat-gateways \
        --filter Name=tag:Name,Values="$NAT_GATEWAY_NAME" \
        --query 'NatGateways[0].NatGatewayId' \
        --output text)
    aws ec2 delete-nat-gateway \
        --nat-gateway-id "$NAT_GATEWAY_ID" \
        2>&1 >/dev/null
    while true; do
        STATE=$(aws ec2 describe-nat-gateways \
            --nat-gateway-ids $NAT_GATEWAY_ID \
            --query 'NatGateways[0].State' \
            --output text)
        if [ "$STATE" = "deleted" ]; then
            echo "   OK"
            break
        fi
        echo "   Pending..."
        sleep 15 # espera de 15 segundos
    done

    echo " - EC2 Instance"
    # TODO: la eliminacion de la EC2 tarda unos segundos, se debe consultar si ya fue elimanada y esperar...
    INSTANCE_ID=$(aws ec2 describe-instances \
        --filters "Name=tag:Name,Values=$INSTANCE_NAME" \
        --query "Reservations[].Instances[].InstanceId" \
        --output text)
    aws ec2 terminate-instances --instance-ids $INSTANCE_ID \
        2>&1 >/dev/null
    while true; do
        STATE=$(aws ec2 describe-instances \
            --instance-ids $INSTANCE_ID \
            --query 'Reservations[0].Instances[0].State.Name' \
            --output text)
        if [ "$STATE" = "terminated" ]; then
            echo "   OK"
            break
        fi
        echo "   Pending..."
        sleep 15 # espera de 15 segundos
    done

    echo " - Security Group"
    SECURITY_GROUP_ID=$(aws ec2 describe-security-groups \
        --filters Name=group-name,Values=$SECURITY_GROUP_NAME Name=vpc-id,Values=$VPC_ID \
        --query 'SecurityGroups[0].GroupId' \
        --output text)
    sleep 15 # espera de 15 segundos
    aws ec2 delete-security-group --group-id $SECURITY_GROUP_ID

    echo " - Instance Profile"
    aws iam remove-role-from-instance-profile --instance-profile-name $INSTANCE_PROFILE_NAME --role-name $ROLE_NAME
    aws iam delete-instance-profile \
        --instance-profile-name $INSTANCE_PROFILE_NAME

    echo " - IAM Role"
    aws iam detach-role-policy --role-name $ROLE_NAME \
        --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
    aws iam detach-role-policy --role-name $ROLE_NAME \
        --policy-arn arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess
    aws iam delete-role \
        --role-name $ROLE_NAME

    echo " - Elastic IP"
    ELASTIC_IP_ID=$(aws ec2 describe-tags --filters "Name=tag:Name,Values=$ELASTIC_IP_NAME" --query "Tags[?Key=='Name'].ResourceId" --output text)
    aws ec2 release-address --allocation-id "$ELASTIC_IP_ID"

    echo "Finalized"
    exit 0
fi

echo "Creating resources"

echo " - IAM Role"
aws iam create-role --role-name $ROLE_NAME \
    --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}' \
    --tags Key=Team,Value=MSPDinocloud Key=Project,Value=MSPSessions \
    2>&1 >/dev/null
aws iam attach-role-policy --role-name $ROLE_NAME \
    --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
aws iam attach-role-policy --role-name $ROLE_NAME \
    --policy-arn arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess

echo " - Instance Profile"
aws iam create-instance-profile \
    --instance-profile-name $INSTANCE_PROFILE_NAME \
    2>&1 >/dev/null
aws iam add-role-to-instance-profile \
    --role-name $ROLE_NAME --instance-profile-name $INSTANCE_PROFILE_NAME

echo " - Security Group"
CIDR_BLOCK=$(aws ec2 describe-vpcs \
    --vpc-ids "$VPC_ID" \
    --query "Vpcs[0].CidrBlock" \
    --output text)
aws ec2 create-security-group --group-name $SECURITY_GROUP_NAME \
    --description "Allows HTTPS for VPC Endpoint" \
    --vpc-id $VPC_ID \
    --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value='$SECURITY_GROUP_NAME'},{Key=Team,Value=MSPDinocloud},{Key=Project,Value=MSPSessions}]" \
    2>&1 >/dev/null
SECURITY_GROUP_ID=$(aws ec2 describe-security-groups \
    --filters Name=group-name,Values=$SECURITY_GROUP_NAME Name=vpc-id,Values=$VPC_ID \
    --query 'SecurityGroups[0].GroupId' \
    --output text)
aws ec2 authorize-security-group-ingress --group-id $SECURITY_GROUP_ID \
    --protocol tcp --port 443 --cidr $CIDR_BLOCK \
    2>&1 >/dev/null

echo " - VPC Endpoints Interface"
aws ec2 create-vpc-endpoint \
    --vpc-id $VPC_ID \
    --vpc-endpoint-type Interface \
    --service-name com.amazonaws.us-east-1.ssm \
    --subnet-ids $PRIVATE_SUBNET_ID \
    --security-group-id $SECURITY_GROUP_ID \
    --tag-specifications "ResourceType=vpc-endpoint,Tags=[{Key=Name,Value='$VPC_ENDPOINT_SSM'},{Key=Team,Value=MSPDinocloud},{Key=Project,Value=MSPSessions}]" \
    2>&1 >/dev/null
aws ec2 create-vpc-endpoint \
    --vpc-id $VPC_ID \
    --vpc-endpoint-type Interface \
    --service-name com.amazonaws.us-east-1.ssmmessages \
    --subnet-ids $PRIVATE_SUBNET_ID \
    --security-group-id $SECURITY_GROUP_ID \
    --tag-specifications "ResourceType=vpc-endpoint,Tags=[{Key=Name,Value='$VPC_ENDPOINT_SSMMESSAGES'},{Key=Team,Value=MSPDinocloud},{Key=Project,Value=MSPSessions}]" \
    2>&1 >/dev/null
aws ec2 create-vpc-endpoint \
    --vpc-id $VPC_ID \
    --vpc-endpoint-type Interface \
    --service-name com.amazonaws.us-east-1.ec2messages \
    --subnet-ids $PRIVATE_SUBNET_ID \
    --security-group-id $SECURITY_GROUP_ID \
    --tag-specifications "ResourceType=vpc-endpoint,Tags=[{Key=Name,Value='$VPC_ENDPOINT_EC2MESSAGES'},{Key=Team,Value=MSPDinocloud},{Key=Project,Value=MSPSessions}]" \
    2>&1 >/dev/null

echo " - VPC Endpoint Gateway"
ROUTE_TABLE_ID=$(aws ec2 describe-route-tables \
    --filters "Name=association.subnet-id,Values=$PRIVATE_SUBNET_ID" \
    --query "RouteTables[].RouteTableId" \
    --output text)
aws ec2 create-vpc-endpoint \
    --vpc-id $VPC_ID \
    --service-name com.amazonaws.us-east-1.s3 \
    --route-table-ids $ROUTE_TABLE_ID \
    --tag-specifications "ResourceType=vpc-endpoint,Tags=[{Key=Name,Value='$VPC_ENDPOINT_S3'},{Key=Team,Value=MSPDinocloud},{Key=Project,Value=MSPSessions}]" \
    2>&1 >/dev/null

echo " - EC2 Instance"
aws ec2 run-instances --image-id ami-0cf10cdf9fcd62d37 --count 1 \
    --instance-type t2.micro \
    --security-group-ids $SECURITY_GROUP_ID \
    --subnet-id $PRIVATE_SUBNET_ID \
    --iam-instance-profile Name=$INSTANCE_PROFILE_NAME \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value='$INSTANCE_NAME'},{Key=Team,Value=MSPDinocloud},{Key=Project,Value=MSPSessions}]" "ResourceType=volume,Tags=[{Key=Name,Value='$INSTANCE_NAME'},{Key=Team,Value=MSPDinocloud},{Key=Project,Value=MSPSessions}]" \
    2>&1 >/dev/null

echo " - Elastic IP"
aws ec2 allocate-address \
    --domain vpc \
    --tag-specifications "ResourceType=elastic-ip,Tags=[{Key=Name,Value='$ELASTIC_IP_NAME'},{Key=Team,Value=MSPDinocloud},{Key=Project,Value=MSPSessions}]" \
    2>&1 >/dev/null

echo " - NAT Gateway"
ELASTIC_IP_ID=$(aws ec2 describe-tags \
    --filters "Name=tag:Name,Values='$ELASTIC_IP_NAME'" \
    --query "Tags[?Key=='Name'].ResourceId" \
    --output text)
aws ec2 create-nat-gateway \
    --subnet-id $PUBLIC_SUBNET_ID \
    --allocation-id $ELASTIC_IP_ID \
    --tag-specifications "ResourceType=natgateway,Tags=[{Key=Name,Value='$NAT_GATEWAY_NAME'},{Key=Team,Value=MSPDinocloud},{Key=Project,Value=MSPSessions}]" \
    2>&1 >/dev/null
# La creacion del NAT tarda unos minutos, se debe consultar si ya fue creado y esperar...
NAT_GATEWAY_ID=$(aws ec2 describe-nat-gateways \
    --filter Name=tag:Name,Values="$NAT_GATEWAY_NAME" \
    --query 'NatGateways[0].NatGatewayId' \
    --output text)
while true; do
    STATE=$(aws ec2 describe-nat-gateways \
        --nat-gateway-ids $NAT_GATEWAY_ID \
        --query 'NatGateways[0].State' \
        --output text)
    if [ "$STATE" = "available" ]; then
        echo "   OK"
        break
    fi
    echo "   Pending..."
    sleep 15 # espera de 15 segundos
done
aws ec2 create-route \
    --route-table-id $ROUTE_TABLE_ID \
    --destination-cidr-block 0.0.0.0/0 \
    --nat-gateway-id $NAT_GATEWAY_ID \
    2>&1 >/dev/null

echo "Finalized"

# https://us-east-1.console.aws.amazon.com/iam/home?region=us-east-1#/roles/details/MSP-SSM-Instance-Role?section=permissions
# https://us-east-1.console.aws.amazon.com/ec2/home?region=us-east-1#SecurityGroups:
# https://us-east-1.console.aws.amazon.com/ec2/home?region=us-east-1#Instances:v=3;$case=tags:true%5C,client:false;$regex=tags:false%5C,client:false
# https://us-east-1.console.aws.amazon.com/vpcconsole/home?region=us-east-1#Endpoints:
# https://us-east-1.console.aws.amazon.com/ec2/home?region=us-east-1#Addresses:
# https://us-east-1.console.aws.amazon.com/vpcconsole/home?region=us-east-1#NatGateways:
# https://us-east-1.console.aws.amazon.com/vpcconsole/home?region=us-east-1#RouteTables:tag:Name=msp
