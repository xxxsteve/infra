#!/bin/bash
# Destroy all terraform workspaces and their resources
# run from `terraform/ec2` directory

set -e

FAILED_WORKSPACES=()

for ws in $(terraform workspace list | grep -v default | tr -d ' *'); do
    echo "========================================"
    echo "Destroying workspace: $ws"
    echo "========================================"
    terraform workspace select "$ws"
    
    # Try destroy with retries (handle race conditions)
    MAX_RETRIES=3
    for i in $(seq 1 $MAX_RETRIES); do
        if terraform destroy -auto-approve; then
            echo "✓ Destroy successful"
            break
        else
            if [ $i -lt $MAX_RETRIES ]; then
                echo "⚠️  Destroy failed, retrying in 10s... (attempt $i/$MAX_RETRIES)"
                sleep 10
            else
                echo "❌ Destroy failed after $MAX_RETRIES attempts"
                FAILED_WORKSPACES+=("$ws")
            fi
        fi
    done
    
    # Only delete workspace if destroy succeeded
    if [[ ! " ${FAILED_WORKSPACES[@]} " =~ " ${ws} " ]]; then
        echo "Deleting workspace: $ws"
        terraform workspace select default
        terraform workspace delete "$ws"
    else
        terraform workspace select default
    fi
done

echo ""
echo "========================================"
if [ ${#FAILED_WORKSPACES[@]} -eq 0 ]; then
    echo "✓ All EC2 workspaces destroyed successfully."
else
    echo "⚠️  Failed to destroy the following workspaces:"
    for ws in "${FAILED_WORKSPACES[@]}"; do
        echo "  - $ws"
    done
    echo ""
    echo "To clean up orphaned resources, run:"
    echo "  ./cleanup_orphaned_resources.sh ap-northeast-1"
fi
echo "Shared resources (S3, IAM) are still intact."
echo "To destroy shared resources: cd shared && terraform destroy"
echo "========================================"