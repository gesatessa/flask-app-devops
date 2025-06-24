#!/bin/bash

set -e

AWS_ACCOUNT_ID="717546795560"
GITHUB_REPO="gesatessa/flask-app-devops"
BRANCH="main"
ROLE_NAME="GitHubActionsRole"
OIDC_PROVIDER_ARN="arn:aws:iam::$AWS_ACCOUNT_ID:oidc-provider/token.actions.githubusercontent.com"

echo "🔐 Creating IAM role: $ROLE_NAME for GitHub OIDC access..."

# Step 1: Create OIDC provider if it doesn't exist
if ! aws iam get-open-id-connect-provider --open-id-connect-provider-arn "$OIDC_PROVIDER_ARN" >/dev/null 2>&1; then
  echo "🔗 OIDC provider not found, creating..."
  aws iam create-open-id-connect-provider \
    --url https://token.actions.githubusercontent.com \
    --client-id-list sts.amazonaws.com \
    --thumbprint-list "6938fd4d98bab03faadb97b34396831e3780aea1"
else
  echo "🔗 OIDC provider already exists."
fi

# Step 2: Define the desired trust policy
TRUST_POLICY=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "$OIDC_PROVIDER_ARN"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com",
          "token.actions.githubusercontent.com:sub": "repo:$GITHUB_REPO:ref:refs/heads/$BRANCH"
        }
      }
    }
  ]
}
EOF
)

echo "$TRUST_POLICY" > trust-policy.json

# Step 3: If role exists, inspect trust policy and compare GitHub repo/branch
if aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
  echo "⚠️  IAM role '$ROLE_NAME' already exists."

  CURRENT_SUB=$(aws iam get-role \
    --role-name "$ROLE_NAME" \
    --query "Role.AssumeRolePolicyDocument.Statement[0].Condition.StringEquals.\"token.actions.githubusercontent.com:sub\"" \
    --output text)

  CURRENT_REPO=$(echo "$CURRENT_SUB" | cut -d':' -f2)
  CURRENT_BRANCH=$(echo "$CURRENT_SUB" | cut -d':' -f4)

  echo "🔍 Current trusted GitHub repo: $CURRENT_REPO"
  echo "🔍 Current trusted branch: $CURRENT_BRANCH"

  if [[ "$CURRENT_REPO" != "$GITHUB_REPO" || "$CURRENT_BRANCH" != "$BRANCH" ]]; then
    echo "⚠️  The role is currently configured for a different repo or branch."
    echo "💡 Desired: repo=$GITHUB_REPO branch=$BRANCH"
    read -p "❓ Do you want to delete and recreate the role with updated trust policy? [y/N]: " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
      echo "🗑️ Deleting existing IAM role..."
      aws iam delete-role-policy --role-name "$ROLE_NAME" --policy-name GitHubECRPushPolicy || true
      aws iam delete-role --role-name "$ROLE_NAME"
    else
      echo "🚫 Aborted by user. Role was not modified."
      rm trust-policy.json
      exit 0
    fi
  else
    echo "✅ The existing role is already configured for repo=$GITHUB_REPO and branch=$BRANCH."
    rm trust-policy.json
    exit 0
  fi
fi

# Step 4: Create the IAM role
aws iam create-role \
  --role-name "$ROLE_NAME" \
  --assume-role-policy-document file://trust-policy.json

# Step 5: Attach ECR permissions
aws iam put-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-name GitHubECRPushPolicy \
  --policy-document '{
    "Version": "2012-10-17",
    "Statement": [
      {
        "Effect": "Allow",
        "Action": [
          "ecr:GetAuthorizationToken",
          "ecr:BatchCheckLayerAvailability",
          "ecr:CompleteLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:InitiateLayerUpload",
          "ecr:PutImage"
        ],
        "Resource": "*"
      }
    ]
  }'

echo "✅ IAM role '$ROLE_NAME' created and ready to use."
echo "🔗 Role ARN: arn:aws:iam::$AWS_ACCOUNT_ID:role/$ROLE_NAME"

# Cleanup
rm trust-policy.json
