#!/bin/bash
# Cleanup orphaned AWS resources from failed terraform destroys
# Run this when you have leftover VPCs/resources after terraform failures

set -e

REGION="${1:-ap-northeast-1}"
# Optional: specify owner to only clean resources belonging to this user
OWNER_FILTER="${2:-}"

echo "=========================================="
echo "Cleaning orphaned resources in $REGION"
echo "=========================================="

# Get current AWS identity for safety check
CURRENT_USER=$(aws sts get-caller-identity --query 'Arn' --output text | awk -F'/' '{print $NF}')
echo "Current AWS user: $CURRENT_USER"
echo ""

# Find all VPCs tagged with binance-vpc-steven
if [ -n "$OWNER_FILTER" ]; then
    echo "Filtering by owner: $OWNER_FILTER"
    VPCS=$(aws ec2 describe-vpcs --region "$REGION" \
        --filters "Name=tag:Name,Values=binance-vpc-steven" "Name=tag:Owner,Values=$OWNER_FILTER" \
        --query 'Vpcs[].VpcId' --output text)
else
    echo "⚠️  WARNING: No owner filter specified. This will clean ALL binance-vpc-steven resources!"
    echo "To filter by owner, run: $0 $REGION <owner-name>"
    echo "Continuing in 5 seconds... (Ctrl+C to cancel)"
    sleep 5
    VPCS=$(aws ec2 describe-vpcs --region "$REGION" --filters "Name=tag:Name,Values=binance-vpc-steven" --query 'Vpcs[].VpcId' --output text)
fi

if [ -z "$VPCS" ]; then
    echo "✓ No orphaned VPCs found"
    exit 0
fi

echo "Found VPCs: $VPCS"
echo ""

