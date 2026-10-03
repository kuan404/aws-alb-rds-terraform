# AWS VPC + ALB + EC2 + RDS — Terraform

A VPC-based AWS stack provisioned with Terraform: a 2-AZ VPC, public/private subnetting, an internet-facing Application Load Balancer, a single EC2 web server (SSM-managed, no SSH), and a private MySQL RDS instance.

## Architecture

```
                                    INTERNET
                                       │
                                       ▼
                          ┌─────────────────────┐
                          │  Internet Gateway   │
                          └─────────────────────┘
                                       │
        ┌──────────────────────────────┴──────────────────────────────┐
        │                    VPC — 10.0.0.0/16                        │
        │                                                             │
        │   PUBLIC SUBNETS (route → IGW)                              │
        │   ┌─────────────────────┐   ┌─────────────────────┐         │
        │   │ 10.0.1.0/24 (AZ-a)  │   │ 10.0.2.0/24 (AZ-b)  │         │
        │   │                     │   │                     │         │
        │   │  [ALB, SG: alb] ────┼───┼── spans both AZs ───┤         │
        │   │  [NAT GW + EIP]     │   │                     │         │
        │   └─────────────────────┘   └─────────────────────┘         │
        │              │ (0.0.0.0/0 via NAT, for private subnets)     │
        │              ▼                                              │
        │   PRIVATE SUBNETS (route → NAT GW)                          │
        │   ┌─────────────────────┐   ┌─────────────────────┐         │
        │   │ 10.0.11.0/24 (AZ-a) │   │ 10.0.12.0/24 (AZ-b) │         │
        │   │  [EC2, SG: ec2] ────┼──> registered in ALB    │         │
        │   │  (instance lives    │   │ target group :80    │         │
        │   │   here only)        │   │                     │         │
        │   │                     │   │                     │         │
        │   │  [RDS MySQL ────────┼───┼─ DB subnet group    │         │
        │   │   SG: rds]          │   │  spans both AZs]    │         │
        │   └─────────────────────┘   └─────────────────────┘         │
        │                                                             │
        └─────────────────────────────────────────────────────────────┘

SECURITY GROUP CHAIN (each ring trusts only the one before it):
Internet ──:80──▶ [alb-sg] ──:80──▶ [ec2-sg] ──:3306──▶ [rds-sg]

EC2 has no SSH rule — admin access is via AWS Systems Manager
Session Manager, through an IAM instance profile (AmazonSSMManagedInstanceCore).
```

**Traffic flow:** User → ALB (public subnets, both AZs) → EC2 (private subnet, AZ-a) on port 80 → EC2 queries RDS on port 3306 (private subnet, same AZ) → EC2's own outbound internet access (package installs) goes out through the single NAT Gateway in `public[0]`.

## Services provisioned

| Service | Resource(s) | Notes |
|---|---|---|
| VPC | `aws_vpc.main` | `10.0.0.0/16`, DNS support + hostnames enabled |
| Subnetting | `aws_subnet.public` / `aws_subnet.private` | 2 public + 2 private, spread across 2 AZs via `data.aws_availability_zones` |
| Routing | `aws_internet_gateway`, `aws_nat_gateway`, `aws_eip`, `aws_route_table` × 2 | Public → IGW; private → NAT Gateway |
| Security | `aws_security_group.alb/ec2/rds` | Layered: internet → ALB → EC2 → RDS, each referencing the SG in front of it |
| ALB | `aws_lb`, `aws_lb_target_group`, `aws_lb_listener` | Internet-facing, HTTP:80, health check on `/` |
| IAM | `aws_iam_role.ec2`, `aws_iam_instance_profile.ec2` | Grants EC2 `AmazonSSMManagedInstanceCore` for Session Manager access |
| EC2 | `aws_instance.app` | Single instance, Amazon Linux 2023 (latest AMI via data source), private subnet, no public IP |
| RDS | `aws_db_instance.main`, `aws_db_subnet_group.main` | MySQL 8.0, private, `publicly_accessible = false`, spans both private subnets |

## Apache test page

The EC2 instance's `user_data` bootstraps the AWS re/Start lab web app on first boot:

```bash
dnf install -y httpd wget php mariadb105-server
wget https://aws-tc-largeobjects.s3.us-west-2.amazonaws.com/CUR-TF-100-RESTRT-1/267-lab-NF-build-vpc-web-server/s3/lab-app.zip
unzip lab-app.zip -d /var/www/html/
systemctl enable httpd
systemctl start httpd
```

This installs Apache, PHP, and MariaDB client tooling, then deploys a small pre-built PHP app (not just a static placeholder page) so the ALB health check on `/` has something real to hit, and so RDS connectivity can be demonstrated end-to-end if the app is pointed at the database.

## Deployment steps

