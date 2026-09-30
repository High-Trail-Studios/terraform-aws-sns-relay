# CI

`.github/workflows/test.yml` runs on every pull request to `main`, every push
to `main`, weekly (Mondays 06:17 UTC), and on demand.

| Job | What it checks |
|-----|----------------|
| `python` | Unit tests on Python 3.14, the Lambda runtime |
| `terraform` | `fmt`, `validate`, `terraform test` (mocked AWS provider), and `validate` of `examples/basic` and `tests/e2e` |
| `ci-passed` | Succeeds only if every job above succeeded. This is the one required check |
| `notify-failure` | On a failed scheduled or `main` run, publishes to an SNS topic |

No job in `test.yml` has AWS credentials except `notify-failure`, and that
one can only publish to one topic. Real AWS testing lives in a separate
workflow; see [End-to-end tests](#end-to-end-tests-real-aws).

Two GitHub limits to know about:
- GitHub disables scheduled workflows after 60 days with no repository
  activity. Re-enable the workflow from the Actions tab if that happens.
- Scheduled runs can start late under load. Don't rely on the exact time.

## Blocking merges on red CI

Require the `ci-passed` check on `main`:

```sh
gh api -X PUT repos/<owner>/<repo>/branches/main/protection --input - <<'EOF'
{
  "required_status_checks": { "strict": true, "checks": [{ "context": "ci-passed" }] },
  "enforce_admins": true,
  "required_pull_request_reviews": null,
  "restrictions": null
}
EOF
```

Branch protection and rulesets are **not available on private repositories
in a Free GitHub organization**. On that plan the workflow still runs on
every PR, but GitHub won't block the merge. Make the repository public or
upgrade the plan to enforce it.

## Failure alerts through SNS (optional)

This dogfoods the relay: a failed run publishes to an SNS topic that an
sns-relay deployment forwards to Slack or elsewhere. It uses GitHub OIDC,
so no long-lived AWS keys are stored in GitHub.

1. **Topic.** Add a route to an sns-relay deployment (e.g. `ci-alerts`) and
   note its topic ARN.

2. **OIDC provider.** Create it once per AWS account if it doesn't exist:

   ```sh
   aws iam create-open-id-connect-provider \
     --url https://token.actions.githubusercontent.com \
     --client-id-list sts.amazonaws.com
   ```

3. **Role.** Only workflow runs on this repo's `main` branch can assume it,
   and it can only publish to the one topic. Scheduled runs use the default
   branch, so they match.

   Trust policy:
   ```json
   {
     "Version": "2012-10-17",
     "Statement": [{
       "Effect": "Allow",
       "Principal": { "Federated": "arn:aws:iam::<account-id>:oidc-provider/token.actions.githubusercontent.com" },
       "Action": "sts:AssumeRoleWithWebIdentity",
       "Condition": {
         "StringEquals": {
           "token.actions.githubusercontent.com:aud": "sts.amazonaws.com",
           "token.actions.githubusercontent.com:sub": "repo:<owner>/<repo>:ref:refs/heads/main"
         }
       }
     }]
   }
   ```

   Permission policy:
   ```json
   {
     "Version": "2012-10-17",
     "Statement": [{
       "Effect": "Allow",
       "Action": "sns:Publish",
       "Resource": "<topic-arn>"
     }]
   }
   ```

   If the topic uses a customer-managed KMS key, also allow
   `kms:GenerateDataKey` and `kms:Decrypt` on that key.

   **Renaming the repository changes the `sub` claim.** Update the trust
   policy when you rename the repository, or alerts will fail with an
   AssumeRole error.

4. **Repository variables.** These are variables, not secrets, because none
   of the values is a credential:

   ```sh
   gh variable set CI_ALERT_ROLE_ARN  --body "arn:aws:iam::<account-id>:role/<role-name>"
   gh variable set CI_ALERT_TOPIC_ARN --body "<topic-arn>"
   gh variable set CI_ALERT_REGION    --body "<region>"
   ```

5. **Test it.** Check the delivery path with
   `aws sns publish --topic-arn <topic-arn> --message test`. The role trusts
   `main` only, so a failing test branch can't exercise the workflow step.
   The first real failure on `main` or a scheduled run will.

Until `CI_ALERT_TOPIC_ARN` is set, `notify-failure` is skipped. GitHub still
emails whoever last changed the workflow file when a scheduled run fails.

If the relay that receives these alerts is itself broken, the alert ends up
in that relay's DLQ instead of reaching you. That relay's DLQ alarm
(`create_dlq_alarm`) is what catches that case.

## End-to-end tests (real AWS)

`.github/workflows/e2e.yml` deploys the module into a dedicated test AWS
account, sends real alerts through it, and destroys everything. The unit and
`terraform test` suites mock AWS; this is the check that the module actually
works there.

It runs on pull requests to `main` that touch `*.tf`, `src/`, `tests/e2e/`
or the workflow itself, weekly (Mondays 07:17 UTC), and on demand. Each run:

1. Applies `tests/e2e/`: the module with two `webhook` routes, plus a
   throwaway receiver Lambda behind a function URL. Every name starts with
   `ci-e2e-<run id>-<attempt>`, so parallel runs don't collide.
2. Runs `tests/e2e/run.sh`, which publishes one alert to each route and
   checks that:
   - the `ok` alert reaches the receiver with the correct `Authorization`
     header (the receiver rejects anything else with 401);
   - the `missing` alert, whose route has no SSM parameter, lands in the
     DLQ as a Lambda on-failure record.
3. Destroys everything, even if an earlier step failed or the run was
   cancelled.

A run takes about five minutes and costs effectively nothing: everything is
billed per request, well inside the free tier, and lives for minutes.

**What it does not cover:** Slack, the heartbeat, SNS-side redrive, KMS
options, existing topics, and a caller-supplied code bucket. It runs the
module with `max_retry_attempts = 0` so failures reach the DLQ quickly, which
means it does not exercise Lambda's retry timing.

### Limits

- **Fork PRs skip it.** GitHub gives fork PRs no secrets or OIDC token. A
  maintainer can run the workflow on demand after reviewing the change.
- **It is not part of `ci-passed`.** Because of the path filter, it doesn't
  run on every PR, and a required check that never reports would block the
  merge. Read its result on the PR before merging.
- **The receiver's function URL is public** for the few minutes of the run.
  It returns 401 unless the request has that run's random token.
- **Test secrets are stored in Terraform state.** Unlike a real deployment,
  the fixture creates its own SSM parameters so that destroy removes them.
  The state is on the runner and is discarded with it. The values are the
  receiver's URL and a token generated for that run, and both stop working
  when the run ends.
- **Destroy is the only cleanup.** State is local to the runner. If the
  runner dies between apply and destroy (rare, but possible), the resources
  are left behind and nothing tracks them. The job fails loudly when
  destroy fails. To find leftovers:

  ```sh
  aws resourcegroupstaggingapi get-resources \
    --tag-filters Key=ManagedBy,Values=sns-relay-e2e \
    --query 'ResourceTagMappings[].ResourceARN'
  aws iam list-roles --query "Roles[?starts_with(RoleName, 'ci-e2e-')].RoleName"
  aws ssm describe-parameters \
    --parameter-filters Key=Name,Option=BeginsWith,Values=/ci-e2e- \
    --query 'Parameters[].Name'
  ```

  Put an AWS Budgets alert on the test account as a backstop.

### Setup

1. **A dedicated AWS account.** The CI role can create IAM roles and pass
   them to Lambda functions it controls. That is effectively admin inside
   the account, however tightly the names are scoped. Keep nothing else in
   it.

2. **OIDC provider** in that account (same command as in the SNS alert
   setup below).

3. **Role.** Trust policy. The `pull_request` subject covers same-repository
   PRs; the `main` subject covers scheduled runs and on-demand runs from
   `main`:

   ```json
   {
     "Version": "2012-10-17",
     "Statement": [{
       "Effect": "Allow",
       "Principal": { "Federated": "arn:aws:iam::<account-id>:oidc-provider/token.actions.githubusercontent.com" },
       "Action": "sts:AssumeRoleWithWebIdentity",
       "Condition": {
         "StringEquals": {
           "token.actions.githubusercontent.com:aud": "sts.amazonaws.com",
           "token.actions.githubusercontent.com:sub": [
             "repo:<owner>/<repo>:pull_request",
             "repo:<owner>/<repo>:ref:refs/heads/main"
           ]
         }
       }
     }]
   }
   ```

   To run it on demand from another branch, add that branch's `ref`
   subject.

   Permission policy. Everything is scoped to the `ci-e2e-` prefix that the
   fixture enforces:

   ```json
   {
     "Version": "2012-10-17",
     "Statement": [
       { "Sid": "Sns", "Effect": "Allow", "Action": "sns:*",
         "Resource": "arn:aws:sns:*:<account-id>:ci-e2e-*" },
       { "Sid": "Sqs", "Effect": "Allow", "Action": "sqs:*",
         "Resource": "arn:aws:sqs:*:<account-id>:ci-e2e-*" },
       { "Sid": "Lambda", "Effect": "Allow", "Action": "lambda:*",
         "Resource": "arn:aws:lambda:*:<account-id>:function:ci-e2e-*" },
       { "Sid": "Logs", "Effect": "Allow", "Action": "logs:*",
         "Resource": "arn:aws:logs:*:<account-id>:log-group:/aws/lambda/ci-e2e-*" },
       { "Sid": "LogsDescribe", "Effect": "Allow", "Action": "logs:DescribeLogGroups",
         "Resource": "*" },
       { "Sid": "Ssm", "Effect": "Allow",
         "Action": ["ssm:PutParameter", "ssm:GetParameter", "ssm:GetParameters",
                    "ssm:DeleteParameter", "ssm:AddTagsToResource",
                    "ssm:RemoveTagsFromResource", "ssm:ListTagsForResource"],
         "Resource": "arn:aws:ssm:*:<account-id>:parameter/ci-e2e-*" },
       { "Sid": "SsmDescribe", "Effect": "Allow", "Action": "ssm:DescribeParameters",
         "Resource": "*" },
       { "Sid": "CodeBucket", "Effect": "Allow", "Action": "s3:*",
         "Resource": ["arn:aws:s3:::ci-e2e-*", "arn:aws:s3:::ci-e2e-*/*"] },
       { "Sid": "Roles", "Effect": "Allow",
         "Action": ["iam:CreateRole", "iam:DeleteRole", "iam:GetRole",
                    "iam:TagRole", "iam:UntagRole", "iam:UpdateAssumeRolePolicy",
                    "iam:PutRolePolicy", "iam:GetRolePolicy", "iam:DeleteRolePolicy",
                    "iam:ListRolePolicies", "iam:ListAttachedRolePolicies",
                    "iam:ListInstanceProfilesForRole"],
         "Resource": "arn:aws:iam::<account-id>:role/ci-e2e-*" },
       { "Sid": "PassRolesToLambda", "Effect": "Allow", "Action": "iam:PassRole",
         "Resource": "arn:aws:iam::<account-id>:role/ci-e2e-*",
         "Condition": { "StringEquals": { "iam:PassedToService": "lambda.amazonaws.com" } } },
       { "Sid": "FindLeftovers", "Effect": "Allow",
         "Action": ["tag:GetResources", "iam:ListRoles"], "Resource": "*" }
     ]
   }
   ```

   The fixture turns off the DLQ alarm and the heartbeat, so no CloudWatch
   alarm or EventBridge permissions are needed. If a run fails with
   `AccessDenied`, the error names the missing action.

4. **Repository secret and variable:**

   ```sh
   gh secret set AWS_TF_TEST_ACCESS_ROLE --body "arn:aws:iam::<account-id>:role/<role-name>"
   gh variable set AWS_TF_TEST_REGION --body "us-east-1"   # optional, this is the default
   ```

   The role ARN is a secret so that the test account ID stays out of the
   logs. The workflow also masks the account ID in the credentials step.
   Set it as a **repository** secret: on the GitHub Free plan, private
   repositories can't read organization secrets.

**Renaming the repository changes the `sub` claim**, the same as for the
SNS alert role.
