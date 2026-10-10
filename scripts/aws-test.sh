# ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
# REGISTRY="$ACCOUNT.dkr.ecr.us-east-1.amazonaws.com/catalog-api"

# aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin "${REGISTRY%%/*}"

# export ECR_IMAGE="$REGISTRY:sha-xxxxxxx"     # your newest tag
# echo "${ECR_IMAGE##*:}"
# ./scripts/local-cluster-test.sh

# aws ecr describe-repositories --repository-names catalog-api --region us-east-1 \
#   --query 'repositories[0].{Name:repositoryName,TagMutability:imageTagMutability,ScanOnPush:imageScanningConfiguration.scanOnPush,Encryption:encryptionConfiguration.encryptionType}' \
#   --output table

# aws ecr get-lifecycle-policy --repository-name catalog-api --region us-east-1 \
#   --query lifecyclePolicyText --output text | python3 -m json.tool

# aws ecr describe-images --repository-name catalog-api --region us-east-1 \
#   --query 'sort_by(imageDetails,&imagePushedAt)[].{Tag:imageTags[0],Pushed:imagePushedAt,Scan:imageScanStatus.status}' \
#   --output table


# BUCKET=$(aws s3 ls | awk '/catalog-api-tfstate/{print $3}')
# echo "Bucket: $BUCKET" | sed -E 's/[0-9]{12}/************/g'

# aws s3api get-bucket-versioning --bucket "$BUCKET"
# aws s3api get-bucket-encryption --bucket "$BUCKET" --query 'ServerSideEncryptionConfiguration.Rules[0]'
# aws s3api get-public-access-block --bucket "$BUCKET"
# aws s3 ls "s3://$BUCKET" --recursive | sed -E 's/[0-9]{12}/************/g'