### 1. Prerequisites
- Terraform `>= 1.3` installed
- AWS CLI installed and authenticated (`aws configure` or SSO) — credentials are picked up automatically by the provider; none are hardcoded in this repo
- Confirm your AWS account/region has at least 2 Availability Zones available in `ap-southeast-1` (or whichever region you set)

### 2. Set required variables
This repo deploys using a `terraform.tfvars` file (gitignored — see below), which overrides the region default from `variables.tf`:
```hcl
aws_region   = "ap-southeast-1"
project_name = "assessment"
db_password  = "YourSecurePasswordHere"
```

**Copy `terraform.tfvars.example` to `terraform.tfvars` and set a real password before applying** — the example file ships with a placeholder only, never a real credential. `db_password` has no default in `variables.tf` on purpose, so Terraform will prompt for it interactively if you skip this step.

### 3. Initialize, plan, apply
```bash
terraform init
terraform plan
terraform apply
```
Type `yes` when prompted. Takes roughly 5–8 minutes — RDS provisioning is the slowest step.

### 4. Retrieve outputs
```bash
terraform output
```
Key values: `alb_dns_name` (to test the app), `rds_endpoint`, `ec2_instance_id`, `vpc_id`.

## Validation steps

1. **ALB reachability** — open `http://<alb_dns_name>` from `terraform output alb_dns_name` in a browser. Should return the deployed web app, not a timeout or 5xx.
2. **Target health** — in the AWS Console: EC2 → Target Groups → confirm the instance shows `healthy`.
3. **EC2 has no public IP** — EC2 → Instances → confirm "Public IPv4 address" is blank for `aws_instance.app`.
4. **EC2 is reachable without SSH** — Systems Manager → Session Manager → Start session → select the instance. Confirms the IAM instance profile and SSM agent are working, with no port 22 ever opened.
5. **RDS is private** — RDS → Databases → confirm "Publicly accessible" shows `No`.
6. **RDS subnet group spans both AZs** — RDS → Subnet groups → confirm both private subnets, in both AZs, are listed.
7. **Security group chain** — EC2 → Security Groups → confirm `ec2-sg` only allows inbound from `alb-sg` (not `0.0.0.0/0`), and `rds-sg` only allows inbound from `ec2-sg` on 3306.
8. **No port 3306 exposure** — confirm `rds-sg` has no rule with `cidr_blocks` containing `0.0.0.0/0` on port 3306.

## Key assumptions

- Single EC2 instance is intentional for this assessment scope — no Auto Scaling Group or multi-instance redundancy was required.
- RDS and EC2 share the same `private` subnet tier (no separate dedicated DB subnet tier) — acceptable here since both are already fully private and the DB subnet group still spans 2 AZs as required.
- A single NAT Gateway (not one per AZ) is used — acceptable cost/complexity trade-off for an assessment; in production this would be a single point of failure for private-subnet outbound traffic if that AZ went down.
- AWS credentials are assumed to be configured in the environment running Terraform (`aws configure` / env vars / SSO) rather than hardcoded — the provider block intentionally has no `access_key`/`secret_key`.
- `skip_final_snapshot` is left at its default (`false`) rather than overridden to `true` — a final snapshot will be taken if this stack is destroyed; adjust if faster teardown is preferred during testing.

## Security recommendations

- **No SSH access at all** — EC2 has no inbound rule on port 22. Administrative access is via **SSM Session Manager** instead, through the attached IAM instance profile. This avoids managing SSH keys and removes the most commonly flagged finding (`0.0.0.0/0` on port 22) entirely, rather than just restricting it to one IP.
- **RDS is fully private** — `publicly_accessible = false`, and the only inbound rule on `rds-sg` is sourced from `ec2-sg` by security-group reference (not a CIDR block), so only the EC2 tier can ever reach port 3306.
- **Least-privilege security group chaining** — each tier (ALB → EC2 → RDS) only accepts traffic from the specific security group in front of it, never a wider CIDR, except the ALB's deliberate `0.0.0.0/0:80` (required, since it's the public entry point).
- **`db_password` is never hardcoded** — declared as a `sensitive = true` variable with no default, intended to be supplied via `TF_VAR_db_password` or a gitignored `.tfvars` file.
- **Recommended hardening not yet implemented** (out of scope for this assessment, worth noting if asked): enabling RDS encryption at rest (`storage_encrypted = true`), enabling Multi-AZ on RDS for failover, adding a second NAT Gateway per AZ for HA, and adding HTTPS on the ALB via an ACM certificate instead of plain HTTP.

## Clean up

```bash
terraform destroy
```
RDS and the NAT Gateway both bill hourly — destroy promptly once validation is complete.

## Author

Eddie Kuan | [LinkedIn](https://www.linkedin.com/in/eddiekuan/)

