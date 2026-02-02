#!/usr/bin/env bash
set -euo pipefail

# TODO update instance ID
INSTANCE_ID=i-xxxxxxxxxxxxxxxxx

# Detect region from the instance AZ
AZ=$(aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].Placement.AvailabilityZone' \
  --output text)

REGION="${AZ::-1}"

VPC_ID=$(aws --region "$REGION" ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].VpcId' \
  --output text)

SUBNET_ID=$(aws --region "$REGION" ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].SubnetId' \
  --output text)

RTB_ID=$(aws --region "$REGION" ec2 describe-route-tables \
  --filters "Name=association.subnet-id,Values=$SUBNET_ID" \
  --query 'RouteTables[0].RouteTableId' \
  --output text)

# fallback to main RT if needed
if [ "$RTB_ID" = "None" ] || [ -z "$RTB_ID" ]; then
  RTB_ID=$(aws --region "$REGION" ec2 describe-route-tables \
    --filters "Name=vpc-id,Values=$VPC_ID" "Name=association.main,Values=true" \
    --query 'RouteTables[0].RouteTableId' \
    --output text)
fi

SERVICE_NAME="com.amazonaws.${REGION}.s3"

# Optional: avoid creating a duplicate endpoint
EXISTING=$(aws --region "$REGION" ec2 describe-vpc-endpoints \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=service-name,Values=$SERVICE_NAME" \
  --query 'VpcEndpoints[0].VpcEndpointId' \
  --output text)

if [ "$EXISTING" != "None" ] && [ -n "$EXISTING" ]; then
  echo "S3 Gateway endpoint already exists: $EXISTING"
else
  aws --region "$REGION" ec2 create-vpc-endpoint \
    --vpc-id "$VPC_ID" \
    --service-name "$SERVICE_NAME" \
    --vpc-endpoint-type Gateway \
    --route-table-ids "$RTB_ID"
fi

# Verify the route table has been updated
echo "Verifying route table $RTB_ID in $REGION..."
aws --region "$REGION" ec2 describe-route-tables \
  --route-table-ids "$RTB_ID" \
  --query 'RouteTables[0].Routes'

# you should see a route like this in the output:
    # {
    #     "DestinationPrefixListId": "pl-61a54008",
    #     "GatewayId": "vpce-02a47b8ff523069d7",
    #     "Origin": "CreateRoute",
    #     "State": "active"
    # }

