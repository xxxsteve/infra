#!/bin/bash
# Destroy all terraform workspaces and their resources
# run from `terraform` directory

for ws in $(terraform workspace list | grep -v default | tr -d ' *'); do
    echo "========================================"
    echo "Destroying workspace: $ws"
    echo "========================================"
    terraform workspace select "$ws"
    terraform destroy -auto-approve
    echo "Deleting workspace: $ws"
    terraform workspace select default
    terraform workspace delete "$ws"
done