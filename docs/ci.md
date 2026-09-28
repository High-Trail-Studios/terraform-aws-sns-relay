# CI

`.github/workflows/test.yml` runs on every pull request to `main`, every push
to `main`, weekly (Mondays 06:17 UTC), and on demand.

| Job | What it checks |
|-----|----------------|
| `python` | Unit tests on Python 3.14, the Lambda runtime |
| `terraform` | `fmt`, `validate`, `terraform test` (mocked AWS provider), and `validate` of `examples/basic` |
| `ci-passed` | Succeeds only if every job above succeeded. This is the one required check |
| `notify-failure` | On a failed scheduled or `main` run, publishes to an SNS topic |

No job has AWS credentials except `notify-failure`, and that one can only
publish to one topic.

**What CI does not cover:** the tests mock the AWS provider, so they prove
the module's wiring and input validation, not AWS behaviour. A real
`terraform apply` of `examples/basic` is still a manual check before a
release.

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
