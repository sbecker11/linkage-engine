while true; do
  clear
  echo "=== $(date) ==="
  aws ecs describe-services --region us-west-1 \
    --cluster linkage-engine-cluster \
    --services linkage-engine-service \
    --query 'services[0].{running:runningCount,desired:desiredCount,pending:pendingCount,taskDef:taskDefinition}' \
    --output table
  echo ""
  aws ecs describe-services --region us-west-1 \
    --cluster linkage-engine-cluster \
    --services linkage-engine-service \
    --query 'services[0].events[:5].message' \
    --output text | tr '\t' '\n'
  sleep 5
done
