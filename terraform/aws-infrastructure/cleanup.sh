#!/bin/bash
echo "Cleaning up AWS resources..."

# Read resource IDs
VPC_ID=$(cat vpc_id.txt 2>/dev/null)
RANCHER_INSTANCE_ID=$(cat rancher_instance_id.txt 2>/dev/null)
K8S_INSTANCE_IDS=$(cat k8s_instance_ids.txt 2>/dev/null)
NAT_GW_ID=$(cat nat_gw_id.txt 2>/dev/null)

# Terminate instances
if [ ! -z "$RANCHER_INSTANCE_ID" ]; then
    aws ec2 terminate-instances --instance-ids $RANCHER_INSTANCE_ID --region us-east-1
fi

if [ ! -z "$K8S_INSTANCE_IDS" ]; then
    aws ec2 terminate-instances --instance-ids $K8S_INSTANCE_IDS --region us-east-1
fi

# Wait for instances to terminate
echo "Waiting for instances to terminate..."
sleep 60

# Delete NAT Gateway
if [ ! -z "$NAT_GW_ID" ]; then
    aws ec2 delete-nat-gateway --nat-gateway-id $NAT_GW_ID --region us-east-1
    sleep 30
fi

# Release Elastic IP
EIP_ALLOC_ID=$(aws ec2 describe-addresses --filters "Name=tag:Name,Values=ioc-platform-demo-nat-eip" --query 'Addresses[0].AllocationId' --output text --region us-east-1)
if [ "$EIP_ALLOC_ID" != "None" ]; then
    aws ec2 release-address --allocation-id $EIP_ALLOC_ID --region us-east-1
fi

# Delete key pair
aws ec2 delete-key-pair --key-name ioc-platform-demo-key --region us-east-1

# Delete VPC (this will delete associated resources)
if [ ! -z "$VPC_ID" ]; then
    aws ec2 delete-vpc --vpc-id $VPC_ID --region us-east-1
fi

# Clean up files
rm -f *.txt rancher_userdata.sh k8s_userdata.sh

echo "Cleanup completed!"
