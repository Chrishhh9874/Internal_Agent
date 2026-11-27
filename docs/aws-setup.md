# AWS One-time Setup (v1)

A click-by-click checklist for the one-time setup in [ci-cd-design.md §7](ci-cd-design.md#7-aws-resources-and-one-time-setup). Work top to bottom in **us-east-2**, and tick each box as you go. If something in the console differs from this list, write down what you actually chose; this file becomes the input for Terraform later.

Never paste the real account ID, ARNs or keys into this file. Keep the placeholders.

## Names

These names are proposals; change any of them before you start. If you change one, also update the GitHub repository variables (step 9) and anything else that uses it.

| Resource | Name |
|---|---|
| Region | `us-east-2` |
| ECR repository | `internal-agent-api` (created 2026-11-27 in step 1a) |
| S3 bundle bucket | `internal-agent-deploy-bundles-4f7k2q` (created 2026-11-26) |
| GitHub OIDC role | `internal-agent-github-actions` |
| EC2 instance role | `internal-agent-ec2` |
| CodeDeploy service role | `internal-agent-codedeploy` |
| CodeDeploy application | `internal-agent` |
| CodeDeploy deployment group | `internal-agent-api` |
| EC2 tag used by the deployment group | `DeployGroup` = `internal-agent-api` |
| CodePipeline | `internal-agent-pipeline` |

## 1. S3 bundle bucket

- [x] S3 → Create bucket. Region `us-east-2`, name `internal-agent-deploy-bundles-4f7k2q`.
- [x] Leave **Block all public access** on.
- [x] **Bucket Versioning: Enable.** Without versioning, CodePipeline never triggers.
- [x] Create.

Done 2026-11-26: general purpose bucket in the global namespace, ACLs disabled, SSE-S3, versioning confirmed Enabled under Properties.

## 1a. ECR repository

The notes said an ECR repository already existed, but a scan of every region on 2026-11-26 found none. The EC2 instance was confirmed in us-east-2 (m7i-flex.large, stopped).

- [x] Create the repository in us-east-2, from CloudShell or via ECR → Create repository with the default settings:

```bash
aws ecr create-repository --repository-name internal-agent-api --region us-east-2
```

- Keep tag mutability **Mutable** (the default). With Immutable, re-running a workflow whose push already succeeded would fail at `docker push`, because the SHA tag would already exist.
- No lifecycle policy in v1: old images are what a rollback would pull.

Done 2026-11-27 in the console: ECR → **Private registry** → Repositories → Create repository. Name `internal-agent-api`, Mutable, no mutable tag exclusions, AES-256, scan on push off (marked deprecated in the console). The URI is `<account-id>.dkr.ecr.us-east-2.amazonaws.com/internal-agent-api`.

## 2. GitHub OIDC identity provider

- [x] IAM → Identity providers. If `token.actions.githubusercontent.com` is already listed, skip this step.
- [x] Otherwise: Add provider → OpenID Connect.
  - Provider URL: `https://token.actions.githubusercontent.com`
  - Audience: `sts.amazonaws.com`

Done 2026-11-26 through CloudShell, because this account's simplified IAM console has no Identity providers entry in the sidebar (only Roles, Policies, IAM users, Root access management):

```bash
aws iam list-open-id-connect-providers      # was empty
aws iam create-open-id-connect-provider \
  --url https://token.actions.githubusercontent.com \
  --client-id-list sts.amazonaws.com
```

It returned `arn:aws:iam::<account-id>:oidc-provider/token.actions.githubusercontent.com`.

## 3. GitHub OIDC role

- [x] IAM → Roles → Create role → **Web identity**.
  - Identity provider `token.actions.githubusercontent.com`, audience `sts.amazonaws.com`.
  - GitHub organization: `<owner>`. Repository: `<repo>`. Branch: `main`.
- [x] Skip the managed policies. Name it `internal-agent-github-actions` and create it.
- [x] Open the role → Trust relationships. Check that the condition limits `sub` to the main branch of this repo. Because this repo uses GitHub's **immutable subject** format, that is `repo:Chrishhh9874@170212786/Internal_Agent@1413579455:ref:refs/heads/main` (see the fix note below).

Done 2026-11-27. This account's console has no **Web identity** option (only AWS service, AWS account and Custom trust policy), so the role was created with **Custom trust policy** and this JSON. No managed policies were attached.

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {
      "Federated": "arn:aws:iam::<account-id>:oidc-provider/token.actions.githubusercontent.com"
    },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "token.actions.githubusercontent.com:aud": "sts.amazonaws.com",
        "token.actions.githubusercontent.com:sub": "repo:Chrishhh9874@170212786/Internal_Agent@1413579455:ref:refs/heads/main"
      }
    }
  }]
}
```

**Fix on 2026-11-27.** The role was first created with `sub` = `repo:Chrishhh9874/Internal_Agent:ref:refs/heads/main`. The first push to main then failed at Configure AWS credentials with `Not authorized to perform sts:AssumeRoleWithWebIdentity`.
- Cause: the repo has GitHub's immutable OIDC subject turned on. Its `sub` embeds the owner and repo IDs, and `gh api repos/Chrishhh9874/Internal_Agent/actions/oidc/customization/sub` returns `"use_immutable_subject":true` with `"sub_claim_prefix":"repo:Chrishhh9874@170212786/Internal_Agent@1413579455"`.
- Fix: edit the trust policy so `sub` uses that prefix, as shown above.
- The IDs are public and not secrets. They keep the role safe even if the repo were deleted and someone recreated one with the same name.
- If a future repo has this setting, read `sub_claim_prefix` first and build the condition from it.

- [x] Permissions → Add permissions → Create inline policy → JSON. Name it `ecr-push-and-bundle-upload`. Fill in `<account-id>`. (Done 2026-11-27; shows as type Customer inline.)

```json
{
  "Version": "2012-10-17",
  "Statement": [
    { "Effect": "Allow", "Action": "ecr:GetAuthorizationToken", "Resource": "*" },
    {
      "Effect": "Allow",
      "Action": [
        "ecr:BatchCheckLayerAvailability",
        "ecr:InitiateLayerUpload",
        "ecr:UploadLayerPart",
        "ecr:CompleteLayerUpload",
        "ecr:PutImage",
        "ecr:BatchGetImage"
      ],
      "Resource": "arn:aws:ecr:us-east-2:<account-id>:repository/internal-agent-api"
    },
    {
      "Effect": "Allow",
      "Action": "s3:PutObject",
      "Resource": "arn:aws:s3:::internal-agent-deploy-bundles-4f7k2q/bundle.zip"
    }
  ]
}
```

**Fix on 2026-11-27: added `ecr:BatchGetImage`.** After the OIDC fix, the first real push uploaded every layer, then failed on `HEAD …/v2/internal-agent-api/manifests/sha256:… : 403 Forbidden`.
- The runner's Docker checks whether each manifest already exists before writing it, and that HEAD request needs `ecr:BatchGetImage`.
- The five classic push actions don't cover it.
- `BatchGetImage` is read-only and scoped to this one repo.

- [ ] Copy the role ARN for step 9. It goes into a GitHub variable, not into the repo.

## 4. EC2 instance role

- [x] IAM → Roles → Create role → **AWS service → EC2**.
- [x] Attach the managed policy `AmazonEC2ContainerRegistryReadOnly`. Name it `internal-agent-ec2` and create it.
- [x] Add an inline policy that lets the agent download the bundle. Named `read-deploy-bundle` (done 2026-11-27; the console also created an instance profile with the same name):

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": ["s3:GetObject", "s3:GetObjectVersion"],
    "Resource": ["arn:aws:s3:::internal-agent-deploy-bundles-4f7k2q/*"]
  }]
}
```