for VPC_ID in $VPCS; do
    echo "=== Cleaning VPC: $VPC_ID ==="
    
    # Show VPC tags for visibility
    VPC_TAGS=$(aws ec2 describe-vpcs --region "$REGION" --vpc-ids "$VPC_ID" \
        --query 'Vpcs[0].Tags[?Key==`Owner` || Key==`CreatedBy`].[Key,Value]' --output text 2>/dev/null | tr '\t' '=' | tr '\n' ', ' || echo "No owner tags")
    echo "  Tags: $VPC_TAGS"
    
    # Check if VPC has any running instances
    INSTANCES=$(aws ec2 describe-instances --region "$REGION" \
        --filters "Name=vpc-id,Values=$VPC_ID" "Name=instance-state-name,Values=running,pending,stopping,stopped" \
        --query 'Reservations[].Instances[].[InstanceId,State.Name]' --output text)
    
    if [ -n "$INSTANCES" ]; then
        echo "⚠️  VPC has active instances:"
        echo "$INSTANCES"
        echo "Skipping this VPC (use terraform destroy instead)"
        continue
    fi
    
    # 1. Delete EIP associations
    echo "  Deleting EIP associations..."
    aws ec2 describe-addresses --region "$REGION" --filters "Name=domain,Values=vpc" \
        --query "Addresses[?NetworkInterfaceId!=null].AssociationId" --output text | \
        xargs -r -n1 aws ec2 disassociate-address --region "$REGION" --association-id 2>/dev/null || true
    
    # 2. Release EIPs (only those not associated)
    echo "  Releasing EIPs..."
    aws ec2 describe-addresses --region "$REGION" --filters "Name=domain,Values=vpc" \
        --query "Addresses[?NetworkInterfaceId==null].AllocationId" --output text | \
        xargs -r -n1 aws ec2 release-address --region "$REGION" --allocation-id 2>/dev/null || true
    
    # 3. Delete network interfaces (not attached to instances)
    echo "  Deleting detached network interfaces..."
    aws ec2 describe-network-interfaces --region "$REGION" --filters "Name=vpc-id,Values=$VPC_ID" \
        --query 'NetworkInterfaces[?!Attachment].[NetworkInterfaceId]' --output text | \
        xargs -r -n1 aws ec2 delete-network-interface --region "$REGION" --network-interface-id 2>/dev/null || true
    
    # 4. Delete NAT Gateways
    echo "  Deleting NAT gateways..."
    aws ec2 describe-nat-gateways --region "$REGION" --filter "Name=vpc-id,Values=$VPC_ID" "Name=state,Values=available,pending" \
        --query 'NatGateways[].NatGatewayId' --output text | \
        xargs -r -n1 aws ec2 delete-nat-gateway --region "$REGION" --nat-gateway-id 2>/dev/null || true
    
    # Wait a moment for NAT gateways to start deleting
    sleep 3
    
    # 5. Delete route table associations (except main)
    echo "  Deleting route table associations..."
    aws ec2 describe-route-tables --region "$REGION" --filters "Name=vpc-id,Values=$VPC_ID" \
        --query 'RouteTables[].Associations[?!Main].RouteTableAssociationId' --output text | \
        xargs -r -n1 aws ec2 disassociate-route-table --region "$REGION" --association-id 2>/dev/null || true
    
    # 6. Delete routes (except local)
    echo "  Deleting routes..."
    aws ec2 describe-route-tables --region "$REGION" --filters "Name=vpc-id,Values=$VPC_ID" \
        --query 'RouteTables[].RouteTableId' --output text | tr '\t' '\n' | while read RT_ID; do
        [ -z "$RT_ID" ] && continue
        aws ec2 describe-route-tables --region "$REGION" --route-table-ids "$RT_ID" \
            --query 'RouteTables[].Routes[?GatewayId!=`local`].DestinationCidrBlock' --output text | tr '\t' '\n' | \
            while read CIDR; do
                [ -z "$CIDR" ] && continue
                aws ec2 delete-route --region "$REGION" --route-table-id "$RT_ID" --destination-cidr-block "$CIDR" 2>/dev/null || true
            done
    done
    
    # 7. Detach and delete internet gateways
    echo "  Detaching and deleting internet gateways..."
    aws ec2 describe-internet-gateways --region "$REGION" --filters "Name=attachment.vpc-id,Values=$VPC_ID" \
        --query 'InternetGateways[].InternetGatewayId' --output text | while read IGW_ID; do
        aws ec2 detach-internet-gateway --region "$REGION" --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID" 2>/dev/null || true
        aws ec2 delete-internet-gateway --region "$REGION" --internet-gateway-id "$IGW_ID" 2>/dev/null || true
    done
    
    # 8. Delete route tables (except main)
    echo "  Deleting route tables..."
    aws ec2 describe-route-tables --region "$REGION" --filters "Name=vpc-id,Values=$VPC_ID" \
        --query 'RouteTables[?Associations[0].Main!=`true`].RouteTableId' --output text | \
        xargs -r -n1 aws ec2 delete-route-table --region "$REGION" --route-table-id 2>/dev/null || true
    
    # 9. Delete security group rules (ingress/egress)
    echo "  Deleting security group rules..."
    aws ec2 describe-security-groups --region "$REGION" --filters "Name=vpc-id,Values=$VPC_ID" \
        --query 'SecurityGroups[?GroupName!=`default`].GroupId' --output text | tr '\t' '\n' | while read SG_ID; do
        [ -z "$SG_ID" ] && continue
        # Delete ingress rules
        aws ec2 describe-security-groups --region "$REGION" --group-ids "$SG_ID" \
            --query 'SecurityGroups[].IpPermissions' --output json | \
            jq -c '.[][]' 2>/dev/null | while read RULE; do
            aws ec2 revoke-security-group-ingress --region "$REGION" --group-id "$SG_ID" --ip-permissions "$RULE" >/dev/null 2>&1 || true
        done
        # Delete egress rules
        aws ec2 describe-security-groups --region "$REGION" --group-ids "$SG_ID" \
            --query 'SecurityGroups[].IpPermissionsEgress' --output json | \
            jq -c '.[][]' 2>/dev/null | while read RULE; do
            aws ec2 revoke-security-group-egress --region "$REGION" --group-id "$SG_ID" --ip-permissions "$RULE" >/dev/null 2>&1 || true
        done
    done
    
    # 10. Delete security groups (except default)
    echo "  Deleting security groups..."
    aws ec2 describe-security-groups --region "$REGION" --filters "Name=vpc-id,Values=$VPC_ID" \
        --query 'SecurityGroups[?GroupName!=`default`].GroupId' --output text | \
        xargs -r -n1 aws ec2 delete-security-group --region "$REGION" --group-id 2>/dev/null || true
    
    # 11. Delete subnets
    echo "  Deleting subnets..."
    aws ec2 describe-subnets --region "$REGION" --filters "Name=vpc-id,Values=$VPC_ID" \
        --query 'Subnets[].SubnetId' --output text | \
        xargs -r -n1 aws ec2 delete-subnet --region "$REGION" --subnet-id 2>/dev/null || true
    
    # 12. Finally, delete the VPC
    echo "  Deleting VPC..."
    aws ec2 delete-vpc --region "$REGION" --vpc-id "$VPC_ID" 2>/dev/null && echo "✓ VPC deleted" || echo "⚠️  VPC deletion failed"
    
    echo ""
done

echo "=========================================="
echo "Cleanup complete!"
echo "=========================================="