- [x] EC2 → the instance → Actions → Security → **Modify IAM role** → `internal-agent-ec2`. (Done 2026-11-27; the instance's Security tab shows the role. The managed policy was confirmed to be `AmazonEC2ContainerRegistryReadOnly`.)
- [ ] The CodePipeline artifact bucket gets added to this policy in step 8, once the bucket exists.

## 5. CodeDeploy service role

- [x] IAM → Roles → Create role → **AWS service → CodeDeploy**, use case **CodeDeploy**. This attaches `AWSCodeDeployRole`.
- [x] Name it `internal-agent-codedeploy` and create it. (Done 2026-11-27.)

## 6. EC2 host

- [ ] EC2 → the instance → Tags → add `DeployGroup` = `internal-agent-api`.
- [x] Security group: HTTP (80) is open, because the container is published on port 80. SSH should come from **My IP**, not `0.0.0.0/0`.
  - Before (2026-11-27): `launch-wizard-1` allowed 22, 80 and 443 from `0.0.0.0/0`, and all outbound traffic.
  - Done 2026-11-27: the port 22 source changed to My IP (Security Groups → `launch-wizard-1` → Edit inbound rules). 80 and 443 still allow `0.0.0.0/0`. SSH from the Mac with the key pair; the console's EC2 Instance Connect no longer gets through. When your network (and public IP) changes, update this rule.
  - Outbound must stay open: the host needs it for apt, ECR, S3 and the CodeDeploy endpoints.
- [x] SSH in and install Docker and the AWS CLI. Done 2026-11-27 on Ubuntu 26.04.1 (x86_64), which has a 6.6 GB root volume. Ports 80 and 8000 were free beforehand. Use `docker.io` from apt and the official AWS CLI v2 installer, not the snap packages Ubuntu suggests. SSH with the full key path: `ssh -i ~/.ssh/internal-agent-key-pair.pem ubuntu@<public-ip>`.

```bash
sudo apt-get update
sudo apt-get install -y docker.io unzip curl wget
sudo systemctl enable --now docker
sudo docker run --rm hello-world

curl -sSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o awscliv2.zip
unzip -q awscliv2.zip && sudo ./aws/install
aws --version
```

- [x] Install the CodeDeploy agent **v2** from the us-east-2 bucket. Note the `latestv2/` prefix. Done 2026-11-27: agent `2.1.4` (amd64 `.deb`; the installer also pulled in `gdebi-core`). The systemd unit `codedeploy-agent.service` is enabled and active (running), with the binary at `/opt/codedeploy-agent/bin/codedeploy-agent`.

```bash
wget https://aws-codedeploy-us-east-2.s3.us-east-2.amazonaws.com/latestv2/install
chmod +x ./install
sudo ./install auto
systemctl status codedeploy-agent --no-pager
```

  Why `latestv2/` (found 2026-11-27, design Q6):
  - `latest/install` is the frozen 1.x installer. It needs Ruby and only accepts certain versions. On Ubuntu 26.04 (Ruby 3.3.8) it fails with `Current running Ruby version for root is 3.3.8, but Ruby version 2.x, 3.x needs to be installed`, and no service gets created.
  - Agent 2.0.0 and later is a single Rust binary with no Ruby dependency. Its README lists Ubuntu 16.04–26.04 as supported, and the AWS install guide for Ubuntu uses `latestv2/install` for 2.0.x and later.
  - A running agent's status shows "The AWS CodeDeploy agent is running."

- [x] If the agent was installed before the role was attached: `sudo systemctl restart codedeploy-agent`. (Not needed here: the role was attached first, on 2026-11-27.)
- [x] Check the identity: `aws sts get-caller-identity` should show `assumed-role/internal-agent-ec2/i-…`. (Done 2026-11-27. The agent journal shows one restart by the installer's update check, then the agent stays active.)

## 7. Manual rehearsal (implementation steps 3 and 4)

On your Mac, from the repo root. `--platform linux/amd64` is required, because the Mac is arm64 and EC2 is x86_64.

```bash
REGISTRY=<account-id>.dkr.ecr.us-east-2.amazonaws.com
aws ecr get-login-password --region us-east-2 | docker login --username AWS --password-stdin "$REGISTRY"
docker build --platform linux/amd64 -t "$REGISTRY/internal-agent-api:manual-test" .
docker push "$REGISTRY/internal-agent-api:manual-test"
```

Done 2026-11-27. The Mac had no AWS CLI credentials at first (`Unable to locate credentials`). `aws login` gave temporary console-session credentials as `assumed-role/AccountFullAccessRole/…`, with no long-lived keys. The push shows up in ECR as three entries:
- `manual-test`, an **Image Index**
- two untagged **Image** entries: the linux/amd64 image (about 52 MB) and a 0 MB attestation manifest that Docker Desktop's BuildKit adds

The untagged entries belong to the index. Don't delete them.

On EC2, these are the same commands as `pull.sh` and `start.sh`:

```bash
REGISTRY=<account-id>.dkr.ecr.us-east-2.amazonaws.com
aws ecr get-login-password --region us-east-2 | sudo docker login --username AWS --password-stdin "$REGISTRY"
sudo docker pull "$REGISTRY/internal-agent-api:manual-test"
sudo docker rm -f internal-agent || true
sudo docker run -d --name internal-agent --restart unless-stopped -p 80:8000 "$REGISTRY/internal-agent-api:manual-test"
curl -f http://localhost/api/health
```

- [x] `curl` on EC2 returns `{"status":"ok"}`.
- [x] From your Mac, `curl http://<ec2-public-ip>/api/health` returns the same. The public IP changes after a stop and start.

Done 2026-11-27:
- On EC2, the pulled digest matched the `manual-test` Image Index in ECR.
- The first `curl` right after `docker run` returned `(52) Empty reply from server`, because uvicorn was still starting. A few seconds later it returned 200. This is why `validate.sh` retries.
- From the Mac, the public IP returned HTTP 200 in about 0.13 s.
- The `internal-agent` container from this rehearsal is still running. The first pipeline deploy replaces it through `start.sh`.

## 8. CodeDeploy and CodePipeline

- [x] CodeDeploy → Applications → Create application: `internal-agent`, compute platform **EC2/On-premises**.
- [x] In it, create a deployment group. Done 2026-11-27: In-place, service role `internal-agent-codedeploy`, `CodeDeployDefault.AllAtOnce`, Rollback enabled False, tag `DeployGroup=internal-agent-api`, no triggers or alarms.
  - Name `internal-agent-api`, service role `internal-agent-codedeploy`, deployment type **In-place**.
  - Environment: **Amazon EC2 instances**, tag `DeployGroup` = `internal-agent-api`. It should match 1 instance.
  - Agent install: **Never**, because it is already installed.
  - Deployment settings: `CodeDeployDefault.AllAtOnce`.
  - Load balancer: off. Rollbacks: off (v1).
- [x] CodePipeline → Create pipeline → build a custom pipeline, name `internal-agent-pipeline`, new service role, default artifact store. Done 2026-11-27:
  - Execution mode Superseded, service role `AWSCodePipelineServiceRole-us-east-2-internal-agent-pipeline`, artifacts encrypted with the default AWS managed key.
  - Source: EventBridge rule on, automatic retry on.
  - Deploy: **automatic rollback on stage failure unchecked**, matching the deployment group's rollback off; automatic retry also off.
  - Source: **Amazon S3**, bucket `internal-agent-deploy-bundles-4f7k2q`, object key `bundle.zip`. Keep the default (recommended) change detection.
  - Build: skip. Test: skip.
  - Deploy: **AWS CodeDeploy**, application `internal-agent`, deployment group `internal-agent-api`.
- [x] The first execution fails because `bundle.zip` doesn't exist yet. That is expected. (2026-11-27: Source failed, Deploy didn't run.)
- [x] Pipeline → Settings → note the artifact store bucket (`codepipeline-us-east-2-…`). Add `arn:aws:s3:::<codepipeline-artifact-bucket>/*` to the `internal-agent-ec2` inline policy from step 4.
  - Done 2026-11-27. The artifact bucket is `codepipeline-us-east-2-d435ad8d1f6a-469a-b51b-1d4647b29822`, found with `aws codepipeline get-pipeline --name internal-agent-pipeline --query 'pipeline.artifactStore.location' --output text`.
  - `read-deploy-bundle` now allows `s3:GetObject` and `s3:GetObjectVersion` on `arn:aws:s3:::internal-agent-deploy-bundles-4f7k2q/*` and `arn:aws:s3:::codepipeline-us-east-2-d435ad8d1f6a-469a-b51b-1d4647b29822/*`.
  - Pitfall: an S3 ARN has no region or account. It is `arn:aws:s3:::<bucket>/*`, never the pipeline's ARN with `s3` in front.

## 9. GitHub repository variables

- [x] GitHub repo → Settings → Secrets and variables → Actions → **Variables** tab (done 2026-11-27; checked with `gh variable list`):

| Variable | Value |
|---|---|
| `AWS_ROLE_ARN` | ARN of `internal-agent-github-actions` |
| `AWS_REGION` | `us-east-2` |
| `ECR_REPOSITORY` | `internal-agent-api` |
| `BUNDLE_BUCKET` | `internal-agent-deploy-bundles-4f7k2q` |

- [x] No secrets are needed. Make sure there is no `AWS_ACCESS_KEY_ID` under Secrets. (`gh secret list` is empty.)

## 10. First pipeline run

- [x] Open a pull request. The run should show `test` and `build` (build plus smoke test) passing, with every AWS step skipped. (PR #2, 2026-11-27: green, all five AWS steps skipped.)
- [x] Merge it. Follow it through. Merge commit `cd7472d`, 2026-11-27; it took two fixes before it went green, see step 3:
  - Attempt 1 failed at Configure AWS credentials: the trust policy needed the immutable `sub` format.
  - Attempt 2 failed at the manifest push with 403: the role needed `ecr:BatchGetImage`.
  - Attempt 3 was green.
  - **Actions:** every step is green, and the log prints `IMAGE=…:<sha>`.
  - **S3:** `bundle.zip` has a new version.
  - **CodePipeline:** a new execution has started.
  - **CodeDeploy:** all lifecycle events succeed.
  - Observed on attempt 3:
    - `bundle.zip` got a new S3 version at 07:18:58Z.
    - Three seconds later the pipeline started (trigger `CloudWatchEvent`, the EventBridge rule) and Succeeded.
    - Deployment `d-ARZ9NKQRL` took 39 s, with every lifecycle event Succeeded. ValidateService took about 3 s, so one retry.
- [x] On EC2, the tag in `sudo docker ps` equals `git rev-parse origin/main`. (2026-11-27: `internal-agent-api:cd7472df4f86366eae896072c12b9b58dde127fe`, which replaced the rehearsal's `manual-test` container.)
- [x] `curl http://<ec2-public-ip>/api/health` works. (HTTP 200 from the Mac after the deploy.)
- [ ] Merge a second small change and check that the SHA on EC2 moves again.
- [x] Read the agent log to see which bucket the bundle was downloaded from (design Q5): `/opt/codedeploy-agent/deployment-root/deployment-logs/codedeploy-agent-deployments.log`.
  - Answered from the deployment itself: `aws deploy get-deployment` shows the revision at `codepipeline-us-east-2-d435ad8d1f6a-469a-b51b-1d4647b29822/internal-agent-pipel/SourceArti/…zip`.
  - So pipeline deploys read the **artifact bucket**.

If something fails, use the troubleshooting section in [ci-cd-design.md §9](ci-cd-design.md#9-verification-and-troubleshooting).
